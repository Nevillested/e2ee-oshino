import OshinobuCore
import PhotosUI
import SwiftUI

/// Переписка с собеседником: лента снизу вверх, пузыри, ответ свайпом, отправка.
struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let peer: ChatSummary
    @State private var messages: [StoredMessage] = []
    @State private var draft = ""
    @State private var replyTo: StoredMessage?
    @State private var editing: StoredMessage?
    @State private var deleting: StoredMessage?
    @State private var scrollTarget: String?
    @State private var peerOnline = false
    @State private var peerLastSeenMs: Int64 = 0
    @State private var peerTyping = false
    @State private var typingClear: Task<Void, Never>?
    @State private var lastTypingSent = Date.distantPast
    @State private var showProfile = false
    @State private var wallpaper: UIImage?
    @State private var forwarding: StoredMessage?
    @State private var showStickers = false
    @State private var stickerSheet: String?
    @State private var sharing: URL?
    @State private var searching = false
    @State private var query = ""
    /// Верх последнего сообщения и высота ленты — для кнопки «вниз».
    @State private var lastRowTop: CGFloat = .infinity
    @State private var viewportHeight: CGFloat = 0
    @State private var pickingWallpaper = false
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var wallpaperDraft: UIImage?
    @State private var toast: String?
    /// Режим выбора: отмеченные сообщения.
    @State private var selected: Set<String> = []
    @State private var selecting = false
    @State private var deletingSelected = false
    @State private var forwardingSelected = false
    @State private var confirmClear = false
    @State private var confirmDeleteChat = false
    @FocusState private var inputFocused: Bool

    private var current: ChatSummary { model.chats.first { $0.peerLogin == peer.peerLogin } ?? peer }

    var body: some View {
        VStack(spacing: 0) {
            if let pinnedId = current.pinnedMessageId, let pinned = messages.first(where: { $0.messageId == pinnedId }) {
                HStack {
                    Rectangle().fill(model.theme.primary).frame(width: 3)
                    VStack(alignment: .leading) {
                        Text("chat_pinnedMessage").font(.caption.bold()).foregroundStyle(model.theme.primary)
                        Text(pinned.text.isEmpty ? ChatStore.decodePreview(ChatStore.previewMarker(pinned)) { NSLocalizedString($0.replacingOccurrences(of: ".", with: "_"), comment: "") } : pinned.text)
                            .font(.caption).lineLimit(1).foregroundStyle(model.theme.textPrimary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12).padding(.top, 4)
                .onTapGesture { scrollTarget = pinnedId }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(messages) { m in
                            HStack(spacing: 8) {
                                if selecting {
                                    Image(systemName: selected.contains(m.messageId) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(selected.contains(m.messageId) ? model.theme.primary : model.theme.textMuted)
                                        .transition(.move(edge: .leading).combined(with: .opacity))
                                }
                                MessageRow(message: m, peerLogin: current.peerLogin, onReply: { replyTo = m; inputFocused = true },
                                           onStickerTap: { stickerSheet = $0 })
                                    .allowsHitTesting(!selecting)
                            }
                            .id(m.messageId)
                            .background {
                                if m.messageId == messages.last?.messageId {
                                    GeometryReader { g in
                                        Color.clear.preference(key: LastRowTopKey.self, value: g.frame(in: .named("chatScroll")).minY)
                                    }
                                }
                            }
                            .transition(.asymmetric(insertion: .opacity, removal: .dissolve))
                            .contentShape(Rectangle())
                            .onTapGesture { if selecting { toggleSelection(m.messageId) } }
                            .contextMenu { if !selecting { menu(for: m) } }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: "chatScroll")
                .background { GeometryReader { g in Color.clear.preference(key: ViewportHeightKey.self, value: g.size.height) } }
                .onPreferenceChange(LastRowTopKey.self) { lastRowTop = $0 }
                .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
                .overlay(alignment: .bottomTrailing) {
                    // последнее сообщение целиком ушло за низ ленты — кнопка «вниз»
                    if viewportHeight > 0 && lastRowTop >= viewportHeight && !selecting, let lastId = messages.last?.messageId {
                        ScrollDownButton {
                            // та же прокрутка, что и переход к закрепу
                            withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(lastId, anchor: .bottom) }
                        }
                        .padding(12)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: viewportHeight > 0 && lastRowTop >= viewportHeight)
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.messageId) { id in
                    if let id { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onChange(of: scrollTarget) { id in
                    // переход к закрепу — плавная прокрутка
                    if let id { withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) }; scrollTarget = nil }
                }
            }
            .background {
                if let wallpaper {
                    Image(uiImage: wallpaper).resizable().scaledToFill().ignoresSafeArea().clipped()
                } else {
                    model.theme.chatBackground
                }
            }
            if selecting { selectionBar } else { composer }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    AvatarView(accountId: current.lastKnownAccountId, login: current.peerLogin, size: 32)
                        .onTapGesture { showProfile = true }
                    VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: current.peerLogin).font(.headline).foregroundStyle(model.theme.textPrimary)
                    presenceLine.font(.caption).foregroundStyle(peerOnline || peerTyping ? model.theme.primary : model.theme.textMuted)
                        .contentTransition(.opacity).animation(.easeInOut, value: peerTyping)
                    }
                }
            }
        }
        .task { await followPresence() }
        .task { await followWallpaper() }
        .sheet(isPresented: Binding(get: { forwarding != nil }, set: { if !$0 { forwarding = nil } })) {
            ForwardPicker { target in
                if let text = forwarding?.text { Task { try? await model.core.chatService.forwardText(text, to: ChatPeer(target)) } }
                forwarding = nil
            }
            .environmentObject(model)
        }
        .confirmationDialog("deleteMessage_title", isPresented: $deletingSelected, titleVisibility: .visible) {
            Button("action_delete", role: .destructive) { removeSelected(forBoth: false) }
            Button("\(NSLocalizedString("deleteMessage_alsoForPeer", comment: "")) \(current.peerLogin)", role: .destructive) { removeSelected(forBoth: true) }
        }
        .sheet(isPresented: $forwardingSelected) {
            ForwardPicker { target in
                let texts = messages.filter { selected.contains($0.messageId) && !$0.text.isEmpty && !$0.isMedia }.sorted { $0.timestamp < $1.timestamp }
                Task { for m in texts { try? await model.core.chatService.forwardText(m.text, to: ChatPeer(target)) } }
                endSelection()
            }
            .environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { stickerSheet != nil }, set: { if !$0 { stickerSheet = nil } })) {
            if let id = stickerSheet {
                StickerPackSheet(stickerId: id, peer: current).environmentObject(model).presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { ShareSheet(items: [sharing]) }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(verbatim: toast).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .photosPicker(isPresented: $pickingWallpaper, selection: $wallpaperItem, matching: .images)
        .onChange(of: wallpaperItem) { item in
            guard let item else { return }
            wallpaperItem = nil
            Task {
                // исходник с запасом на увеличение; preparingThumbnail учитывает ориентацию
                if let data = try? await item.loadTransferable(type: Data.self), let full = UIImage(data: data) {
                    let k = min(1, 2560 / max(full.size.width, full.size.height))
                    wallpaperDraft = await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * k, height: full.size.height * k)) ?? full
                } else {
                    showToast(NSLocalizedString("error_wallpaperFailed", comment: ""))
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { wallpaperDraft != nil }, set: { if !$0 { wallpaperDraft = nil } })) {
            if let draft = wallpaperDraft, let account = current.lastKnownAccountId {
                WallpaperEditor(image: draft, peerLogin: current.peerLogin, peerAccountId: account).environmentObject(model)
            }
        }
        .sheet(isPresented: $searching) {
            ChatSearchSheet(messages: messages, query: $query) { id in
                searching = false
                scrollTarget = id
            }
            .environmentObject(model)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStickers) {
            StickerPanel(peer: current).environmentObject(model).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showProfile) { PeerProfileView(chat: current).environmentObject(model).presentationDetents([.medium, .large]) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { startCall() } label: { Image(systemName: "phone.fill") }
                    .disabled(current.lastKnownDeviceId == nil || current.blockedByMe || current.blockingMe)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { searching = true } label: { Label("chat_searchAction", systemImage: "magnifyingglass") }
                    Button { pickingWallpaper = true } label: { Label("chat_wallpaperAction", systemImage: "photo") }
                    if wallpaper != nil, let account = current.lastKnownAccountId {
                        Button("chat_wallpaperRemove") {
                            Task {
                                do { try await model.core.wallpapers.remove(account) }
                                catch { showToast(NSLocalizedString("error_wallpaperFailed", comment: "")) }
                            }
                        }
                    }
                    Button(current.muted ? "chatMenu_unmute" : "chatMenu_mute") { Task { try? await model.core.setMuted(current, !current.muted) } }
                    Button(current.blockedByMe ? "chatMenu_unblock" : "chatMenu_block") { Task { try? await model.core.setBlocked(current, !current.blockedByMe) } }
                    Button("chat_resetSessionAction") { Task { await model.core.chatService.resetSession(ChatPeer(current)) } }
                    Divider()
                    Button("chatMenu_clearHistory", role: .destructive) { confirmClear = true }
                    Button("chatMenu_deleteChat", role: .destructive) { confirmDeleteChat = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await follow() }
        .confirmationDialog("chatMenu_clearHistoryTitle", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("chatMenu_clearHistoryConfirm", role: .destructive) { Task { await model.core.chatService.clearOrDelete(ChatPeer(current), deleteChat: false, forPeer: true) } }
        }
        .confirmationDialog("chatMenu_deleteChatTitle", isPresented: $confirmDeleteChat, titleVisibility: .visible) {
            Button("chatMenu_deleteChatConfirm", role: .destructive) {
                Task { await model.core.chatService.clearOrDelete(ChatPeer(current), deleteChat: true, forPeer: true); dismiss() }
            }
        }
        .confirmationDialog("deleteMessage_title", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let m = deleting {
                Button("action_delete", role: .destructive) { remove(m, forBoth: false) }
                if m.isMine || !m.isCallLog {
                    Button("\(NSLocalizedString("deleteMessage_alsoForPeer", comment: "")) \(current.peerLogin)", role: .destructive) { remove(m, forBoth: true) }
                }
            }
        }
        .onAppear { model.chatOpened(peer.peerLogin) }
        .onDisappear { model.chatOpened(nil) }
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

    /// «печатает…» / «в сети» / «был(а) N мин назад» (как на Android).
    @ViewBuilder private var presenceLine: some View {
        if peerTyping {
            Text("presence_typing")
        } else if peerOnline {
            Text("presence_online")
        } else if peerLastSeenMs > 0 {
            let date = Date(timeIntervalSince1970: Double(peerLastSeenMs) / 1000)
            let minutes = Int(Date().timeIntervalSince(date) / 60)
            if minutes < 1 {
                Text("presence_justNow")
            } else if minutes < 60 {
                Text("\(minutes) \(NSLocalizedString("presence_minutesAgoSuffix", comment: ""))")
            } else {
                Text(date, format: .dateTime.day().month().hour().minute())
            }
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
                peerLastSeenMs = event["LastSeenMs"]?.int ?? 0
                if peerOnline { peerTyping = false }
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
        let fresh = model.core.chats.messages(peer.peerLogin).sorted { $0.timestamp < $1.timestamp }
        // что-то исчезло (удалил собеседник у обоих) — с той же анимацией, что своё удаление
        let removed = !Set(messages.map(\.messageId)).subtracting(fresh.map(\.messageId)).isEmpty
        if removed { withAnimation(.easeOut(duration: 0.35)) { messages = fresh } } else { messages = fresh }
    }

    /// Меню по долгому нажатию: реакции и действия (как на Android).
    @ViewBuilder private func menu(for m: StoredMessage) -> some View {
        let peer = ChatPeer(current)
        ControlGroup {
            ForEach(["❤️", "👍", "😂", "😮", "😢", "🔥"], id: \.self) { e in
                Button(e) { Task { await model.core.chatService.react(peer, messageId: m.messageId, emoji: m.myReaction == e ? nil : e) } }
            }
        }
        if m.isMine && m.status == MessageStatus.failed {
            Button {
                Task { if m.isMedia { await model.core.retryMedia(m, to: current) } else { await model.core.retryText(m, to: current) } }
            } label: { Label("action_retrySend", systemImage: "arrow.clockwise") }
        }
        Button { replyTo = m; inputFocused = true } label: { Label("action_reply", systemImage: "arrowshape.turn.up.left") }
        if m.isMedia && (m.mediaId != nil || m.localSourcePath != nil) {
            Button { Task { await saveToDevice(m) } } label: { Label("chat_saveToDevice", systemImage: "square.and.arrow.down") }
        }
        if !m.text.isEmpty && !m.isMedia {
            Button { forwarding = m } label: { Label("action_forward", systemImage: "arrowshape.turn.up.right") }
        }
        if !m.text.isEmpty {
            Button { UIPasteboard.general.string = m.text } label: { Label("action_copy", systemImage: "doc.on.doc") }
        }
        if m.isMine && !m.isMedia && !m.isSticker && !m.isCallLog {
            Button { editing = m; draft = m.text; inputFocused = true } label: { Label("action_edit", systemImage: "pencil") }
        }
        if current.pinnedMessageId == m.messageId {
            Button { Task { await model.core.chatService.pin(peer, messageId: nil) } } label: { Label("action_unpin", systemImage: "pin.slash") }
        } else {
            Button { Task { await model.core.chatService.pin(peer, messageId: m.messageId) } } label: { Label("action_pin", systemImage: "pin") }
        }
        Button {
            withAnimation(.spring(duration: 0.25)) { selecting = true; selected = [m.messageId] }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: { Label("action_select", systemImage: "checkmark.circle") }
        Button(role: .destructive) { deleting = m } label: { Label("action_delete", systemImage: "trash") }
    }

    /// Фото/видео — в «Фото», остальное — через «Поделиться» (сохранить в «Файлы» и т. п.).
    private func saveToDevice(_ m: StoredMessage) async {
        let url: URL?
        if let p = m.localSourcePath, FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p) }
        else if let spec = DownloadSpec.of(m, peerLogin: current.peerLogin) { url = try? await model.core.downloads.ensureDownloaded(spec) }
        else { url = nil }
        guard let url else { return showToast(NSLocalizedString("chat_saveToDeviceFailed", comment: "")) }
        if m.isFile || m.isVoice {
            sharing = url
            return
        }
        let ok = await PhotoLibrary.save(url, isVideo: m.isVideo || m.isVideoNote)
        showToast(NSLocalizedString(ok ? "chat_savedToDevice" : "chat_saveToDeviceFailed", comment: ""))
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }

    private func toggleSelection(_ id: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        if selected.isEmpty { withAnimation { selecting = false } }
    }

    private func endSelection() {
        withAnimation(.spring(duration: 0.25)) { selecting = false; selected = [] }
    }

    /// Панель режима выбора вместо поля ввода.
    private var selectionBar: some View {
        let chosen = messages.filter { selected.contains($0.messageId) }
        let texts = chosen.filter { !$0.text.isEmpty && !$0.isMedia }
        return HStack(spacing: 20) {
            Button { endSelection() } label: { Image(systemName: "xmark").font(.title3) }
            Text(verbatim: "\(selected.count)").font(.headline)
            Spacer()
            Button {
                UIPasteboard.general.string = texts.sorted { $0.timestamp < $1.timestamp }.map(\.text).joined(separator: "\n")
                endSelection()
            } label: { Image(systemName: "doc.on.doc").font(.title3) }
            .disabled(texts.isEmpty)
            Button { forwardingSelected = true } label: { Image(systemName: "arrowshape.turn.up.right").font(.title3) }
                .disabled(texts.isEmpty)
            Button(role: .destructive) { deletingSelected = true } label: { Image(systemName: "trash").font(.title3) }
        }
        .foregroundStyle(model.theme.primary)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(model.theme.background)
    }

    private func removeSelected(forBoth: Bool) {
        let ids = Array(selected)
        let peer = ChatPeer(current)
        withAnimation(.easeOut(duration: 0.3)) { messages.removeAll { selected.contains($0.messageId) } }
        endSelection()
        Task { await model.core.chatService.delete(peer, messageIds: ids, forBoth: forBoth) }
    }

    private func remove(_ m: StoredMessage, forBoth: Bool) {
        let peer = ChatPeer(current)
        deleting = nil
        withAnimation(.easeOut(duration: 0.3)) { messages.removeAll { $0.messageId == m.messageId } }
        Task { await model.core.chatService.delete(peer, messageIds: [m.messageId], forBoth: forBoth) }
    }

    @ViewBuilder private var composer: some View {
        VStack(spacing: 0) {
            if let editing {
                HStack {
                    Image(systemName: "pencil").foregroundStyle(model.theme.primary)
                    VStack(alignment: .leading) {
                        Text("chat_editingMessage").font(.caption.bold()).foregroundStyle(model.theme.primary)
                        Text(editing.text).font(.caption).lineLimit(1).foregroundStyle(model.theme.textMuted)
                    }
                    Spacer()
                    Button { self.editing = nil; draft = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(model.theme.textMuted) }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            if let replyTo {
                HStack {
                    Rectangle().fill(model.theme.primary).frame(width: 3)
                    VStack(alignment: .leading) {
                        Group { if replyTo.isMine { Text("chat_replyYou") } else { Text(verbatim: current.peerLogin) } }
                            .font(.caption.bold()).foregroundStyle(model.theme.primary)
                        Text(replyTo.text).font(.caption).lineLimit(1).foregroundStyle(model.theme.textMuted)
                    }
                    Spacer()
                    Button { self.replyTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(model.theme.textMuted) }
                }
                .padding(.horizontal, 12).padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                AttachButton(peer: current)
                    .disabled(current.blockedByMe || current.blockingMe)
                Button { showStickers = true } label: {
                    Image(systemName: "face.smiling").font(.title2).foregroundStyle(model.theme.textMuted).frame(width: 30, height: 40)
                }
                .disabled(current.blockedByMe || current.blockingMe)
                TextField("chat_messageHint", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .onChange(of: draft) { _ in
                        // «печатает» — не чаще раза в 3 с
                        if let deviceId = current.lastKnownDeviceId, !draft.isEmpty, Date().timeIntervalSince(lastTypingSent) > 3 {
                            lastTypingSent = Date()
                            model.core.ws.sendTyping(deviceId)
                        }
                    }
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && editing == nil {
                    // пустое поле — кружок и микрофон (удерживать), как на Android
                    VideoNoteButton(peer: current).disabled(current.blockedByMe || current.blockingMe)
                    MicButton(peer: current).disabled(current.blockedByMe || current.blockingMe)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(model.theme.primary)
                    }
                    .disabled(current.blockedByMe || current.blockingMe)
                }
            }
            .padding(8)
        }
        .background(model.theme.background)
        .animation(.spring(duration: 0.25), value: replyTo?.messageId)
    }

    private func startCall() {
        guard let deviceId = current.lastKnownDeviceId else { return }
        let callee = CallPeer(deviceId: deviceId, login: current.peerLogin, accountId: current.lastKnownAccountId)
        model.callController.startCall(callee)
        Task { await model.core.calls.startCall(callee) }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let reply = replyTo
        draft = ""
        replyTo = nil
        let peer = current
        if let original = editing {
            editing = nil
            if original.text != text { Task { await model.core.chatService.edit(ChatPeer(peer), messageId: original.messageId, newText: text) } }
            return
        }
        Task { await model.core.sendText(text, to: peer, replyTo: reply) }
    }
}

struct MessageRow: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let peerLogin: String
    let onReply: () -> Void
    var onStickerTap: ((String) -> Void)?
    @State private var dragX: CGFloat = 0

    var body: some View {
        if message.isCallLog || message.isUndecryptable {
            CenteredNotice(message: message, peerLogin: peerLogin)
        } else {
            HStack {
                if message.isMine { Spacer(minLength: 48) }
                if message.isSticker || message.isVideoNote {
                    // стикер и кружок — без пузыря, время под ними (как на Android)
                    VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                        if message.isVideoNote {
                            VideoNoteContent(message: message, peerLogin: peerLogin)
                        } else {
                            StickerContent(stickerId: message.stickerId ?? "").onTapGesture { onStickerTap?(message.stickerId ?? "") }
                        }
                        HStack(spacing: 4) {
                            Text(Date(timeIntervalSince1970: Double(message.timestamp) / 1000), format: .dateTime.hour().minute()).font(.caption2)
                            if message.isMine { StatusTick(status: message.status) }
                        }
                        .foregroundStyle(model.theme.textMuted)
                    }
                } else {
                    bubble
                }
                if !message.isMine { Spacer(minLength: 48) }
            }
            .offset(x: dragX)
            .gesture(
                // свайп строки влево — ответ (как на Android)
                DragGesture(minimumDistance: 20)
                    .onChanged { v in dragX = min(0, max(-80, v.translation.width)) }
                    .onEnded { _ in
                        if dragX <= -60 { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onReply() }
                        withAnimation(.spring(duration: 0.3)) { dragX = 0 }
                    }
            )
        }
    }

    private var bubble: some View {
        let mine = message.isMine
        return VStack(alignment: .leading, spacing: 4) {
            if let preview = message.replyToPreview {
                HStack(spacing: 6) {
                    Rectangle().fill(mine ? model.theme.onBubbleMine : model.theme.primary).frame(width: 2)
                    Text(preview).font(.caption).lineLimit(2)
                }
                .opacity(0.8)
            }
            if message.isMedia {
                if message.isVoice {
                    VoiceBubbleContent(message: message, peerLogin: peerLogin)
                } else {
                    MediaBubbleContent(message: message, peerLogin: peerLogin)
                    if let step = message.processingStep, message.status == MessageStatus.sending {
                        UploadStepText(messageId: message.messageId, step: step)
                    }
                }
            } else {
                Text(message.text).textSelection(.enabled)
            }
            HStack(spacing: 4) {
                if let r = message.peerReaction { Text(r) }
                if let r = message.myReaction, r != message.peerReaction { Text(r) }
                Spacer(minLength: 0)
                if message.edited { Image(systemName: "pencil").font(.caption2) }
                Text(Date(timeIntervalSince1970: Double(message.timestamp) / 1000), format: .dateTime.hour().minute()).font(.caption2)
                if mine { StatusTick(status: message.status) }
            }
            .opacity(0.75)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(mine ? model.theme.onBubbleMine : model.theme.textPrimary)
        .background(mine ? model.theme.bubbleMine : model.theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StatusTick: View {
    @EnvironmentObject private var model: AppModel
    let status: String

    var body: some View {
        switch status {
        case MessageStatus.sending, MessageStatus.queued: Image(systemName: "clock").font(.caption2)
        case MessageStatus.failed: Image(systemName: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(.red)
        case MessageStatus.read: Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(model.theme.sentTick)
        default: Image(systemName: "checkmark").font(.caption2)
        }
    }
}

/// Запись о звонке и заглушка «не удалось расшифровать» — по центру.
struct CenteredNotice: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let peerLogin: String

    var body: some View {
        let text: String = message.isUndecryptable
            ? String(format: NSLocalizedString("chat_undecryptable", comment: ""), peerLogin)
            : ChatStore.decodePreview(ChatStore.previewMarker(message)) { NSLocalizedString($0.replacingOccurrences(of: ".", with: "_"), comment: "") }
        Text(text).font(.footnote).italic(message.isUndecryptable).foregroundStyle(model.theme.textMuted)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(model.theme.surface.opacity(0.8), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

/// Выбор чата для пересылки.
struct ForwardPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (ChatSummary) -> Void

    var body: some View {
        NavigationStack {
            List(model.chats.filter { !$0.blockedByMe && !$0.blockingMe }) { chat in
                Button { onPick(chat); dismiss() } label: { ChatRow(chat: chat) }
                    .listRowBackground(model.theme.background)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(model.theme.background.ignoresSafeArea())
            .navigationTitle("action_forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common_cancel") { dismiss() } } }
        }
    }
}

/// Уход удалённого сообщения: растворяется с размытием и лёгким сжатием, соседи съезжают следом.
private struct DissolveModifier: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .blur(radius: progress * 12)
            .scaleEffect(1 - progress * 0.15)
    }
}

extension AnyTransition {
    static var dissolve: AnyTransition {
        .modifier(active: DissolveModifier(progress: 1), identity: DissolveModifier(progress: 0))
    }
}

/// Поиск по переписке (локально — текст есть только на устройстве): список совпадений, тап — к сообщению.
struct ChatSearchSheet: View {
    @EnvironmentObject private var model: AppModel
    let messages: [StoredMessage]
    @Binding var query: String
    let onPick: (String) -> Void

    private var results: [StoredMessage] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.fileName?.localizedCaseInsensitiveContains(q) ?? false) }.reversed()
    }

    var body: some View {
        NavigationStack {
            List(results) { m in
                Button { onPick(m.messageId) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: m.text.isEmpty ? (m.fileName ?? "") : m.text).lineLimit(2).foregroundStyle(model.theme.textPrimary)
                        Text(Date(timeIntervalSince1970: Double(m.timestamp) / 1000), format: .dateTime.day().month().year().hour().minute())
                            .font(.caption).foregroundStyle(model.theme.textMuted)
                    }
                }
                .listRowBackground(model.theme.background)
            }
            .overlay { if !query.isEmpty && results.isEmpty { Text("chat_searchNoResults").foregroundStyle(model.theme.textMuted) } }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(model.theme.background.ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("chat_searchHint"))
            .navigationTitle("chat_searchAction")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Этап отправки вложения; при выгрузке — с процентом.
struct UploadStepText: View {
    @EnvironmentObject private var model: AppModel
    let messageId: String
    let step: String
    @State private var percent: Double?

    var body: some View {
        let label = NSLocalizedString(step.replacingOccurrences(of: ".", with: "_"), comment: "")
        Text(verbatim: percent.map { "\(label) \(Int($0))%" } ?? label).font(.caption2.monospacedDigit())
            .task(id: messageId) { for await p in model.core.uploadProgress.stream() { percent = p[messageId] } }
    }
}

/// Верх последнего сообщения в координатах ленты; нет строки (ушла далеко) — бесконечность.
private struct LastRowTopKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Квадратная кнопка со скруглёнными углами и стрелкой вниз — к последнему сообщению.
struct ScrollDownButton: View {
    @EnvironmentObject private var model: AppModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down").font(.headline).foregroundStyle(model.theme.textPrimary)
                .frame(width: 44, height: 44)
                .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("chat_scrollToBottom"))
    }
}
