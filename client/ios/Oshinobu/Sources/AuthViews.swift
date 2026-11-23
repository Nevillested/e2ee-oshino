import CoreImage.CIFilterBuiltins
import OshinobuCore
import SwiftUI

// Вход, регистрация, подключение аутентификатора и восстановление доступа —
// те же экраны и переходы, что у Android (ui/auth/AuthScreens.kt, AppNavigation.kt).

private let supportEmail = "support@oshino.space"

/// Перевод ключа ошибки ядра ("error.loginTaken") — ключ строк тот же, что на Android ("error_loginTaken").
func localizedError(_ error: Error) -> String {
    if let api = error as? ApiError { return tr(api.key) }
    return error.localizedDescription
}

/// Зачем восстанавливаем доступ: пароль или приложение-аутентификатор (TOTP).
enum RecoveryPurpose: Hashable { case password, totp }

/// Экраны до входа.
enum AuthRoute: Hashable {
    case login, register
    case verifyTotp(login: String, url: String)
    case recoveryChoose(RecoveryPurpose)
    case recoveryRequest(RecoveryPurpose)
    case recoveryNoEmail(RecoveryPurpose)
    case recoveryCode(RecoveryPurpose, login: String)
    case recoveryReset(RecoveryPurpose, login: String, code: String)
}

/// Стек экранов до входа (backToLogin на Android — стек «приветствие → вход»).
typealias AuthNavigator = StackNav<AuthRoute>

extension StackNav where Route == AuthRoute {
    func backToLogin() { reset([.login]) }
}

struct AuthFlow: View {
    @StateObject private var nav = AuthNavigator()

    var body: some View {
        NavHost(nav: nav) {
            WelcomeView()
        } screen: { route in
            switch route {
            case .login: LoginView()
            case .register: RegisterView()
            case let .verifyTotp(login, url): VerifyTotpView(login: login, totpURL: url)
            case let .recoveryChoose(p): RecoveryChooseView(purpose: p)
            case let .recoveryRequest(p): RecoveryRequestView(purpose: p)
            case let .recoveryNoEmail(p): RecoveryNoEmailView(purpose: p)
            case let .recoveryCode(p, login): RecoveryCodeView(purpose: p, login: login)
            case let .recoveryReset(.password, login, code): SetNewPasswordView(login: login, code: code)
            case let .recoveryReset(.totp, login, code): ResetTotpView(login: login, code: code)
            }
        }
        .environmentObject(nav)
    }
}

/// Заставка: кошка во всю ширину с полями по 10%, пока поднимается сессия.
struct SplashView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { g in
            AppLoadingIndicator(size: min(g.size.width, g.size.height) * 0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(model.theme.splashBackground.ignoresSafeArea())
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AuthNavigator

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "Oshinobu").font(.roboto(32, .bold)).foregroundStyle(model.theme.textPrimary)
            Gap(48)
            PrimaryButton("welcome_login") { nav.push(.login) }
            Gap(12)
            SecondaryButton("welcome_register") { nav.push(.register) }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.background.ignoresSafeArea())
    }
}

/// Отправка формы: индикатор и ошибка (FormState на Android).
@MainActor
final class FormState: ObservableObject {
    @Published var loading = false
    @Published var error: String?

    func run(_ action: @escaping () async throws -> Void) {
        Task {
            loading = true
            error = nil
            defer { loading = false }
            do { try await action() } catch { self.error = localizedError(error) }
        }
    }
}

private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Вход: логин + пароль + код TOTP. Язык интерфейса берётся из аккаунта.
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AuthNavigator
    @StateObject private var form = FormState()
    @State private var login = ""
    @State private var password = ""
    @State private var totp = ""

    var body: some View {
        FormScreen(title: "login_title") {
            AuthTextField(text: $login, hint: "auth_loginHint", contentType: .username)
            Gap()
            AuthTextField(text: $password, hint: "auth_passwordHint", kind: .password, contentType: .password)
            Gap()
            AuthTextField(text: $totp, hint: "auth_totpHint", kind: .number, contentType: .oneTimeCode)
            ErrorLine(text: form.error)
            Gap(24)
            PrimaryButton("welcome_login", loading: form.loading) {
                hideKeyboard()
                form.run {
                    let language = try await model.core.login(login: login.trimmingCharacters(in: .whitespaces), password: password,
                                                              totpCode: totp.trimmingCharacters(in: .whitespaces))
                    model.setLanguage(language, sendToServer: false)
                    await model.signedIn()
                }
            }
            Gap(10)
            TextButtonM("recovery_forgotPassword", fillWidth: true, enabled: !form.loading) { nav.push(.recoveryChoose(.password)) }
            TextButtonM("recovery_forgotTotp", fillWidth: true, enabled: !form.loading) { nav.push(.recoveryChoose(.totp)) }
        }
    }
}

/// Ссылка на документ сайта на языке интерфейса.
private func siteDocURL(_ doc: String, _ locale: Locale) -> URL {
    URL(string: "https://ee2e.oshino.space/\(doc)/\(locale.identifier.hasPrefix("ru") ? "ru" : "en")/")!
}

/// Регистрация по инвайт-коду → настройка TOTP.
struct RegisterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AuthNavigator
    @StateObject private var form = FormState()
    @State private var login = ""
    @State private var password = ""
    @State private var invite = ""

    var body: some View {
        FormScreen(title: "register_title") {
            AuthTextField(text: $login, hint: "auth_loginHint", contentType: .username)
            Gap()
            AuthTextField(text: $password, hint: "auth_passwordHint", kind: .password, contentType: .newPassword)
            Gap(6)
            MutedText("password_requirementsHint", size: 12)
            Gap()
            AuthTextField(text: $invite, hint: "auth_inviteCodeHint", kind: .number)
            ErrorLine(text: form.error)
            Gap(24)
            PrimaryButton("common_next", loading: form.loading) {
                hideKeyboard()
                let name = login.trimmingCharacters(in: .whitespaces)
                if let invalid = validateLogin(name) ?? validatePassword(password) {
                    form.error = tr(invalid)
                    return
                }
                form.run {
                    let url = try await model.core.api.register(login: name, password: password, inviteCode: invite.trimmingCharacters(in: .whitespaces))
                    nav.push(.verifyTotp(login: name, url: url))
                }
            }
            Gap(16)
            Text(agreement).font(.roboto(12)).foregroundStyle(model.theme.textMuted).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .tint(model.theme.primary)
        }
    }

    private var agreement: AttributedString {
        func link(_ key: String, _ doc: String) -> AttributedString {
            var s = AttributedString(tr(key))
            s.link = siteDocURL(doc, model.locale)
            s.foregroundColor = model.theme.primary
            s.underlineStyle = .single
            return s
        }
        var s = AttributedString(tr("register_agreementPrefix"))
        s += link("about_terms", "terms")
        s += AttributedString(tr("register_agreementJoiner"))
        s += link("about_privacy", "privacy")
        s += AttributedString(".")
        return s
    }
}

/// QR-код для приложения-аутентификатора: чёрное на белом, без сглаживания.
private func qrImage(_ content: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(content.utf8)
    guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
}

/// Подключение приложения-аутентификатора: QR + секрет для ручного ввода + проверочный код.
struct VerifyTotpView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AuthNavigator
    @StateObject private var form = FormState()
    let login: String
    let totpURL: String
    @State private var code = ""

    var body: some View {
        let secret = totpSecret(totpURL)
        FormScreen(title: "totp_title") {
            MutedText("totp_scanInstruction")
            Gap(20)
            if let qr = qrImage(totpURL) {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: cardRadius))
                    .frame(maxWidth: .infinity)
            }
            Gap(20)
            MutedText("totp_manualEntry", size: 13)
            Gap(8)
            HStack(spacing: 0) {
                Text(verbatim: secret).font(.roboto(16)).tracking(1.5).foregroundStyle(model.theme.textPrimary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButtonM(.contentCopy, tint: model.theme.primary) {
                    UIPasteboard.general.string = secret
                    model.toasts.show(tr("totp_codeCopied"))
                }
            }
            Gap(24)
            AuthTextField(text: $code, hint: "auth_totpHint", kind: .number, contentType: .oneTimeCode)
            ErrorLine(text: form.error)
            Gap(24)
            PrimaryButton("totp_confirm", loading: form.loading) {
                hideKeyboard()
                form.run {
                    try await model.core.api.verifyTotp(login: login, code: code.trimmingCharacters(in: .whitespaces))
                    nav.backToLogin()
                }
            }
        }
    }
}

/// Как восстанавливать: по коду на почту или без почты (через поддержку).
struct RecoveryChooseView: View {
    @EnvironmentObject private var nav: AuthNavigator
    let purpose: RecoveryPurpose

    var body: some View {
        FormScreen(title: "recovery_chooseTitle") {
            Gap(48)
            PrimaryButton(purpose == .password ? "recovery_hasEmailButton" : "recovery_hasEmailButtonTotp") { nav.push(.recoveryRequest(purpose)) }
            Gap()
            SecondaryButton(purpose == .password ? "recovery_noEmailButton" : "recovery_noEmailButtonTotp") { nav.push(.recoveryNoEmail(purpose)) }
        }
    }
}

/// Запрос кода восстановления на привязанную почту.
struct RecoveryRequestView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AuthNavigator
    @StateObject private var form = FormState()
    let purpose: RecoveryPurpose
    @State private var login = ""

    var body: some View {
        FormScreen(title: purpose == .password ? "recovery_title" : "recovery_titleTotp") {
            MutedText("recovery_requestSentInfo")
            Gap(20)
            AuthTextField(text: $login, hint: "auth_loginHint", contentType: .username)
            ErrorLine(text: form.error)
            Gap(24)
            PrimaryButton("recovery_sendCode", loading: form.loading, enabled: !login.trimmingCharacters(in: .whitespaces).isEmpty) {
                hideKeyboard()
                let name = login.trimmingCharacters(in: .whitespaces)
                form.run {
                    try await model.core.api.requestPasswordRecovery(login: name)
                    nav.push(.recoveryCode(purpose, login: name))
                }
            }
        }
    }
}

/// Ввод кода из письма.
struct RecoveryCodeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AuthNavigator
    @StateObject private var form = FormState()
    let purpose: RecoveryPurpose
    let login: String
    @State private var code = ""

    var body: some View {
        FormScreen(title: "recovery_codeTitle") {
            AuthTextField(text: $code, hint: "recovery_codeHint", kind: .lettersCode)
            ErrorLine(text: form.error)
            Gap(24)
            PrimaryButton("recovery_confirmCode", loading: form.loading, enabled: !code.trimmingCharacters(in: .whitespaces).isEmpty) {
                hideKeyboard()
                let value = code.trimmingCharacters(in: .whitespaces)
                form.run {
                    try await model.core.api.verifyRecoveryCode(login: login, token: value)
                    nav.push(.recoveryReset(purpose, login: login, code: value))
                }
            }
        }
    }
}

/// Без почты восстановить нельзя автоматически — только через поддержку.
struct RecoveryNoEmailView: View {
    @EnvironmentObject private var model: AppModel
    let purpose: RecoveryPurpose

    var body: some View {
        FormScreen(title: "recovery_noEmailTitle") {
            Text(purpose == .password ? "recovery_noEmailBody" : "recovery_noEmailBodyTotp")
                .font(.roboto(16)).foregroundStyle(model.theme.textPrimary).lineSpacing(1)
            Gap(24)
            SecondaryButton("recovery_copyEmail") {
                UIPasteboard.general.string = supportEmail
                model.toasts.show(tr("common_copied"))
            }
        }
    }
}

/// Новый пароль по коду восстановления.
struct SetNewPasswordView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AuthNavigator
    @StateObject private var form = FormState()
    let login: String
    let code: String
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        FormScreen(title: "recovery_newPasswordTitle") {
            AuthTextField(text: $password, hint: "recovery_newPasswordHint", kind: .password, contentType: .newPassword)
            Gap(6)
            MutedText("password_requirementsHint", size: 12)
            Gap()
            AuthTextField(text: $confirm, hint: "recovery_confirmPasswordHint", kind: .password, contentType: .newPassword)
            ErrorLine(text: form.error)
            Gap(24)
            PrimaryButton("recovery_save", loading: form.loading) {
                hideKeyboard()
                if password != confirm {
                    form.error = tr("recovery_passwordsDontMatch")
                    return
                }
                if let invalid = validatePassword(password) {
                    form.error = tr(invalid)
                    return
                }
                form.run {
                    try await model.core.api.resetPasswordWithRecoveryCode(login: login, token: code, newPassword: password)
                    model.toasts.show(tr("recovery_success"))
                    nav.backToLogin()
                }
            }
        }
    }
}

/// Новый секрет TOTP по коду восстановления → тот же экран подключения аутентификатора.
struct ResetTotpView: View {
    @EnvironmentObject private var model: AppModel
    let login: String
    let code: String
    @State private var totpURL: String?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        if let totpURL {
            VerifyTotpView(login: login, totpURL: totpURL)
        } else {
            FormScreen(title: "recovery_titleTotp") {
                Gap(48)
                if let error {
                    Text(verbatim: error).font(.roboto(16)).foregroundStyle(errorRed).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    Gap(16)
                    PrimaryButton("common_retry") { attempt += 1 }
                } else {
                    AppLoadingIndicator(size: 64).frame(maxWidth: .infinity)
                }
            }
            .task(id: attempt) {
                error = nil
                do { totpURL = try await model.core.api.resetTotpWithRecoveryCode(login: login, token: code) } catch { self.error = localizedError(error) }
            }
        }
    }
}
