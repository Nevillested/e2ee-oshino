import Foundation

// Сообщение в локальной истории и строка списка чатов (как
// core/storage/StoredMessage.kt — те же JSON-ключи и умолчания).

public enum MessageStatus {
    public static let sending = "sending"
    public static let queued = "queued"
    public static let sent = "sent"
    public static let read = "read"
    public static let failed = "failed"
}

public struct StoredMessage: Codable, Equatable, Identifiable, Sendable {
    public var messageId: String
    public var text: String
    public var isMine: Bool
    public var timestamp: Int64
    public var isMedia = false
    public var isFile = false
    /// Видео из галереи (с превью-кадром), в отличие от isFile.
    public var isVideo = false
    public var fileSize: Int64 = 0
    public var chunked = false
    public var mediaId: String?
    public var mediaKeyBase64: String?
    public var mediaNonceBase64: String?
    public var mediaMacBase64: String?
    public var fileName: String?
    /// Фото/видео под спойлером; раскрытие не сохраняется.
    public var isSpoiler = false
    public var isVoice = false
    public var isVideoNote = false
    public var durationMs: Int64?
    /// Стикер: id на сервере, текст пустой.
    public var stickerId: String?
    public var status: String = MessageStatus.sent
    public var processingStep: String?
    public var localPreviewPath: String?
    /// Исходный файл, выбранный для отправки.
    public var localSourcePath: String?
    public var groupId: String?
    public var isCallLog = false
    public var callDirection: String? // outgoing | incoming
    public var callOutcome: String? // answered | no_answer | missed
    public var callDurationSeconds: Int64?
    /// Заглушка на месте окончательно нерасшифрованного входящего.
    public var isUndecryptable = false
    public var replyToMessageId: String?
    public var replyToPreview: String?
    public var edited = false
    public var myReaction: String?
    public var peerReaction: String?
    /// Только для чужих: квитанция о прочтении уже отправлена.
    public var readReceiptSent = false

    public var id: String { messageId }
    public var isSticker: Bool { stickerId != nil }

    public init(messageId: String, text: String, isMine: Bool, timestamp: Int64) {
        self.messageId = messageId
        self.text = text
        self.isMine = isMine
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case messageId = "id", text, isMine = "is_mine", timestamp = "ts", isMedia = "is_media", isFile = "is_file", isVideo = "is_video"
        case fileSize = "file_size", chunked, mediaId = "media_id", mediaKeyBase64 = "media_key", mediaNonceBase64 = "media_nonce"
        case mediaMacBase64 = "media_mac", fileName = "file_name", isSpoiler = "is_spoiler", isVoice = "is_voice", isVideoNote = "is_video_note"
        case durationMs = "duration_ms", stickerId = "sticker_id", status, processingStep = "step", localPreviewPath = "local_preview"
        case localSourcePath = "local_source", groupId = "group_id", isCallLog = "is_call_log", callDirection = "call_direction"
        case callOutcome = "call_outcome", callDurationSeconds = "call_duration", isUndecryptable = "undecryptable"
        case replyToMessageId = "reply_to_id", replyToPreview = "reply_to_preview", edited, myReaction = "my_reaction"
        case peerReaction = "peer_reaction", readReceiptSent = "read_receipt_sent"
    }

    /// Отсутствующие поля — умолчания (как optBool ?: false на Android).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func b(_ k: CodingKeys) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? false }
        func s(_ k: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
        func l(_ k: CodingKeys) -> Int64? { try? c.decodeIfPresent(Int64.self, forKey: k) }
        messageId = s(.messageId) ?? ""
        text = s(.text) ?? ""
        isMine = b(.isMine)
        timestamp = l(.timestamp) ?? 0
        isMedia = b(.isMedia); isFile = b(.isFile); isVideo = b(.isVideo)
        fileSize = l(.fileSize) ?? 0
        chunked = b(.chunked)
        mediaId = s(.mediaId); mediaKeyBase64 = s(.mediaKeyBase64); mediaNonceBase64 = s(.mediaNonceBase64); mediaMacBase64 = s(.mediaMacBase64)
        fileName = s(.fileName)
        isSpoiler = b(.isSpoiler); isVoice = b(.isVoice); isVideoNote = b(.isVideoNote)
        durationMs = l(.durationMs)
        stickerId = s(.stickerId)
        status = s(.status) ?? MessageStatus.sent
        processingStep = s(.processingStep); localPreviewPath = s(.localPreviewPath); localSourcePath = s(.localSourcePath)
        groupId = s(.groupId)
        isCallLog = b(.isCallLog); callDirection = s(.callDirection); callOutcome = s(.callOutcome); callDurationSeconds = l(.callDurationSeconds)
        isUndecryptable = b(.isUndecryptable)
        replyToMessageId = s(.replyToMessageId); replyToPreview = s(.replyToPreview)
        edited = b(.edited)
        myReaction = s(.myReaction); peerReaction = s(.peerReaction)
        readReceiptSent = b(.readReceiptSent)
    }
}

/// Строка списка чатов.
public struct ChatSummary: Codable, Equatable, Identifiable, Sendable {
    public var peerLogin: String
    public var lastMessage: String
    public var lastTimestamp: Int64
    public var lastKnownAccountId: String?
    public var lastKnownDeviceId: String?
    public var isDeleted = false
    public var unreadCount = 0
    public var pinnedMessageId: String?
    /// Когда чат закреплён в списке; nil — не закреплён.
    public var chatPinnedAt: Int64?
    public var muted = false
    public var blockedByMe = false
    public var blockingMe = false
    public var lastMessageIsMine = false
    public var lastMessageIsRead = false

    public var id: String { peerLogin }

    public init(peerLogin: String, lastMessage: String = "", lastTimestamp: Int64 = 0, lastKnownAccountId: String? = nil, lastKnownDeviceId: String? = nil) {
        self.peerLogin = peerLogin
        self.lastMessage = lastMessage
        self.lastTimestamp = lastTimestamp
        self.lastKnownAccountId = lastKnownAccountId
        self.lastKnownDeviceId = lastKnownDeviceId
    }

    enum CodingKeys: String, CodingKey {
        case peerLogin = "login", lastMessage = "last_message", lastTimestamp = "last_ts", lastKnownAccountId = "account_id"
        case lastKnownDeviceId = "device_id", isDeleted = "is_deleted", unreadCount = "unread", pinnedMessageId = "pinned_message_id"
        case chatPinnedAt = "chat_pinned_at", muted, blockedByMe = "blocked_by_me", blockingMe = "blocking_me"
        case lastMessageIsMine = "last_is_mine", lastMessageIsRead = "last_is_read"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func b(_ k: CodingKeys) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? false }
        func s(_ k: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
        peerLogin = try c.decode(String.self, forKey: .peerLogin)
        lastMessage = s(.lastMessage) ?? ""
        lastTimestamp = (try? c.decodeIfPresent(Int64.self, forKey: .lastTimestamp)) ?? 0
        lastKnownAccountId = s(.lastKnownAccountId)
        lastKnownDeviceId = s(.lastKnownDeviceId)
        isDeleted = b(.isDeleted)
        unreadCount = (try? c.decodeIfPresent(Int.self, forKey: .unreadCount)) ?? 0
        pinnedMessageId = s(.pinnedMessageId)
        chatPinnedAt = try? c.decodeIfPresent(Int64.self, forKey: .chatPinnedAt)
        muted = b(.muted); blockedByMe = b(.blockedByMe); blockingMe = b(.blockingMe)
        lastMessageIsMine = b(.lastMessageIsMine); lastMessageIsRead = b(.lastMessageIsRead)
    }
}
