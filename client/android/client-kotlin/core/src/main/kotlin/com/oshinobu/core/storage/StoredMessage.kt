package com.oshinobu.core.storage

import com.oshinobu.core.optBool
import com.oshinobu.core.optInt
import com.oshinobu.core.optLong
import com.oshinobu.core.optString
import com.oshinobu.core.string
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Сообщение в локальной истории чата — порт StoredMessage из
// client/lib/storage/chat_store.dart. JSON-ключи и умолчания совпадают
// посимвольно: эту же историю читает и пишет Flutter-сборка.

object MessageStatus {
    const val SENDING = "sending"
    const val QUEUED = "queued"
    const val SENT = "sent"
    const val READ = "read"
    const val FAILED = "failed"
}

data class StoredMessage(
    val messageId: String,
    val text: String,
    val isMine: Boolean,
    val timestamp: Long,
    val isMedia: Boolean = false,
    val isFile: Boolean = false,
    /** Видео из галереи (с превью-кадром), в отличие от isFile. */
    val isVideo: Boolean = false,
    val fileSize: Long = 0,
    val chunked: Boolean = false,
    val mediaId: String? = null,
    val mediaKeyBase64: String? = null,
    val mediaNonceBase64: String? = null,
    val mediaMacBase64: String? = null,
    val fileName: String? = null,
    /** Фото/видео под спойлером; раскрытие не сохраняется. */
    val isSpoiler: Boolean = false,
    val isVoice: Boolean = false,
    val isVideoNote: Boolean = false,
    val durationMs: Long? = null,
    val status: String = MessageStatus.SENT,
    val processingStep: String? = null,
    val localPreviewPath: String? = null,
    /** Исходный файл, выбранный для отправки (видео/файл/голосовое). */
    val localSourcePath: String? = null,
    val groupId: String? = null,
    val isCallLog: Boolean = false,
    val callDirection: String? = null, // 'outgoing' | 'incoming'
    val callOutcome: String? = null, // 'answered' | 'no_answer' | 'missed'
    val callDurationSeconds: Long? = null,
    /** Заглушка на месте окончательно нерасшифрованного входящего сообщения. */
    val isUndecryptable: Boolean = false,
    val replyToMessageId: String? = null,
    val replyToPreview: String? = null,
    val edited: Boolean = false,
    val myReaction: String? = null,
    val peerReaction: String? = null,
    /** Только для чужих: квитанция о прочтении уже отправлена. */
    val readReceiptSent: Boolean = false,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("id", messageId)
        put("text", text)
        put("is_mine", isMine)
        put("ts", timestamp)
        put("is_media", isMedia)
        put("is_file", isFile)
        put("is_video", isVideo)
        put("file_size", fileSize)
        put("chunked", chunked)
        put("media_id", mediaId)
        put("media_key", mediaKeyBase64)
        put("media_nonce", mediaNonceBase64)
        put("media_mac", mediaMacBase64)
        put("file_name", fileName)
        put("is_spoiler", isSpoiler)
        put("is_voice", isVoice)
        put("is_video_note", isVideoNote)
        put("duration_ms", durationMs)
        put("status", status)
        put("step", processingStep)
        put("local_preview", localPreviewPath)
        put("local_source", localSourcePath)
        put("group_id", groupId)
        put("is_call_log", isCallLog)
        put("call_direction", callDirection)
        put("call_outcome", callOutcome)
        put("call_duration", callDurationSeconds)
        put("undecryptable", isUndecryptable)
        put("reply_to_id", replyToMessageId)
        put("reply_to_preview", replyToPreview)
        put("edited", edited)
        put("my_reaction", myReaction)
        put("peer_reaction", peerReaction)
        put("read_receipt_sent", readReceiptSent)
    }

    companion object {
        fun fromJson(j: JsonObject): StoredMessage {
            fun s(name: String) = j.optString(name)
            fun b(name: String) = j.optBool(name) ?: false
            fun l(name: String) = j.optLong(name)
            return StoredMessage(
                messageId = s("id") ?: "",
                text = s("text") ?: "",
                isMine = b("is_mine"),
                timestamp = l("ts") ?: 0,
                isMedia = b("is_media"),
                isFile = b("is_file"),
                isVideo = b("is_video"),
                fileSize = l("file_size") ?: 0,
                chunked = b("chunked"),
                mediaId = s("media_id"),
                mediaKeyBase64 = s("media_key"),
                mediaNonceBase64 = s("media_nonce"),
                mediaMacBase64 = s("media_mac"),
                fileName = s("file_name"),
                isSpoiler = b("is_spoiler"),
                isVoice = b("is_voice"),
                isVideoNote = b("is_video_note"),
                durationMs = l("duration_ms"),
                status = s("status") ?: MessageStatus.SENT,
                processingStep = s("step"),
                localPreviewPath = s("local_preview"),
                localSourcePath = s("local_source"),
                groupId = s("group_id"),
                isCallLog = b("is_call_log"),
                callDirection = s("call_direction"),
                callOutcome = s("call_outcome"),
                callDurationSeconds = l("call_duration"),
                isUndecryptable = b("undecryptable"),
                replyToMessageId = s("reply_to_id"),
                replyToPreview = s("reply_to_preview"),
                edited = b("edited"),
                myReaction = s("my_reaction"),
                peerReaction = s("peer_reaction"),
                readReceiptSent = b("read_receipt_sent"),
            )
        }
    }
}

/** Строка списка чатов — порт ChatSummary (ключ known_peers). */
data class ChatSummary(
    val peerLogin: String,
    var lastMessage: String,
    var lastTimestamp: Long,
    var lastKnownAccountId: String? = null,
    var lastKnownDeviceId: String? = null,
    var isDeleted: Boolean = false,
    var unreadCount: Int = 0,
    var pinnedMessageId: String? = null,
    /** Когда чат закреплён в списке; null — не закреплён. */
    var chatPinnedAt: Long? = null,
    var muted: Boolean = false,
    var blockedByMe: Boolean = false,
    var blockingMe: Boolean = false,
    var lastMessageIsMine: Boolean = false,
    var lastMessageIsRead: Boolean = false,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("login", peerLogin)
        put("account_id", lastKnownAccountId)
        put("device_id", lastKnownDeviceId)
        put("last_message", lastMessage)
        put("last_ts", lastTimestamp)
        put("is_deleted", isDeleted)
        put("unread", unreadCount)
        put("pinned_message_id", pinnedMessageId)
        put("chat_pinned_at", chatPinnedAt)
        put("muted", muted)
        put("blocked_by_me", blockedByMe)
        put("blocking_me", blockingMe)
        put("last_is_mine", lastMessageIsMine)
        put("last_is_read", lastMessageIsRead)
    }

    companion object {
        fun fromJson(j: JsonObject): ChatSummary {
            fun s(name: String) = j.optString(name)
            fun b(name: String) = j.optBool(name) ?: false
            return ChatSummary(
                peerLogin = j.string("login"),
                lastMessage = s("last_message") ?: "",
                lastTimestamp = j.optLong("last_ts") ?: 0,
                lastKnownAccountId = s("account_id"),
                lastKnownDeviceId = s("device_id"),
                isDeleted = b("is_deleted"),
                unreadCount = j.optInt("unread") ?: 0,
                pinnedMessageId = s("pinned_message_id"),
                chatPinnedAt = j.optLong("chat_pinned_at"),
                muted = b("muted"),
                blockedByMe = b("blocked_by_me"),
                blockingMe = b("blocking_me"),
                lastMessageIsMine = b("last_is_mine"),
                lastMessageIsRead = b("last_is_read"),
            )
        }

        /** Закреплённые сверху (новые закрепы выше), дальше — по времени последнего сообщения. */
        val listOrder: Comparator<ChatSummary> = Comparator { a, b ->
            val ap = a.chatPinnedAt
            val bp = b.chatPinnedAt
            when {
                ap != null && bp != null -> bp.compareTo(ap)
                ap != null -> -1
                bp != null -> 1
                else -> b.lastTimestamp.compareTo(a.lastTimestamp)
            }
        }
    }
}
