import OshinobuCore
import PhotosUI
import SwiftUI

/// Свой профиль: фото (сменить/убрать), имя, статус, дата рождения — с сохранением на сервере.
struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @State private var me: MyAccountInfo?
    @State private var displayName = ""
    @State private var status = ""
    @State private var photo: PhotosPickerItem?
    @State private var error: String?
    @State private var avatarVersion = 0
    @State private var birthday: Date?
    @State private var birthdaySave: Task<Void, Never>?

    /// Формат сервера — "YYYY-MM-DD"; разбор и вывод в одном поясе, чтобы день не съезжал.
    private static let birthdayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $photo, matching: .images) {
                        AvatarView(accountId: model.core.session.accountId, login: model.core.session.login ?? "?", size: 120)
                            .id(avatarVersion)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.circle.fill").font(.title).foregroundStyle(model.theme.primary).background(Circle().fill(.background))
                            }
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
                Text(verbatim: "@\(model.core.session.login ?? "")").frame(maxWidth: .infinity).foregroundStyle(model.theme.textMuted).listRowBackground(Color.clear)
            }
            Section("profile_displayName") {
                TextField("profile_displayNameHint", text: $displayName).onSubmit { save { try await $0.updateDisplayName(token: $1, displayName: displayName) } }
            }
            Section("profile_status") {
                TextField("profile_statusHint", text: $status).onSubmit { save { try await $0.updateStatus(token: $1, status: status) } }
            }
            Section("profile_birthday") {
                if let b = birthday {
                    HStack {
                        DatePicker("profile_birthday", selection: Binding(get: { b }, set: { birthday = $0; saveBirthday() }),
                                   in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                        Spacer()
                        Button(role: .destructive) { birthday = nil; saveBirthday() } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                } else {
                    Button("profile_birthdayEmpty") {
                        birthday = Calendar.current.date(byAdding: .year, value: -20, to: Date())
                        saveBirthday()
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle("profile_title")
        .task { await load() }
        .onChange(of: photo) { item in
            guard let item else { return }
            photo = nil
            Task { await upload(item) }
        }
    }

    private func load() async {
        guard let token = model.core.session.token, let info = await model.core.api.getMyAccountInfo(token: token) else { return }
        me = info
        displayName = info.displayName ?? ""
        status = info.status ?? ""
        birthday = info.birthday.flatMap { Self.birthdayFormat.date(from: $0) }
    }

    /// Колесо даты меняет значение часто — на сервер уходит последнее через полсекунды.
    private func saveBirthday() {
        birthdaySave?.cancel()
        let value = birthday.map { Self.birthdayFormat.string(from: $0) }
        birthdaySave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save { try await $0.updateBirthday(token: $1, birthday: value) }
        }
    }

    private func save(_ action: @escaping (ApiClient, String) async throws -> Void) {
        guard let token = model.core.session.token else { return }
        Task {
            do { try await action(model.core.api, token); error = nil } catch { self.error = localizedError(error) }
        }
    }

    /// Фото — JPEG до 2 МБ (сервер больше не примет): уменьшаем до 1024 px и подбираем качество.
    private func upload(_ item: PhotosPickerItem) async {
        guard let token = model.core.session.token, let data = try? await item.loadTransferable(type: Data.self),
              let source = UIImage(data: data) else { return }
        let jpeg: Data? = await Task.detached {
            let side: CGFloat = 1024
            let scale = min(1, side / max(source.size.width, source.size.height))
            let target = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            let resized = UIGraphicsImageRenderer(size: target).image { _ in source.draw(in: CGRect(origin: .zero, size: target)) }
            for q in stride(from: 0.85, through: 0.4, by: -0.15) {
                if let d = resized.jpegData(compressionQuality: q), d.count <= 2 * 1024 * 1024 { return d }
            }
            return nil
        }.value
        guard let jpeg else { return }
        do {
            try await model.core.api.uploadAvatar(token: token, jpeg: jpeg)
            if let id = model.core.session.accountId { await model.core.avatars.invalidate(id) }
            avatarVersion += 1
            error = nil
        } catch {
            self.error = localizedError(error)
        }
    }
}

/// Профиль собеседника (по нажатию на шапку чата): фото, имя, статус, день рождения.
struct PeerProfileView: View {
    @EnvironmentObject private var model: AppModel
    let chat: ChatSummary
    @State private var profile: AccountProfile?

    var body: some View {
        VStack(spacing: 14) {
            AvatarView(accountId: chat.lastKnownAccountId, login: chat.peerLogin, size: 140).padding(.top, 32)
            Text(verbatim: profile?.displayName ?? chat.peerLogin).font(.title2.bold()).foregroundStyle(model.theme.textPrimary)
            Text(verbatim: "@\(chat.peerLogin)").foregroundStyle(model.theme.textMuted)
            if let s = profile?.status, !s.isEmpty { Text(verbatim: s).foregroundStyle(model.theme.textPrimary).multilineTextAlignment(.center) }
            if let b = profile?.birthday, !b.isEmpty {
                Label { Text(verbatim: b) } icon: { Image(systemName: "gift") }.foregroundStyle(model.theme.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(model.theme.background.ignoresSafeArea())
        .task {
            guard let token = model.core.session.token else { return }
            profile = try? await model.core.api.getAccountProfile(token: token, login: chat.peerLogin)
        }
    }
}
