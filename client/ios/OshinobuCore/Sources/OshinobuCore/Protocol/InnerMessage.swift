import Foundation

// Открытый текст внутри зашифрованного конверта (как core/protocol/InnerMessage.kt).
// [body] — строка: для 'text' — сам текст, для остальных типов — JSON-строка с
// полями типа. Формат на проводе: его читают все версии клиентов.

public enum MessageType {
    public static let text = "text"
    public static let media = "media"
    public static let voice = "voice"
    public static let videoNote = "video_note"
    public static let sticker = "sticker"
    public static let mediaGroup = "media_group"
    public static let callMissed = "call_missed"
    public static let reaction = "reaction"
    public static let pin = "pin"
    public static let edit = "edit"
    public static let delete = "delete"
    public static let clearChat = "clear_chat"
    public static let deleteChat = "delete_chat"
    public static let readReceipt = "read_receipt"
}

/// Ключ и параметры зашифрованного вложения (общая часть media/voice/video_note).
public struct MediaRef: Equatable, Sendable {
    public var mediaId: String
    public var keyBase64: String
    /// nonce/mac — только у НЕчанковых файлов.
    public var nonceBase64: String?
    public var macBase64: String?
    public var fileSize: Int64
    public var chunked: Bool

    public init(mediaId: String, keyBase64: String, nonceBase64: String?, macBase64: String?, fileSize: Int64, chunked: Bool) {
        self.mediaId = mediaId
        self.keyBase64 = keyBase64
        self.nonceBase64 = nonceBase64
        self.macBase64 = macBase64
        self.fileSize = fileSize
        self.chunked = chunked
    }

    fileprivate var fields: [String: JSONValue] {
        [
            "media_id": .string(mediaId), "key": .string(keyBase64), "nonce": .optional(nonceBase64), "mac": .optional(macBase64),
            "file_size": .int(fileSize), "chunked": .bool(chunked),
        ]
    }
}

public struct InnerMessage: Equatable, Sendable {
    public var messageId: String
    public var type: String
    public var sentAt: Int64
    public var body: String
    public var groupId: String?
    public var replyToMessageId: String?
    public var replyToPreview: String?

    public init(messageId: String, type: String, sentAt: Int64, body: String, groupId: String? = nil, replyToMessageId: String? = nil, replyToPreview: String? = nil) {
        self.messageId = messageId
        self.type = type
        self.sentAt = sentAt
        self.body = body
        self.groupId = groupId
        self.replyToMessageId = replyToMessageId
        self.replyToPreview = replyToPreview
    }

    public func encode() -> String {
        JSONValue.object([
            "message_id": .string(messageId),
            "type": .string(type),
            "sent_at": .int(sentAt),
            "body": .string(body),
            "group_id": .optional(groupId),
            "reply_to_id": .optional(replyToMessageId),
            "reply_to_preview": .optional(replyToPreview),
        ]).encoded()
    }

    /// body как JSON-объект — для всех типов, кроме 'text'.
    public func bodyJSON() -> [String: JSONValue] { (try? JSONValue.parse(body))?.object ?? [:] }

    public static func decode(_ raw: String) throws -> InnerMessage {
        let o = try JSONValue.parse(raw)
        guard let id = o["message_id"]?.primitiveContent, let type = o["type"]?.primitiveContent,
              let sentAt = o["sent_at"]?.int, let body = o["body"]?.primitiveContent else {
            throw CryptoError.badEnvelope("неполное внутреннее сообщение")
        }
        return InnerMessage(
            messageId: id, type: type, sentAt: sentAt, body: body,
            groupId: o["group_id"]?.primitiveContent,
            replyToMessageId: o["reply_to_id"]?.primitiveContent,
            replyToPreview: o["reply_to_preview"]?.primitiveContent
        )
    }

    // MARK: - фабрики (поля body — те же, что у Android)

    static func newId() -> String { UUID().uuidString.lowercased() }
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func json(_ fields: [String: JSONValue]) -> String { JSONValue.object(fields).encoded() }

    public static func text(_ body: String, replyTo: String? = nil, replyPreview: String? = nil) -> InnerMessage {
        InnerMessage(messageId: newId(), type: MessageType.text, sentAt: now(), body: body, replyToMessageId: replyTo, replyToPreview: replyPreview)
    }

    public static func media(_ ref: MediaRef, fileName: String, isFile: Bool = false, isVideo: Bool = false, spoiler: Bool = false,
                             messageId: String? = nil, replyTo: String? = nil, replyPreview: String? = nil) -> InnerMessage {
        var f = ref.fields
        f["file_name"] = .string(fileName)
        f["is_file"] = .bool(isFile)
        f["is_video"] = .bool(isVideo)
        f["spoiler"] = .bool(spoiler)
        return InnerMessage(messageId: messageId ?? newId(), type: MessageType.media, sentAt: now(), body: json(f), replyToMessageId: replyTo, replyToPreview: replyPreview)
    }

    /// Стикер — только его id; файл получатель берёт из пака на сервере.
    public static func sticker(_ stickerId: String, messageId: String? = nil, replyTo: String? = nil, replyPreview: String? = nil) -> InnerMessage {
        InnerMessage(messageId: messageId ?? newId(), type: MessageType.sticker, sentAt: now(), body: json(["sticker_id": .string(stickerId)]),
                     replyToMessageId: replyTo, replyToPreview: replyPreview)
    }

    private static func recorded(_ type: String, _ ref: MediaRef, durationMs: Int64, messageId: String?, replyTo: String?, replyPreview: String?) -> InnerMessage {
        var f = ref.fields
        f["duration_ms"] = .int(durationMs)
        return InnerMessage(messageId: messageId ?? newId(), type: type, sentAt: now(), body: json(f), replyToMessageId: replyTo, replyToPreview: replyPreview)
    }

    public static func voice(_ ref: MediaRef, durationMs: Int64, messageId: String? = nil, replyTo: String? = nil, replyPreview: String? = nil) -> InnerMessage {
        recorded(MessageType.voice, ref, durationMs: durationMs, messageId: messageId, replyTo: replyTo, replyPreview: replyPreview)
    }

    public static func videoNote(_ ref: MediaRef, durationMs: Int64, messageId: String? = nil, replyTo: String? = nil, replyPreview: String? = nil) -> InnerMessage {
        recorded(MessageType.videoNote, ref, durationMs: durationMs, messageId: messageId, replyTo: replyTo, replyPreview: replyPreview)
    }

    /// [files] — по объекту на файл, в том же виде, что body у 'media'.
    public static func mediaGroup(groupId: String, files: [[String: JSONValue]], caption: String? = nil, textMessageId: String? = nil, messageId: String? = nil) -> InnerMessage {
        InnerMessage(messageId: messageId ?? newId(), type: MessageType.mediaGroup, sentAt: now(),
                     body: json(["caption": .optional(caption), "text_message_id": .optional(textMessageId), "files": .array(files.map(JSONValue.object))]),
                     groupId: groupId)
    }

    public static func missedCall(calledAt: Int64, callId: String?) -> InnerMessage {
        InnerMessage(messageId: newId(), type: MessageType.callMissed, sentAt: now(), body: json(["called_at": .int(calledAt), "call_id": .optional(callId)]))
    }

    /// emoji = nil — снять реакцию.
    public static func reaction(target: String, emoji: String?) -> InnerMessage {
        InnerMessage(messageId: newId(), type: MessageType.reaction, sentAt: now(), body: json(["target_id": .string(target), "emoji": .optional(emoji)]))
    }

    public static func pin(target: String, pinned: Bool) -> InnerMessage {
        InnerMessage(messageId: newId(), type: MessageType.pin, sentAt: now(), body: json(["target_id": .string(target), "pinned": .bool(pinned)]))
    }

    public static func edit(target: String, newText: String) -> InnerMessage {
        InnerMessage(messageId: newId(), type: MessageType.edit, sentAt: now(), body: json(["target_id": .string(target), "text": .string(newText)]))
    }

    public static func delete(targets: [String]) -> InnerMessage {
        InnerMessage(messageId: newId(), type: MessageType.delete, sentAt: now(), body: json(["target_ids": .array(targets.map(JSONValue.string))]))
    }

    public static func clearChat() -> InnerMessage { InnerMessage(messageId: newId(), type: MessageType.clearChat, sentAt: now(), body: "{}") }

    public static func deleteChat() -> InnerMessage { InnerMessage(messageId: newId(), type: MessageType.deleteChat, sentAt: now(), body: "{}") }

    public static func readReceipt(targets: [String]) -> InnerMessage {
        InnerMessage(messageId: newId(), type: MessageType.readReceipt, sentAt: now(), body: json(["target_ids": .array(targets.map(JSONValue.string))]))
    }
}
