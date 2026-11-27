import OshinobuCore
import PhotosUI
import SwiftUI

// Экран переписки — как у Android (ui/chat/ChatScreen.kt, ChatParts.kt, MessageBubbles.kt, Composer.kt):
// лента поверх фона чата (обои или цвет темы), шапка и поле ввода — плавающие «таблетки».
// Жесты на сообщении: нажатие — меню, двойное — реакция по умолчанию, долгое — выбор, свайп влево — ответ.

/// Открытое меню сообщения: представитель строки (альбома), id всех её сообщений, точка нажатия
/// (в координатах окна) и общий статус отправки строки.
private struct MenuTarget: Equatable {
    let message: StoredMessage
    let groupIds: [String]
    let anchor: CGPoint
    let groupStatus: String?
}

/// Строка ленты: одно сообщение или альбом — подряд идущие сообщения одной отправки (общий groupId).
struct MessageGroup: Identifiable, Equatable {
    let messages: [StoredMessage]
    var id: String { messages[0].groupId ?? messages[0].messageId }
    /// Представитель альбома: подпись, если есть, иначе первое вложение.
    var rep: StoredMessage { messages.first { !$0.isMedia } ?? messages[0] }
    var ids: [String] { messages.map(\.messageId) }
}

func groupMessages(_ messages: [StoredMessage]) -> [MessageGroup] {
    var result: [MessageGroup] = []
    var i = 0
    while i < messages.count {
        guard let gid = messages[i].groupId else {
            result.append(MessageGroup(messages: [messages[i]]))
            i += 1
            continue
        }
        var cluster: [StoredMessage] = []
        while i < messages.count, messages[i].groupId == gid {
            cluster.append(messages[i])
            i += 1
        }
        result.append(MessageGroup(messages: cluster))
    }
    return result
}

/// Общий статус альбома: сбой у одного — сбой, отправляется хоть одно — отправляется.
private func aggregateStatus(_ group: [StoredMessage]) -> String {
    if group.contains(where: { $0.status == MessageStatus.failed }) { return MessageStatus.failed }
    if group.contains(where: { $0.status == MessageStatus.sending || $0.status == MessageStatus.queued }) { return MessageStatus.sending }
    if group.allSatisfy({ $0.status == MessageStatus.read }) { return MessageStatus.read }
    return MessageStatus.sent
}

/// Краткое описание сообщения для баннеров (ответ, закреп).
func previewOf(_ m: StoredMessage) -> String {
    if m.isSticker { return tr("sticker_preview") }
    if m.isVoice { return "🎤 \(tr("media_voiceNote"))" }
    if m.isVideoNote { return "🎥 \(tr("media_videoNote"))" }
    if m.isMedia && m.isFile { return "📎 \(tr("media_file"))" }
    if m.isMedia { return "📷 \(tr("media_photo"))" }
    return m.text
}

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AppNavigator
    @EnvironmentObject private var forwardDraft: ForwardDraft
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.navBack) private var navBack
    let peer: ChatSummary
    @StateObject private var media: ChatMedia
    @State private var messages: [StoredMessage] = []
    @State private var groups: [MessageGroup] = []
    /// Раскрытые спойлеры (до выхода из чата).
    @State private var revealed: Set<String> = []
    @State private var tapZones = TapZones()
    @State private var previewing: URL?
    @State private var draft = ""
    @State private var replyTo: StoredMessage?
    @State private var editing: StoredMessage?
    @State private var peerOnline: Bool?
    @State private var peerLastSeenMs: Int64?
    @State private var peerTyping = false
    @State private var typingClear: Task<Void, Never>?
    @State private var lastTypingSent = Date.distantPast
    @State private var wallpaper: UIImage?
    /// Пересылаемое в этот чат: показано над полем ввода, уходит по «отправить».
    @State private var forwarding: [ForwardItem]?
    @StateObject private var emojiKeyboard = EmojiKeyboardState(withStickers: true)
    @StateObject private var keyboard = KeyboardObserver()
    @State private var stickerPreview: String?
    @State private var sharing: URL?
    @State private var searchQuery: String?
    @State private var searchIndex = 0
    @State private var searchJump = 0
    @State private var searchAsList = false
    @State private var pickingWallpaper = false
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var wallpaperDraft: WallpaperDraft?
    @State private var wallpaperForPeer = true
    @State private var wallpaperBusy = false
    @State private var selected: Set<String> = []
    @State private var menu: MenuTarget?
    @State private var headerHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    @State private var bottomInset: CGFloat = 34
    @State private var bottomVisible = true
    @State private var flashId: String?
    @State private var flashStartedAt: Date?
    /// Рассыпающиеся сообщения остаются на своих местах, пока идёт анимация.
    @State private var dissolving: [String: StoredMessage] = [:]
    /// Уже рассыпавшиеся — больше не показываются, даже если запоздалое перечитывание вернёт их.
    @State private var removedIds: Set<String> = []
    /// Протяжка выбора: рамки строк на экране и строка, на которой палец был последней.
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragSelectAt: CGPoint?
    @State private var dragLastId: String?
    @State private var feedProxy: ScrollViewProxy?
    /// Лента (UIScrollView) — для автопрокрутки протяжкой; верх экрана чата в окне.
    @State private var feedScrollView: UIScrollView?
    /// Низ шапки (со всеми полосами) в окне — верхний край ленты для автопрокрутки протяжкой.
    @State private var headerBottom: CGFloat = 0
    @State private var scrollTarget: String?
    @State private var scrollToBottom = 0
    @State private var justReacted: Set<String> = []
    @StateObject private var recorder = ChatRecorder()
    @FocusState private var inputFocused: Bool

    init(peer: ChatSummary, core: OshinobuCore) {
        self.peer = peer
        _media = StateObject(wrappedValue: ChatMedia(core: core, peerLogin: peer.peerLogin))
    }

    private var current: ChatSummary { model.chats.first { $0.peerLogin == peer.peerLogin } ?? peer }
    private var selectionMode: Bool { !selected.isEmpty }
    private var composerBlocked: Bool { current.blockedByMe || current.blockingMe }

    private var searchMatches: [StoredMessage] {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return [] }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.fileName?.localizedCaseInsensitiveContains(q) ?? false) }.reversed()
    }

    var body: some View {
        layers
        .ignoresSafeArea(.keyboard)
        // поле ввода — у самого низа: касания там система отдаёт сразу, а не ждёт свой жест «домой»
        // (иначе удержание кнопки записи доходило, только когда палец сдвинется)
        .defersSystemGestures(on: .bottom)
        .background { GeometryReader { g in Color.clear.onAppear { bottomInset = g.safeAreaInsets.bottom } } }
        .animation(.easeOut(duration: 0.16), value: bottomVisible)
        .animation(.easeOut(duration: 0.2), value: selectionMode)
        // пока палец занят превью стикера или протяжкой выбора, свайп назад не перехватывает его
        .onChange(of: stickerPreview != nil || dragSelectAt != nil) { _, busy in nav.swipeBlocked = busy }
        .task { await follow() }
        .task { await followPresence() }
        .task { await followWallpaper() }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { ShareSheet(items: [sharing]) }
        }
        .quickLookPreview($previewing)
        .environmentObject(media)
        .environment(\.tapZones, tapZones)
        .photosPicker(isPresented: $pickingWallpaper, selection: $wallpaperItem, matching: .images)
        .onChange(of: wallpaperItem) { _, item in
            guard let item else { return }
            wallpaperItem = nil
            Task {
                // исходник с запасом на увеличение; preparingThumbnail учитывает ориентацию
                if let data = try? await item.loadTransferable(type: Data.self), let full = UIImage(data: data) {
                    let k = min(1, 2560 / max(full.size.width, full.size.height))
                    let source = await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * k, height: full.size.height * k)) ?? full
                    wallpaperForPeer = true
                    // превью — на весь чат: клавиатуры не мешают
                    inputFocused = false
                    emojiKeyboard.closeEmoji()
                    wallpaperDraft = WallpaperDraft(image: source)
                } else {
                    model.toasts.show(tr("error_wallpaperFailed"))
                }
            }
        }
        .onAppear {
            model.chatOpened(peer.peerLogin)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "focusComposer") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { inputFocused = true } }
            if let q = UserDefaults.standard.string(forKey: "debugSearch") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    searchQuery = q
                    searchAsList = UserDefaults.standard.bool(forKey: "debugSearchList")
                }
            }
            if UserDefaults.standard.bool(forKey: "debugSelect") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if let g = groups.last { toggleSelection(g) } }
            }
            if let kind = UserDefaults.standard.string(forKey: "debugRecord") {
                // запись без пальца — проверить старт и строку записи по скриншоту
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    recorder.cameraSelected = kind == "video"
                    recorder.onPointer(true)
                    recorder.begin(dir: model.core.dirs.documents.appendingPathComponent("outgoing"))
                }
            }
            #endif
            let draft = forwardDraft.take(for: peer.peerLogin)
            if !draft.isEmpty { forwarding = draft }
            let core = model.core, peer = current
            recorder.onRecorded = { url, ms, isVideo in Task { await core.sendRecorded(url, durationMs: ms, videoNote: isVideo, to: peer) } }
        }
        .onDisappear {
            model.chatOpened(nil)
            recorder.release()
        }
    }

    /// Слои экрана: фон, лента, шапка, поле ввода, запись, меню.
    @ViewBuilder private var layers: some View {
        let matches = searchMatches
        let currentMatch = matches.indices.contains(searchIndex) ? matches[searchIndex] : nil
        ZStack {
            ChatBackdrop(wallpaper: wallpaper, draft: wallpaperDraft)
            // лента живёт и под списком совпадений (он непрозрачный): выбор в списке переносит к
            // сообщению в той же ленте, а не в новой, которая встаёт к низу
            feed(highlighted: currentMatch?.messageId)
            if searchQuery != nil && searchAsList {
                SearchResultsList(matches: matches, top: headerHeight, bottom: max(0, composerHeight - bottomInset)) { m in
                    searchAsList = false
                    searchIndex = matches.firstIndex(of: m) ?? 0
                    searchJump += 1
                }
            }
            VStack(spacing: 0) {
                // шапка со всеми полосами под ней — её высоту лента оставляет сверху (закреп не закрывает сообщения)
                VStack(spacing: 0) {
                header
                OngoingCallBanner(peerLogin: current.peerLogin)
                // панель плеера — только если играет сообщение из этого чата
                if let id = playback.activeId, messages.contains(where: { $0.messageId == id }) {
                    MediaControlBar().transition(.move(edge: .top).combined(with: .opacity))
                }
                if let pinnedId = current.pinnedMessageId, searchQuery == nil, !selectionMode {
                    pinnedBanner(pinnedId).transition(.move(edge: .top).combined(with: .opacity))
                }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0 }
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.25), value: current.pinnedMessageId)
            .animation(.easeInOut(duration: 0.26), value: playback.activeId)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if selectionMode && searchQuery == nil {
                    selectionActions.transition(.move(edge: .bottom).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    bottomBar
                    // клавиатура шторки галереи или окна поверх чата — не наша: лента и поле ввода не двигаются
                    PopupAware(popups: model.popups) { overlaid in
                        EmojiKeyboardArea(state: emojiKeyboard, keyboard: keyboard, bottomInset: bottomInset, onEmoji: { draft += $0 },
                                          stickers: composerBlocked || searchQuery != nil ? nil : { reserve in
                                              StickerPanel(bottomPadding: reserve, onSend: sendSticker, onPreview: { stickerPreview = $0 })
                                          },
                                          followsKeyboard: !overlaid)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            if !bottomVisible && !selectionMode && !(searchQuery != nil && searchAsList) {
                ScrollDownButton { scrollToBottom += 1 }
                    .padding(.trailing, 12)
                    .padding(.bottom, composerHeight + 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if recorder.recording && recorder.kind == .video {
                VideoNoteLivePreview(recorder: recorder)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, composerHeight)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            if recorder.phase == .dragging {
                RecordingLockIndicator(recorder: recorder)
                    .padding(.trailing, 18)
                    .padding(.bottom, composerHeight + 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            // выбранная картинка — фоном всего чата, снизу — «Установить как фон чата»
            if let draft = wallpaperDraft, let account = current.lastKnownAccountId {
                WallpaperGestures(draft: draft)
                WallpaperPreviewBar(peerAccountId: account, peerLogin: current.peerLogin, canSetForPeer: !composerBlocked,
                                    forPeer: $wallpaperForPeer, busy: wallpaperBusy,
                                    onSet: { setWallpaper(draft, account: account) }, onCancel: { wallpaperDraft = nil })
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            StickerPreviewOverlay(stickerId: stickerPreview)
            if let menu {
                let m = menu.message
                MessageMenuOverlay(target: menu, isPinned: current.pinnedMessageId == m.messageId,
                                   showCopy: !m.isMedia && !m.isCallLog && !m.isSticker,
                                   showEdit: m.isMine && !m.isMedia && !m.isCallLog && !m.isSticker && m.groupId == nil,
                                   onReaction: { emoji in react(m, emoji) },
                                   onAction: { action in handle(action, on: menu) },
                                   onDismiss: { self.menu = nil })
            }
        }
    }

    /// К совпадению поиска (его строке — альбом общий).
    private func scrollToMatch(_ id: String?, _ proxy: ScrollViewProxy) {
        guard let id, !searchAsList, let key = groups.first(where: { g in g.messages.contains { $0.messageId == id } })?.id else { return }
        withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(key, anchor: .center) }
    }

    private func pinnedBanner(_ pinnedId: String) -> some View {
        let text = messages.first { $0.messageId == pinnedId }.map(previewOf) ?? tr("chat_pinnedMessage")
        return PinnedBanner(text: text) { jump(to: pinnedId) }
    }

    /// «Ответить» (выбрана одна строка) и «Переслать» над полем ввода в режиме выбора.
    private var selectionActions: some View {
        let selectedGroups = groups.filter { g in g.messages.contains { selected.contains($0.messageId) } }
        return SelectionActions(canReply: selectedGroups.count == 1 && !composerBlocked, canForward: !selectedForwardItems.isEmpty,
                                onReply: {
                                    guard let target = selectedGroups.first?.rep, selectedGroups.count == 1 else { return }
                                    selected = []
                                    replyTo = target
                                    editing = nil
                                    inputFocused = true
                                },
                                onForward: { startForward(selectedForwardItems) })
    }

    // MARK: лента

    private func feed(highlighted: String?) -> some View {
        GeometryReader { g in
            let maxText = g.size.width * 0.65
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            row(group, maxText: maxText, maxBubble: g.size.width * 0.72,
                                highlighted: highlighted.map { id in group.messages.contains { $0.messageId == id } } ?? false)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[group.id] = $0 }
                                .onDisappear { rowFrames[group.id] = nil }
                                .collapseOnDissolve(group.messages.contains { dissolving[$0.messageId] != nil })
                                .id(group.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { bottomVisible = true }
                            .onDisappear { bottomVisible = false }
                    }
                    .padding(.horizontal, 16)
                }
                .contentMargins(.top, headerHeight + 8, for: .scrollContent)
                // поле ввода измерено от низа экрана, а лента и так отступает на жестовую полосу
                .contentMargins(.bottom, max(0, composerHeight + 12 - bottomInset), for: .scrollContent)
                .defaultScrollAnchor(.bottom)
                // лента сдвинулась — клавиатура уходит сразу, и поле ввода опускается вместе с ней
                .scrollDismissesKeyboard(.immediately)
                .scrollDisabled(dragSelectAt != nil)
                .onAppear { feedProxy = proxy }
                .onChange(of: messages.last?.messageId) { _, _ in
                    // своё — всегда вниз; чужое — если и так были внизу
                    if messages.last?.isMine == true || bottomVisible { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: scrollToBottom) { _, _ in withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: scrollTarget) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) }
                    scrollTarget = nil
                }
                .onChange(of: highlighted) { _, id in scrollToMatch(id, proxy) }
                .onChange(of: searchJump) { _, _ in scrollToMatch(highlighted, proxy) }
            }
        }
    }

    @ViewBuilder private func row(_ group: MessageGroup, maxText: CGFloat, maxBubble: CGFloat, highlighted: Bool) -> some View {
        let m = group.rep
        if m.isCallLog {
            CallLogRow(message: m)
        } else if m.isUndecryptable {
            CenteredNotice(icon: .oLock, iconTint: model.theme.textMuted, text: String(format: tr("chat_undecryptable"), current.peerLogin),
                           timestamp: m.timestamp, italic: true)
        } else {
            MessageRow(message: m, selectionMode: selectionMode, selected: selected.contains(m.messageId),
                       flashStartedAt: flashId == group.id ? flashStartedAt : nil, highlighted: highlighted,
                       dissolving: group.messages.contains { dissolving[$0.messageId] != nil }, swipeEnabled: !selectionMode && !composerBlocked,
                       onTap: { anchor in
                           if selectionMode { toggleSelection(group) } else { openMenu(group, anchor) }
                       },
                       onDoubleTap: { if !selectionMode { react(m, model.core.settings.defaultReaction) } },
                       onLongPress: { point, scrollView in
                           // вход в режим выбора (или выбор ещё одной строки) — и дальше протяжка
                           toggleSelection(group)
                           dragLastId = group.id
                           feedScrollView = scrollView
                           dragSelect(point)
                       },
                       onDragSelect: { point in dragSelect(point) },
                       onSwipeReply: {
                           replyTo = m
                           editing = nil
                           inputFocused = true
                       },
                       feedArea: CGRect(x: 0, y: headerBottom, width: UIScreen.main.bounds.width,
                                        height: max(0, UIScreen.main.bounds.height - composerHeight - headerBottom))) {
                MessageBubble(group: group.messages, peerName: current.peerLogin, peerLogin: current.peerLogin, maxText: maxText, maxBubble: maxBubble,
                              justReacted: justReacted.contains(m.messageId),
                              original: m.replyToMessageId.flatMap { id in messages.first { $0.messageId == id } },
                              revealed: revealed,
                              onReveal: { revealed.insert($0) },
                              onJump: { jump(to: $0) },
                              onStickerTap: { openStickerPack($0) },
                              onOpenViewer: { nav.open(.media(peerLogin: current.peerLogin, messageId: $0.messageId)) },
                              onOpenFile: { openFile($0) },
                              onSaveFile: { msg in Task { await saveToDevice(msg) } })
            }
        }
    }

    // MARK: шапка

    @ViewBuilder private var header: some View {
        Group {
            if selectionMode {
                // скачать — только одно голосовое или видеосообщение
                let single = selected.count == 1 ? messages.first { selected.contains($0.messageId) && ($0.isVoice || $0.isVideoNote) } : nil
                SelectionHeader(count: selected.count,
                                onClose: { selected = [] },
                                onSave: single.map { msg in {
                                    Task { await saveToDevice(msg) }
                                    selected = []
                                } },
                                onCopy: copySelected,
                                onForward: { if !selectedForwardItems.isEmpty { startForward(selectedForwardItems) } },
                                onDelete: { askDelete(Array(selected)) })
            } else if let query = searchQuery {
                // поле, исчезая при закрытии, ещё раз отдаёт свой текст — закрытый поиск им не открывается снова
                SearchHeader(query: Binding(get: { query }, set: { q in
                    guard searchQuery != nil else { return }
                    searchQuery = q
                    searchIndex = 0
                })) {
                    searchQuery = nil
                    searchAsList = false
                }
            } else {
                ChatHeader(peer: current, online: peerOnline, lastSeenMs: peerLastSeenMs, typing: peerTyping,
                           onBack: { navBack() },
                           onTransfers: { model.popups.show { TransfersView() } },
                           onProfile: { if let id = current.lastKnownAccountId { nav.open(.peerProfile(accountId: id, login: current.peerLogin)) } },
                           onCall: composerBlocked || current.isDeleted ? nil : startCall,
                           onSearch: {
                               searchQuery = ""
                               searchIndex = 0
                           },
                           onWallpaper: current.isDeleted || current.lastKnownAccountId == nil ? nil : { pickingWallpaper = true },
                           onRemoveWallpaper: wallpaper == nil ? nil : removeWallpaper,
                           onResetSession: { model.popups.show { ResetSessionDialog(peer: current) } })
            }
        }
        .animation(.easeInOut(duration: 0.28), value: selectionMode)
        .animation(.easeInOut(duration: 0.28), value: searchQuery == nil)
    }

    // MARK: низ

    @ViewBuilder private var bottomBar: some View {
        if searchQuery != nil {
            let matches = searchMatches
            SearchControls(current: matches.isEmpty ? 0 : searchIndex + 1, total: matches.count, asList: searchAsList,
                           // стрелка всегда ведёт к совпадению — и когда оно то же (ленту увели в сторону)
                           onOlder: { if searchIndex < matches.count - 1 { searchIndex += 1 }; searchJump += 1 },
                           onNewer: { if searchIndex > 0 { searchIndex -= 1 }; searchJump += 1 },
                           onToggleList: { searchAsList.toggle() })
        } else {
            VStack(spacing: 0) {
                if !composerBlocked { composerBanner }
                composer
            }
        }
    }

    @ViewBuilder private var composerBanner: some View {
        let banner: (MaterialIcon, String, () -> Void)? = if editing != nil {
            (.edit, tr("chat_editingMessage"), { editing = nil; draft = "" })
        } else if let replyTo {
            (.reply, "\(tr("action_reply")): \(previewOf(replyTo))", { self.replyTo = nil })
        } else if let forwarding, !forwarding.isEmpty {
            (.forward, "\(tr("chat_forwardingCount")): \(forwarding.count)", { self.forwarding = nil })
        } else {
            nil
        }
        if let (icon, text, cancel) = banner {
            HStack(spacing: 8) {
                MIcon(icon, size: 15, tint: model.theme.primary)
                Text(verbatim: text).font(.roboto(12.5)).foregroundStyle(model.theme.textPrimary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MIcon(.close, size: 16, tint: model.theme.textMuted).onTapGesture(perform: cancel)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .transition(.opacity)
        }
    }

    /// Поле ввода в «таблетке»: эмодзи, растущий до 5 строк текст, справа — «отправить» либо скрепка и запись.
    private var composer: some View {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ZStack {
            if composerBlocked {
                Text(current.blockedByMe && current.blockingMe ? "chat_blockedMutual" : current.blockedByMe ? "chat_blockedByMe" : "chat_blockingMe")
                    .font(.roboto(12.5)).foregroundStyle(model.theme.textMuted).multilineTextAlignment(.center).lineLimit(2)
                    .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 8)
            } else {
                HStack(spacing: 2) {
                    Button { emojiKeyboard.toggle { inputFocused = $0 } } label: {
                        let icon: MaterialIcon = emojiKeyboard.emojiMode ? .keyboard : emojiKeyboard.stickersPage ? .oStickyNote2 : .oEmojiEmotions
                        MIcon(icon, tint: model.theme.textMuted).frame(width: 40, height: 40)
                            .id(icon).transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .animation(.easeOut(duration: 0.2), value: icon)
                    }
                    .buttonStyle(RippleStyle(shape: Circle(), color: model.theme.textPrimary))
                    TextField(text: $draft, prompt: Text("chat_messageHint").foregroundStyle(model.theme.textMuted), axis: .vertical) { EmptyView() }
                        .lineLimit(1...5)
                        .font(.roboto(16))
                        .tracking(0)
                        .foregroundStyle(model.theme.textPrimary)
                        .textInputAutocapitalization(.sentences)
                        .focused($inputFocused)
                        .onChange(of: inputFocused) { _, now in if now { emojiKeyboard.onFieldFocused() } }
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .onChange(of: draft) {
                            // «печатает» — не чаще раза в 3 с
                            if let deviceId = current.lastKnownDeviceId, !draft.isEmpty, Date().timeIntervalSince(lastTypingSent) > 3 {
                                lastTypingSent = Date()
                                model.core.ws.sendTyping(deviceId)
                            }
                        }
                    if hasText || editing != nil || !(forwarding ?? []).isEmpty {
                        Button(action: send) { MIcon(.send, tint: model.theme.primary).frame(width: 40, height: 40) }
                            .buttonStyle(RippleStyle(shape: Circle(), color: model.theme.primary))
                            .disabled(editing != nil && !hasText)
                    } else {
                        AttachButton(peer: current)
                        RecordButton(recorder: recorder)
                    }
                }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .frame(minHeight: 52)
        // строка записи — поверх поля: поле и его фокус остаются на месте
        .overlay {
            if recorder.recording { RecordingRow(recorder: recorder).padding(.leading, 2).padding(.trailing, 8 + 40) }
        }
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .tint(model.theme.primary)
    }

    // MARK: действия

    /// Выделенное для пересылки: тексты, стикеры и вложения.
    private var selectedForwardItems: [ForwardItem] {
        forwardItems(of: messages.filter { selected.contains($0.messageId) }, peerLogin: current.peerLogin)
    }

    /// «Переслать»: выбрать чат; он откроется с пересылаемым над полем ввода.
    private func startForward(_ items: [ForwardItem]) {
        guard !items.isEmpty else { return }
        selected = []
        forwardDraft.items = items
        forwardDraft.target = nil
        nav.open(.forward)
    }

    /// Пак стикера из ленты — шторка на половину экрана (StickerPackSheet).
    private func openStickerPack(_ id: String) {
        let target: ChatSummary? = composerBlocked ? nil : current
        model.popups.show(dim: false) {
            BottomSheetM(fraction: 0.5, background: model.theme.surface) { StickerPackSheet(stickerId: id, peer: target) }
        }
    }

    /// Файл — Quick Look (после скачивания и расшифровки).
    private func openFile(_ m: StoredMessage) {
        Task {
            if let url = try? await media.file(m) { previewing = url } else { model.toasts.show(tr("chat_openFileFailed")) }
        }
    }

    private func openMenu(_ group: MessageGroup, _ anchor: CGPoint) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let status: String? = {
            let s = aggregateStatus(group.messages)
            return group.messages.contains { $0.isMine } && (s == MessageStatus.sending || s == MessageStatus.failed) ? s : nil
        }()
        menu = MenuTarget(message: group.rep, groupIds: group.ids, anchor: anchor, groupStatus: status)
    }

    private func react(_ m: StoredMessage, _ emoji: String) {
        let peer = ChatPeer(current)
        let value = m.myReaction == emoji ? nil : emoji
        if let value { model.core.settings.recordReactionUse(value) }
        markJustReacted(m.messageId)
        Task { await model.core.chatService.react(peer, messageId: m.messageId, emoji: value) }
    }

    private func handle(_ action: MessageAction, on t: MenuTarget) {
        let peer = ChatPeer(current)
        let m = t.message
        switch action {
        case .reply:
            replyTo = m
            editing = nil
            inputFocused = true
        case .copy:
            UIPasteboard.general.string = m.text
            model.toasts.show(tr("common_copied"))
        case .pin: Task { await model.core.chatService.pin(peer, messageId: m.messageId) }
        case .unpin: Task { await model.core.chatService.pin(peer, messageId: nil) }
        case .forward: startForward(forwardItems(of: messages.filter { t.groupIds.contains($0.messageId) }, peerLogin: current.peerLogin))
        case .edit:
            editing = m
            replyTo = nil
            draft = m.text
            inputFocused = true
        case .select:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            setSelected(t.groupIds, !selected.contains(m.messageId))
        case .delete: askDelete(t.groupIds)
        case .report:
            let core = model.core, toasts = model.toasts
            model.popups.show {
                ReportDialog { comment in
                    guard let token = core.session.token, let deviceId = current.lastKnownDeviceId else { throw ApiError("error.notSignedIn") }
                    try await core.api.reportMessage(token: token, reportedDeviceId: deviceId, messageText: m.reportText, reason: comment)
                } onSent: {
                    toasts.show(tr("report_sent"))
                    // сразу предложить и заблокировать — чтобы нарушитель больше не мог писать (App Store 1.2)
                    if !current.blockedByMe {
                        let chat = current, popups = model.popups
                        popups.show {
                            BlockAfterReportDialog(peerLogin: chat.peerLogin) {
                                try await core.setBlocked(chat, true)
                            }
                        }
                    }
                }
            }
        case .cancelSend: model.core.cancelOutgoing(current.peerLogin, t.groupIds)
        case .retrySend:
            Task { if m.isMedia { await model.core.retryMedia(m, to: current) } else { await model.core.retryText(m, to: current) } }
        }
    }

    private func askDelete(_ ids: [String]) {
        let delivered = messages.contains { ids.contains($0.messageId) && ($0.status == MessageStatus.sent || $0.status == MessageStatus.read) }
        let peerName = current.peerLogin, peerAccountId = current.lastKnownAccountId
        let showPeer = delivered && !current.isDeleted
        // своя карточка поверх чата (не стандартное окно) — как на Android
        model.popups.show(dim: false) {
            DeleteMessagesDialog(peerName: peerName, peerAccountId: peerAccountId, showPeerCheckbox: showPeer) { forPeer in remove(ids, forBoth: forPeer) }
        }
    }

    private func copySelected() {
        let texts = messages.filter { selected.contains($0.messageId) && !$0.isMedia && !$0.isSticker && !$0.isCallLog && !$0.isUndecryptable }
            .sorted { $0.timestamp < $1.timestamp }
        guard !texts.isEmpty else { return }
        UIPasteboard.general.string = texts.map(\.text).joined(separator: "\n")
        selected = []
        model.toasts.show(tr("common_copied"))
    }

    /// Переход к сообщению (закреп, цитата) — прокрутка и подсветка.
    private func jump(to id: String) {
        guard let key = groups.first(where: { g in g.messages.contains { $0.messageId == id } })?.id else { return }
        scrollTarget = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            flashId = key
            flashStartedAt = Date()
        }
    }

    /// Реакцию поставили (я или собеседник, пока чат открыт) — отклик вибрацией и «взрыв» у бейджа.
    private func markJustReacted(_ id: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        justReacted.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { justReacted.remove(id) }
    }

    /// Палец протяжкой зашёл на новую строку — переключить её выбор; у края ленты — автопрокрутка.
    private func dragSelect(_ point: CGPoint?) {
        guard let point else {
            dragSelectAt = nil
            dragLastId = nil
            return
        }
        let starting = dragSelectAt == nil
        dragSelectAt = point
        selectRow(at: point)
        if starting { autoScrollWhileDragging() }
    }

    /// Строка под точкой (только строки на экране) — переключить, если палец на ней впервые.
    private func selectRow(at point: CGPoint) {
        if let hit = rowFrames.first(where: { point.y >= $0.value.minY && point.y < $0.value.maxY })?.key, hit != dragLastId,
           let group = groups.first(where: { $0.id == hit }) {
            dragLastId = hit
            toggleSelection(group)
        }
    }

    /// Палец у верхнего края ленты — листаем к более старым, у нижнего — к новым; чем ближе к краю,
    /// тем быстрее (до 14 pt за кадр). После каждого сдвига под неподвижным пальцем — новая строка.
    private func autoScrollWhileDragging() {
        Task { @MainActor in
            let edge: CGFloat = 72, maxStep: CGFloat = 14
            while let point = dragSelectAt {
                if let sv = feedScrollView {
                    let top = headerBottom
                    let bottom = UIScreen.main.bounds.height - composerHeight
                    var step: CGFloat = 0
                    if point.y < top + edge { step = -maxStep * min(1, max(0, (top + edge - point.y) / edge)) }
                    else if point.y > bottom - edge { step = maxStep * min(1, max(0, (point.y - (bottom - edge)) / edge)) }
                    if step != 0 {
                        let minY = -sv.adjustedContentInset.top
                        let maxY = max(minY, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
                        let y = min(maxY, max(minY, sv.contentOffset.y + step))
                        if y != sv.contentOffset.y {
                            sv.contentOffset.y = y
                            // рамки строк обновятся к следующему кадру
                            try? await Task.sleep(for: .milliseconds(16))
                            if let p = dragSelectAt { selectRow(at: p) }
                            continue
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func setWallpaper(_ draft: WallpaperDraft, account: String) {
        wallpaperBusy = true
        let forPeer = wallpaperForPeer && !composerBlocked
        Task {
            defer { wallpaperBusy = false }
            guard let jpeg = await draft.croppedJpeg() else { return model.toasts.show(tr("error_wallpaperFailed")) }
            do {
                try await model.core.wallpapers.set(account, jpeg: jpeg, forPeer: forPeer)
                wallpaperDraft = nil
            } catch {
                model.toasts.show(tr("error_wallpaperFailed"))
            }
        }
    }

    private func removeWallpaper() {
        guard let account = current.lastKnownAccountId else { return }
        Task {
            do { try await model.core.wallpapers.remove(account) } catch { model.toasts.show(tr("error_wallpaperFailed")) }
        }
    }

    /// Лента перечитывается по любому изменению в хранилище; видимый чат — прочитан.
    private func follow() async {
        reload()
        await model.core.markChatRead(current)
        if let deviceId = current.lastKnownDeviceId { model.core.ws.subscribePresence(deviceId) }
        for await _ in model.core.chats.changes.stream() {
            reload()
            await model.core.markChatRead(current)
        }
    }

    /// Обои этого чата (с сервера, кэш на диске); сменились — перерисовать.
    private func followWallpaper() async {
        guard let account = current.lastKnownAccountId else { return }
        let url = model.core.wallpapers.file(account)
        func load() async { wallpaper = await Task.detached { UIImage(contentsOfFile: url.path) }.value }
        await load()
        for await changed in model.core.wallpapers.changes.stream() where changed == account { await load() }
    }

    private func followPresence() async {
        guard let deviceId = current.lastKnownDeviceId else { return }
        for await event in model.core.ws.presenceEvents.stream() {
            guard event["FromDeviceId"]?.string == deviceId else { continue }
            switch event["Type"]?.string {
            case "presence":
                peerOnline = event["Online"]?.bool ?? false
                peerLastSeenMs = event["LastSeenMs"]?.int
                if peerOnline == true { peerTyping = false }
            case "typing":
                peerTyping = true
                typingClear?.cancel()
                typingClear = Task {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { peerTyping = false }
                }
            default: break
            }
        }
    }

    private func reload() {
        let stored = model.core.chats.messages(peer.peerLogin).filter { !removedIds.contains($0.messageId) }
        let ids = Set(stored.map(\.messageId))
        // исчезло (удалил собеседник у обоих) — рассыпается так же, как своё удаление
        let gone = messages.filter { !ids.contains($0.messageId) && dissolving[$0.messageId] == nil }
        if !gone.isEmpty && !messages.isEmpty { dissolve(gone, then: nil) }
        // реакция собеседника, пока чат открыт, — тот же отклик, что и своя
        let old = Dictionary(messages.map { ($0.messageId, $0.peerReaction) }, uniquingKeysWith: { a, _ in a })
        for m in stored where m.peerReaction != nil && old[m.messageId] != nil && old[m.messageId]! != m.peerReaction { markJustReacted(m.messageId) }
        let ghosts = dissolving.values.filter { !ids.contains($0.messageId) }
        messages = (stored + ghosts).sorted { $0.timestamp < $1.timestamp }
        groups = groupMessages(messages)
    }

    /// Анимация удаления, затем then и уборка призраков.
    private func dissolve(_ gone: [StoredMessage], then: (() -> Void)?) {
        for m in gone { dissolving[m.messageId] = m }
        DispatchQueue.main.asyncAfter(deadline: .now() + dissolveSeconds) {
            let ids = Set(gone.map(\.messageId))
            // рассыпалось — убрано насовсем, ещё до удаления из хранилища
            removedIds.formUnion(ids)
            for id in ids { dissolving[id] = nil }
            messages.removeAll { ids.contains($0.messageId) }
            groups = groupMessages(messages)
            then?()
            reload()
        }
    }

    /// Фото/видео — в «Фото», остальное — через «Поделиться» (сохранить в «Файлы» и т. п.).
    private func saveToDevice(_ m: StoredMessage) async {
        let url: URL?
        if let p = m.localSourcePath, FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p) }
        else if let spec = DownloadSpec.of(m, peerLogin: current.peerLogin) { url = try? await model.core.downloads.ensureDownloaded(spec) }
        else { url = nil }
        guard let url else { return model.toasts.show(tr("chat_saveToDeviceFailed")) }
        if m.isFile || m.isVoice {
            sharing = url
            return
        }
        let ok = await PhotoLibrary.save(url, isVideo: m.isVideo || m.isVideoNote)
        model.toasts.show(tr(ok ? "chat_savedToDevice" : "chat_saveToDeviceFailed"))
    }

    /// Выбор или снятие выбора строки (всего альбома) — с коротким откликом вибрацией.
    private func toggleSelection(_ group: MessageGroup) {
        UISelectionFeedbackGenerator().selectionChanged()
        setSelected(group.ids, !selected.contains(group.rep.messageId))
    }

    private func setSelected(_ ids: [String], _ on: Bool) {
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    private func remove(_ ids: [String], forBoth: Bool) {
        let peer = ChatPeer(current)
        selected = []
        let core = model.core
        dissolve(messages.filter { ids.contains($0.messageId) }) {
            Task { await core.chatService.delete(peer, messageIds: ids, forBoth: forBoth) }
        }
    }

    private func sendSticker(_ id: String) {
        let peer = current
        Task { await model.core.sendSticker(id, to: peer) }
    }

    /// Устройство собеседника может быть ещё неизвестно (новая установка, от него не было сообщений) —
    /// звонок сам спрашивает у сервера его нынешнее устройство по логину (как на Android).
    private func startCall() {
        let callee = CallPeer(deviceId: current.lastKnownDeviceId ?? "", login: current.peerLogin, accountId: current.lastKnownAccountId)
        model.callController.startCall(callee)
        Task { await model.core.calls.startCall(callee) }
    }

    /// «Отправить»: правка, пересылка (+ свой текст) или новое сообщение.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let peer = current
        if let original = editing {
            guard !text.isEmpty else { return }
            draft = ""
            editing = nil
            if original.text != text { Task { await model.core.chatService.edit(ChatPeer(peer), messageId: original.messageId, newText: text) } }
            return
        }
        if let forward = forwarding, !forward.isEmpty {
            draft = ""
            forwarding = nil
            sendForwarded(forward + (text.isEmpty ? [] : [.text(text)]), to: peer, model: model)
            return
        }
        guard !text.isEmpty else { return }
        let reply = replyTo
        draft = ""
        replyTo = nil
        Task { await model.core.sendText(text, to: peer, replyTo: reply) }
    }
}

// MARK: - фон

/// Фон переписки: свои обои чата (по ширине экрана) или цвет темы.
struct ChatBackdrop: View {
    @EnvironmentObject private var model: AppModel
    let wallpaper: UIImage?
    var draft: WallpaperDraft?

    var body: some View {
        GeometryReader { g in
            if let draft {
                ZStack { model.theme.chatBackground; WallpaperDraftImage(draft: draft) }
            } else if let wallpaper {
                Image(uiImage: wallpaper).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
            } else {
                model.theme.chatBackground
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - шапка

/// «Таблетка» шапки: поверхность, полное скругление, тень.
struct HeaderPill<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    var minHeight: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(minHeight: minHeight)
            .background(model.theme.surface, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
    }
}

/// Значок в таблетке: 22 + поля 8, нажатие — круг.
struct PillIcon: View {
    @EnvironmentObject private var model: AppModel
    let icon: MaterialIcon
    var enabled = true
    let action: () -> Void

    init(_ icon: MaterialIcon, enabled: Bool = true, action: @escaping () -> Void) {
        self.icon = icon
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MIcon(icon, size: 22, tint: enabled ? model.theme.textPrimary : model.theme.textMuted.opacity(0.5)).padding(8)
        }
        .buttonStyle(RippleStyle(shape: Circle(), color: model.theme.textPrimary))
        .disabled(!enabled)
    }
}

/// Обычная шапка: назад и передачи слева; собеседник (аватар, имя, присутствие) по центру —
/// нажатие открывает профиль; звонок и меню справа.
private struct ChatHeader: View {
    @EnvironmentObject private var model: AppModel
    let peer: ChatSummary
    let online: Bool?
    let lastSeenMs: Int64?
    let typing: Bool
    let onBack: () -> Void
    let onTransfers: () -> Void
    let onProfile: () -> Void
    let onCall: (() -> Void)?
    let onSearch: () -> Void
    let onWallpaper: (() -> Void)?
    let onRemoveWallpaper: (() -> Void)?
    let onResetSession: () -> Void
    @State private var centerHeight: CGFloat = 0
    @State private var moreFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 8) {
            HeaderPill(minHeight: centerHeight) {
                HStack(spacing: 0) {
                    PillIcon(.arrowBack, action: onBack)
                    PillIcon(.swapVert, action: onTransfers)
                }
            }
            HeaderPill {
                Button(action: onProfile) {
                    HStack(spacing: 8) {
                        if !peer.isDeleted { SharedPeerAvatar(accountId: peer.lastKnownAccountId, size: 32, role: .source) }
                        VStack(spacing: 0) {
                            Group {
                                if peer.isDeleted { Text("home_deletedAccount") } else { PeerName(accountId: peer.lastKnownAccountId, login: peer.peerLogin) }
                            }
                            .font(.roboto(16, .medium)).foregroundStyle(model.theme.textPrimary).lineLimit(1).lineBox(16)
                            if !peer.isDeleted {
                                let status = formatPresence(typing: typing, online: online, lastSeenMs: lastSeenMs) { tr($0) }
                                if !status.isEmpty {
                                    Text(verbatim: status).font(.roboto(12)).foregroundStyle(typing ? model.theme.primary : model.theme.textPrimary.opacity(0.7))
                                        .lineLimit(1).lineBox(12)
                                        .id(status)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                        .animation(.easeOut(duration: 0.25), value: status)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(RippleStyle(shape: Capsule(), color: model.theme.textPrimary))
                .disabled(peer.isDeleted)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { centerHeight = $0 }
            .frame(maxWidth: .infinity)
            HeaderPill(minHeight: centerHeight) {
                HStack(spacing: 0) {
                    PillIcon(.oCall, enabled: onCall != nil) { onCall?() }
                    PillIcon(.moreVert) { showMenu() }.globalFrame($moreFrame)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var status: String { formatPresence(typing: typing, online: online, lastSeenMs: lastSeenMs) { tr($0) } }

    private func showMenu() {
        model.popups.menu(at: moreFrame, trailing: true) {
            MenuItemM("chat_searchAction", icon: .search, action: onSearch)
            if let onWallpaper { MenuItemM("chat_wallpaperAction", icon: .oWallpaper, action: onWallpaper) }
            if let onRemoveWallpaper { MenuItemM("chat_wallpaperRemove", icon: .oHideImage, action: onRemoveWallpaper) }
            MenuItemM("chat_resetSessionAction", icon: .lockReset, action: onResetSession)
        }
    }
}

/// Шапка режима выбора: счётчик, копировать, переслать, удалить.
private struct SelectionHeader: View {
    @EnvironmentObject private var model: AppModel
    let count: Int
    let onClose: () -> Void
    /// nil — скачать нечего (кнопка только для одного голосового или видеосообщения).
    let onSave: (() -> Void)?
    let onCopy: () -> Void
    let onForward: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            IconButtonM(.close, action: onClose)
            Text(verbatim: "\(tr("chat_selectedCount")): \(count)").font(.roboto(18)).foregroundStyle(model.theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onSave { IconButtonM(.oDownload, action: onSave).transition(.opacity.combined(with: .scale)) }
            IconButtonM(.oContentCopy, action: onCopy)
            IconButtonM(.oForward, action: onForward)
            IconButtonM(.oDelete, action: onDelete)
        }
        .padding(.horizontal, 4)
        .frame(height: 56)
        .background(model.theme.surface.ignoresSafeArea(edges: .top))
    }
}

/// Шапка поиска: «назад» и поле запроса в таблетках.
private struct SearchHeader: View {
    @EnvironmentObject private var model: AppModel
    @Binding var query: String
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // кнопка — слоем выше поля: системное поле ввода ловит касания шире, чем видно, и лежало
            // поверх кнопки — нажатие «назад» уходило в поле
            HeaderPill {
                PillIcon(.arrowBack, action: onClose)
                    .overlay(UIKitTapTarget(action: onClose))
                    .accessibilityIdentifier("searchBack")
            }
            .zIndex(1)
            HeaderPill {
                TextField(text: $query, prompt: Text("chat_searchHint").foregroundStyle(model.theme.textMuted)) { EmptyView() }
                    .font(.roboto(15)).foregroundStyle(model.theme.textPrimary).tint(model.theme.primary)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { focused = true }
    }
}

/// Закреплённое сообщение — пузырём под шапкой; нажатие переносит к нему.
private struct PinnedBanner: View {
    @EnvironmentObject private var model: AppModel
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                MIcon(.pushPin, size: 16, tint: model.theme.primary)
                Text(verbatim: text).font(.roboto(13)).foregroundStyle(model.theme.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(model.theme.surface, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// Над полем ввода в режиме выбора: «Ответить» (если выбрано одно) и «Переслать».
private struct SelectionActions: View {
    @EnvironmentObject private var model: AppModel
    let canReply: Bool
    let canForward: Bool
    let onReply: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if canReply { pill(.reply, "action_reply", enabled: true, action: onReply).transition(.opacity.combined(with: .scale)) }
            pill(.oForward, "action_forward", enabled: canForward, action: onForward)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: canReply)
    }

    private func pill(_ icon: MaterialIcon, _ title: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        let tint = enabled ? model.theme.primary : model.theme.textMuted.opacity(0.5)
        return Button(action: action) {
            HStack(spacing: 6) {
                MIcon(icon, size: 18, tint: tint)
                Text(title).font(.roboto(16, .medium)).foregroundStyle(enabled ? model.theme.textPrimary : model.theme.textMuted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(model.theme.surface, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - поиск

/// Панель поиска вместо поля ввода: N/M, переход по совпадениям, «списком»/«в чате».
private struct SearchControls: View {
    @EnvironmentObject private var model: AppModel
    let current: Int
    let total: Int
    let asList: Bool
    let onOlder: () -> Void
    let onNewer: () -> Void
    let onToggleList: () -> Void

    var body: some View {
        ZStack {
            Text(verbatim: "\(current)/\(total)").font(.roboto(18, .bold)).foregroundStyle(model.theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !asList {
                HStack(spacing: 14) {
                    nav(.keyboardArrowDown, onNewer).accessibilityIdentifier("searchNewer")
                    nav(.keyboardArrowUp, onOlder).accessibilityIdentifier("searchOlder")
                }
            }
            Button(action: onToggleList) {
                Text(asList ? "chat_showAsChat" : "chat_showAsList").font(.roboto(15, .bold)).foregroundStyle(model.theme.primary)
                    .padding(.horizontal, 18).padding(.vertical, 13)
                    .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 52)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func nav(_ icon: MaterialIcon, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MIcon(icon, size: 30, tint: total > 0 ? model.theme.textPrimary : model.theme.textMuted).padding(10).background(model.theme.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(total == 0)
    }
}

/// Совпадения поиска списком (новые сверху); нажатие — к сообщению в чате.
private struct SearchResultsList: View {
    @EnvironmentObject private var model: AppModel
    let matches: [StoredMessage]
    let top: CGFloat
    let bottom: CGFloat
    let onPick: (StoredMessage) -> Void

    var body: some View {
        if matches.isEmpty {
            Text("chat_searchNoResults").foregroundStyle(model.theme.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(model.theme.background)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matches) { m in
                        Button { onPick(m) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: m.text).font(.roboto(16)).foregroundStyle(model.theme.textPrimary).lineLimit(2).lineBox(16)
                                Text(verbatim: formatChatTime(m.timestamp)).font(.roboto(12)).foregroundStyle(model.theme.textMuted).lineBox(12)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
                    }
                }
            }
            .contentMargins(.top, top + 8, for: .scrollContent)
            .contentMargins(.bottom, bottom + 8, for: .scrollContent)
            // список — на фоне экрана: поверх обоев прозрачные строки не читались
            .background(model.theme.background)
        }
    }
}

// MARK: - строка и пузырь

/// Строка сообщения во всю ширину: зона нажатия — вся строка; галочка выбора — сбоку
/// (слева у чужих, справа у своих); подсветка по переходу — тоже во всю ширину.
private struct MessageRow<Bubble: View>: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let selectionMode: Bool
    let selected: Bool
    let flashStartedAt: Date?
    let highlighted: Bool
    let dissolving: Bool
    let swipeEnabled: Bool
    let onTap: (CGPoint) -> Void
    let onDoubleTap: () -> Void
    let onLongPress: (CGPoint, UIScrollView?) -> Void
    /// Протяжка после долгого нажатия: где палец (окно); nil — отпустили.
    let onDragSelect: (CGPoint?) -> Void
    let onSwipeReply: () -> Void
    /// Видимая часть ленты в окне: касания по шапке и полю ввода над строкой — не её.
    let feedArea: CGRect
    @ViewBuilder var bubble: () -> Bubble
    @Environment(\.tapZones) private var zones
    @State private var dx: CGFloat = 0
    @State private var fired = false

    var body: some View {
        let mine = message.isMine
        HStack(spacing: 0) {
            if !mine { slot }
            if mine { Spacer(minLength: 0) }
            Dissolvable(dissolving: dissolving) {
                bubble()
            }
            .offset(x: dx)
            if !mine { Spacer(minLength: 0) }
            if mine { slot }
        }
        .padding(.vertical, 2)
        .background(JumpFlash(startedAt: flashStartedAt, color: model.theme.primary))
        // совпадение поиска пульсирует на всю ширину строки, как подсветка перехода
        .background { if highlighted { PulsingHighlight(color: model.theme.primary) } }
        // зона касания — вся строка, а не только пузырь
        .contentShape(Rectangle())
        .allowsHitTesting(!dissolving)
        .gesture(RowGestures(handlers: RowGestureHandlers(
            selectionMode: selectionMode,
            feedArea: feedArea,
            zones: zones,
            swipeReplyEnabled: swipeEnabled,
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            onLongPress: { point, scrollView in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onLongPress(point, scrollView)
            },
            onDragSelect: onDragSelect,
            onSwipe: { value in
                // свайп влево — ответ: строка уезжает не дальше 10% ширины, на пределе — ответ
                guard let value else {
                    fired = false
                    withAnimation(.linear(duration: 0.18)) { dx = 0 }
                    return
                }
                let limit = UIScreen.main.bounds.width * 0.10
                dx = max(-limit, value)
                if !fired && dx <= -limit {
                    fired = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSwipeReply()
                }
            })))
    }

    @ViewBuilder private var slot: some View {
        if selectionMode {
            MIcon(selected ? .checkCircle : .oRadioButtonUnchecked, size: 22, tint: selected ? model.theme.primary : model.theme.textMuted)
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: message.isMine ? .trailing : .leading)))
        }
    }
}

/// Ширина пузыря — по самому широкому содержимому: текст переносится по maxText,
/// нижняя строка (реакции и время) — по своей естественной ширине (IntrinsicSize.Max на Android).
private struct BubbleColumn: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = contentWidth(proposal, subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            s.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + spacing
        }
    }

    private func contentWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let limit = proposal.width ?? .infinity
        return min(limit, subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
    }
}

/// Пузырь: одно сообщение (текст, голосовое, вложение) или альбом; стикер и видеосообщение — без пузыря.
private struct MessageBubble: View {
    @EnvironmentObject private var model: AppModel
    let group: [StoredMessage]
    let peerName: String
    let peerLogin: String
    let maxText: CGFloat
    let maxBubble: CGFloat
    let justReacted: Bool
    let original: StoredMessage?
    let revealed: Set<String>
    let onReveal: (String) -> Void
    let onJump: (String) -> Void
    let onStickerTap: (String) -> Void
    let onOpenViewer: (StoredMessage) -> Void
    let onOpenFile: (StoredMessage) -> Void
    let onSaveFile: (StoredMessage) -> Void

    var body: some View {
        if group.count > 1 {
            album
        } else {
            single(group[0])
        }
    }

    /// Альбом: плитки и подпись одним пузырём; реакция — на подписи (или первом вложении), время — последнего.
    private var album: some View {
        let mediaItems = group.filter(\.isMedia)
        let caption = group.first { !$0.isMedia }
        let mine = group[0].isMine
        let repMessage = caption ?? group[0]
        var last = group.max { $0.timestamp < $1.timestamp } ?? group[0]
        last.edited = false
        last.status = aggregateStatus(group)
        return VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                if !mediaItems.isEmpty {
                    MediaGrid(media: mediaItems, maxWidth: maxBubble - 12, revealed: revealed, onReveal: onReveal,
                              onOpenViewer: onOpenViewer, onOpenFile: onOpenFile, onSaveFile: onSaveFile)
                }
                if let caption {
                    Text(linkified(caption.text, mine: mine)).font(.roboto(16)).foregroundStyle(textColor(mine)).tint(linkColor(mine))
                        .lineBox(16)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4).padding(.top, 6)
                }
            }
            HStack(spacing: 0) {
                ReactionBadges(mine: repMessage.myReaction, peer: repMessage.peerReaction, justChanged: justReacted)
                Spacer(minLength: 10)
                MetaRow(message: last)
            }
            .padding(.horizontal, 4)
        }
        .padding(6)
        .frame(maxWidth: maxBubble)
        .fixedSize()
        .background(bubbleColor(mine), in: RoundedRectangle(cornerRadius: 14))
        .padding(.vertical, 4)
    }

    @ViewBuilder private func single(_ m: StoredMessage) -> some View {
        if m.isVideoNote {
            VStack(alignment: m.isMine ? .trailing : .leading, spacing: 4) {
                VideoNotePlayer(message: m, expandedSize: UIScreen.main.bounds.width - 32)
                HStack(spacing: 0) {
                    if m.myReaction != nil || m.peerReaction != nil {
                        ReactionBadges(mine: m.myReaction, peer: m.peerReaction, justChanged: justReacted)
                        Spacer().frame(width: 10)
                    }
                    if m.fileSize > 0 {
                        Text(verbatim: formatFileSize(m.fileSize) { tr($0) }).font(.roboto(10)).foregroundStyle(model.theme.textMuted)
                        Spacer().frame(width: 6)
                    }
                    MetaRow(message: m, onColoredBubble: false)
                }
                .padding(.horizontal, 4)
            }
        } else if let stickerId = m.stickerId {
            // стикер — без пузыря; нажатие по нему — его пак
            VStack(alignment: m.isMine ? .trailing : .leading, spacing: 4) {
                if m.replyToPreview != nil {
                    ReplyPreview(message: m, original: original, peerName: peerName, onJump: onJump)
                        .frame(maxWidth: maxText)
                        .padding(.horizontal, 8).padding(.top, 6)
                        .background(bubbleColor(m.isMine), in: RoundedRectangle(cornerRadius: 14))
                }
                StickerContent(stickerId: stickerId).tapZone().onTapGesture { onStickerTap(stickerId) }
                HStack(spacing: 10) {
                    ReactionBadges(mine: m.myReaction, peer: m.peerReaction, justChanged: justReacted)
                    MetaRow(message: m, onColoredBubble: false)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(model.theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.vertical, 4)
        } else {
            BubbleColumn {
                if m.replyToPreview != nil { ReplyPreview(message: m, original: original, peerName: peerName, onJump: onJump) }
                Group {
                    if m.isVoice {
                        VoicePlayer(message: m)
                    } else if m.isMedia {
                        AttachmentBubble(message: m, side: 220, revealed: revealed.contains(m.messageId), onReveal: { onReveal(m.messageId) },
                                         onOpenViewer: onOpenViewer, onOpenFile: onOpenFile, onSaveFile: onSaveFile)
                    } else {
                        Text(linkified(m.text, mine: m.isMine)).font(.roboto(16)).foregroundStyle(textColor(m.isMine)).tint(linkColor(m.isMine))
                            .lineBox(16)
                            .frame(maxWidth: maxText, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 0) {
                    ReactionBadges(mine: m.myReaction, peer: m.peerReaction, justChanged: justReacted)
                    Spacer(minLength: 10)
                    if m.fileSize > 0 && m.isVoice {
                        Text(verbatim: formatFileSize(m.fileSize) { tr($0) }).font(.roboto(10)).foregroundStyle(mutedColor(m.isMine))
                        Spacer().frame(width: 6)
                    }
                    MetaRow(message: m)
                }
                .padding(.top, 4)
            }
            .foregroundStyle(textColor(m.isMine))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleColor(m.isMine), in: RoundedRectangle(cornerRadius: 14))
            .padding(.vertical, 4)
        }
    }

    private func bubbleColor(_ mine: Bool) -> Color { mine ? model.theme.bubbleMine : model.theme.surface }
    private func textColor(_ mine: Bool) -> Color { mine ? model.theme.onBubbleMine : model.theme.textPrimary }
    private func mutedColor(_ mine: Bool) -> Color { mine ? model.theme.onBubbleMine.opacity(0.7) : model.theme.textMuted }
    private func linkColor(_ mine: Bool) -> Color { mine ? model.theme.linkOnMine : model.theme.primary }

    /// Ссылки — от http(s):// или www. до пробела (как на Android).
    private func linkified(_ text: String, mine: Bool) -> AttributedString {
        var s = AttributedString(text)
        guard let regex = try? NSRegularExpression(pattern: "((https?://)|(www\\.))\\S+", options: .caseInsensitive) else { return s }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(match.range, in: text), let ar = Range(r, in: s) else { continue }
            let url = String(text[r])
            s[ar].link = URL(string: url.lowercased().hasPrefix("http") ? url : "https://\(url)")
            s[ar].foregroundColor = linkColor(mine)
        }
        return s
    }
}

/// Время, отметка правки и статус доставки. onColoredBubble = false — для лежащих прямо на фоне (кружки, стикеры).
struct MetaRow: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    var onColoredBubble = true

    var body: some View {
        let muted = onColoredBubble ? (message.isMine ? model.theme.onBubbleMine.opacity(0.7) : model.theme.textMuted) : model.theme.textMuted
        HStack(spacing: 0) {
            if message.edited {
                MIcon(.edit, size: 11, tint: muted)
                Spacer().frame(width: 3)
            }
            Text(verbatim: formatChatTime(message.timestamp)).font(.roboto(10)).foregroundStyle(muted).lineBox(10)
            if message.isMine {
                Spacer().frame(width: 4)
                StatusIcon(status: message.status, onColoredBubble: onColoredBubble)
            }
        }
    }
}

struct StatusIcon: View {
    @EnvironmentObject private var model: AppModel
    let status: String
    var onColoredBubble = true

    var body: some View {
        switch status {
        case MessageStatus.failed: MIcon(.errorOutline, size: 13, tint: Color(hex: 0xFF5252))
        case MessageStatus.sending, MessageStatus.queued:
            MIcon(.schedule, size: 13, tint: onColoredBubble ? model.theme.onBubbleMine.opacity(0.7) : model.theme.textMuted)
        case MessageStatus.read: MIcon(.doneAll, size: 13, tint: onColoredBubble ? model.theme.onBubbleMine : model.theme.primary)
        default: MIcon(.done, size: 13, tint: onColoredBubble ? model.theme.sentTick : model.theme.textMuted)
        }
    }
}

/// Цитата внутри пузыря: своя подложка, полоска слева, сверху — чьё сообщение, ниже — сама цитата.
/// Оригинал удалён — фиксированная надпись; иначе нажатие переносит к оригиналу.
private struct ReplyPreview: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let original: StoredMessage?
    let peerName: String
    let onJump: (String) -> Void

    var body: some View {
        let muted = message.isMine ? model.theme.onBubbleMine.opacity(0.7) : model.theme.textMuted
        let nameColor = message.isMine ? model.theme.onBubbleMine : model.theme.primary
        VStack(alignment: .leading, spacing: 0) {
            if let original {
                Group { if original.isMine { Text("chat_replyYou") } else { Text(verbatim: peerName) } }
                    .font(.roboto(12, .semibold)).foregroundStyle(nameColor).lineLimit(1)
            }
            Text(verbatim: original == nil ? tr("chat_replyDeleted") : message.replyToPreview ?? "")
                .font(.roboto(12)).italic(original == nil).foregroundStyle(muted).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 11).padding(.trailing, 8).padding(.vertical, 4)
        .background(alignment: .leading) { muted.frame(width: 3) }
        .background(Color.black.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .tapZone(original != nil)
        .onTapGesture { if let original { onJump(original.messageId) } }
        .padding(.bottom, 6)
    }
}

/// Реакции — раздельно: своя (рамка акцентом) и собеседника (приглушённая); появление — с «хлопком».
private struct ReactionBadges: View {
    let mine: String?
    let peer: String?
    let justChanged: Bool

    var body: some View {
        HStack(spacing: 4) {
            ReactionChip(emoji: mine, mine: true, justChanged: justChanged)
            ReactionChip(emoji: peer, mine: false, justChanged: justChanged)
        }
    }
}

private struct ReactionChip: View {
    @EnvironmentObject private var model: AppModel
    let emoji: String?
    let mine: Bool
    let justChanged: Bool
    @State private var scale: CGFloat = 1
    @State private var burst: String?
    /// Последняя «отпразднованная» реакция этого бейджа — второй бейдж (не менявшийся) не взрывается.
    @State private var celebrated: String?

    var body: some View {
        if let emoji {
            Text(verbatim: emoji).font(.system(size: 13))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mine ? model.theme.primary : model.theme.textMuted.opacity(0.4), lineWidth: 1))
                .scaleEffect(scale)
                .overlay { if let b = burst { ReactionBurst(emoji: b) { burst = nil }.id(b) } }
                .transition(.scale.combined(with: .opacity))
                .onChange(of: emoji) { _, _ in pop() }
                .onChange(of: justChanged) { _, now in if now { pop() } }
                .onAppear { if justChanged { pop() } else { celebrated = emoji } }
        }
    }

    /// Появление или смена — «хлопок» и разлёт (только у бейджа, который действительно поменялся).
    private func pop() {
        guard justChanged, let emoji, emoji != celebrated, burst == nil else { return }
        celebrated = emoji
        burst = emoji
        scale = 1.35
        withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { scale = 1 }
    }
}

/// Нейтральный ряд по центру — для записей о звонках и заглушек нерасшифрованных сообщений.
private struct CenteredNotice: View {
    @EnvironmentObject private var model: AppModel
    let icon: MaterialIcon
    let iconTint: Color
    let text: String
    let timestamp: Int64
    var italic = false

    var body: some View {
        HStack(spacing: 6) {
            MIcon(icon, size: 16, tint: iconTint)
            Text(verbatim: text).font(.roboto(16)).italic(italic).foregroundStyle(model.theme.textPrimary)
            Text(verbatim: formatChatTime(timestamp)).font(.roboto(10)).foregroundStyle(model.theme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

/// Запись о звонке — по центру, а не пузырём одной из сторон.
private struct CallLogRow: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage

    var body: some View {
        let outgoing = message.callDirection == "outgoing"
        let (icon, label): (MaterialIcon, String) = switch message.callOutcome {
        case "answered":
            (outgoing ? .callMade : .callReceived, "\(tr("call_answered")) · \(duration(message.callDurationSeconds ?? 0))")
        case "missed": (.callMissed, tr("call_missed"))
        default: (.callMade, tr("call_noAnswer"))
        }
        let bad = message.callOutcome == "missed" || message.callOutcome == "no_answer"
        CenteredNotice(icon: icon, iconTint: bad ? Color(hex: 0xFF5252) : model.theme.textMuted, text: label, timestamp: message.timestamp)
    }

    private func duration(_ s: Int64) -> String { "\(s / 60):\(s % 60 < 10 ? "0" : "")\(s % 60)" }
}

// MARK: - меню сообщения

enum MessageAction { case reply, copy, pin, unpin, forward, edit, select, delete, report, cancelSend, retrySend }

/// Меню сообщения поверх чата (MessageMenu.kt): панель реакций (частые первыми, стрелка раскрывает все)
/// и действия — две отдельные панели. Своё сообщение — меню левее точки нажатия, чужое — правее; всегда
/// в видимой части экрана. В процессе отправки — только «отменить», после сбоя — «повторить»/«отменить», без реакций.
private struct MessageMenuOverlay: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var keyboard = KeyboardObserver()
    let target: MenuTarget
    let isPinned: Bool
    let showCopy: Bool
    let showEdit: Bool
    let onReaction: (String) -> Void
    let onAction: (MessageAction) -> Void
    let onDismiss: () -> Void
    @State private var appear: CGFloat = 0
    @State private var expanded = false
    @State private var closing = false

    private let cell: CGFloat = 42
    private let rowEmojis = 6
    private let gridColumns = 7
    private let barPadding: CGFloat = 6
    private var barWidth: CGFloat { cell * CGFloat(rowEmojis + 1) + barPadding * 2 }
    private var barHeight: CGFloat { cell + barPadding * 2 }
    private var gridHeight: CGFloat { cell * 6 + barPadding * 2 }
    private let actionsWidth: CGFloat = 232
    private let actionHeight: CGFloat = 44
    private let panelGap: CGFloat = 8
    private let danger = Color(hex: 0xFF5252)

    private struct Item: Identifiable {
        let icon: MaterialIcon
        let label: LocalizedStringKey
        let action: MessageAction
        var danger = false
        var id: String { "\(action)" }
    }

    private var items: [Item] {
        let m = target.message
        switch target.groupStatus {
        case MessageStatus.sending: return [Item(icon: .close, label: "action_cancelSend", action: .cancelSend, danger: true)]
        case MessageStatus.failed:
            return [Item(icon: .refresh, label: "action_retrySend", action: .retrySend),
                    Item(icon: .close, label: "action_cancelSend", action: .cancelSend, danger: true)]
        default:
            var list = [Item(icon: .reply, label: "action_reply", action: .reply)]
            if showCopy { list.append(Item(icon: .oContentCopy, label: "action_copy", action: .copy)) }
            list.append(isPinned ? Item(icon: .oPushPin, label: "action_unpin", action: .unpin) : Item(icon: .oPushPin, label: "action_pin", action: .pin))
            list.append(Item(icon: .oForward, label: "action_forward", action: .forward))
            if showEdit { list.append(Item(icon: .oEdit, label: "action_edit", action: .edit)) }
            list.append(Item(icon: .oCheckCircleOutline, label: "action_select", action: .select))
            list.append(Item(icon: .oDelete, label: "action_delete", action: .delete, danger: true))
            if !m.isMine { list.append(Item(icon: .oFlag, label: "action_report", action: .report, danger: true)) }
            return list
        }
    }

    var body: some View {
        let withReactions = target.groupStatus == nil
        let emojis = model.core.settings.sortedReactions(allEmojis)
        GeometryReader { g in
            let width = withReactions ? barWidth : actionsWidth
            // место — по большей высоте (ряд + действия или раскрытая сетка): раскрытие не сдвигает меню
            let collapsed = (withReactions ? barHeight + panelGap : 0) + actionHeight * CGFloat(items.count)
            let estimated = withReactions ? max(collapsed, gridHeight) : collapsed
            let frame = g.frame(in: .global)
            let top = windowSafeArea.top, bottom = max(keyboard.height, windowSafeArea.bottom)
            let m: CGFloat = 8
            let x = min(max(m, (target.message.isMine ? target.anchor.x - width : target.anchor.x) - frame.minX), max(m, g.size.width - width - m))
            let y = min(max(top + m, target.anchor.y - frame.minY), max(top + m, g.size.height - bottom - estimated - m))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25 * appear).contentShape(Rectangle()).onTapGesture { close(onDismiss) }
                VStack(spacing: 0) {
                    if withReactions { reactionPanel(emojis) }
                    if !expanded {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                Button { close { onAction(item.action) } } label: {
                                    HStack(spacing: 13) {
                                        MIcon(item.icon, size: 22, tint: item.danger ? danger : model.theme.textMuted)
                                        Text(item.label).font(.roboto(17)).tracking(0).foregroundStyle(item.danger ? danger : model.theme.textPrimary)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 16)
                                    .frame(height: actionHeight)
                                }
                                .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
                            }
                        }
                        .frame(width: actionsWidth)
                        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 16))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        .padding(.top, withReactions ? panelGap : 0)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)).combined(with: .scale(scale: 0.9, anchor: .top)),
                            removal: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.14)).combined(with: .scale(scale: 0.9, anchor: .top))))
                    }
                }
                .frame(width: width)
                .scaleEffect(0.85 + 0.15 * appear, anchor: target.message.isMine ? .topTrailing : .topLeading)
                .opacity(appear)
                .offset(x: x, y: y)
            }
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.16)) { appear = 1 } }
    }

    @ViewBuilder private func reactionPanel(_ emojis: [String]) -> some View {
        let my = target.message.myReaction
        ZStack(alignment: .topTrailing) {
            if expanded {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 0), count: gridColumns), spacing: 0) {
                        ForEach(Array(emojis.enumerated()), id: \.element) { i, e in
                            EmojiCell(emoji: e, selected: e == my, order: min(i, gridColumns), side: cell) { close { onReaction(e) } }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(width: barWidth - barPadding * 2, height: gridHeight - barPadding * 2)
                .padding(barPadding)
                Button { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) { expanded = false } } label: {
                    MIcon(.keyboardArrowUp, tint: model.theme.textMuted).frame(width: cell, height: cell).background(model.theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(barPadding)
            } else {
                ReactionRow(emojis: Array(emojis.prefix(rowEmojis + 1)), myReaction: my, cell: cell, rowEmojis: rowEmojis, barPadding: barPadding,
                            onReaction: { e in close { onReaction(e) } },
                            onExpand: { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) { expanded = true } })
            }
        }
        .frame(width: barWidth, height: expanded ? gridHeight : barHeight)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: expanded ? 18 : barHeight / 2))
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 18 : barHeight / 2))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    /// Закрытие — обратная анимация открытия (140 мс), и только потом действие; повторные нажатия — мимо.
    private func close(_ then: @escaping () -> Void) {
        guard !closing else { return }
        closing = true
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.14)) { appear = 0 } completion: {
            onDismiss()
            then()
        }
    }
}

/// Ряд реакций: шесть эмодзи и стрелка. Повести пальцем справа налево — ряд тянется, как резина
/// (чем дальше, тем туже, и сам ряд чуть растягивается влево), и из-под стрелки выезжает седьмой эмодзи.
/// Выехал целиком — короткая вибрация: отпустишь — раскроется сетка. Отпустили раньше — ряд пружинисто возвращается.
private struct ReactionRow: View {
    @EnvironmentObject private var model: AppModel
    let emojis: [String]
    let myReaction: String?
    let cell: CGFloat
    let rowEmojis: Int
    let barPadding: CGFloat
    let onReaction: (String) -> Void
    let onExpand: () -> Void
    @State private var pull: CGFloat = 0
    @State private var armed = false

    /// Насколько (в ячейках) ряд можно оттянуть и как туго.
    private let rubberLimit: CGFloat = 1.4
    private let rubberStiffness: CGFloat = 1.2

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(emojis.enumerated()), id: \.element) { i, e in
                    EmojiCell(emoji: e, selected: e == myReaction, order: i, side: cell) { onReaction(e) }
                }
            }
            .offset(x: -pull)
            .frame(width: cell * CGFloat(rowEmojis), height: cell, alignment: .leading)
            .clipped()
            .padding(.leading, barPadding)
            Button(action: onExpand) {
                MIcon(.keyboardArrowDown, tint: model.theme.textMuted).frame(width: cell, height: cell)
                    .background(model.theme.textMuted.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(1 - min(1, pull / cell) * 0.6)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, barPadding)
        }
        .frame(width: cell * CGFloat(rowEmojis + 1) + barPadding * 2, height: cell + barPadding * 2)
        .scaleEffect(x: 1 + (pull / cell) * 0.06, y: 1, anchor: .trailing)
        .contentShape(Rectangle())
        // протяжка — главнее кнопок эмодзи: короткое нажатие без сдвига остаётся их нажатием
        .highPriorityGesture(DragGesture(minimumDistance: 8)
            .onChanged { v in
                let d = max(0, -v.translation.width)
                let p = rubberLimit * cell * (1 - exp(-d / (rubberStiffness * cell)))
                let nowArmed = p >= cell
                if nowArmed && !armed { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
                armed = nowArmed
                pull = p
            }
            .onEnded { _ in
                if armed { onExpand() } else { withAnimation(.interpolatingSpring(stiffness: 420, damping: 2 * 0.45 * sqrt(420))) { pull = 0 } }
                armed = false
            })
    }
}

/// Эмодзи-кнопка: при появлении «выпрыгивает» с пружинкой — по очереди слева направо (28 мс шаг).
private struct EmojiCell: View {
    @EnvironmentObject private var model: AppModel
    let emoji: String
    let selected: Bool
    let order: Int
    let side: CGFloat
    let onTap: () -> Void
    @State private var pop: CGFloat = 0.3

    var body: some View {
        Button(action: onTap) {
            Text(verbatim: emoji).font(.system(size: 24)).frame(width: side, height: side)
                .background(selected ? model.theme.primary.opacity(0.25) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(pop)
        .opacity(min(1, max(0, (pop - 0.3) / 0.7)))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(order) * 0.028) {
                withAnimation(.interpolatingSpring(stiffness: 520, damping: 2 * 0.45 * sqrt(520))) { pop = 1 }
            }
        }
    }
}

/// Жалоба на сообщение. Сервер не видит переписку — текст сообщения уходит вместе с жалобой
/// добровольно, по решению пользователя.
private struct ReportDialog: View {
    @EnvironmentObject private var model: AppModel
    let onSend: (String) async throws -> Void
    let onSent: () -> Void
    @State private var comment = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        AppDialog(title: "report_title", onDismiss: { model.popups.dismiss() }) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(text: $comment, prompt: Text("report_commentHint").foregroundStyle(model.theme.textMuted), axis: .vertical) { EmptyView() }
                    .lineLimit(2...5)
                    .font(.roboto(16))
                    .foregroundStyle(model.theme.textPrimary)
                    .focused($focused)
                    .padding(16)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? model.theme.primary : model.theme.textMuted, lineWidth: focused ? 2 : 1))
                ErrorLine(text: error)
            }
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("common_send") {
                guard !sending else { return }
                sending = true
                error = nil
                Task {
                    do {
                        try await onSend(comment.trimmingCharacters(in: .whitespacesAndNewlines))
                        model.popups.dismiss()
                        onSent()
                    } catch {
                        self.error = localizedError(error)
                    }
                    sending = false
                }
            }
        }
        .tint(model.theme.primary)
    }
}

/// После жалобы: «Заблокировать и этого пользователя?»
private struct BlockAfterReportDialog: View {
    @EnvironmentObject private var model: AppModel
    let peerLogin: String
    let onBlock: () async throws -> Void
    @State private var error: String?

    var body: some View {
        AppDialog(title: "report_blockTitle", onDismiss: { model.popups.dismiss() }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: tr("report_blockText"), peerLogin))
                ErrorLine(text: error)
            }
        } buttons: {
            DialogButton("report_blockLater") { model.popups.dismiss() }
            DialogButton("chatMenu_block") {
                Task {
                    do {
                        try await onBlock()
                        model.popups.dismiss()
                    } catch {
                        self.error = localizedError(error)
                    }
                }
            }
        }
        .tint(model.theme.primary)
    }
}

// MARK: - диалоги

/// Удаление сообщений: у собеседника тоже — галочкой (если уже доставлено).
private struct DeleteMessagesDialog: View {
    @EnvironmentObject private var model: AppModel
    let peerName: String
    let peerAccountId: String?
    let showPeerCheckbox: Bool
    let onConfirm: (Bool) -> Void
    @State private var forPeer = false
    @State private var appear: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.4 * appear).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close(nil) }
            VStack(spacing: 0) {
                Text("deleteMessage_title").font(.roboto(18, .semibold)).tracking(0).foregroundStyle(model.theme.textPrimary)
                if showPeerCheckbox {
                    Gap(8)
                    Button { forPeer.toggle() } label: {
                        HStack(spacing: 0) {
                            CheckboxM(checked: forPeer).frame(width: 24, height: 24)
                            Spacer().frame(width: 8)
                            Text("deleteMessage_alsoForPeer").font(.roboto(15)).tracking(0).foregroundStyle(model.theme.textPrimary)
                            Spacer().frame(width: 6)
                            PeerAvatar(accountId: peerAccountId, size: 20)
                            Spacer().frame(width: 4)
                            Text(verbatim: peerName).font(.roboto(15, .semibold)).tracking(0).foregroundStyle(model.theme.textPrimary).lineLimit(1)
                        }
                        .padding(4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: 8), color: model.theme.textPrimary))
                }
                Gap(14)
                HStack(spacing: 10) {
                    button("common_cancel", model.theme.primary) { close(nil) }
                    button("action_delete", errorRed) { close(showPeerCheckbox && forPeer) }
                }
            }
            .padding(16)
            .frame(maxWidth: 320)
            .background(model.theme.surface, in: RoundedRectangle(cornerRadius: cardRadius))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .contentShape(Rectangle())
            .onTapGesture {}
            .padding(.horizontal, 32)
            .scaleEffect(0.9 + 0.1 * appear)
            .opacity(appear)
        }
        .onAppear { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.16)) { appear = 1 } }
    }

    private func button(_ title: LocalizedStringKey, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.roboto(14, .semibold)).tracking(0).foregroundStyle(color)
                .frame(maxWidth: .infinity).frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(color, lineWidth: 1))
        }
        .buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: cardRadius), color: color))
    }

    /// nil — отмена; иначе удалить (true — и у собеседника).
    private func close(_ result: Bool?) {
        model.popups.dismiss()
        if let result { onConfirm(result) }
    }
}

/// Сброс сессии шифрования с подтверждением.
private struct ResetSessionDialog: View {
    @EnvironmentObject private var model: AppModel
    let peer: ChatSummary

    var body: some View {
        AppDialog(title: "chat_resetSessionTitle", onDismiss: { model.popups.dismiss() }) {
            Text("chat_resetSessionBody")
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("chat_resetSessionConfirm") {
                model.popups.dismiss()
                let peer = peer
                Task {
                    await model.core.chatService.resetSession(ChatPeer(peer))
                    model.toasts.show(tr("chat_resetSessionDone"))
                }
            }
        }
    }
}

// MARK: - прочее

/// Этап отправки вложения; при выгрузке — с процентом.
struct UploadStepText: View {
    @EnvironmentObject private var model: AppModel
    let messageId: String
    let step: String
    @State private var percent: Double?

    var body: some View {
        let label = tr(step)
        Text(verbatim: percent.map { "\(label) \(Int($0))%" } ?? label).font(.roboto(11).monospacedDigit())
            .task(id: messageId) { for await p in model.core.uploadProgress.stream() { percent = p[messageId] } }
    }
}

/// Квадратная кнопка со скруглёнными углами и стрелкой вниз — к последнему сообщению.
struct ScrollDownButton: View {
    @EnvironmentObject private var model: AppModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MIcon(.keyboardArrowDown, tint: model.theme.textPrimary)
                .frame(width: 44, height: 44)
                .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("chat_scrollToBottom"))
    }
}
