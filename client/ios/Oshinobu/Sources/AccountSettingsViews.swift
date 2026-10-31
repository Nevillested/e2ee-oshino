import OshinobuCore
import SwiftUI

/// Приватность: кто видит фото, статус, день рождения и кто находит по логину (0 — никто, 1 — все, 2 — контакты).
struct PrivacyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var p = PrivacySettings(findByLogin: 1, avatar: 1, birthday: 1, status: 1)
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Form {
            row("privacy_findByLogin", \.findByLogin)
            row("privacy_avatar", \.avatar)
            row("privacy_status", \.status)
            row("privacy_birthday", \.birthday)
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle("privacy_title")
        .task {
            guard let token = model.core.session.token, let me = await model.core.api.getMyAccountInfo(token: token) else { return }
            p = PrivacySettings(findByLogin: me.findByLoginVisibility, avatar: me.avatarVisibility, birthday: me.birthdayVisibility, status: me.statusVisibility)
            loaded = true
        }
    }

    private func row(_ title: LocalizedStringKey, _ field: WritableKeyPath<PrivacySettings, Int>) -> some View {
        Section(title) {
            Picker(title, selection: Binding(get: { p[keyPath: field] }, set: { v in
                p[keyPath: field] = v
                save()
            })) {
                Text("privacy_everyone").tag(1)
                Text("privacy_contactsOnly").tag(2)
                Text("privacy_nobody").tag(0)
            }
            .pickerStyle(.segmented)
            .disabled(!loaded)
        }
    }

    private func save() {
        guard let token = model.core.session.token else { return }
        let settings = p
        Task {
            do { try await model.core.api.updatePrivacy(token: token, settings); error = nil } catch { self.error = localizedError(error) }
        }
    }
}

/// Почта для восстановления: адрес → код из письма → подтверждено.
struct EmailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var current: String?
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("email_description").foregroundStyle(model.theme.textMuted)
                if let current { Text(verbatim: current).bold() } else { Text("email_notSet").foregroundStyle(model.theme.textMuted) }
            }
            Section {
                TextField("email_hint", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if codeSent {
                    TextField("recovery_codeHint", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
            }
            Section {
                Button {
                    Task { await (codeSent ? confirm() : request()) }
                } label: {
                    HStack { Spacer(); if busy { ProgressView() } else { Text(codeSent ? "recovery_confirmCode" : "email_sendCode").bold() }; Spacer() }
                }
                .disabled(busy || email.isEmpty || (codeSent && code.isEmpty))
            }
            if let message { Section { Text(message).foregroundStyle(model.theme.primary) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle("email_title")
        .task {
            if let token = model.core.session.token { current = await model.core.api.getMyAccountInfo(token: token)?.email }
        }
    }

    private func request() async {
        guard email.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil else {
            error = NSLocalizedString("email_invalid", comment: "")
            return
        }
        guard let token = model.core.session.token else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.core.api.requestEmailVerification(token: token, email: email)
            codeSent = true
            error = nil
            message = "\(NSLocalizedString("email_codeSentTo", comment: "")) \(email)"
        } catch {
            self.error = localizedError(error)
        }
    }

    private func confirm() async {
        guard let token = model.core.session.token else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.core.api.confirmEmailVerification(token: token, code: code)
            current = email
            codeSent = false
            code = ""
            error = nil
            message = NSLocalizedString("email_saved", comment: "")
        } catch {
            self.error = localizedError(error)
        }
    }
}
