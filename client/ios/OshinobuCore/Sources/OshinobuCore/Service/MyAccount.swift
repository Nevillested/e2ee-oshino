import Foundation

/// Свой профиль для экранов профиля и настроек (MyProfile на Android).
public struct MyProfile: Codable, Equatable, Sendable {
    public var login: String
    public var displayName: String?
    public var status: String?
    public var birthday: String?
    public var findByLoginVisibility: Int
    public var avatarVisibility: Int
    public var birthdayVisibility: Int
    public var statusVisibility: Int
}

/**
 * Свой аккаунт (MyAccount на Android): профиль, аватар, почта. Копия профиля и
 * аватара — на диске, первым кадром показывается она, затем — свежее с сервера.
 */
public final class MyAccount: @unchecked Sendable {
    private let api: ApiClient
    private let session: Session
    private let profileFile: URL
    private let avatarFile: URL

    public let profile = StateValue<MyProfile?>(nil)
    public let avatar = StateValue<Data?>(nil)
    public let email = StateValue<String?>(nil)

    public init(api: ApiClient, session: Session, dirs: AppDirs) {
        self.api = api
        self.session = session
        profileFile = dirs.support.appendingPathComponent("my_profile.json")
        avatarFile = dirs.support.appendingPathComponent("my_avatar.jpg")
    }

    /// Диск → сервер. Сетевые ошибки оставляют дисковую копию.
    public func load() async {
        guard let token = session.token else { return }
        if profile.value == nil, let data = try? Data(contentsOf: profileFile) { profile.value = try? JSONDecoder().decode(MyProfile.self, from: data) }
        if avatar.value == nil { avatar.value = try? Data(contentsOf: avatarFile) }
        if let info = await api.getMyAccountInfo(token: token) {
            session.login = info.login
            session.accountId = info.accountId
            email.value = info.email
            setProfile(MyProfile(login: info.login, displayName: info.displayName, status: info.status, birthday: info.birthday,
                                 findByLoginVisibility: info.findByLoginVisibility, avatarVisibility: info.avatarVisibility,
                                 birthdayVisibility: info.birthdayVisibility, statusVisibility: info.statusVisibility))
        }
        if let data = try? await api.getMyAvatar(token: token) { setAvatar(data) }
    }

    private func setProfile(_ p: MyProfile?) {
        profile.value = p
        if let p, let data = try? JSONEncoder().encode(p) { try? data.write(to: profileFile, options: .atomic) } else { try? FileManager.default.removeItem(at: profileFile) }
    }

    private func update(_ change: (inout MyProfile) -> Void) {
        guard var p = profile.value else { return }
        change(&p)
        setProfile(p)
    }

    public func setDisplayName(_ name: String?) { update { $0.displayName = name?.isEmpty == false ? name : nil } }
    public func setStatus(_ status: String?) { update { $0.status = status } }
    public func setBirthday(_ birthday: String?) { update { $0.birthday = birthday } }
    public func setPrivacy(_ s: PrivacySettings) {
        update {
            $0.findByLoginVisibility = s.findByLogin
            $0.avatarVisibility = s.avatar
            $0.birthdayVisibility = s.birthday
            $0.statusVisibility = s.status
        }
    }

    public func setEmail(_ value: String?) { email.value = value }

    /// nil/пусто — аватар удалён.
    public func setAvatar(_ data: Data?) {
        let value = data?.isEmpty == false ? data : nil
        avatar.value = value
        if let value { try? value.write(to: avatarFile, options: .atomic) } else { try? FileManager.default.removeItem(at: avatarFile) }
    }

    /// Выход из аккаунта.
    public func reset() {
        setProfile(nil)
        setAvatar(nil)
        email.value = nil
    }
}
