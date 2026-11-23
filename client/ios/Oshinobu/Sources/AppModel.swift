import AudioToolbox
import Combine
import Lottie
import OshinobuCore
import SwiftUI
import UserNotifications

/// Состояние приложения поверх ядра: фаза входа, тема, язык, статус соединения,
/// список чатов. Обновления из ядра (Broadcast/StateValue) — на главный поток.
@MainActor
final class AppModel: ObservableObject, RouterHost {
    enum Phase: Equatable { case launching, signedOut, signedIn }

    @Published var phase: Phase = .launching
    /// Главный экран сразу после заставки — раскрывается кругом (после входа — въезжает, как любой экран).
    private(set) var revealHome = false
    /// Когда показалась заставка: экран меняется ровно на стыке кругов кошки.
    private let splashStarted = Date()
    @Published var connection: ConnectionStatus = .connecting
    @Published var chats: [ChatSummary] = []
    @Published var theme: AppTheme = .navy
    @Published var locale: Locale = Locale(identifier: "en")
    /// Размер текста из настроек (шаги — как на Android).
    @Published private(set) var textScale: Double = 1.0
    /// Логин чата, открытого на экране (уведомления и звук для него не нужны).
    @Published var openChatLogin: String?
    /// На экране ли приложение; при запуске задаёт AppDelegate (по пушу оно стартует в фоне).
    var isForeground = false
    /// Всплывающие подсказки внизу экрана (Toast на Android).
    let toasts = ToastCenter()
    /// Диалоги и выпадающие меню поверх всего приложения.
    let popups = PopupHost()

    // RouterHost вызывается из ядра с любых потоков — значения дублируются атомарно
    private let hostState = HostState()
    lazy var core: OshinobuCore = OshinobuCore(host: self, rtcEngine: WebRtcEngine())
    lazy var callController = CallController(core: core)

    private var tasks: [Task<Void, Never>] = []

    init() {
        let prefs = UserDefaultsPrefs()
        theme = AppTheme.byId(prefs.string("ui_theme") ?? "dark")
        locale = Locale(identifier: prefs.string("ui_locale") ?? (Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en"))
        L10n.setLanguage(locale.identifier)
        textScale = UiSettings(secure: KeychainSecureStore(), prefs: prefs).textScale
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
                await waitForSplashLoop()
                revealHome = resumed
                phase = resumed ? .signedIn : .signedOut
                if resumed { await requestNotificationPermission() }
            }
        }
        await launchTask?.value
        if phase == .signedIn { core.ws.wake() } // по пушу после долгой паузы — подключиться сразу
    }

    /// Кошка докручивает хотя бы один полный круг, и экран меняется на стыке кругов — не посреди движения
    /// (дольше 4 с не ждём). Как SplashScreen на Android.
    private func waitForSplashLoop() async {
        let loop = LottieAnimation.named("loading_cat")?.duration ?? 2
        guard loop > 0 else { return }
        let elapsed = Date().timeIntervalSince(splashStarted)
        let target = max(1, (elapsed / loop).rounded(.up)) * loop
        let wait = min(target - elapsed, max(0, 4 - elapsed))
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
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
        revealHome = false
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

    func setTextScale(_ scale: Double) {
        textScale = scale
        core.settings.textScale = scale
    }

    /// Размер текста → размер шрифта системы, от которого считаются все шрифты приложения.
    var dynamicTypeSize: DynamicTypeSize {
        switch textScale {
        case ..<0.875: .small
        case ..<0.95: .medium
        case ..<1.05: .large
        case ..<1.15: .xLarge
        case ..<1.25: .xxLarge
        default: .xxxLarge
        }
    }

    /// Язык интерфейса; sendToServer — сохранить в аккаунте (при входе язык приходит из аккаунта).
    func setLanguage(_ tag: String, sendToServer: Bool = true) {
        L10n.setLanguage(tag)
        locale = Locale(identifier: tag)
        core.prefs.set("ui_locale", tag)
        if sendToServer, let token = core.session.token { Task { try? await core.api.updateLanguage(token: token, language: tag) } }
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

    nonisolated func playMessageSound() { MessageSound.play() }

    nonisolated func showBackgroundMessageNotification() {
        // без содержимого: текст — только внутри приложения
        let content = UNMutableNotificationContent()
        content.title = "Oshinobu"
        content.body = tr("push_newMessageBody")
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
    private var _foreground = false

    var openChat: String? {
        get { lock.lock(); defer { lock.unlock() }; return _openChat }
        set { lock.lock(); _openChat = newValue; lock.unlock() }
    }

    var foreground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _foreground }
        set { lock.lock(); _foreground = newValue; lock.unlock() }
    }
}
