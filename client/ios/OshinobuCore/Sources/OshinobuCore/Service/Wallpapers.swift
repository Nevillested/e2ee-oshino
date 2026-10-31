import Foundation

/**
 * Обои чатов (как Wallpapers на Android): список версий с сервера, файлы — на диске
 * (переживают перезапуск), сверка при подключении и по сигналу `wallpaper_changed`.
 */
public actor Wallpapers {
    private let api: ApiClient
    private let session: Session
    private let dir: URL
    private var versions: [String: Int64] = [:]
    /// account_id собеседника, у чата с которым сменились обои.
    public nonisolated let changes = Broadcast<String>()

    public init(api: ApiClient, session: Session, dirs: AppDirs) {
        self.api = api
        self.session = session
        dir = dirs.support.appendingPathComponent("wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        versions = (try? JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: dir.appendingPathComponent("versions.json")))) ?? [:]
    }

    /// Версии скачанных обоев — на диск: при запуске перекачивать незачем.
    private func saveVersions() {
        if let data = try? JSONEncoder().encode(versions) { try? data.write(to: dir.appendingPathComponent("versions.json"), options: .atomic) }
    }

    public nonisolated func file(_ peerAccountId: String) -> URL { dir.appendingPathComponent("\(peerAccountId).jpg") }

    /// Сверить со списком сервера: новые/изменённые — скачать, снятые — удалить.
    public func sync() async {
        guard let token = session.token, let server = await api.getChatWallpapers(token: token) else { return }
        let fm = FileManager.default
        for (account, version) in server where versions[account] != version || !fm.fileExists(atPath: file(account).path) {
            await download(account, token: token)
            versions[account] = version
        }
        for gone in Set(versions.keys).subtracting(server.keys) {
            try? fm.removeItem(at: file(gone))
            versions[gone] = nil
            changes.emit(gone)
        }
        saveVersions()
    }

    public func refresh(_ peerAccountId: String) async {
        guard let token = session.token else { return }
        await download(peerAccountId, token: token)
    }

    /// Поставить обои чату с [peerAccountId] ([forPeer] — и собеседнику). Ошибка сети — исключение.
    public func set(_ peerAccountId: String, jpeg: Data, forPeer: Bool) async throws {
        guard let token = session.token else { throw ApiError("error.notSignedIn") }
        let version = try await api.setChatWallpaper(token: token, peerAccountId: peerAccountId, jpeg: jpeg, forPeer: forPeer)
        try jpeg.write(to: file(peerAccountId), options: .atomic)
        versions[peerAccountId] = version
        saveVersions()
        changes.emit(peerAccountId)
    }

    /// Убрать обои чата (только у себя).
    public func remove(_ peerAccountId: String) async throws {
        guard let token = session.token else { throw ApiError("error.notSignedIn") }
        try await api.deleteChatWallpaper(token: token, peerAccountId: peerAccountId)
        try? FileManager.default.removeItem(at: file(peerAccountId))
        versions[peerAccountId] = nil
        saveVersions()
        changes.emit(peerAccountId)
    }

    private func download(_ account: String, token: String) async {
        do {
            if let jpeg = try await api.getChatWallpaper(token: token, peerAccountId: account) {
                try jpeg.write(to: file(account), options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: file(account))
            }
            changes.emit(account)
        } catch {
            // NAS/сеть — остаются прежние обои
        }
    }
}
