import OshinobuCore
import PhotosUI
import SwiftUI

// Вкладка своего профиля — как у Android (ui/home/ProfileTab.kt): крупный аватар
// (смотреть / сменить / убрать), логин, имя, «о себе», день рождения.

/// Аватар: не больше 512×512, JPEG 85% (как на Android).
private func avatarJpeg(_ data: Data) async -> Data? {
    await Task.detached {
        guard let source = UIImage(data: data) else { return nil }
        let scale = min(1, 512 / max(source.size.width, source.size.height))
        let size = CGSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.85)
    }.value
}

struct ProfileTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var profile: MyProfile?
    @State private var avatar: Data?
    @State private var uploading = false
    @State private var picking = false
    @State private var picked: PhotosPickerItem?

    /// Шторка аватара (ModalBottomSheet на Android): посмотреть, сменить, удалить — пункт закрывает её сразу.
    private func showAvatarSheet() {
        model.popups.show(dim: false) {
            BottomSheetM(background: model.theme.surface) {
                VStack(spacing: 0) {
                    sheetAction(.oVisibility, "settings_avatarView", model.theme.primary) {
                        model.popups.dismiss(animated: false)
                        if let avatar, let image = UIImage(data: avatar) {
                            model.popups.show(dim: false) { PhotoViewer(image: image) { model.popups.dismiss() } }
                        }
                    }
                    sheetAction(.oPhotoCamera, "settings_avatarChange", model.theme.primary) {
                        model.popups.dismiss(animated: false)
                        picking = true
                    }
                    sheetAction(.oDelete, "settings_avatarRemove", errorRed) {
                        model.popups.dismiss(animated: false)
                        changeAvatar(nil)
                    }
                    Gap(24)
                }
            }
        }
    }

    var body: some View {
        GeometryReader { g in
            if let p = profile {
                let diameter = g.size.width * 0.4
                ScrollView {
                    VStack(spacing: 0) {
                        Button { if avatar == nil { picking = true } else { showAvatarSheet() } } label: {
                            ZStack {
                                if uploading { AppLoadingIndicator(size: 64) } else { AvatarImage(data: avatar, size: diameter) }
                            }
                            .frame(width: diameter, height: diameter)
                        }
                        .buttonStyle(.plain)
                        .disabled(uploading)
                        Gap(24)
                        ProfileRow(icon: .oBadge, title: tr("profile_login"), value: p.login)
                        ProfileRow(icon: .oBadge, title: tr("profile_displayName"), value: nonEmpty(p.displayName) ?? tr("profile_displayNameEmpty")) {
                            model.popups.show {
                                TextEditDialog(title: "profile_editDisplayName", hint: "profile_displayNameHint", initial: p.displayName ?? "", maxLength: 50) { name in
                                    save({ try await $0.updateDisplayName(token: $1, displayName: name) }) { model.core.myAccount.setDisplayName(name) }
                                }
                            }
                        }
                        ProfileRow(icon: .oChatBubbleOutline, title: tr("profile_status"), value: nonEmpty(p.status) ?? tr("profile_statusEmpty")) {
                            model.popups.show {
                                TextEditDialog(title: "profile_editStatus", hint: "profile_statusHint", initial: p.status ?? "", maxLength: 200, singleLine: false) { status in
                                    save({ try await $0.updateStatus(token: $1, status: status) }) { model.core.myAccount.setStatus(status) }
                                }
                            }
                        }
                        ProfileRow(icon: .oCake, title: tr("profile_birthday"), value: p.birthday ?? tr("profile_birthdayEmpty")) {
                            model.popups.show {
                                BirthdayDialog(current: p.birthday) { date in
                                    save({ try await $0.updateBirthday(token: $1, birthday: date) }) { model.core.myAccount.setBirthday(date) }
                                }
                            }
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, homeTabsReserve)
                }
            } else {
                FullScreenLoading()
            }
        }
        .task { for await value in model.core.myAccount.profile.stream() { profile = value } }
        .task { for await value in model.core.myAccount.avatar.stream() { avatar = value } }
        .photosPicker(isPresented: $picking, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = await avatarJpeg(data) else { return }
                changeAvatar(jpeg)
            }
        }
    }

    private func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }

    private func sheetAction(_ icon: MaterialIcon, _ text: LocalizedStringKey, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                MIcon(icon, tint: tint)
                Text(text).font(.roboto(16)).foregroundStyle(tint == errorRed ? errorRed : model.theme.textPrimary).lineBox(16)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
    }

    /// Загрузка/удаление аватара; nil — удалить.
    private func changeAvatar(_ jpeg: Data?) {
        guard let token = model.core.session.token else { return }
        uploading = true
        let core = model.core
        Task {
            do {
                if let jpeg { try await core.api.uploadAvatar(token: token, jpeg: jpeg) } else { try await core.api.deleteAvatar(token: token) }
                core.myAccount.setAvatar(jpeg)
            } catch {
                model.toasts.show(tr("settings_avatarUploadFailed"))
            }
            uploading = false
        }
    }

    /// Сохранение поля профиля: повторы до успеха, потом — в локальную копию.
    private func save(_ update: @escaping (ApiClient, String) async throws -> Void, apply: @escaping () -> Void) {
        guard let token = model.core.session.token else { return }
        let api = model.core.api
        Task {
            await retryUntilSuccess { try await update(api, token) }
            apply()
        }
    }
}

/// Строка профиля: значок, подпись, значение; есть onEdit — карандаш и нажатие.
struct ProfileRow: View {
    @EnvironmentObject private var model: AppModel
    let icon: MaterialIcon
    let title: String
    let value: String
    var onEdit: (() -> Void)?

    var body: some View {
        let row = HStack(spacing: 0) {
            MIcon(icon, tint: model.theme.textMuted)
            Spacer().frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(.roboto(16)).foregroundStyle(model.theme.textPrimary).lineBox(16)
                Text(verbatim: value).font(.roboto(16)).foregroundStyle(model.theme.textMuted).lineBox(16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if onEdit != nil { MIcon(.oEdit, tint: model.theme.textMuted) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        if let onEdit {
            Button(action: onEdit) { row }.buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
        } else {
            row
        }
    }
}

/// Окно с полем ввода (OutlinedTextField со счётчиком символов).
struct TextEditDialog: View {
    @EnvironmentObject private var model: AppModel
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    let initial: String
    let maxLength: Int
    var singleLine = true
    let onSave: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        AppDialog(title: title, onDismiss: { model.popups.dismiss() }) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(text: $text, prompt: Text(hint).foregroundStyle(model.theme.textMuted), axis: singleLine ? .horizontal : .vertical) { EmptyView() }
                    .lineLimit(singleLine ? 1 : 3)
                    .font(.roboto(16))
                    .foregroundStyle(model.theme.textPrimary)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? model.theme.primary : model.theme.textMuted,
                                                                         lineWidth: focused ? 2 : 1))
                    .onChange(of: text) { _, v in if v.count > maxLength { text = String(v.prefix(maxLength)) } }
                Text(verbatim: "\(text.count)/\(maxLength)").font(.roboto(12)).padding(.horizontal, 16)
            }
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("common_save") {
                model.popups.dismiss()
                onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        .tint(model.theme.primary)
        .onAppear {
            text = initial
            focused = true
        }
    }
}

/// День рождения: 1900 — сегодня; на сервер уходит "YYYY-MM-DD".
private struct BirthdayDialog: View {
    @EnvironmentObject private var model: AppModel
    let current: String?
    let onPicked: (String) -> Void
    @State private var date = Date()

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let range = Self.format.date(from: "1900-01-01")!...Date()
        AppDialog(title: nil, onDismiss: { model.popups.dismiss() }) {
            DatePicker(selection: $date, in: range, displayedComponents: .date) { EmptyView() }
                .datePickerStyle(.graphical)
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .tint(model.theme.primary)
        } buttons: {
            DialogButton("common_cancel") { model.popups.dismiss() }
            DialogButton("common_save") {
                model.popups.dismiss()
                onPicked(Self.format.string(from: date))
            }
        }
        .onAppear { date = current.flatMap(Self.format.date(from:)) ?? Self.format.date(from: "2000-01-01")! }
    }
}
