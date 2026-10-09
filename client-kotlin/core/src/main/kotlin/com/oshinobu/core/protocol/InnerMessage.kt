package com.oshinobu.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.util.UUID

// Открытый текст внутри зашифрованного конверта — порт
// client/lib/crypto/message_envelope.dart. [body] — строка (для 'text' —
// сам текст, для остальных типов — JSON-строка с полями типа), ровно как в
// Dart: собеседник на Flutter декодирует её тем же кодом.

object MessageType {
    const val TEXT = "text"
    const val MEDIA = "media"
    const val VOICE = "voice"
    const val VIDEO_NOTE = "video_note"
    const val MEDIA_GROUP = "media_group"
    const val CALL_MISSED = "call_missed"
    const val REACTION = "reaction"
    const val PIN = "pin"
    const val EDIT = "edit"
    const val DELETE = "delete"
    const val CLEAR_CHAT = "clear_chat"
    const val DELETE_CHAT = "delete_chat"
    const val READ_RECEIPT = "read_receipt"
}

/** Ключ и параметры зашифрованного вложения (общая часть media/voice/video_note). */
data class MediaRef(
    val mediaId: String,
    val keyBase64: String,
    /** nonce/mac — только у НЕчанковых файлов (целиком одним AES-GCM). */
    val nonceBase64: String?,
    val macBase64: String?,
    val fileSize: Long,
    val chunked: Boolean,
)

data class InnerMessage(
    val messageId: String,
    val type: String,
    val sentAt: Long,
    val body: String,
    val groupId: String? = null,
    val replyToMessageId: String? = null,
    val replyToPreview: String? = null,
) {
    fun encode(): String = Json.encodeToString(
        JsonObject.serializer(),
        buildJsonObject {
            put("message_id", messageId)
            put("type", type)
            put("sent_at", sentAt)
            put("body", body)
            put("group_id", groupId)
            put("reply_to_id", replyToMessageId)
            put("reply_to_preview", replyToPreview)
        },
    )

    /** body как JSON-объект — для всех типов, кроме 'text'. */
    fun bodyJson(): JsonObject = Json.parseToJsonElement(body).jsonObject

    companion object {
        private fun newId() = UUID.randomUUID().toString()
        private fun now() = System.currentTimeMillis()
        private fun json(vararg fields: Pair<String, Any?>): String =
            Json.encodeToString(JsonObject.serializer(), JsonObject(fields.associate { (k, v) -> k to toJson(v) }))

        private fun toJson(v: Any?): JsonElement = when (v) {
            null -> JsonNull
            is JsonElement -> v
            is String -> JsonPrimitive(v)
            is Number -> JsonPrimitive(v)
            is Boolean -> JsonPrimitive(v)
            is List<*> -> JsonArray(v.map { toJson(it) })
            else -> error("не JSON-значение: $v")
        }

        fun decode(raw: String): InnerMessage {
            val o = Json.parseToJsonElement(raw).jsonObject
            fun opt(name: String) = (o[name] as? JsonPrimitive)?.contentOrNull
            return InnerMessage(
                messageId = o["message_id"]!!.jsonPrimitive.content,
                type = o["type"]!!.jsonPrimitive.content,
                sentAt = o["sent_at"]!!.jsonPrimitive.long,
                body = o["body"]!!.jsonPrimitive.content,
                groupId = opt("group_id"),
                replyToMessageId = opt("reply_to_id"),
                replyToPreview = opt("reply_to_preview"),
            )
        }

        fun text(body: String, replyToMessageId: String? = null, replyToPreview: String? = null) =
            InnerMessage(newId(), MessageType.TEXT, now(), body, replyToMessageId = replyToMessageId, replyToPreview = replyToPreview)

        fun media(
            ref: MediaRef,
            fileName: String,
            isFile: Boolean = false,
            isVideo: Boolean = false,
            spoiler: Boolean = false,
            messageId: String? = null,
            replyToMessageId: String? = null,
            replyToPreview: String? = null,
        ) = InnerMessage(
            messageId ?: newId(), MessageType.MEDIA, now(),
            json(
                "media_id" to ref.mediaId, "key" to ref.keyBase64, "nonce" to ref.nonceBase64, "mac" to ref.macBase64,
                "file_name" to fileName, "is_file" to isFile, "is_video" to isVideo, "file_size" to ref.fileSize,
                "chunked" to ref.chunked, "spoiler" to spoiler,
            ),
            replyToMessageId = replyToMessageId, replyToPreview = replyToPreview,
        )

        private fun recorded(type: String, ref: MediaRef, durationMs: Long, messageId: String?, replyTo: String?, replyPreview: String?) =
            InnerMessage(
                messageId ?: newId(), type, now(),
                json(
                    "media_id" to ref.mediaId, "key" to ref.keyBase64, "nonce" to ref.nonceBase64, "mac" to ref.macBase64,
                    "file_size" to ref.fileSize, "chunked" to ref.chunked, "duration_ms" to durationMs,
                ),
                replyToMessageId = replyTo, replyToPreview = replyPreview,
            )

        fun voice(ref: MediaRef, durationMs: Long, messageId: String? = null, replyToMessageId: String? = null, replyToPreview: String? = null) =
            recorded(MessageType.VOICE, ref, durationMs, messageId, replyToMessageId, replyToPreview)

        fun videoNote(ref: MediaRef, durationMs: Long, messageId: String? = null, replyToMessageId: String? = null, replyToPreview: String? = null) =
            recorded(MessageType.VIDEO_NOTE, ref, durationMs, messageId, replyToMessageId, replyToPreview)

        /** [files] — по объекту на файл, в том же виде, что body у 'media'. */
        fun mediaGroup(groupId: String, files: List<JsonObject>, caption: String? = null, textMessageId: String? = null, messageId: String? = null) =
            InnerMessage(
                messageId ?: newId(), MessageType.MEDIA_GROUP, now(),
                json("caption" to caption, "text_message_id" to textMessageId, "files" to files),
                groupId = groupId,
            )

        fun missedCall(calledAt: Long, callId: String?) =
            InnerMessage(newId(), MessageType.CALL_MISSED, now(), json("called_at" to calledAt, "call_id" to callId))

        /** emoji = null — снять реакцию. */
        fun reaction(targetMessageId: String, emoji: String?) =
            InnerMessage(newId(), MessageType.REACTION, now(), json("target_id" to targetMessageId, "emoji" to emoji))

        fun pin(targetMessageId: String, pinned: Boolean) =
            InnerMessage(newId(), MessageType.PIN, now(), json("target_id" to targetMessageId, "pinned" to pinned))

        fun edit(targetMessageId: String, newText: String) =
            InnerMessage(newId(), MessageType.EDIT, now(), json("target_id" to targetMessageId, "text" to newText))

        fun delete(targetMessageIds: List<String>) =
            InnerMessage(newId(), MessageType.DELETE, now(), json("target_ids" to targetMessageIds))

        fun clearChat() = InnerMessage(newId(), MessageType.CLEAR_CHAT, now(), "{}")

        fun deleteChat() = InnerMessage(newId(), MessageType.DELETE_CHAT, now(), "{}")

        fun readReceipt(targetMessageIds: List<String>) =
            InnerMessage(newId(), MessageType.READ_RECEIPT, now(), json("target_ids" to targetMessageIds))
    }
}
