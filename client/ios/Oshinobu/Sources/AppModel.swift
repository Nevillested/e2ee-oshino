import AudioToolbox
import Combine
import OshinobuCore
import SwiftUI
import UserNotifications

/// Состояние приложения поверх ядра: фаза входа, тема, язык, статус соединения,
/// список чатов. Обновления из ядра (Broadcast/StateValue) — на главный поток.
@MainActor
final class AppModel: ObservableObject, RouterHost {
    enum Phase: Equatable { case launching, signedOut, signedIn }

    @Published var phase: Phase = .launching
    @Published var connection: ConnectionStatus = .connecting
    @Published var chats: [ChatSummary] = []
    @Published var theme: AppTheme = .navy
    @Published var locale: Locale = Locale(identifier: "en")
    /// Логин чата, открытого на экране (уведомления и звук для него не нужны).
    @Published var openChatLogin: String?
    var isForeground = true

    // RouterHost вызывается из ядра с любых потоков — значения дублируются атомарно
    private let hostState = HostState()
    lazy var core: OshinobuCore = OshinobuCore(host: self, rtcEngine: WebRtcEngine())
    lazy var callController = CallController(core: core)

    private var tasks: [Task<Void, Never>] = []

    init() {
        let prefs = UserDefaultsPrefs()
        theme = AppTheme.byId(prefs.string("ui_theme") ?? "dark")
        locale = Locale(identifier: prefs.string("ui_locale") ?? (Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en"))
    }

    // MARK: запуск

    private var launchTask: Task<Void, Never>?

    /// Поднять сессию — с экрана-заставки или по пушу (без окна); повторный вызов ждёт первый.
    func launch() async {
        if launchTask == nil {
            launchTask = Task {
                _ = callController // CallKit-провайдер — с запуска: входящий может прийти сразу
                observeCore()
                let resumed = await core.resumeSession()
                phase = resumed ? .signedIn : .signedOut
                if resumed { await requestNotificationPermission() }
            }
        }
        await launchTask?.value
        if phase == .signedIn { core.ws.wake() } // по пушу после долгой паузы — подключиться сразу
    }

    private func observeCore() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            guard let stream = self?.core.ws.status.stream() else { return }
            for await s in stream { self?.connection = s }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            self.reloadChats()
            for await _ in self.core.chats.changes.stream() { self.reloadChats() }
        })
        tasks.append(Task { [weak self] in
            guard let stream = self?.core.ws.sessionInvalidated.stream() else { return }
            for await _ in stream {
                // вошли с этим аккаунтом на другом устройстве
                self?.core.signOutLocally()
                self?.phase = .signedOut
            }
        })
    }

    func reloadChats() {
        chats = core.chats.knownPeers()
        // непрочитанные (без замьюченных) — на значке приложения
        let unread = chats.filter { !$0.muted }.reduce(0) { $0 + $1.unreadCount }
        UNUserNotificationCenter.current().setBadgeCount(unread)
    }

    func signedIn() async {
        phase = .signedIn
        reloadChats()
        await requestNotificationPermission()
    }

    func logout() async {
        await core.logout()
        phase = .signedOut
    }

    // MARK: настройки

    func setTheme(_ t: AppTheme) {
        theme = t
        core.prefs.set("ui_theme", t.id)
    }

    func setLanguage(_ tag: String) {
        locale = Locale(identifier: tag)
        core.prefs.set("ui_locale", tag)
        if let token = core.session.token { Task { try? await core.api.updateLanguage(token: token, language: tag) } }
    }

    // MARK: уведомления

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func clearDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: RouterHost

    nonisolated var openChatPeerLogin: String? { hostState.openChat }
    nonisolated var isAppInForeground: Bool { hostState.foreground }

    nonisolated func playMessageSound() { AudioServicesPlaySystemSound(1003) }

    nonisolated func showBackgroundMessageNotification() {
        // без содержимого: текст — только внутри приложения
        let content = UNMutableNotificationContent()
        content.title = "Oshinobu"
        content.body = NSLocalizedString("push_newMessageBody", comment: "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "new_message", content: content, trigger: nil))
    }

    func chatOpened(_ login: String?) {
        openChatLogin = login
        hostState.openChat = login
    }

    func foregroundChanged(_ value: Bool) {
        isForeground = value
        hostState.foreground = value
    }
}

/// Состояние для RouterHost, читаемое с любого потока.
private final class HostState: @unchecked Sendable {
    private let lock = NSLock()
    private var _openChat: String?
    private var _foreground = true

    var openChat: String? {
        get { lock.lock(); defer { lock.unlock() }; return _openChat }
        set { lock.lock(); _openChat = newValue; lock.unlock() }
    }

    var foreground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _foreground }
        set { lock.lock(); _foreground = newValue; lock.unlock() }
    }
}
