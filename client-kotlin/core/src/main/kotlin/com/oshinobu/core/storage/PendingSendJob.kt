package com.oshinobu.core.storage

import com.oshinobu.core.optBool
import com.oshinobu.core.optLong
import com.oshinobu.core.optObjects
import com.oshinobu.core.optString
import com.oshinobu.core.string
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Отправка, упавшая (или ещё не начатая) ДО готового конверта — файл надо
 * загрузить, либо для текста не было сессии/бандла. Формат JSON — тот же,
 * что пишет Flutter-клиент в `pending_send_queue` (chat_screen.dart,
 * pending_send_retrier.dart): задания переживают переход между сборками.
 */
sealed class PendingSendJob {
    abstract val id: String
    abstract val state: String
    abstract val peerLogin: String
    abstract val peerDeviceId: String

    /** Задания чата «Заметки» из Flutter-сборки — в Kotlin не выполняются. */
    abstract val legacyNotes: Boolean

    /** id сообщений в истории, чей статус зависит от этого задания. */
    abstract val messageIds: List<String>

    abstract fun withState(state: String): PendingSendJob

    abstract fun toJson(): JsonObject

    protected fun JsonObjectBuilder.common(kind: String) {
        put("id", id)
        put("kind", kind)
        put("state", state)
        put("notes", legacyNotes)
        put("peer_login", peerLogin)
        put("peer_device_id", peerDeviceId)
    }

    data class Text(
        override val id: String,
        override val state: String,
        override val peerLogin: String,
        override val peerDeviceId: String,
        val text: String,
        val sentAt: Long,
        val replyToId: String? = null,
        val replyToPreview: String? = null,
    ) : PendingSendJob() {
        override val legacyNotes get() = false
        override val messageIds get() = listOf(id)
        override fun withState(state: String) = copy(state = state)
        override fun toJson() = buildJsonObject {
            common("text")
            put("text", text)
            put("sent_at", sentAt)
            replyToId?.let { put("reply_to_id", it) }
            replyToPreview?.let { put("reply_to_preview", it) }
        }
    }

    /** Голосовое ([videoNote] = false) или видео-кружок. Файл — своя копия, удаляется после отправки. */
    data class Recorded(
        override val id: String,
        override val state: String,
        override val peerLogin: String,
        override val peerDeviceId: String,
        val peerAccountId: String,
        val videoNote: Boolean,
        val filePath: String,
        val size: Long,
        val durationMs: Long,
        override val legacyNotes: Boolean = false,
    ) : PendingSendJob() {
        override val messageIds get() = listOf(id)
        override fun withState(state: String) = copy(state = state)
        override fun toJson() = buildJsonObject {
            common(if (videoNote) "video_note" else "voice")
            put("peer_account_id", peerAccountId)
            put("file_path", filePath)
            put("size", size)
            put("duration_ms", durationMs)
        }
    }

    /** Один файл из пикера (фото/видео/документ). */
    data class FileItem(
        val messageId: String,
        val filePath: String,
        val size: Long,
        val fileName: String,
        val isFile: Boolean,
        val isVideo: Boolean,
        val isSpoiler: Boolean,
        /** Файл — наша копия (не оригинал пикера): удалить после отправки. */
        val persisted: Boolean = false,
    ) {
        fun toJson() = buildJsonObject {
            put("message_id", messageId)
            put("file_path", filePath)
            put("size", size)
            put("file_name", fileName)
            put("is_file", isFile)
            put("is_video", isVideo)
            put("is_spoiler", isSpoiler)
            if (persisted) put("persisted", true)
        }

        companion object {
            fun fromJson(j: JsonObject, messageId: String = j.string("message_id")) = FileItem(
                messageId = messageId,
                filePath = j.string("file_path"),
                size = j.optLong("size") ?: 0,
                fileName = j.optString("file_name") ?: "file",
                isFile = j.optBool("is_file") ?: false,
                isVideo = j.optBool("is_video") ?: false,
                isSpoiler = j.optBool("is_spoiler") ?: false,
                persisted = j.optBool("persisted") ?: false,
            )
        }
    }

    data class Media(
        override val id: String,
        override val state: String,
        override val peerLogin: String,
        override val peerDeviceId: String,
        val peerAccountId: String,
        val item: FileItem,
        val replyToId: String? = null,
        val replyToPreview: String? = null,
        override val legacyNotes: Boolean = false,
    ) : PendingSendJob() {
        override val messageIds get() = listOf(id)
        override fun withState(state: String) = copy(state = state)
        override fun toJson() = buildJsonObject {
            common("media")
            put("peer_account_id", peerAccountId)
            put("file_path", item.filePath)
            put("size", item.size)
            put("file_name", item.fileName)
            put("is_file", item.isFile)
            put("is_video", item.isVideo)
            put("is_spoiler", item.isSpoiler)
            if (item.persisted) put("persisted", true)
            replyToId?.let { put("reply_to_id", it) }
            replyToPreview?.let { put("reply_to_preview", it) }
        }
    }

    /** Несколько файлов (и подпись) одним действием — собеседнику одним конвертом. id = groupId. */
    data class MediaGroup(
        override val id: String,
        override val state: String,
        override val peerLogin: String,
        override val peerDeviceId: String,
        val peerAccountId: String,
        val caption: String?,
        val textMessageId: String?,
        val items: List<FileItem>,
        override val legacyNotes: Boolean = false,
    ) : PendingSendJob() {
        override val messageIds get() = items.map { it.messageId } + listOfNotNull(textMessageId)
        override fun withState(state: String) = copy(state = state)
        override fun toJson() = buildJsonObject {
            common("media_group")
            put("peer_account_id", peerAccountId)
            put("caption", caption)
            put("text_message_id", textMessageId)
            put("items", JsonArray(items.map { it.toJson() }))
        }
    }

    companion object {
        const val QUEUED = "queued"
        const val FAILED = "failed"

        /** null — неизвестный тип задания (из будущей версии) — пропускается. */
        fun fromJson(j: JsonObject): PendingSendJob? {
            val id = j.string("id")
            val state = j.optString("state") ?: QUEUED
            val peerLogin = j.optString("peer_login") ?: ""
            val peerDeviceId = j.optString("peer_device_id") ?: ""
            val peerAccountId = j.optString("peer_account_id") ?: ""
            val notes = j.optBool("notes") ?: false
            return when (j.optString("kind")) {
                "text" -> Text(
                    id, state, peerLogin, peerDeviceId, j.string("text"), j.optLong("sent_at") ?: 0,
                    j.optString("reply_to_id"), j.optString("reply_to_preview"),
                )
                "voice", "video_note" -> Recorded(
                    id, state, peerLogin, peerDeviceId, peerAccountId, j.optString("kind") == "video_note",
                    j.string("file_path"), j.optLong("size") ?: 0, j.optLong("duration_ms") ?: 0, notes,
                )
                "media" -> Media(
                    id, state, peerLogin, peerDeviceId, peerAccountId, FileItem.fromJson(j, messageId = id),
                    j.optString("reply_to_id"), j.optString("reply_to_preview"), notes,
                )
                "media_group" -> MediaGroup(
                    id, state, peerLogin, peerDeviceId, peerAccountId, j.optString("caption"), j.optString("text_message_id"),
                    j.optObjects("items").map { FileItem.fromJson(it) }, notes,
                )
                else -> null
            }
        }
    }
}
