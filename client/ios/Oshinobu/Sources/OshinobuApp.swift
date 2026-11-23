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
        .onChange(of: scenePhase) { _, phase in
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
        // окружение — последним: оно нужно и экранам, и слоям диалогов и подсказок поверх них
        RootView()
            .overlay { PopupOverlay(host: model.popups) }
            .overlay { ToastOverlay(center: model.toasts) }
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
            .tint(model.theme.primary)
            .font(.roboto(16))
            .tracking(0.5) // межбуквенный интервал обычного текста Compose (bodyLarge)
            .dynamicTypeSize(model.dynamicTypeSize)
            .environment(\.locale, model.locale)
            .environmentObject(model)
    }
}

/// Раскрытие кругом из центра — анимируемый круг-маска.
private struct RevealMask: ViewModifier, Animatable {
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View { content.clipShape(CircleReveal(fraction: fraction)) }
}

/// Экран въезжает справа (450 мс, EaseInOut) — как переход Android.
private let slideIn = AnyTransition.asymmetric(insertion: .move(edge: .trailing), removal: .identity)
    .animation(.timingCurve(0.42, 0, 0.58, 1, duration: 0.45))

/// Корень навигации: заставка поднимает сессию, дальше — вход или главный экран.
struct RootView: View {
    /// Раскрытие кругом 600 мс (FastOutSlowIn) из центра, где крутилась кошка; заставка под ним
    /// держится до конца и убирается по завершении анимации.
    private func startReveal() {
        guard revealed < 1 else { return }
        guard model.revealHome else {
            // после входа главный экран въезжает целиком, без круга
            revealed = 1
            return
        }
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.6)) { revealed = 1 } completion: { splashShown = false }
        }
    }

    @EnvironmentObject private var model: AppModel
    @StateObject private var call = CallViewModel()
    @State private var splashShown = true
    /// Раскрытие главного экрана после заставки: 0 — круг в точку, 1 — экран целиком.
    @State private var revealed: CGFloat = 0

    var body: some View {
        ZStack {
            model.theme.background.ignoresSafeArea()
            // заставка — отдельным слоем под экранами: после загрузки она остаётся, пока главный экран
            // раскрывается над ней кругом из того же центра, где крутилась кошка (как на Android)
            if splashShown { SplashView().zIndex(0) }
            switch model.phase {
            case .launching: Color.clear
            case .signedOut: AuthFlow().transition(slideIn).zIndex(1)
            case .signedIn:
                AppLockGate { SignedInFlow() }
                    .modifier(RevealMask(fraction: revealed))
                    .transition(model.revealHome ? .identity : slideIn)
                    .zIndex(1)
                    .onAppear(perform: startReveal)
            }
        }
        .onChange(of: model.phase) { was, now in
            // экран входа въезжает за 450 мс поверх заставки; главный экран снимает её сам — после раскрытия
            if was == .launching && now == .signedOut { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { splashShown = false } }
        }
        .task {
            await model.launch()
            call.follow(model.core.calls)
        }
        // звонок — поверх всего, пока не закончится (появляется и уходит сразу, без выезда)
        // (заставка убирается только после раскрытия: первая отрисовка главного экрана бывает дольше
        // анимации, и таймер снимал её раньше, чем круг успевал начаться)
        .overlay { CallScreens(call: call) }
        .environmentObject(call)
    }
}
