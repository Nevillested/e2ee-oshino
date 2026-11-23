import Foundation

/// Профиль собеседника, каким его отдаёт сервер с учётом его настроек приватности.
public struct PeerProfile: Codable, Equatable, Sendable {
    public let login: String
    public let displayName: String
    public let status: String?
    public let birthday: String?
    public let hasAvatar: Bool

    enum CodingKeys: String, CodingKey {
        case login, displayName = "display_name", status, birthday, hasAvatar = "has_avatar"
    }
}

/**
 * Профили собеседников по account_id (как PeerProfiles на Android): копия на диске
 * (имя видно сразу после запуска), сеть — не чаще раза за запуск на аккаунт и
 * заново по `profile_updated`. Профиль запрашивается по логину.
 */
public actor PeerProfiles {
    private let api: ApiClient
    private let session: Session
    private let dir: URL
    private var memory: [String: PeerProfile] = [:]
    private var logins: [String: String] = [:]
    private var fetched: Set<String> = []
    private var inFlight: [String: Task<PeerProfile?, Never>] = [:]
    /// account_id, у которого профиль поменялся — повод перерисовать.
    public nonisolated let changes = Broadcast<String>()

    public init(api: ApiClient, session: Session, dirs: AppDirs) {
        self.api = api
        self.session = session
        dir = dirs.support.appendingPathComponent("peer_profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ accountId: String) -> URL { dir.appendingPathComponent("\(accountId).json") }

    /// Что уже есть в памяти или на диске — без сети (первый кадр экрана).
    public func peek(_ accountId: String) -> PeerProfile? {
        if let m = memory[accountId] { return m }
        guard let data = try? Data(contentsOf: file(accountId)), let p = try? JSONDecoder().decode(PeerProfile.self, from: data) else { return nil }
        memory[accountId] = p
        return p
    }

    /// Профиль: память → диск → сеть (один запрос за запуск). nil — профиль скрыт или аккаунт удалён.
    public func get(_ accountId: String, login: String) async -> PeerProfile? {
        logins[accountId] = login
        let cached = peek(accountId)
        if fetched.contains(accountId) { return cached }
        if let running = inFlight[accountId] { return await running.value }
        let task = Task { await self.fetch(accountId) }
        inFlight[accountId] = task
        let result = await task.value
        inFlight[accountId] = nil
        return result
    }

    private func fetch(_ accountId: String) async -> PeerProfile? {
        guard let token = session.token, let login = logins[accountId] else { return memory[accountId] }
        do {
            let profile = try await api.getAccountProfile(token: token, login: login).map {
                PeerProfile(login: $0.login, displayName: $0.displayName, status: $0.status, birthday: $0.birthday, hasAvatar: $0.hasAvatar)
            }
            fetched.insert(accountId)
            let changed = profile != memory[accountId]
            memory[accountId] = profile
            if let profile, let data = try? JSONEncoder().encode(profile) {
                try? data.write(to: file(accountId), options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: file(accountId))
            }
            if changed { changes.emit(accountId) }
            return profile
        } catch {
            return memory[accountId] // нет сети — показываем сохранённое
        }
    }

    /// Собеседник поменял профиль (profile_updated) — перезапросить.
    public func invalidate(_ accountId: String) {
        fetched.remove(accountId)
        changes.emit(accountId)
    }
}
