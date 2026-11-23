import LocalAuthentication
import OshinobuCore
import SwiftUI

// Блокировка приложения — как у Android (ui/lock/AppLock.kt): экран с PIN и биометрией,
// цифровая клавиатура 3×4, установка PIN с повтором.

private let lockErrorColor = Color(hex: 0xFF5252)

/// Замок поверх всего приложения: при запуске, если блокировка включена, и после
/// возвращения из фона, если там провели не меньше заданного времени.
struct AppLockGate<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder let content: () -> Content
    @State private var locked = false
    @State private var leftAt: Date?

    var body: some View {
        ZStack {
            content()
            if locked && model.core.appLock.state.value.enabled {
                AppLockScreen { locked = false }.zIndex(1)
            }
        }
        .onAppear { locked = model.core.appLock.state.value.enabled }
        .onChange(of: scenePhase) { _, phase in
            let s = model.core.appLock.state.value
            guard s.enabled else { return }
            switch phase {
            case .background: leftAt = Date()
            case .active:
                if let leftAt, Date().timeIntervalSince(leftAt) >= Double(s.timeoutSeconds) { locked = true }
                leftAt = nil
            default: break
            }
        }
    }
}

/// Системный запрос Face ID / Touch ID; true — подтверждено.
private func authenticateBiometric() async -> Bool {
    let ctx = LAContext()
    ctx.localizedCancelTitle = tr("applock_usePinInstead")
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
    return (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: tr("applock_useBiometricReason"))) ?? false
}

/// Экран блокировки: PIN (проверяется, как только введено нужное число цифр) и, если
/// включено, биометрия — сразу при показе и по кнопке; после трёх неудач остаётся только PIN.
struct AppLockScreen: View {
    @EnvironmentObject private var model: AppModel
    let onUnlocked: () -> Void
    @State private var pin = ""
    @State private var error = false
    @State private var biometricFails = 0

    var body: some View {
        let s = model.core.appLock.state.value
        VStack(spacing: 0) {
            MIcon(.oLock, size: 48, tint: model.theme.primary)
            Gap(12)
            Text(error ? "applock_wrongPin" : "applock_enterPin").font(.roboto(16)).foregroundStyle(error ? lockErrorColor : model.theme.textPrimary)
            Gap(24)
            PinPad(value: pin, maxLength: s.pinLength, showError: error) { value in
                pin = value
                error = false
                if value.count == s.pinLength {
                    if model.core.appLock.checkPin(value) {
                        onUnlocked()
                    } else {
                        error = true
                        pin = ""
                    }
                }
            }
            if s.biometricEnabled && biometricFails < 3 {
                Gap(12)
                Button { tryBiometric() } label: {
                    HStack(spacing: 8) {
                        MIcon(.fingerprint, tint: model.theme.primary)
                        Text("applock_unlockWithBiometric").font(.roboto(14, .medium)).foregroundStyle(model.theme.primary)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                }
                .buttonStyle(RippleStyle(shape: Capsule(), color: model.theme.primary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.background.ignoresSafeArea())
        .contentShape(Rectangle())
        .onAppear { tryBiometric() }
    }

    private func tryBiometric() {
        let s = model.core.appLock.state.value
        guard s.biometricEnabled, biometricFails < 3 else { return }
        Task {
            if await authenticateBiometric() { onUnlocked() } else { biometricFails += 1 }
        }
    }
}

/// Точки введённых цифр и цифровая клавиатура 3×4.
struct PinPad: View {
    @EnvironmentObject private var model: AppModel
    let value: String
    let maxLength: Int
    let showError: Bool
    let onChange: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<value.count, id: \.self) { _ in
                    Circle().fill(showError ? lockErrorColor : model.theme.primary).frame(width: 12, height: 12).padding(.horizontal, 5)
                }
            }
            .frame(height: 16)
            Gap(32)
            VStack(spacing: 14) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]], id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(row, id: \.self) { key in
                            keyView(key).frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: 280)
                }
            }
        }
    }

    @ViewBuilder private func keyView(_ key: String) -> some View {
        switch key {
        case "":
            Color.clear.frame(width: 72, height: 72)
        case "⌫":
            Button { if !value.isEmpty { onChange(String(value.dropLast())) } } label: {
                MIcon(.oBackspace, tint: model.theme.textMuted).frame(width: 72, height: 72)
            }
            .buttonStyle(RippleStyle(shape: Circle(), color: model.theme.textPrimary))
            .disabled(value.isEmpty)
        default:
            Button { if value.count < maxLength { onChange(value + key) } } label: {
                Text(verbatim: key).font(.roboto(26)).foregroundStyle(model.theme.textPrimary)
                    .frame(width: 72, height: 72).background(model.theme.surface, in: Circle())
            }
            .buttonStyle(RippleStyle(shape: Circle(), color: model.theme.textPrimary))
            .disabled(value.count >= maxLength)
        }
    }
}

/// Новый PIN: 4–8 цифр, затем повтор; совпало — сохраняем и onDone(true). Во весь экран.
struct PinSetupDialog: View {
    @EnvironmentObject private var model: AppModel
    let onDone: (Bool) -> Void
    @State private var first: String?
    @State private var pin = ""
    @State private var mismatch = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconButtonM(.arrowBack) { onDone(false) }
                Text("applock_pin").font(.roboto(20)).foregroundStyle(model.theme.textPrimary)
                Spacer()
            }
            .padding(4)
            VStack(spacing: 0) {
                let entering = first == nil
                Text(entering ? "applock_newPin" : mismatch ? "applock_pinMismatch" : "applock_confirmPin")
                    .font(.roboto(16)).foregroundStyle(mismatch && !entering ? lockErrorColor : model.theme.textPrimary)
                    .multilineTextAlignment(.center)
                Gap(24)
                if entering {
                    PinPad(value: pin, maxLength: 8, showError: false) { pin = $0 }
                    Gap(24)
                    PrimaryButton("common_next", enabled: (4...8).contains(pin.count)) {
                        first = pin
                        pin = ""
                    }
                    .padding(.horizontal, 48)
                } else {
                    let target = first ?? ""
                    PinPad(value: pin, maxLength: target.count, showError: mismatch) { value in
                        pin = value
                        mismatch = false
                        if value.count == target.count {
                            if value == target {
                                model.core.appLock.setPin(value)
                                onDone(true)
                            } else {
                                mismatch = true
                                pin = ""
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(model.theme.background.ignoresSafeArea())
    }
}
