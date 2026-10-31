import OshinobuCore
import SwiftUI

/// Перевод ключа ошибки ядра ("error.loginTaken") — ключ строк тот же, что на Android ("error_loginTaken").
func localizedError(_ error: Error) -> String {
    if let api = error as? ApiError {
        let key = api.key.replacingOccurrences(of: ".", with: "_")
        let text = NSLocalizedString(key, comment: "")
        return text == key ? api.key : text
    }
    return error.localizedDescription
}

struct SplashView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 96))
                .foregroundStyle(model.theme.primary)
                .symbolEffectPulseIfAvailable()
            ProgressView().tint(model.theme.primary)
        }
    }
}

private extension View {
    @ViewBuilder func symbolEffectPulseIfAvailable() -> some View {
        if #available(iOS 17, *) { self.symbolEffect(.pulse) } else { self }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield.fill").font(.system(size: 88)).foregroundStyle(model.theme.primary)
            Text("Oshinobu").font(.largeTitle.bold()).foregroundStyle(model.theme.textPrimary)
            Spacer()
            NavigationLink { LoginView() } label: { PrimaryLabel("welcome_login") }
            NavigationLink { RegisterView() } label: { SecondaryLabel("welcome_register") }
        }
        .padding(24)
        .background(model.theme.background.ignoresSafeArea())
    }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var login = ""
    @State private var password = ""
    @State private var totp = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("auth_loginHint", text: $login).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("auth_passwordHint", text: $password).textContentType(.password)
                TextField("auth_totpHint", text: $totp).textContentType(.oneTimeCode).keyboardType(.numberPad)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text("login_title").bold() }; Spacer() }
                }
                .disabled(busy || login.isEmpty || password.isEmpty || totp.count < 6)
            }
            Section {
                NavigationLink("recovery_forgotPassword") { RecoveryView(purpose: .password) }
                NavigationLink("recovery_forgotTotp") { RecoveryView(purpose: .totp) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle("login_title")
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await model.core.login(login: login.trimmingCharacters(in: .whitespaces), password: password, totpCode: totp)
            await model.signedIn()
        } catch {
            self.error = localizedError(error)
        }
    }
}

struct RegisterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var login = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var busy = false
    @State private var error: String?
    @State private var totpURL: String?

    var body: some View {
        Form {
            Section {
                TextField("auth_loginHint", text: $login).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("auth_passwordHint", text: $password).textContentType(.newPassword)
                TextField("auth_inviteCodeHint", text: $invite).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("login_invalid").foregroundStyle(model.theme.textMuted)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text("welcome_register").bold() }; Spacer() }
                }
                .disabled(busy || login.isEmpty || password.isEmpty || invite.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle("register_title")
        .navigationDestination(item: $totpURL) { url in TotpSetupView(login: login, password: password, otpauthURL: url) }
    }

    private func submit() async {
        // логин — только латиница и цифры, 3–32 символа (как сервер и Android)
        guard login.range(of: "^[A-Za-z0-9]{3,32}$", options: .regularExpression) != nil else {
            error = NSLocalizedString("login_invalid", comment: "")
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            totpURL = try await model.core.api.register(login: login, password: password, inviteCode: invite)
        } catch {
            self.error = localizedError(error)
        }
    }
}

/// Настройка TOTP после регистрации: ссылка для приложения-аутентификатора и подтверждение кодом.
struct TotpSetupView: View {
    @EnvironmentObject private var model: AppModel
    let login: String
    let password: String
    let otpauthURL: String
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    private var secret: String {
        URLComponents(string: otpauthURL)?.queryItems?.first { $0.name == "secret" }?.value ?? ""
    }

    var body: some View {
        Form {
            Section {
                Text("totp_scanInstruction")
                if let url = URL(string: otpauthURL) { Link(destination: url) { Label("totp_title", systemImage: "key.fill") } }
                Text("totp_manualEntry").foregroundStyle(model.theme.textMuted)
                Text(secret).font(.body.monospaced()).textSelection(.enabled)
            }
            Section {
                TextField("auth_totpHint", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button {
                    Task { await confirm() }
                } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text("totp_confirm").bold() }; Spacer() }
                }
                .disabled(busy || code.count < 6)
            }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle("totp_title")
    }

    private func confirm() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await model.core.api.verifyTotp(login: login, code: code)
            // код ещё действует — сразу и входим им же (как на Android)
            try await model.core.login(login: login, password: password, totpCode: code)
            await model.signedIn()
        } catch {
            self.error = localizedError(error)
        }
    }
}

struct PrimaryLabel: View {
    @EnvironmentObject private var model: AppModel
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(model.theme.onPrimary).background(model.theme.primary, in: Capsule())
    }
}

struct SecondaryLabel: View {
    @EnvironmentObject private var model: AppModel
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(model.theme.primary).overlay(Capsule().stroke(model.theme.primary, lineWidth: 1.5))
    }
}
