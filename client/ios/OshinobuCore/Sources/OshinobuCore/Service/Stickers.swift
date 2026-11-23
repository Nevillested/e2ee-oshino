import Foundation

/**
 * Стикеры (как Stickers.kt на Android): сообщение несёт только id стикера;
 * получатель скачивает весь пак одним ZIP (сервер не видит, какой стикер пришёл)
 * и кэширует его. Файл стикера — `<кэш>/stickers/<pack>/<id>.<формат>`.
 */
public actor Stickers {
    private let api: ApiClient
    private let session: Session
    private let dir: URL
    /// id стикера → пак (запомнено в памяти).
    private var packOf: [String: StickerPackInfo] = [:]
    private var loading: [String: Task<Bool, Never>] = [:]

    public init(api: ApiClient, session: Session, dirs: AppDirs) {
        self.api = api
        self.session = session
        dir = dirs.temp.appendingPathComponent("stickers", isDirectory: true)
    }

    /// Файл стикера на устройстве; нет — скачать пак (повтор — следующий вызов).
    public func file(_ stickerId: String) async -> URL? {
        if let found = local(stickerId) { return found }
        guard let token = session.token else { return nil }
        let pack: StickerPackInfo
        if let known = packOf[stickerId] { pack = known } else {
            guard let p = try? await api.getStickerPackBySticker(token: token, stickerId: stickerId) else { return nil }
            remember(p)
            pack = p
        }
        guard await ensurePack(pack.id, token: token) else { return nil }
        return local(stickerId)
    }

    /// Известный пак стикера — из памяти или с диска (описание лежит рядом с файлами пака), без сети.
    public func pack(of stickerId: String) -> StickerPackInfo? {
        if let known = packOf[stickerId] { return known }
        guard let packDir = local(stickerId)?.deletingLastPathComponent(),
              let data = try? Data(contentsOf: packDir.appendingPathComponent("pack.json")),
              let p = try? JSONDecoder().decode(StickerPackInfo.self, from: data) else { return nil }
        for s in p.stickers { packOf[s.id] = p }
        return p
    }

    /// Свежее описание пака (с сервера) — в память и на диск, чтобы в следующий раз открыть без сети.
    public func remember(_ p: StickerPackInfo) {
        for s in p.stickers { packOf[s.id] = p }
        let packDir = dir.appendingPathComponent(p.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: packDir.appendingPathComponent("pack.json"), options: .atomic) }
    }

    private func local(_ stickerId: String) -> URL? {
        guard let packs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for p in packs {
            for ext in ["webp", "png", "tgs"] {
                let f = p.appendingPathComponent("\(stickerId).\(ext)")
                if FileManager.default.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }

    private func ensurePack(_ packId: String, token: String) async -> Bool {
        if let running = loading[packId] { return await running.value }
        let target = dir.appendingPathComponent(packId, isDirectory: true)
        let task = Task<Bool, Never> { [api] in
            let zip = FileManager.default.temporaryDirectory.appendingPathComponent("pack_\(packId).zip")
            defer { try? FileManager.default.removeItem(at: zip) }
            guard (try? await api.downloadStickerPack(token: token, packId: packId, dest: zip)) == true else { return false }
            return (try? ZipReader.extract(zip, to: target)) != nil
        }
        loading[packId] = task
        let ok = await task.value
        loading[packId] = nil
        return ok
    }

    /// Сколько занимают скачанные паки (байты).
    public func cacheSize() -> Int64 { directorySize(dir) }

    /// Очистка кэша: паки скачаются заново при показе.
    public func clearCache() {
        try? FileManager.default.removeItem(at: dir)
    }
}
