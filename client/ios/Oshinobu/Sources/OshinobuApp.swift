import OshinobuCore
import SwiftUI
import UserNotifications

@main
struct OshinobuApp: App {
    /// Модель живёт в делегате: по пушу приложение запускается и без окна.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRoot(model: delegate.model)
        }
        .onChange(of: scenePhase) { phase in
            let model = delegate.model
            // «в сети» — только пока человек видит приложение (как на Android)
            model.core.ws.sendForegroundState(phase == .active)
            model.foregroundChanged(phase == .active)
            if phase == .active { model.clearDeliveredNotifications() }
        }
    }
}

/// Тема и язык меняются на лету — корень следит за моделью.
private struct AppRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        RootView()
            .environmentObject(model)
            .environment(\.locale, model.locale)
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
            .tint(model.theme.primary)
    }
}

/// Корень навигации: заставка поднимает сессию, дальше — вход или главный экран.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var call = CallViewModel()

    var body: some View {
        ZStack {
            model.theme.background.ignoresSafeArea()
            switch model.phase {
            case .launching: SplashView()
            case .signedOut: NavigationStack { WelcomeView() }
            case .signedIn: AppLockGate { HomeView() }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.phase)
        .task {
            await model.launch()
            call.follow(model.core.calls)
        }
        // звонок — поверх всего, пока не закончится
        .fullScreenCover(isPresented: Binding(get: { call.state != .idle }, set: { _ in })) {
            CallView(call: call).environmentObject(model)
        }
    }
}
