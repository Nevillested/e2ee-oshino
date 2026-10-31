import LocalAuthentication
import OshinobuCore
import SwiftUI

/// Замок поверх приложения: при возврате дольше таймаута — Face ID или PIN
/// (как AppLockGate на Android). Встаёт и перед экраном звонка — безопасность важнее.
struct AppLockGate<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder let content: () -> Content
    @State private var locked = false
    @State private var leftAt: Date?

    var body: some View {
        ZStack {
            content()
            if locked {
                LockScreen { locked = false }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: locked)
        .onAppear { locked = model.core.appLock.state.value.enabled }
        .onChange(of: scenePhase) { phase in
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

struct LockScreen: View {
    @EnvironmentObject private var model: AppModel
    let onUnlock: () -> Void
    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        let s = model.core.appLock.state.value
        VStack(spacing: 24) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(model.theme.primary)
            Text("applock_enterPin").font(.title3).foregroundStyle(model.theme.textPrimary)
            HStack(spacing: 14) {
                ForEach(0..<s.pinLength, id: \.self) { i in
                    Circle().fill(i < pin.count ? model.theme.primary : model.theme.textMuted.opacity(0.3)).frame(width: 14, height: 14)
                }
            }
            .modifier(Shake(animatable: wrong ? 1 : 0))
            if wrong { Text("applock_wrongPin").foregroundStyle(.red).font(.footnote) }
            PinPad(
                onDigit: { digit in
                    guard pin.count < s.pinLength else { return }
                    pin += digit
                    wrong = false
                    if pin.count == s.pinLength {
                        if model.core.appLock.checkPin(pin) { onUnlock() } else {
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                            withAnimation(.default) { wrong = true }
                            pin = ""
                        }
                    }
                },
                onDelete: { if !pin.isEmpty { pin.removeLast() } },
                onBiometric: s.biometricEnabled ? { biometric() } : nil
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.background.ignoresSafeArea())
        .onAppear { if s.biometricEnabled { biometric() } }
    }

    private func biometric() {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: NSLocalizedString("applock_useBiometricReason", comment: "")) { ok, _ in
            if ok { Task { @MainActor in onUnlock() } }
        }
    }
}

struct PinPad: View {
    @EnvironmentObject private var model: AppModel
    let onDigit: (String) -> Void
    let onDelete: () -> Void
    let onBiometric: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                HStack(spacing: 28) { ForEach(row, id: \.self) { d in key(d) } }
            }
            HStack(spacing: 28) {
                Button { onBiometric?() } label: { Image(systemName: "faceid").font(.title2).frame(width: 72, height: 72) }
                    .opacity(onBiometric == nil ? 0 : 1).disabled(onBiometric == nil)
                key("0")
                Button(action: onDelete) { Image(systemName: "delete.left").font(.title2).frame(width: 72, height: 72) }
            }
            .foregroundStyle(model.theme.textPrimary)
        }
    }

    private func key(_ d: String) -> some View {
        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onDigit(d) } label: {
            Text(d).font(.title).frame(width: 72, height: 72).foregroundStyle(model.theme.textPrimary)
                .background(model.theme.surface, in: Circle())
        }
    }
}

/// Тряска полоски точек при неверном PIN.
struct Shake: GeometryEffect {
    var animatable: CGFloat
    var animatableData: CGFloat { get { animatable } set { animatable = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatable * .pi * 6), y: 0))
    }
}

/// Настройка блокировки: PIN (ввод дважды), Face ID, таймаут.
struct AppLockSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var settings = AppLockSettings()
    @State private var settingPin = false
    @State private var first = ""
    @State private var second = ""
    @State private var mismatch = false

    var body: some View {
        Form {
            Section {
                Toggle("applock_title", isOn: Binding(get: { settings.enabled }, set: { on in
                    if on && !settings.hasPin { settingPin = true } else { model.core.appLock.setEnabled(on); reload() }
                }))
                if settings.hasPin {
                    Toggle("applock_unlockWithBiometric", isOn: Binding(get: { settings.biometricEnabled }, set: { model.core.appLock.setBiometric($0); reload() }))
                    Picker("applock_timeout", selection: Binding(get: { settings.timeoutSeconds }, set: { model.core.appLock.setTimeout($0); reload() })) {
                        ForEach([0, 60, 300, 900, 3600], id: \.self) { s in Text(s == 0 ? "0" : "\(s / 60) min").tag(s) }
                    }
                    Button("applock_changePin") { settingPin = true }
                    Button("applock_removePin", role: .destructive) { model.core.appLock.removePin(); reload() }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle("applock_title")
        .onAppear(perform: reload)
        .sheet(isPresented: $settingPin) {
            VStack(spacing: 20) {
                Text(first.count < 4 ? "applock_newPin" : "applock_confirmPin").font(.title3)
                SecureField("applock_pin", text: first.count < 4 ? $first : $second).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center).font(.title)
                if mismatch { Text("applock_pinMismatch").foregroundStyle(.red) }
                Button("common_save") {
                    guard first.count >= 4 else { return }
                    if second.isEmpty { return }
                    if first == second {
                        model.core.appLock.setPin(first)
                        model.core.appLock.setEnabled(true)
                        settingPin = false
                        reload()
                    } else {
                        mismatch = true
                        first = ""
                        second = ""
                    }
                }
                .disabled(second.count < 4)
            }
            .padding(32)
            .presentationDetents([.medium])
            .onDisappear { first = ""; second = ""; mismatch = false }
        }
    }

    private func reload() { settings = model.core.appLock.state.value }
}
