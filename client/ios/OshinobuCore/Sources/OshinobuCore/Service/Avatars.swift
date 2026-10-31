import Foundation

/**
 * Фото профиля собеседников и своё (как Avatars/RemoteCache на Android): копия
 * на диске (переживает перезапуск, показывается сразу), сеть — не чаще раза за
 * запуск на аккаунт и заново по `profile_updated`. Пустой ответ 200 — сбой
 * хранилища: сохранённую копию не затираем.
 */
public actor Avatars {
    private let api: ApiClient
    private let session: Session
    private let dir: URL
    private var memory: [String: Data] = [:]
    private var fetched: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]
    /// account_id, у которого фото поменялось — повод перерисовать.
    public nonisolated let changes = Broadcast<String>()

    public init(api: ApiClient, session: Session, dirs: AppDirs) {
        self.api = api
        self.session = session
        dir = dirs.support.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ accountId: String) -> URL { dir.appendingPathComponent("\(accountId).jpg") }

    /// Фото аккаунта: память → диск → сеть (один запрос за запуск). nil — фото нет.
    public func get(_ accountId: String) async -> Data? {
        if let m = memory[accountId], fetched.contains(accountId) { return m }
        if memory[accountId] == nil, let disk = try? Data(contentsOf: file(accountId)) { memory[accountId] = disk }
        if fetched.contains(accountId) { return memory[accountId] }
        if let running = inFlight[accountId] { return await running.value }
        let task = Task { await self.fetch(accountId) }
        inFlight[accountId] = task
        let result = await task.value
        inFlight[accountId] = nil
        return result
    }

    private func fetch(_ accountId: String) async -> Data? {
        guard let token = session.token else { return memory[accountId] }
        do {
            let data = try await api.getAvatar(token: token, accountId: accountId)
            fetched.insert(accountId)
            if let data {
                memory[accountId] = data
                try? data.write(to: file(accountId), options: .atomic)
            } else {
                memory[accountId] = nil
                try? FileManager.default.removeItem(at: file(accountId))
            }
            changes.emit(accountId)
            return data
        } catch {
            return memory[accountId] // сеть или сбой хранилища — показываем сохранённое
        }
    }

    /// Собеседник поменял фото (profile_updated) — перезапросить.
    public func invalidate(_ accountId: String) {
        fetched.remove(accountId)
        changes.emit(accountId)
    }
}
