import OshinobuCore
import SwiftUI

// Главный экран — как у Android (ui/home/HomeScreen.kt): три вкладки (чаты, настройки, профиль)
// с плавающей овальной панелью внизу, статус соединения вместо заголовка, поиск собеседника по логину.

/// Экраны после входа (стек поверх главного).
enum AppRoute: Hashable {
    case chat(ChatSummary)
    case theme
    case peerProfile(accountId: String, login: String)
    case media(peerLogin: String, messageId: String)
    case forward
}

typealias AppNavigator = StackNav<AppRoute>

extension StackNav where Route == AppRoute {
    func open(_ route: AppRoute) { push(route) }
}

/// Что пересылаем: живёт от выбора «Переслать» до открытия чата-получателя (forwardDraft на Android).
@MainActor
final class ForwardDraft: ObservableObject {
    var items: [ForwardItem] = []
    /// Чат, который откроется с пересылаемым в поле ввода.
    var target: String?

    func take(for login: String) -> [ForwardItem] {
        guard target == login else { return [] }
        defer { items = []; target = nil }
        return items
    }
}

struct SignedInFlow: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var nav = AppNavigator(transition: { route in
        switch route {
        case .peerProfile: .scaleFade
        // просмотр фото/видео проявляется поверх чата: чат будто быстро затемняется
        case .media: .fade
        default: .slide
        }
    }, sharedAvatar: { route in
        if case let .peerProfile(accountId, _) = route { return accountId }
        return nil
    }, swipeBack: { route in
        if case .media = route { return false }
        return true
    })
    @StateObject private var forwardDraft = ForwardDraft()
    /// Плеер голосовых и видеосообщений — один на всё приложение: выход из чата его не останавливает.
    @StateObject private var playback = PlaybackCoordinator()

    var body: some View {
        NavHost(nav: nav) {
            HomeView()
        } screen: { route in
            switch route {
            case let .chat(peer): ChatView(peer: peer, core: model.core)
            case .theme: ThemeScreen()
            case let .peerProfile(accountId, login): PeerProfileView(accountId: accountId, login: login)
            case let .media(peerLogin, messageId): MediaViewerScreen(peerLogin: peerLogin, messageId: messageId)
            case .forward: ForwardScreen()
            }
        }
        .environmentObject(nav)
        .environmentObject(forwardDraft)
        .environmentObject(playback)
        .onDisappear { playback.stop() }
    }
}

enum HomeTab: Int, CaseIterable { case chats, settings, profile }

/// Отступ снизу у списков вкладок — под плавающую панель вкладок.
let homeTabsReserve: CGFloat = 80

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AppNavigator
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var tab = HomeTab.chats
    @State private var forward = true
    @State private var searchOpen = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            OngoingCallBanner(peerLogin: nil)
            GeometryReader { g in
                ZStack(alignment: .top) {
                    tabContent(width: g.size.width)
                    if searchOpen && tab == .chats {
                        SearchResults(query: query, onOpen: { peer in
                            closeSearch()
                            nav.open(.chat(peer))
                        }, onOpenSelf: { select(.profile) })
                    }
                    HomeTabs(tab: tab, onSelect: select)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        // ниже — до половины жестовой полосы, как поле ввода в чате
                        .ignoresSafeArea(.container, edges: .bottom)
                    if tab == .chats { FloatingVideoNote() }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(swipe)
            }
        }
        .background(model.theme.background.ignoresSafeArea())
        #if DEBUG
        .onAppear(perform: applyDebugLaunch)
        #endif
        .onChange(of: searchFocused) { was, now in
            // клавиатуру убрали — поиск закрыт, как на Android
            if was && !now && searchOpen { closeSearch() }
        }
    }

    // MARK: верхняя панель

    @ViewBuilder private var topBar: some View {
        switch tab {
        case .chats:
            TopBar {
                ZStack(alignment: .leading) {
                    if searchOpen {
                        TextField(text: $query, prompt: Text("newChat_loginHint").foregroundStyle(model.theme.textMuted)) { EmptyView() }
                            .font(.roboto(16))
                            .foregroundStyle(model.theme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($searchFocused)
                            .padding(.horizontal, 16)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else {
                        ConnectionStatusText().padding(.horizontal, 8).transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: searchOpen)
            } actions: {
                IconButtonM(.swapVert) { model.popups.show { TransfersView() } }
                IconButtonM(searchOpen ? .close : .search) {
                    if searchOpen { closeSearch() } else { openSearch() }
                }
            }
        case .settings:
            TopBar { Text("settings_title") }
        case .profile:
            TopBar { EmptyView() }
        }
    }

    // MARK: вкладки

    @ViewBuilder private func tabContent(width: CGFloat) -> some View {
        let dir: CGFloat = forward ? 1 : -1
        ZStack {
            switch tab {
            case .chats:
                // играет голосовое или видеосообщение из чата: панель над списком; панель и список —
                // в одной колонке, меняются в такт (260 мс)
                VStack(spacing: 0) {
                    if playback.activeId != nil { MediaControlBar().transition(.move(edge: .top).combined(with: .opacity)) }
                    ChatList()
                }
                .animation(.easeInOut(duration: 0.26), value: playback.activeId != nil)
            case .settings: SettingsTab()
            case .profile: ProfileTab()
            }
        }
        .transition(.asymmetric(
            insertion: .offset(x: width / 4 * dir).combined(with: .opacity),
            removal: .offset(x: -width / 4 * dir).combined(with: .opacity)
        ))
        .id(tab)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Свайп влево/вправо — соседняя вкладка по кругу.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { v in
            let dx = v.translation.width
            guard abs(dx) > 60, abs(dx) > abs(v.translation.height) * 1.5 else { return }
            let n = HomeTab.allCases.count
            let next = dx < 0 ? (tab.rawValue + 1) % n : (tab.rawValue - 1 + n) % n
            select(HomeTab(rawValue: next)!)
        }
    }

    private func select(_ t: HomeTab) {
        guard t != tab else { return }
        closeSearch()
        forward = t.rawValue > tab.rawValue
        withAnimation(.easeInOut(duration: 0.3)) { tab = t }
    }

    #if DEBUG
    /// Отладка на устройстве: `-startTab settings|profile`, `-openRoute theme|transfers`, `-openChat <login>`
    /// в аргументах запуска — сразу нужный экран (для сравнения скриншотов с Android).
    private func applyDebugLaunch() {
        let args = UserDefaults.standard
        if let t = args.string(forKey: "startTab") { tab = t == "settings" ? .settings : t == "profile" ? .profile : .chats }
        switch args.string(forKey: "openRoute") {
        case "theme": nav.open(.theme)
        case "transfers": model.popups.show { TransfersView() }
        default: break
        }
        if let login = args.string(forKey: "openChat") {
            // список чатов поднимается чуть позже первого кадра
            Task {
                for _ in 0..<50 {
                    if let chat = model.chats.first(where: { $0.peerLogin == login || login == "first" }) { return nav.open(.chat(chat)) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
    #endif

    private func openSearch() {
        searchOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
    }

    private func closeSearch() {
        searchFocused = false
        searchOpen = false
        query = ""
    }
}

/// Овальная панель вкладок: значок и подпись; выбранная — подсвеченный овал.
private struct HomeTabs: View {
    @EnvironmentObject private var model: AppModel
    let tab: HomeTab
    let onSelect: (HomeTab) -> Void
    @State private var avatar: Data?

    var body: some View {
        let width = UIScreen.main.bounds.width / 5
        HStack(spacing: 0) {
            button(.chats, "nav_chats", width) { MIcon(.oChat, size: 20, tint: $0) }
            button(.settings, "nav_settings", width) { MIcon(.tune, size: 20, tint: $0) }
            button(.profile, "nav_profile", width) { tint in
                if let avatar, let image = UIImage(data: avatar) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 20, height: 20).clipShape(Circle())
                } else {
                    MIcon(.oPerson, size: 20, tint: tint)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(model.theme.surface.opacity(0.92), in: Capsule())
        .overlay(Capsule().strokeBorder(model.theme.textMuted.opacity(0.18), lineWidth: 1))
        .padding(.bottom, windowSafeArea.bottom / 2 + 6)
        .task {
            for await value in model.core.myAccount.avatar.stream() { avatar = value }
        }
    }

    private func button<I: View>(_ t: HomeTab, _ label: LocalizedStringKey, _ width: CGFloat, @ViewBuilder icon: (Color) -> I) -> some View {
        let selected = t == tab
        let tint = selected ? model.theme.primary : model.theme.textPrimary
        return Button { onSelect(t) } label: {
            VStack(spacing: 2) {
                icon(tint)
                Text(label).font(.roboto(10, selected ? .semibold : .regular)).foregroundStyle(tint).lineLimit(1).lineBox(10)
            }
            .frame(width: width)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? model.theme.primary.opacity(0.16) : .clear))
            .animation(.easeInOut(duration: 0.22), value: selected)
        }
        .buttonStyle(RippleStyle(shape: Capsule(), color: model.theme.textPrimary))
        .padding(.horizontal, 2)
    }
}

/// Состояние соединения с сервером — вместо заголовка, обновляется само.
struct ConnectionStatusText: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let key: LocalizedStringKey = switch model.connection {
        case .waitingForNetwork: "connection_waitingForNetwork"
        case .connecting: "connection_connecting"
        case .connected: "connection_connected"
        case .reconnecting: "connection_reconnecting"
        }
        Text(key).font(.roboto(12)).foregroundStyle(model.theme.textMuted)
            .id(model.connection)
            .transition(.opacity)
            .animation(.easeInOut, value: model.connection)
    }
}

// MARK: - поиск

private enum SearchResult {
    case me
    case found(login: String, accountId: String, displayName: String?)
    case notFound(String)
}

/// Результат поиска по логину — карточка под панелью; пока печатают, сервер не дёргаем (400 мс).
private struct SearchResults: View {
    @EnvironmentObject private var model: AppModel
    let query: String
    let onOpen: (ChatSummary) -> Void
    let onOpenSelf: () -> Void
    @State private var loading = false
    @State private var result: SearchResult?

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // якорь всегда на месте: на пустом Group поиск (.task) не запускался вовсе
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if loading || result != nil {
                VStack(spacing: 0) {
                    switch result {
                    case nil:
                        AppLoadingIndicator(size: 24).frame(maxWidth: .infinity).padding(16)
                    case let .notFound(message):
                        Text(verbatim: message).foregroundStyle(model.theme.textMuted).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    case .me:
                        row(title: model.core.session.login ?? "", subtitle: tr("nav_profile")) { MyAvatar(size: 40) } action: { onOpenSelf() }
                    case let .found(login, accountId, displayName):
                        row(title: displayName ?? login, subtitle: displayName == nil ? nil : login) {
                            PeerAvatar(accountId: accountId, size: 40)
                        } action: {
                            Task { if let peer = try? await model.core.openChat(login: login) { onOpen(peer) } }
                        }
                    }
                }
                .background(model.theme.surface, in: RoundedRectangle(cornerRadius: cardRadius))
                .clipShape(RoundedRectangle(cornerRadius: cardRadius))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .task(id: trimmed) { await search(trimmed) }
    }

    private func row<A: View>(title: String, subtitle: String?, @ViewBuilder avatar: () -> A, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                avatar()
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title).font(.roboto(16, .semibold)).foregroundStyle(model.theme.textPrimary)
                    if let subtitle { Text(verbatim: subtitle).font(.roboto(13)).foregroundStyle(model.theme.textMuted) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
    }

    private func search(_ login: String) async {
        result = nil
        guard !login.isEmpty else {
            loading = false
            return
        }
        loading = true
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        if login == model.core.session.login {
            result = .me
        } else if let token = model.core.session.token {
            do {
                if let p = try await model.core.api.getAccountProfile(token: token, login: login) {
                    result = .found(login: p.login, accountId: p.accountId, displayName: p.displayName == p.login ? nil : p.displayName)
                } else {
                    result = .notFound(tr("error_userNotFound"))
                }
            } catch {
                guard !Task.isCancelled else { return }
                result = .notFound(localizedError(error))
            }
        }
        loading = false
    }
}

// MARK: - список чатов

private struct ChatList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.chats) { chat in ChatRow(chat: chat) }
            }
            .padding(.bottom, homeTabsReserve)
        }
    }
}

private struct ChatRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AppNavigator
    let chat: ChatSummary
    @State private var frame: CGRect = .zero
    @State private var longPressed = false

    var body: some View {
        let unread = chat.unreadCount > 0
        let accent = unread ? model.theme.primary : model.theme.textMuted
        Button {
            if longPressed {
                longPressed = false
                return
            }
            nav.open(.chat(chat))
        } label: {
            HStack(spacing: 0) {
                PeerAvatar(accountId: chat.lastKnownAccountId, size: 54)
                Spacer().frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    let nameFont = Font.roboto(17, unread ? .bold : .semibold)
                    if chat.isDeleted {
                        Text("home_deletedAccount").font(nameFont).foregroundStyle(model.theme.textPrimary).lineLimit(1)
                    } else {
                        PeerName(accountId: chat.lastKnownAccountId, login: chat.peerLogin).font(nameFont).tracking(0).foregroundStyle(model.theme.textPrimary)
                    }
                    Text(verbatim: ChatStore.decodePreview(chat.lastMessage) { tr($0) })
                        .font(.roboto(14, unread ? .semibold : .regular)).foregroundStyle(model.theme.textMuted).lineLimit(1).lineBox(14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    if unread {
                        Text(verbatim: chat.unreadCount > 9 ? "9+" : "\(chat.unreadCount)").font(.roboto(12, .bold)).foregroundStyle(model.theme.onPrimary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(model.theme.primary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if chat.chatPinnedAt != nil { MIcon(.pushPin, size: 13, tint: model.theme.textMuted) }
                    if chat.muted { MIcon(.notificationsOff, size: 14, tint: model.theme.textMuted) }
                    if chat.blockedByMe || chat.blockingMe { MIcon(.block, size: 13, tint: model.theme.textMuted) }
                    if chat.lastTimestamp > 0 {
                        if chat.lastMessageIsMine { MIcon(chat.lastMessageIsRead ? .doneAll : .done, size: 14, tint: accent) }
                        Text(verbatim: formatChatTime(chat.lastTimestamp)).font(.roboto(12, unread ? .bold : .regular)).foregroundStyle(accent).lineBox(12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(unread ? model.theme.primary.opacity(0.12) : .clear)
        }
        .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
        .globalFrame($frame)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            longPressed = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showMenu()
        })
    }

    private func showMenu() {
        let chat = chat
        let core = model.core
        let model = model
        model.popups.menu(at: frame, offsetX: 72) {
            if chat.chatPinnedAt != nil {
                MenuItemM("chatMenu_unpin") { core.chats.setChatPinned(chat.peerLogin, pinned: false) }
            } else {
                MenuItemM("chatMenu_pin") { core.chats.setChatPinned(chat.peerLogin, pinned: true) }
            }
            MenuItemM(chat.muted ? "chatMenu_unmute" : "chatMenu_mute") { run { try await core.setMuted(chat, !chat.muted) } }
            MenuItemM(chat.blockedByMe ? "chatMenu_unblock" : "chatMenu_block") { run { try await core.setBlocked(chat, !chat.blockedByMe) } }
            MenuDividerM()
            MenuItemM("chatMenu_clearHistory", danger: true) { model.popups.show { DeleteChatDialog(chat: chat, delete: false) } }
            MenuItemM("chatMenu_deleteChat", danger: true) { model.popups.show { DeleteChatDialog(chat: chat, delete: true) } }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { model.toasts.show(localizedError(error)) }
        }
    }
}

/// Подтверждение очистки/удаления — с галочкой «также у собеседника».
struct DeleteChatDialog: View {
    @EnvironmentObject private var model: AppModel
    let chat: ChatSummary
    let delete: Bool
    @State private var forPeer = false

    var body: some View {
        AppDialog(title: delete ? "chatMenu_deleteChatTitle" : "chatMenu_clearHistoryTitle", onDismiss: { model.popups.dismiss() }) {
            Button { forPeer.toggle() } label: {
                HStack(spacing: 0) {
                    CheckboxM(checked: forPeer).frame(width: 48, height: 48)
                    Text(verbatim: "\(tr("deleteMessage_alsoForPeer")) \(chat.peerLogin)").font(.roboto(14)).foregroundStyle(model.theme.textPrimary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        } buttons: {
            TextButtonM("common_cancel") { model.popups.dismiss() }
            TextButtonM(delete ? "chatMenu_deleteChatConfirm" : "chatMenu_clearHistoryConfirm", color: errorRed) {
                model.popups.dismiss()
                let chat = chat, forPeer = forPeer, delete = delete, core = model.core
                Task { await core.chatService.clearOrDelete(ChatPeer(chat), deleteChat: delete, forPeer: forPeer) }
            }
        }
    }
}

// MARK: - аватары и имена

/// Аватар по байтам: фото по кругу, нет — силуэт на круге цвета поверхности.
struct AvatarImage: View {
    @EnvironmentObject private var model: AppModel
    let data: Data?
    let size: CGFloat

    var body: some View {
        ZStack {
            model.theme.surface
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                MIcon(.person, size: size * 0.6, tint: model.theme.textMuted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Аватар собеседника по account_id: сразу с диска, затем — обновление с сервера.
struct PeerAvatar: View {
    @EnvironmentObject private var model: AppModel
    let accountId: String?
    let size: CGFloat
    @State private var data: Data?

    var body: some View {
        AvatarImage(data: data, size: size)
            .task(id: accountId) {
                guard let accountId, !accountId.isEmpty else { return }
                data = await model.core.avatars.get(accountId)
                for await changed in model.core.avatars.changes.stream() where changed == accountId {
                    data = await model.core.avatars.get(accountId)
                }
            }
    }
}

/// Свой аватар (вкладка профиля, поиск).
struct MyAvatar: View {
    @EnvironmentObject private var model: AppModel
    let size: CGFloat
    @State private var data: Data?

    var body: some View {
        AvatarImage(data: data, size: size)
            .task { for await value in model.core.myAccount.avatar.stream() { data = value } }
    }
}

/// Отображаемое имя собеседника (display_name из профиля), пока не загрузилось — логин.
struct PeerName: View {
    @EnvironmentObject private var model: AppModel
    let accountId: String?
    let login: String
    @State private var name: String?

    var body: some View {
        Text(verbatim: name ?? login).lineLimit(1)
            .task(id: accountId) {
                guard let accountId, !accountId.isEmpty else { return }
                let profiles = model.core.peerProfiles
                name = await profiles.peek(accountId)?.displayName
                if let p = await profiles.get(accountId, login: login) { name = p.displayName }
                for await changed in profiles.changes.stream() where changed == accountId {
                    name = await profiles.get(accountId, login: login)?.displayName ?? login
                }
            }
    }
}

/// Checkbox Material 3: квадрат 18 со скруглением 2; отмечен — заливка акцентом и галочка.
struct CheckboxM: View {
    @EnvironmentObject private var model: AppModel
    let checked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(checked ? model.theme.primary : .clear)
            RoundedRectangle(cornerRadius: 2).strokeBorder(checked ? model.theme.primary : model.theme.textMuted, lineWidth: 2)
            if checked { MIcon(.check, size: 16, tint: model.theme.onPrimary) }
        }
        .frame(width: 18, height: 18)
        .animation(.easeOut(duration: 0.15), value: checked)
    }
}
