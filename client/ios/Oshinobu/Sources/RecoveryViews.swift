import OshinobuCore
import SwiftUI

/// Что восстанавливаем: пароль или доступ к аутентификатору (TOTP) — как RecoveryPurpose на Android.
enum RecoveryPurpose { case password, totp }

/// Восстановление по коду из письма: логин → код → новый пароль (или новая ссылка TOTP).
struct RecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let purpose: RecoveryPurpose
    @State private var login = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var step = 0
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @State private var totpURL: String?

    var body: some View {
        Form {
            switch step {
            case 0:
                Section {
                    TextField("auth_loginHint", text: $login).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                action("recovery_sendCode", disabled: login.isEmpty) {
                    try await model.core.api.requestPasswordRecovery(login: login)
                    info = NSLocalizedString("recovery_requestSentInfo", comment: "")
                    step = 1
                }
            case 1:
                if let info { Section { Text(info).foregroundStyle(model.theme.textMuted) } }
                Section("recovery_codeTitle") {
                    TextField("recovery_codeHint", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                action("recovery_confirmCode", disabled: code.isEmpty) {
                    try await model.core.api.verifyRecoveryCode(login: login, token: code)
                    if purpose == .totp {
                        totpURL = try await model.core.api.resetTotpWithRecoveryCode(login: login, token: code)
                    } else {
                        step = 2
                    }
                }
            default:
                Section("recovery_newPasswordTitle") {
                    SecureField("recovery_newPasswordHint", text: $password).textContentType(.newPassword)
                    SecureField("recovery_confirmPasswordHint", text: $confirm).textContentType(.newPassword)
                }
                action("recovery_save", disabled: password.isEmpty || confirm.isEmpty) {
                    guard password == confirm else { throw ApiError("recovery.passwordsDontMatch") }
                    try await model.core.api.resetPasswordWithRecoveryCode(login: login, token: code, newPassword: password)
                    dismiss()
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if let totpURL {
                Section {
                    Text("totp_scanInstruction")
                    if let url = URL(string: totpURL) { Link(destination: url) { Label("totp_title", systemImage: "key.fill") } }
                    Text(URLComponents(string: totpURL)?.queryItems?.first { $0.name == "secret" }?.value ?? "")
                        .font(.body.monospaced()).textSelection(.enabled)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle(purpose == .password ? "recovery_title" : "recovery_titleTotp")
    }

    private func action(_ title: LocalizedStringKey, disabled: Bool, _ work: @escaping () async throws -> Void) -> some View {
        Section {
            Button {
                Task {
                    busy = true
                    error = nil
                    defer { busy = false }
                    do { try await work() } catch { self.error = localizedError(error) }
                }
            } label: {
                HStack { Spacer(); if busy { ProgressView() } else { Text(title).bold() }; Spacer() }
            }
            .disabled(busy || disabled)
        }
    }
}
