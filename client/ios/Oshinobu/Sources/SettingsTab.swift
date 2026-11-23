import LocalAuthentication
import OshinobuCore
import SwiftUI

// Вкладка настроек — как у Android (ui/home/SettingsTab.kt, SettingsDialogs.kt):
// пункты с цветными значками, каждый открывает окно поверх вкладки.

struct SettingsTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: AppNavigator

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                item(.oEmail, 0x2AABEE, "settings_email") { EmailDialog() }
                item(.oLock, 0xFF9F0A, "settings_changePassword") { ChangePasswordDialog() }
                item(.oEmojiEmotions, 0xFF6482, "settings_defaultReaction") { DefaultReactionDialog() }
                item(.oLanguage, 0x32C769, "settings_language") { LanguageDialog() }
                SettingsItem(icon: .oPalette, tint: Color(hex: 0xAF52DE), title: "settings_theme") { nav.open(.theme) }
                item(.textFields, 0x5AC8FA, "settings_fontSize") { FontSizeDialog() }
                item(.oPrivacyTip, 0x34C759, "settings_privacy") { PrivacyDialog() }
                item(.oPhonelinkLock, 0x5E5CE6, "settings_appLock") { AppLockSettingsDialog() }
                SettingsItem(icon: .cleaningServices, tint: Color(hex: 0x00C7BE), title: "settings_clearCache") { clearCache() }
                item(.oInfo, 0x8E8E93, "settings_about") { AboutDialog() }
                item(.logout, 0xFF3B30, "settings_logout", danger: true) { LogoutDialog() }
                item(.deleteForever, 0xB00020, "settings_deleteAccount", danger: true) { DeleteAccountDialog() }
                Color.clear.frame(height: homeTabsReserve)
            }
        }
    }

    private func item<D: View>(_ icon: MaterialIcon, _ tint: UInt32, _ title: LocalizedStringKey, danger: Bool = false,
                               @ViewBuilder dialog: @escaping () -> D) -> some View {
        SettingsItem(icon: icon, tint: Color(hex: tint), title: title, danger: danger) { model.popups.show(dialog) }
    }

    /// Кэш пуст — только подсказка, окно не открываем.
    private func clearCache() {
        Task {
            let size = await model.core.cacheSize()
            if size == 0 { model.toasts.show(tr("settings_cacheEmpty")) } else { model.popups.show { ClearCacheDialog(size: size) } }
        }
    }
}

private struct SettingsItem: View {
    @EnvironmentObject private var model: AppModel
    let icon: MaterialIcon
    let tint: Color
    let title: LocalizedStringKey
    var danger = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                MIcon(icon, size: 18, tint: .white).frame(width: 30, height: 30).background(tint, in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.roboto(16)).foregroundStyle(danger ? errorRed : model.theme.textPrimary).lineBox(16)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
    }
}

/// Кнопка диалога (TextButton): по умолчанию — акцентный цвет.
struct DialogButton: View {
    @EnvironmentObject private var model: AppModel
    let title: LocalizedStringKey
    var color: Color?
    let action: () -> Void

    init(_ title: LocalizedStringKey, color: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.roboto(14, .medium)).foregroundStyle(color ?? model.theme.primary).padding(.horizontal, 12).frame(minHeight: 40)
        }
        .buttonStyle(RippleStyle(shape: Capsule(), color: color ?? model.theme.primary))
    }
}

/// Строка внутри окна настроек: значок, заголовок, подпись, справа — переключатель или ничего.
struct SettingRow<Trailing: View>: View {
    @EnvironmentObject private var model: AppModel
    var icon: MaterialIcon?
    let title: String
    var subtitle: String?
    var enabled = true
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let row = HStack(spacing: 0) {
            if let icon {
                MIcon(icon, tint: model.theme.textMuted)
                Spacer().frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(.roboto(16)).foregroundStyle(enabled ? model.theme.textPrimary : model.theme.textMuted).lineBox(16)
                if let subtitle { Text(verbatim: subtitle).font(.roboto(13)).foregroundStyle(model.theme.textMuted).lineBox(13) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 10)
        if let action {
            Button(action: action) { row }.buttonStyle(RowRippleStyle(color: model.theme.textPrimary)).disabled(!enabled)
        } else {
            row
        }
    }
}

extension SettingRow where Trailing == EmptyView {
    init(icon: MaterialIcon? = nil, title: String, subtitle: String? = nil, enabled: Bool = true, action: (() -> Void)? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle, enabled: enabled, action: action, trailing: { EmptyView() })
    }
}

/// Switch Material 3: дорожка 52×32, бегунок 16 (выкл.) / 24 (вкл.).
struct SwitchM: View {
    @EnvironmentObject private var model: AppModel
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button { onChange(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? model.theme.primary : model.theme.surface)
                Capsule().strokeBorder(isOn ? model.theme.primary : model.theme.textMuted, lineWidth: 2)
                Circle().fill(isOn ? model.theme.onPrimary : model.theme.textMuted)
                    .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                    .padding(.horizontal, isOn ? 4 : 8)
            }
            .frame(width: 52, height: 32)
            .animation(.easeInOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
    }
}

/// Выбор из списка снизу экрана с галочкой у текущего (ModalBottomSheet на Android).
struct ChoiceSheet<T: Hashable>: View {
    @EnvironmentObject private var model: AppModel
    var title: String?
    let options: [(T, String)]
    let current: T?
    let onPick: (T) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let title { Text(verbatim: title).font(.roboto(16, .semibold)).foregroundStyle(model.theme.textPrimary).padding(16) }
                ForEach(options, id: \.0) { value, label in
                    Button { onPick(value) } label: {
                        HStack {
                            Text(verbatim: label).font(.roboto(16)).foregroundStyle(model.theme.textPrimary).lineBox(16)
                            Spacer(minLength: 0)
                            if value == current { MIcon(.check, tint: model.theme.primary) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
                }
            }
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Шторка выбора поверх открытого окна настроек; выбор закрывает её сразу (как на Android).
    @MainActor
    static func present(_ model: AppModel, title: String? = nil, options: [(T, String)], current: T?, onPick: @escaping (T) -> Void) {
        model.popups.showOver {
            BottomSheetM(background: model.theme.surface, layered: true) {
                ChoiceSheet(title: title, options: options, current: current) { v in
                    model.popups.dismissOver(animated: false)
                    onPick(v)
                }
            }
        }
    }
}

// MARK: - окна

private struct LanguageDialog: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppDialog(title: "language_title", onDismiss: { model.popups.dismiss() }) {
            VStack(spacing: 0) {
                ForEach([("ru", "language_russian"), ("en", "language_english")], id: \.0) { tag, label in
                    Button {
                        model.popups.dismiss()
                        model.setLanguage(tag)
                    } label: {
                        Text(LocalizedStringKey(label)).font(.roboto(17)).foregroundStyle(model.theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    }
                    .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
                }
            }
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
        }
    }
}

private struct FontSizeDialog: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let steps = UiSettings.textScaleSteps
        AppDialog(title: "fontSize_title", onDismiss: { model.popups.dismiss() }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("fontSize_preview").font(.roboto(16)).foregroundStyle(model.theme.textPrimary)
                Slider(value: Binding(get: { Double(steps.firstIndex(of: model.textScale) ?? 2) },
                                      set: { model.setTextScale(steps[Int($0.rounded())]) }),
                       in: 0...Double(steps.count - 1), step: 1)
                    .tint(model.theme.primary)
            }
        } buttons: {
            DialogButton("common_done") { model.popups.dismiss() }
        }
    }
}

private struct DefaultReactionDialog: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected = UiSettings.defaultReaction

    var body: some View {
        AppDialog(title: "reaction_pickerTitle", onDismiss: { model.popups.dismiss() }) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    ForEach(allEmojis, id: \.self) { emoji in
                        Text(verbatim: emoji).font(.system(size: 24)).frame(width: 44, height: 44)
                            .background(emoji == selected ? model.theme.primary.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: cardRadius))
                            .onTapGesture { selected = emoji }
                    }
                }
            }
            .frame(height: 320)
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("common_save") {
                model.core.settings.defaultReaction = selected
                model.popups.dismiss()
            }
        }
        .onAppear { selected = model.core.settings.defaultReaction }
    }
}

private struct ClearCacheDialog: View {
    @EnvironmentObject private var model: AppModel
    let size: Int64

    var body: some View {
        AppDialog(title: "settings_clearCacheTitle", onDismiss: { model.popups.dismiss() }) {
            Text(verbatim: String(format: tr("settings_clearCacheBody"), formatFileSize(size) { tr($0) }))
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("settings_clearCache") {
                model.popups.dismiss()
                Task {
                    _ = await model.core.clearCache()
                    model.toasts.show(tr("settings_cacheCleared"))
                }
            }
        }
    }
}

private struct LogoutDialog: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppDialog(title: "account_logoutTitle", onDismiss: { model.popups.dismiss() }) {
            Text("account_logoutBody")
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("account_logoutConfirm", color: errorRed) {
                model.popups.dismiss()
                Task { await model.logout() }
            }
        }
    }
}

/// Удаление аккаунта: сначала на сервере — без сети не удаляем ничего и локально.
private struct DeleteAccountDialog: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppDialog(title: "account_deleteTitle", onDismiss: { model.popups.dismiss() }) {
            Text("account_deleteBody")
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("account_deleteConfirm", color: errorRed) {
                model.popups.dismiss()
                Task {
                    if await model.core.deleteAccount() { model.phase = .signedOut } else { model.toasts.show(tr("account_deleteOfflineError")) }
                }
            }
        }
    }
}

private let emailFormat = "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$"

/// Почта для восстановления: показать текущую и удалить (с подтверждением) или добавить —
/// адрес, затем код из письма. Отправленный код можно ввести 25 минут, даже закрыв окно.
private struct EmailDialog: View {
    @EnvironmentObject private var model: AppModel
    @State private var email: String?
    @State private var adding = false
    @State private var confirmRemove = false

    var body: some View {
        Group {
            if adding {
                AddEmailDialog()
            } else if confirmRemove {
                AppDialog(title: "email_removeConfirmTitle", onDismiss: { model.popups.dismiss() }) {
                    Text("email_removeConfirmBody")
                } buttons: {
                    DialogButton("common_cancel") { model.popups.dismiss() }
                    DialogButton("email_removeButton", color: errorRed) { remove() }
                }
            } else {
                let has = email?.isEmpty == false
                AppDialog(title: "email_title", onDismiss: { model.popups.dismiss() }) {
                    Text(verbatim: has ? email! : tr("email_notSet")).foregroundStyle(has ? model.theme.textPrimary : model.theme.textMuted)
                } buttons: {
                    DialogButton("common_cancel") { model.popups.dismiss() }
                    if has {
                        DialogButton("email_removeButton", color: errorRed) { confirmRemove = true }
                    } else {
                        DialogButton("email_addButton") { adding = true }
                    }
                }
            }
        }
        .onAppear {
            adding = model.core.settings.pendingEmail != nil
            email = model.core.myAccount.email.value
        }
    }

    private func remove() {
        let core = model.core
        Task {
            guard let token = core.session.token else { return }
            do {
                try await core.api.updateEmail(token: token, email: "")
                core.myAccount.setEmail(nil)
                model.toasts.show(tr("email_removed"))
            } catch {
                model.toasts.show(localizedError(error))
            }
            model.popups.dismiss()
        }
    }
}

private struct AddEmailDialog: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var form = FormState()
    @State private var pending: String?
    @State private var address = ""
    @State private var code = ""

    var body: some View {
        let codeStep = pending != nil
        AppDialog(title: codeStep ? "recovery_codeTitle" : "email_title", onDismiss: { model.popups.dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                if !codeStep {
                    Text("email_description").font(.roboto(13))
                    Gap(12)
                    AuthTextField(text: $address, hint: "email_hint", contentType: .emailAddress).keyboardType(.emailAddress)
                } else {
                    Text(verbatim: "\(tr("email_codeSentTo")) \(pending ?? "")").font(.roboto(13))
                    Gap(12)
                    AuthTextField(text: $code, hint: "recovery_codeHint", kind: .lettersCode)
                }
                ErrorLine(text: form.error)
            }
        } buttons: {
            DialogButton("common_cancel") {
                if codeStep { model.core.settings.clearPendingEmail() }
                model.popups.dismiss()
            }
            DialogButton(codeStep ? "recovery_confirmCode" : "email_sendCode") { submit(codeStep) }
        }
        .onAppear {
            pending = model.core.settings.pendingEmail
            address = pending ?? ""
        }
    }

    private func submit(_ codeStep: Bool) {
        guard !form.loading, let token = model.core.session.token else { return }
        let core = model.core
        if !codeStep {
            let value = address.trimmingCharacters(in: .whitespaces)
            guard value.range(of: emailFormat, options: .regularExpression) != nil else {
                form.error = tr("email_invalid")
                return
            }
            form.run {
                try await core.api.requestEmailVerification(token: token, email: value)
                core.settings.setPendingEmail(value)
                pending = value
            }
        } else {
            let entered = code.trimmingCharacters(in: .whitespaces)
            guard !entered.isEmpty else { return }
            form.run {
                try await core.api.confirmEmailVerification(token: token, code: entered)
                core.settings.clearPendingEmail()
                core.myAccount.setEmail(pending)
                model.toasts.show(tr("email_saved"))
                model.popups.dismiss()
            }
        }
    }
}

/// Смена пароля: новый, повтор, проверка требований.
private struct ChangePasswordDialog: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var form = FormState()
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        AppDialog(title: "changePassword_title", onDismiss: { model.popups.dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                AuthTextField(text: $password, hint: "recovery_newPasswordHint", kind: .password, contentType: .newPassword)
                Gap(6)
                MutedText("password_requirementsHint", size: 12)
                Gap(14)
                AuthTextField(text: $confirm, hint: "recovery_confirmPasswordHint", kind: .password, contentType: .newPassword)
                ErrorLine(text: form.error)
            }
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("recovery_save") { save() }
        }
    }

    private func save() {
        guard !form.loading else { return }
        if password != confirm {
            form.error = tr("recovery_passwordsDontMatch")
            return
        }
        if let invalid = validatePassword(password) {
            form.error = tr(invalid)
            return
        }
        guard let token = model.core.session.token else { return }
        let core = model.core, password = password
        form.run {
            try await core.api.changePassword(token: token, newPassword: password)
            model.toasts.show(tr("changePassword_success"))
            model.popups.dismiss()
        }
    }
}

/// Повторять действие, пока не получится (как retryUntilSuccess на Android): пауза растёт до 30 с.
func retryUntilSuccess(_ action: @escaping () async throws -> Void) async {
    var delay: Double = 1
    while !Task.isCancelled {
        do {
            try await action()
            return
        } catch {
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }
}

/// Приватность: кто находит по логину и кто видит фото, день рождения и «о себе». Сохранение повторяется до успеха.
private struct PrivacyDialog: View {
    @EnvironmentObject private var model: AppModel
    @State private var values = [1, 1, 1, 1]
    @State private var saving = false

    private let rows: [(MaterialIcon, String, Bool)] = [
        (.oSearch, "privacy_findByLogin", false), (.oPhoto, "privacy_avatar", true),
        (.oCake, "privacy_birthday", true), (.oChatBubbleOutline, "privacy_status", true),
    ]

    var body: some View {
        AppDialog(title: "privacy_title", onDismiss: { model.popups.dismiss() }) {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let (icon, key, allowContacts) = rows[i]
                    SettingRow(icon: icon, title: tr(key), subtitle: label(values[i], allowContacts)) {
                        var options: [(Int, String)] = [(1, tr("privacy_everyone"))]
                        if allowContacts { options.append((2, tr("privacy_contactsOnly"))) }
                        options.append((0, tr("privacy_nobody")))
                        ChoiceSheet.present(model, title: tr(key), options: options, current: values[i]) { v in values[i] = v }
                    }
                }
            }
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton(saving ? "privacy_saving" : "common_save") { save() }
        }
        .onAppear {
            if let p = model.core.myAccount.profile.value {
                values = [p.findByLoginVisibility, p.avatarVisibility, p.birthdayVisibility, p.statusVisibility]
            }
        }
    }

    private func label(_ v: Int, _ allowContacts: Bool) -> String {
        if v == 0 { return tr("privacy_nobody") }
        if v == 2 && allowContacts { return tr("privacy_contactsOnly") }
        return tr("privacy_everyone")
    }

    private func save() {
        guard !saving, let token = model.core.session.token else { return }
        saving = true
        let core = model.core
        let p = PrivacySettings(findByLogin: values[0], avatar: values[1], birthday: values[2], status: values[3])
        Task {
            await retryUntilSuccess { try await core.api.updatePrivacy(token: token, p) }
            core.myAccount.setPrivacy(p)
            model.toasts.show(tr("privacy_saved"))
            model.popups.dismiss()
        }
    }
}

private let timeoutOptions = [30, 60, 120, 300, 600, 900, 1800, 3600, 7200]

private func timeoutLabel(_ seconds: Int) -> String {
    tr("applock_timeout_\(timeoutOptions.contains(seconds) ? seconds : 7200)")
}

/// Блокировка приложения: вкл/выкл, через сколько блокировать, PIN (задать, сменить, удалить)
/// и Face ID / Touch ID. Включение требует PIN — если его нет, сначала задаём.
private struct AppLockSettingsDialog: View {
    @EnvironmentObject private var model: AppModel
    @State private var s = AppLockSettings()
    @State private var pinSetup: (() -> Void)?

    var body: some View {
        let store = model.core.appLock
        Group {
            if let then = pinSetup {
                PinSetupDialog { ok in
                    pinSetup = nil
                    if ok { then() }
                }
            } else {
                AppDialog(title: "applock_title", onDismiss: { model.popups.dismiss() }) {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingRow(title: tr("applock_status"), subtitle: tr(s.enabled ? "applock_on" : "applock_off")) {
                            SwitchM(isOn: s.enabled) { on in if on { withPin { store.setEnabled(true) } } else { store.setEnabled(false) } }
                        }
                        SettingRow(icon: .oTimer, title: tr("applock_timeout"), subtitle: timeoutLabel(s.timeoutSeconds), enabled: s.enabled) {
                            ChoiceSheet.present(model, options: timeoutOptions.map { ($0, timeoutLabel($0)) }, current: s.timeoutSeconds) { store.setTimeout($0) }
                        }
                        model.theme.textMuted.opacity(0.2).frame(height: 1).padding(.vertical, 8)
                        Text("applock_unlockMethod").font(.roboto(13, .semibold))
                        SettingRow(icon: .oPin, title: tr("applock_pin"), subtitle: tr(s.hasPin ? "applock_pinSet" : "applock_pinNotSet")) {
                            if s.hasPin {
                                ChoiceSheet.present(model, options: [(0, tr("applock_changePin")), (1, tr("applock_removePin"))], current: nil) { v in
                                    if v == 0 { pinSetup = {} } else { store.removePin() }
                                }
                            } else {
                                pinSetup = {}
                            }
                        }
                        if let biometric = biometricKind {
                            SettingRow(icon: biometric == .faceID ? .face : .fingerprint,
                                       title: tr(biometric == .faceID ? "applock_face" : biometric == .touchID ? "applock_fingerprint" : "applock_biometric"),
                                       subtitle: s.hasPin ? nil : tr("applock_needPinFirst")) {
                                SwitchM(isOn: s.biometricEnabled) { on in if on { withPin { store.setBiometric(true) } } else { store.setBiometric(false) } }
                            }
                        }
                    }
                } buttons: {
                    DialogButton("common_done") { model.popups.dismiss() }
                }
            }
        }
        .task {
            for await value in store.state.stream() { s = value }
        }
    }

    private var biometricKind: LABiometryType? {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil), ctx.biometryType != .none else { return nil }
        return ctx.biometryType
    }

    /// Нужен PIN: есть — сразу then, нет — сначала задать.
    private func withPin(_ then: @escaping () -> Void) {
        if s.hasPin { then() } else { pinSetup = then }
    }
}

/// О приложении: версия и ссылки на условия и политику (на языке интерфейса).
private struct AboutDialog: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        let lang = model.locale.identifier.hasPrefix("ru") ? "ru" : "en"
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
        AppDialog(title: "about_title", onDismiss: { model.popups.dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                SettingRow(icon: .oInfo, title: tr("about_version"), subtitle: version)
                SettingRow(icon: .oDescription, title: tr("about_terms")) { openURL(URL(string: "https://ee2e.oshino.space/terms/\(lang)/")!) }
                SettingRow(icon: .oPrivacyTip, title: tr("about_privacy")) { openURL(URL(string: "https://ee2e.oshino.space/privacy/\(lang)/")!) }
                Text("about_credits").font(.roboto(12)).padding(.top, 12)
            }
        } buttons: {
            DialogButton("common_done") { model.popups.dismiss() }
        }
    }
}
