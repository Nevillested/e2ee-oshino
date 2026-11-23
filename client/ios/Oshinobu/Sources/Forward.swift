import OshinobuCore
import SwiftUI

// Пересылка — как у Android (ChatService.ForwardItem, ChatViewModel.forwardItemsOf/sendForwarded,
// ui/chat/ForwardScreen.kt): «Переслать» → список чатов → чат-получатель открывается с
// «Пересылается: N» над полем ввода; «отправить» уходит с пересылаемым (и своим текстом, если есть).

/// Что пересылается: текст, стикер (по id) или вложения — одно или альбом с подписью.
/// Вложения уходят заново загруженными, с новым ключом: на сервере файл привязан к получателю.
enum ForwardItem {
    case text(String)
    case sticker(String)
    case media(sourcePeerLogin: String, messages: [StoredMessage], caption: String?)
}

/// Сообщения как пересылаемые, в их порядке: альбом (общий groupId) и одиночное вложение —
/// одним .media с подписью, текст и стикер — как есть; звонки и нерасшифрованные — не пересылаются.
func forwardItems(of source: [StoredMessage], peerLogin: String) -> [ForwardItem] {
    var result: [ForwardItem] = []
    var i = 0
    while i < source.count {
        var group = [source[i]]
        if let gid = source[i].groupId {
            i += 1
            while i < source.count, source[i].groupId == gid {
                group.append(source[i])
                i += 1
            }
        } else {
            i += 1
        }
        let media = group.filter(\.isMedia)
        if !media.isEmpty {
            result.append(.media(sourcePeerLogin: peerLogin, messages: media, caption: group.first { !$0.isMedia }?.text))
            continue
        }
        for m in group where !m.isCallLog && !m.isUndecryptable {
            result.append(m.stickerId.map(ForwardItem.sticker) ?? .text(m.text))
        }
    }
    return result
}

/// Пересылка по порядку: тексты и стикеры — сразу, вложения — заново загруженными (файл из кэша
/// или докачивается). Идёт отдельной задачей: уход из чата пересылку не обрывает.
@MainActor
func sendForwarded(_ items: [ForwardItem], to target: ChatSummary, model: AppModel) {
    let core = model.core, toasts = model.toasts
    Task {
        for item in items {
            switch item {
            case let .text(text): await core.sendText(text, to: target)
            case let .sticker(id): await core.sendSticker(id, to: target, rememberRecent: false)
            case let .media(source, messages, caption):
                func file(_ m: StoredMessage) async throws -> URL { try await ChatMedia.file(m, peerLogin: source, core: core) }
                do {
                    let dir = MediaExport.outgoingDir(core)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    if messages.count == 1, let recorded = messages.first, recorded.isVoice || recorded.isVideoNote {
                        // запись отправка забирает себе (переносит и удаляет) — отдаём копию
                        let copy = dir.appendingPathComponent("fwd_\(UUID().uuidString).\(recorded.isVideoNote ? "mp4" : "m4a")")
                        try FileManager.default.copyItem(at: try await file(recorded), to: copy)
                        await core.sendRecorded(copy, durationMs: recorded.durationMs ?? 0, videoNote: recorded.isVideoNote, to: target)
                        continue
                    }
                    var files: [OshinobuCore.OutgoingFile] = []
                    for m in messages {
                        let name = m.fileName ?? (m.isVideo ? "video.mp4" : "photo.jpg")
                        let copy = dir.appendingPathComponent("\(UUID().uuidString)_\(name)")
                        try FileManager.default.copyItem(at: try await file(m), to: copy)
                        files.append(.init(url: copy, name: name, isVideo: m.isVideo, isFile: m.isFile, isSpoiler: m.isSpoiler))
                    }
                    if !(await core.sendMedia(files, to: target, caption: caption ?? "")).isEmpty { toasts.show(tr("chat_fileTooLarge")) }
                } catch {
                    toasts.show(tr("chat_forwardFailed"))
                }
            }
        }
    }
}

/// Куда переслать: список чатов; выбор открывает чат с пересылаемым в поле ввода.
struct ForwardScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AppNavigator
    @EnvironmentObject private var draft: ForwardDraft
    @State private var chats: [ChatSummary]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconButtonM(.arrowBack) {
                    draft.items = []
                    nav.pop()
                }
                Text("forward_title").font(.roboto(20)).tracking(0).foregroundStyle(model.theme.textPrimary)
                Spacer()
            }
            .frame(height: 56)
            .padding(.horizontal, 4)
            if let chats {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chats) { chat in
                            Button { pick(chat) } label: {
                                HStack(spacing: 14) {
                                    PeerAvatar(accountId: chat.lastKnownAccountId, size: 44)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Group {
                                            if chat.isDeleted { Text("home_deletedAccount") } else { PeerName(accountId: chat.lastKnownAccountId, login: chat.peerLogin) }
                                        }
                                        .font(.roboto(16)).foregroundStyle(model.theme.textPrimary).lineBox(16)
                                        Text(verbatim: ChatStore.decodePreview(chat.lastMessage) { tr($0) })
                                            .font(.roboto(14)).foregroundStyle(model.theme.textMuted).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
                        }
                    }
                    .padding(.bottom, windowSafeArea.bottom)
                }
            } else {
                FullScreenLoading()
            }
        }
        .background(model.theme.background.ignoresSafeArea())
        .task { chats = model.core.chats.knownPeers() }
    }

    private func pick(_ chat: ChatSummary) {
        draft.target = chat.peerLogin
        nav.replaceTop(with: .chat(chat))
    }
}
