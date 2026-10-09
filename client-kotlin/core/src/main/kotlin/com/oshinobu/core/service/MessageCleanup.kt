package com.oshinobu.core.service

import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.ChunkedUploadSessionStore
import com.oshinobu.core.storage.MediaFiles
import com.oshinobu.core.storage.PendingSendStore
import com.oshinobu.core.storage.SendQueueStore
import com.oshinobu.core.storage.StoredMessage
import java.io.File

/**
 * Удаление сообщения — это не только строка в истории (порт
 * message_cleanup.dart): расшифрованный файл в кэше, локальные превью и
 * исходник, незаконченная чанковая загрузка, задания в очередях отправки и
 * ожидание ack — иначе удалённое "воскреснет" отправкой на реконнекте.
 */
class MessageCleanup(
    private val chats: ChatStore,
    private val media: MediaFiles,
    private val dirs: AppDirs,
    private val chunkedSessions: ChunkedUploadSessionStore,
    private val pendingSends: PendingSendStore,
    private val sendQueue: SendQueueStore,
    private val acks: AckRegistry,
    /** Прервать идущую прямо сейчас загрузку этого сообщения (UploadCancelRegistry). */
    private val cancelUpload: (String) -> Unit = {},
) {
    suspend fun purge(msg: StoredMessage) {
        msg.mediaId?.let { media.cacheFile(it).delete() }
        msg.localPreviewPath?.let { runCatching { File(it).delete() } }
        msg.localSourcePath?.let { runCatching { File(it).delete() } }
        if (chunkedSessions.get(msg.messageId) != null) {
            chunkedSessions.clear(msg.messageId)
            runCatching { File(dirs.support, "chunked_uploads/enc_${msg.messageId}.bin").delete() }
        }
        for (key in setOfNotNull(msg.messageId, msg.groupId)) {
            pendingSends.remove(key)
            sendQueue.remove(key)
            acks.cancel(key)
        }
    }

    suspend fun purgeAll(messages: Iterable<StoredMessage>) = messages.forEach { purge(it) }

    /** "Отменить отправку": прервать загрузку, убрать пузыри и все следы. */
    suspend fun cancelOutgoing(peerLogin: String, messageIds: List<String>) {
        messageIds.forEach(cancelUpload)
        val toPurge = chats.getMessages(peerLogin).filter { it.messageId in messageIds }
        chats.deleteMessages(peerLogin, messageIds)
        purgeAll(toPurge)
    }
}
