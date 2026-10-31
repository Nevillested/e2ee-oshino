import Foundation

/**
 * История переписки и список чатов (логика — как core/storage/ChatStore.kt).
 *
 * Хранение на iOS: по файлу на чат (`chats/<sha>.json`) и индекс списка чатов
 * (`chats/index.json`) в Application Support под защитой данных iOS
 * (completeUntilFirstUserAuthentication — зашифровано системой, доступно
 * после первой разблокировки: входящий пуш при заблокированном экране
 * дописывает историю). Читается один раз в кэш памяти, пишется атомарно.
 * Keychain для больших историй не годится — он для ключей.
 */
public final class ChatStore: @unchecked Sendable {
    /** Логин чата «Заметки» первой версии клиента — скрыт. */
    public static let legacyNotesLogin = "__notes__"
    private static let maxTombstones = 500
    /// Маркер системного превью (переводится при показе — см. [decodePreview]).
    static let previewMark = "\u{E000}"

    private let dir: URL
    private let now: () -> Int64
    private let lock = NSRecursiveLock()
    private var messagesCache: [String: [StoredMessage]] = [:]
    private var tombstonesCache: [String: [String]] = [:]
    private var peersCache: [ChatSummary]?

    /** Что-то в истории или списке чатов изменилось — повод перечитать. */
    public let changes = Broadcast<Void>(bufferLimit: 1)

    public init(dirs: AppDirs, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        dir = dirs.support.appendingPathComponent("chats", isDirectory: true)
        self.now = now
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    // MARK: - превью

    /// Превью для списка чатов: системные подписи — маркером '<тип>[:<арг>]'.
    public static func previewMarker(_ m: StoredMessage) -> String {
        if m.isCallLog { return "\(previewMark)call:\(m.callOutcome ?? "no_answer")" }
        if m.isUndecryptable { return "\(previewMark)undecryptable" }
        if m.isVoice { return "\(previewMark)voice" }
        if m.isVideoNote { return "\(previewMark)videoNote" }
        if m.isSticker { return "\(previewMark)sticker" }
        if m.isMedia {
            let caption = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty { return caption }
            if m.isFile { return m.fileName.map { "\(previewMark)file:\($0)" } ?? "\(previewMark)file" }
            return m.isVideo ? "\(previewMark)video" : "\(previewMark)photo"
        }
        return m.text
    }

    /// Маркер → локализованная строка; [tr] — перевод по ключу локализации.
    public static func decodePreview(_ raw: String, tr: (String) -> String) -> String {
        guard raw.hasPrefix(previewMark) else { return raw }
        let body = String(raw.dropFirst(previewMark.count))
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        let type = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch type {
        case "voice": return "🎤 \(tr("media.voiceNote"))"
        case "videoNote": return "🎥 \(tr("media.videoNote"))"
        case "photo": return "📷 \(tr("media.photo"))"
        case "sticker": return tr("sticker.preview")
        case "video": return "🎬 \(tr("media.video"))"
        case "file": return arg.isEmpty ? "📎 \(tr("media.file"))" : arg
        case "undecryptable": return "🔒 \(tr("chat.undecryptablePreview"))"
        case "call":
            switch arg {
            case "answered": return "📞 \(tr("call.answered"))"
            case "missed": return "📞 \(tr("call.missed"))"
            default: return "📞 \(tr("call.noAnswer"))"
            }
        default: return raw
        }
    }

    // MARK: - файлы

    private func fileName(_ login: String, _ kind: String) -> URL {
        // логин → безопасное имя файла
        let safe = Data(login.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return dir.appendingPathComponent("\(kind)-\(safe).json")
    }

    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    private func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func store<T: Encodable>(_ value: T, _ url: URL) {
        guard let data = try? JSONEncoder.oshinobu.encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func notify() { changes.emit(()) }

    // MARK: - история

    public func messages(_ login: String) -> [StoredMessage] {
        lock.sync {
            if let cached = messagesCache[login] { return cached }
            let loaded = load([StoredMessage].self, fileName(login, "messages")) ?? []
            messagesCache[login] = loaded
            return loaded
        }
    }

    private func writeMessages(_ login: String, _ list: [StoredMessage]) {
        messagesCache[login] = list
        store(list, fileName(login, "messages"))
    }

    // «Надгробия» удалённых id: 'delete' может обогнать само удаляемое сообщение.
    private func tombstones(_ login: String) -> [String] {
        if let cached = tombstonesCache[login] { return cached }
        let loaded = load([String].self, fileName(login, "deleted")) ?? []
        tombstonesCache[login] = loaded
        return loaded
    }

    private func writeTombstones(_ login: String, _ ids: [String]) {
        let trimmed = Array(ids.suffix(Self.maxTombstones))
        tombstonesCache[login] = trimmed
        store(trimmed, fileName(login, "deleted"))
    }

    /// Добавляет сообщение; дубль по messageId и уже удалённое (tombstone) молча гасятся.
    public func addMessage(_ login: String, _ message: StoredMessage, accountId: String? = nil, incrementUnread: Bool = false) {
        addMessages(login, [message], accountId: accountId, incrementUnread: incrementUnread)
    }

    /// Несколько сообщений одной записью и одним уведомлением (группа файлов).
    public func addMessages(_ login: String, _ new: [StoredMessage], accountId: String? = nil, incrementUnread: Bool = false) {
        guard !new.isEmpty else { return }
        let added: [StoredMessage] = lock.sync {
            var list = messages(login)
            let existing = Set(list.map(\.messageId))
            var stones = tombstones(login)
            let candidates = new.filter { !existing.contains($0.messageId) }
            let consumed = Set(candidates.map(\.messageId)).intersection(stones)
            if !consumed.isEmpty {
                stones.removeAll { consumed.contains($0) }
                writeTombstones(login, stones)
            }
            let fresh = candidates.filter { !consumed.contains($0.messageId) }
            if !fresh.isEmpty {
                list += fresh
                writeMessages(login, list)
            }
            return fresh
        }
        guard let last = added.max(by: { $0.timestamp < $1.timestamp }) else { return }
        touchPeer(login, preview: Self.previewMarker(last), timestamp: last.timestamp, accountId: accountId,
                  incrementUnread: incrementUnread, isMine: last.isMine, isRead: last.status == MessageStatus.read)
    }

    /// Запись о звонке; [callId] общий для обеих сторон — "удалить у обоих" её находит.
    public func addCallLog(_ login: String, direction: String, outcome: String, timestamp: Int64, durationSeconds: Int64? = nil,
                           accountId: String? = nil, incrementUnread: Bool = false, callId: String? = nil) {
        let answered = outcome == "answered"
        var m = StoredMessage(messageId: callId.map { "call_\($0)" } ?? "call_\(timestamp)_\(direction)", text: "", isMine: direction == "outgoing", timestamp: timestamp)
        m.isCallLog = true
        m.callDirection = direction
        m.callOutcome = outcome
        m.callDurationSeconds = durationSeconds
        m.status = answered ? MessageStatus.read : MessageStatus.sent
        m.readReceiptSent = answered
        addMessage(login, m, accountId: accountId, incrementUnread: incrementUnread)
    }

    /// Заглушка на месте окончательно нерасшифрованного входящего ([id] стабилен для конверта).
    public func addUndecryptableNotice(_ login: String, id: String, timestamp: Int64, accountId: String? = nil, incrementUnread: Bool = false) {
        var m = StoredMessage(messageId: id, text: "", isMine: false, timestamp: timestamp)
        m.isUndecryptable = true
        m.readReceiptSent = true
        addMessage(login, m, accountId: accountId, incrementUnread: incrementUnread)
    }

    private func replace(_ login: String, _ messageId: String, _ update: (inout StoredMessage) -> Void) {
        lock.sync {
            var list = messages(login)
            guard let i = list.firstIndex(where: { $0.messageId == messageId }) else { return }
            update(&list[i])
            writeMessages(login, list)
        }
        notify()
    }

    public func updateMessageStatus(_ login: String, _ messageId: String, _ status: String) {
        replace(login, messageId) {
            $0.status = status
            if [MessageStatus.sent, MessageStatus.failed, MessageStatus.queued].contains(status) { $0.processingStep = nil }
        }
    }

    public func updateProcessingStep(_ login: String, _ messageId: String, _ step: String) { replace(login, messageId) { $0.processingStep = step } }

    public func updateMediaInfo(_ login: String, _ messageId: String, mediaId: String, key: String, nonce: String?, mac: String?, fileSize: Int64, chunked: Bool) {
        replace(login, messageId) {
            $0.mediaId = mediaId; $0.mediaKeyBase64 = key; $0.mediaNonceBase64 = nonce; $0.mediaMacBase64 = mac
            $0.fileSize = fileSize; $0.chunked = chunked
        }
    }

    public func setReaction(_ login: String, _ messageId: String, isMine: Bool, emoji: String?) {
        replace(login, messageId) { if isMine { $0.myReaction = emoji } else { $0.peerReaction = emoji } }
    }

    /// Правка; правят последнее сообщение — обновляется и превью чата.
    public func editMessageText(_ login: String, _ messageId: String, _ text: String) {
        replace(login, messageId) { $0.text = text; $0.edited = true }
        guard let last = messages(login).max(by: { $0.timestamp < $1.timestamp }), last.messageId == messageId else { return }
        updatePeer(login) { p in
            let preview = Self.previewMarker(last)
            guard p.lastMessage != preview else { return false }
            p.lastMessage = preview
            return true
        }
    }

    /// Собеседник прочитал наши сообщения.
    public func markMessagesRead(_ login: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let after: [StoredMessage] = lock.sync {
            var list = messages(login)
            var changed = false
            for i in list.indices where set.contains(list[i].messageId) && list[i].status != MessageStatus.read {
                list[i].status = MessageStatus.read
                changed = true
            }
            if changed { writeMessages(login, list) }
            return list
        }
        if let last = after.max(by: { $0.timestamp < $1.timestamp }) {
            updatePeer(login) { p in
                let isRead = last.isMine && last.status == MessageStatus.read
                guard p.lastMessageIsMine != last.isMine || p.lastMessageIsRead != isRead else { return false }
                p.lastMessageIsMine = last.isMine
                p.lastMessageIsRead = isRead
                return true
            }
        }
        notify()
    }

    /// Квитанции за эти (чужие) сообщения уже отправлены — не слать повторно.
    public func markReadReceiptsSent(_ login: String, _ ids: [String]) {
        let set = Set(ids)
        lock.sync {
            var list = messages(login)
            var changed = false
            for i in list.indices where set.contains(list[i].messageId) && !list[i].readReceiptSent {
                list[i].readReceiptSent = true
                changed = true
            }
            if changed { writeMessages(login, list) }
        }
    }

    /// Удаляет локально и ставит надгробия; удалили закреплённое — закреп снимается.
    public func deleteMessages(_ login: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let remaining: [StoredMessage] = lock.sync {
            var list = messages(login)
            list.removeAll { set.contains($0.messageId) }
            writeMessages(login, list)
            writeTombstones(login, tombstones(login) + ids)
            return list
        }
        updatePeer(login) { p in
            if let pinned = p.pinnedMessageId, set.contains(pinned) { p.pinnedMessageId = nil }
            if let last = remaining.max(by: { $0.timestamp < $1.timestamp }) {
                p.lastMessage = Self.previewMarker(last)
                p.lastTimestamp = last.timestamp
                p.lastMessageIsMine = last.isMine
                p.lastMessageIsRead = last.status == MessageStatus.read
            } else {
                p.lastMessage = ""
                p.lastTimestamp = 0
                p.lastMessageIsMine = false
                p.lastMessageIsRead = false
            }
            return true
        }
        notify()
    }

    /// "Очистить историю" — сообщения и надгробия, сам чат остаётся.
    public func clearHistory(_ login: String) {
        lock.sync {
            writeMessages(login, [])
            tombstonesCache[login] = []
            try? FileManager.default.removeItem(at: fileName(login, "deleted"))
        }
        updatePeer(login) { p in
            p.lastMessage = ""
            p.lastTimestamp = 0
            p.pinnedMessageId = nil
            return true
        }
        notify()
    }

    /// "Удалить чат" — вместе с записью в списке.
    public func removeChat(_ login: String) {
        lock.sync {
            messagesCache[login] = nil
            tombstonesCache[login] = nil
            try? FileManager.default.removeItem(at: fileName(login, "messages"))
            try? FileManager.default.removeItem(at: fileName(login, "deleted"))
            var peers = readPeers()
            peers.removeAll { $0.peerLogin == login }
            writePeers(peers)
        }
        notify()
    }

    // MARK: - список чатов

    private func readPeers() -> [ChatSummary] {
        if let cached = peersCache { return cached }
        let loaded = load([ChatSummary].self, indexURL) ?? []
        peersCache = loaded
        return loaded
    }

    private func writePeers(_ peers: [ChatSummary]) {
        peersCache = peers
        store(peers, indexURL)
    }

    /// Список чатов в порядке показа: закреплённые (последний закреп — выше), потом по времени.
    public func knownPeers() -> [ChatSummary] {
        lock.sync {
            readPeers().filter { $0.peerLogin != Self.legacyNotesLogin }.sorted { a, b in
                switch (a.chatPinnedAt, b.chatPinnedAt) {
                case let (x?, y?): return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.lastTimestamp > b.lastTimestamp
                }
            }
        }
    }

    public func peer(_ login: String) -> ChatSummary? { lock.sync { readPeers().first { $0.peerLogin == login } } }

    /// [update] возвращает true — есть что сохранить.
    private func updatePeer(_ login: String, _ update: (inout ChatSummary) -> Bool) {
        let changed: Bool = lock.sync {
            var peers = readPeers()
            guard let i = peers.firstIndex(where: { $0.peerLogin == login }), update(&peers[i]) else { return false }
            writePeers(peers)
            return true
        }
        if changed { notify() }
    }

    private func touchPeer(_ login: String, preview: String, timestamp: Int64, accountId: String?, incrementUnread: Bool, isMine: Bool, isRead: Bool) {
        lock.sync {
            var peers = readPeers()
            if let i = peers.firstIndex(where: { $0.peerLogin == login }) {
                if timestamp >= peers[i].lastTimestamp {
                    peers[i].lastMessage = preview
                    peers[i].lastTimestamp = timestamp
                    peers[i].lastMessageIsMine = isMine
                    peers[i].lastMessageIsRead = isRead
                }
                if let accountId { peers[i].lastKnownAccountId = accountId }
                if incrementUnread { peers[i].unreadCount += 1 }
                peers[i].isDeleted = false
            } else {
                var p = ChatSummary(peerLogin: login, lastMessage: preview, lastTimestamp: timestamp, lastKnownAccountId: accountId)
                p.unreadCount = incrementUnread ? 1 : 0
                p.lastMessageIsMine = isMine
                p.lastMessageIsRead = isRead
                peers.append(p)
            }
            writePeers(peers)
        }
        notify()
    }

    /// Чат без сообщений (открыли поиском) — появится в списке.
    public func ensurePeer(_ login: String, accountId: String?, deviceId: String?) {
        lock.sync {
            var peers = readPeers()
            guard !peers.contains(where: { $0.peerLogin == login }) else { return }
            peers.append(ChatSummary(peerLogin: login, lastTimestamp: now(), lastKnownAccountId: accountId, lastKnownDeviceId: deviceId))
            writePeers(peers)
        }
        notify()
    }

    public func setPinned(_ login: String, messageId: String?) { updatePeer(login) { $0.pinnedMessageId = messageId; return true } }
    public func setChatPinned(_ login: String, pinned: Bool) { let t = now(); updatePeer(login) { $0.chatPinnedAt = pinned ? t : nil; return true } }
    public func isChatMuted(_ login: String) -> Bool { peer(login)?.muted ?? false }
    public func setChatMuted(_ login: String, muted: Bool) { updatePeer(login) { $0.muted = muted; return true } }
    public func setChatBlockedByMe(_ login: String, blocked: Bool) { updatePeer(login) { $0.blockedByMe = blocked; return true } }
    public func clearUnread(_ login: String) { updatePeer(login) { p in guard p.unreadCount != 0 else { return false }; p.unreadCount = 0; return true } }
    public func setPeerDeleted(_ login: String, isDeleted: Bool) { updatePeer(login) { $0.isDeleted = isDeleted; return true } }
    public func setLastKnownDeviceId(_ login: String, deviceId: String) {
        updatePeer(login) { p in guard p.lastKnownDeviceId != deviceId else { return false }; p.lastKnownDeviceId = deviceId; return true }
    }

    /// Мьюты с сервера (по account_id).
    public func syncMutedFromServer(_ mutedAccountIds: Set<String>) {
        lock.sync {
            var peers = readPeers()
            var changed = false
            for i in peers.indices {
                let muted = peers[i].lastKnownAccountId.map(mutedAccountIds.contains) ?? false
                if peers[i].muted != muted { peers[i].muted = muted; changed = true }
            }
            if changed { writePeers(peers) }
        }
        notify()
    }

    /// Блокировки с сервера (по account_id).
    public func syncBlockedFromServer(blockedByMe: Set<String>, blockingMe: Set<String>) {
        lock.sync {
            var peers = readPeers()
            var changed = false
            for i in peers.indices {
                guard let id = peers[i].lastKnownAccountId else { continue }
                let a = blockedByMe.contains(id), b = blockingMe.contains(id)
                if peers[i].blockedByMe != a || peers[i].blockingMe != b {
                    peers[i].blockedByMe = a
                    peers[i].blockingMe = b
                    changed = true
                }
            }
            if changed { writePeers(peers) }
        }
        notify()
    }

    /// Выход из аккаунта — вся история стирается.
    public func wipeAll() {
        lock.sync {
            messagesCache = [:]
            tombstonesCache = [:]
            peersCache = []
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        notify()
    }
}

extension NSRecursiveLock {
    @inline(__always)
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
