package com.oshinobu.core.service

import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.PendingSendJob
import com.oshinobu.core.storage.PendingSendStore
import com.oshinobu.core.storage.StoredMessage
import com.oshinobu.core.crypto.StreamingFileCipher
import kotlinx.coroutines.CancellationException
import java.io.File
import java.util.Collections
import java.util.UUID

/** Собеседник открытого чата. [deviceId] обновляется, если он переустановил приложение. */
data class ChatPeer(val login: String, val accountId: String, val deviceId: String)

/**
 * Файл, выбранный для отправки (фото/видео из галереи или документ).
 * [name] — имя, которое увидит собеседник (сам файл может лежать под служебным).
 */
data class OutgoingFile(val file: File, val isFile: Boolean, val isVideo: Boolean, val isSpoiler: Boolean = false, val name: String = file.name)

/** Кадр-превью для видео: путь к картинке или null (на Android — MediaMetadataRetriever). */
fun interface VideoThumbnailer {
    fun thumbnail(video: File): File?
}

/**
 * Действия с сообщениями внутри чата (порт логики ChatScreen Flutter-клиента):
 * отправка текста, правка, реакции, закреп, удаление у себя/у обоих,
 * квитанции о прочтении, отмена и повтор отправки, ручной сброс сессии.
 */
/** Максимальный размер вложения (так же ограничивает сервер). */
const val MAX_ATTACHMENT_BYTES = 500L * 1024 * 1024

class ChatService(
    private val chats: ChatStore,
    private val messenger: PeerMessenger,
    private val router: MessageRouter,
    private val cleanup: MessageCleanup,
    private val pendingStore: PendingSendStore,
    private val retrier: PendingSendRetrier,
    private val log: Logger = NoopLogger,
) {
    /** Квитанции, ждущие ack: пока они в очереди, повторно их не шлём (у квитанции нет стабильного id). */
    private val receiptsInFlight: MutableSet<String> = Collections.synchronizedSet(HashSet())

    /** Новый текст: пузырь сразу ('sending'), отправка — следом. */
    suspend fun sendText(peer: ChatPeer, text: String, replyTo: StoredMessage? = null) {
        val inner = InnerMessage.text(text, replyTo?.messageId, replyTo?.text)
        chats.addMessage(
            peer.login,
            StoredMessage(
                inner.messageId, text, true, inner.sentAt, status = MessageStatus.SENDING,
                replyToMessageId = inner.replyToMessageId, replyToPreview = inner.replyToPreview,
            ),
            accountId = peer.accountId,
        )
        sendTextNetwork(peer, inner)
    }

    /** Пересылка: несколько текстов разом — все пузыри появляются одним движением. */
    suspend fun sendTexts(peer: ChatPeer, texts: List<String>) {
        val inners = texts.map { InnerMessage.text(it) }
        inners.forEach {
            chats.addMessage(peer.login, StoredMessage(it.messageId, it.body, true, it.sentAt, status = MessageStatus.SENDING), accountId = peer.accountId)
        }
        inners.forEach { sendTextNetwork(peer, it) }
    }

    /**
     * Сбой ДО готового конверта (нет сети для бандла и т.п.) — сообщение
     * 'failed' и задание в очередь отправок: «Повторить отправку» в меню.
     */
    private suspend fun sendTextNetwork(peer: ChatPeer, inner: InnerMessage) {
        try {
            messenger.send(peer.deviceId, inner, peerLogin = peer.login)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("ChatService send FAILED (text ${inner.messageId}) to=${peer.deviceId}: $e")
            chats.updateMessageStatus(peer.login, inner.messageId, MessageStatus.FAILED)
            pendingStore.put(
                PendingSendJob.Text(
                    inner.messageId, PendingSendJob.FAILED, peer.login, peer.deviceId, inner.body, inner.sentAt,
                    inner.replyToMessageId, inner.replyToPreview,
                ),
            )
        }
    }

    suspend fun editText(peer: ChatPeer, messageId: String, newText: String) {
        chats.editMessageText(peer.login, messageId, newText)
        messenger.sendControl(peer.deviceId, InnerMessage.edit(messageId, newText))
    }

    /** emoji = null — снять свою реакцию. */
    suspend fun react(peer: ChatPeer, messageId: String, emoji: String?) {
        chats.setReaction(peer.login, messageId, isMine = true, emoji = emoji)
        messenger.sendControl(peer.deviceId, InnerMessage.reaction(messageId, emoji))
    }

    suspend fun setPinned(peer: ChatPeer, messageId: String, pinned: Boolean) {
        chats.setPinned(peer.login, if (pinned) messageId else null)
        messenger.sendControl(peer.deviceId, InnerMessage.pin(messageId, pinned))
    }

    /**
     * Удаление [ids]; [forPeer] — и у собеседника. Если среди них закреплённое —
     * открепляем у себя всегда, у собеседника — если удаляем и у него.
     */
    suspend fun deleteMessages(peer: ChatPeer, ids: List<String>, forPeer: Boolean, pinnedId: String?) {
        if (ids.isEmpty()) return
        val deletingPinned = pinnedId != null && pinnedId in ids
        if (forPeer) {
            messenger.sendControl(peer.deviceId, InnerMessage.delete(ids))
            if (deletingPinned) messenger.sendControl(peer.deviceId, InnerMessage.pin(pinnedId!!, false))
        }
        if (deletingPinned) chats.setPinned(peer.login, null)
        val toPurge = chats.getMessages(peer.login).filter { it.messageId in ids }
        chats.deleteMessages(peer.login, ids)
        cleanup.purgeAll(toPurge)
    }

    /** Отметить прочитанными все чужие сообщения на экране; флаг — только по ack. */
    suspend fun sendReadReceipts(peer: ChatPeer, messages: List<StoredMessage>) {
        val ids = messages.filter { !it.isMine && !it.readReceiptSent && it.messageId !in receiptsInFlight }.map { it.messageId }
        if (ids.isEmpty() || peer.deviceId.isEmpty()) return
        receiptsInFlight += ids
        try {
            messenger.send(
                peer.deviceId,
                InnerMessage.readReceipt(ids),
                silent = true,
                onAcked = {
                    chats.markReadReceiptsSent(peer.login, ids)
                    receiptsInFlight -= ids.toSet()
                },
            )
        } catch (e: CancellationException) {
            receiptsInFlight -= ids.toSet()
            throw e
        } catch (e: Exception) {
            // не встала в очередь — следующий повод (новое сообщение, открытие чата) попробует снова
            receiptsInFlight -= ids.toSet()
            log.log("ChatService read receipts not queued: $e")
        }
    }

    /** «Отменить отправку»: прервать загрузку, убрать пузыри и задания. */
    suspend fun cancelSend(peer: ChatPeer, messageIds: List<String>) = cleanup.cancelOutgoing(peer.login, messageIds)

    /** «Повторить отправку» упавшего сообщения (или группы — по её id). */
    suspend fun retrySend(jobId: String): RetryOutcome = retrier.retryNow(jobId)

    /**
     * Отправка выбранных файлов. С подписью или больше одного файла — альбом
     * (подпись — отдельное текстовое сообщение той же группы, собеседнику всё
     * уходит одним конвертом). Пузыри появляются сразу, загрузка — в очереди
     * файлов. Возвращает файлы, отклонённые по размеру (> 500 МБ).
     */
    suspend fun sendMedia(peer: ChatPeer, files: List<OutgoingFile>, caption: String, thumbnailer: VideoThumbnailer): List<OutgoingFile> {
        val (accepted, rejected) = files.partition { it.file.length() <= MAX_ATTACHMENT_BYTES }
        if (accepted.isEmpty()) return rejected
        val hasCaption = caption.isNotBlank()
        val groupId = if (accepted.size + (if (hasCaption) 1 else 0) > 1) "grp_${UUID.randomUUID()}" else null
        var textMessageId: String? = null
        if (hasCaption) {
            val inner = InnerMessage.text(caption)
            textMessageId = inner.messageId
            chats.addMessage(
                peer.login,
                StoredMessage(inner.messageId, caption, true, inner.sentAt, status = MessageStatus.SENDING, groupId = groupId),
                accountId = peer.accountId,
            )
        }
        val items = accepted.map { f ->
            val messageId = UUID.randomUUID().toString()
            val size = f.file.length()
            chats.addMessage(
                peer.login,
                StoredMessage(
                    messageId, "", true, System.currentTimeMillis(),
                    isMedia = true, isFile = f.isFile, isVideo = f.isVideo, fileSize = size,
                    chunked = size > StreamingFileCipher.STREAMING_THRESHOLD_BYTES, fileName = f.name, isSpoiler = f.isSpoiler,
                    status = MessageStatus.SENDING, processingStep = UploadStep.QUEUED,
                    localPreviewPath = when {
                        f.isFile -> null
                        f.isVideo -> thumbnailer.thumbnail(f.file)?.path
                        else -> f.file.path
                    },
                    localSourcePath = if (f.isFile || f.isVideo) f.file.path else null,
                    groupId = groupId,
                ),
                accountId = peer.accountId,
            )
            PendingSendJob.FileItem(messageId, f.file.path, size, f.name, f.isFile, f.isVideo, f.isSpoiler)
        }
        if (groupId != null) {
            retrier.enqueue(PendingSendJob.MediaGroup(groupId, PendingSendJob.QUEUED, peer.login, peer.deviceId, peer.accountId, caption.takeIf { hasCaption }, textMessageId, items))
        } else {
            val item = items.single()
            retrier.enqueue(PendingSendJob.Media(item.messageId, PendingSendJob.QUEUED, peer.login, peer.deviceId, peer.accountId, item))
        }
        return rejected
    }

    /**
     * Голосовое или видео-кружок: запись переносится в постоянную папку
     * (временную система может стереть до отправки), пузырь — сразу.
     */
    suspend fun sendRecorded(peer: ChatPeer, recording: File, durationMs: Long, videoNote: Boolean, thumbnailer: VideoThumbnailer) {
        val messageId = UUID.randomUUID().toString()
        val size = recording.length()
        val preview = if (videoNote) thumbnailer.thumbnail(recording)?.path else null
        val persisted = pendingStore.persistFile(recording, messageId)
        recording.delete()
        chats.addMessage(
            peer.login,
            StoredMessage(
                messageId, "", true, System.currentTimeMillis(),
                isMedia = true, isVoice = !videoNote, isVideoNote = videoNote, fileSize = size,
                chunked = size > StreamingFileCipher.STREAMING_THRESHOLD_BYTES, durationMs = durationMs,
                status = MessageStatus.SENDING, processingStep = UploadStep.QUEUED,
                localPreviewPath = preview, localSourcePath = persisted.path,
            ),
            accountId = peer.accountId,
        )
        retrier.enqueue(
            PendingSendJob.Recorded(messageId, PendingSendJob.QUEUED, peer.login, peer.deviceId, peer.accountId, videoNote, persisted.path, size, durationMs),
        )
    }

    /** «Сбросить шифрование» из меню чата. */
    suspend fun resetSession(peer: ChatPeer) = router.resetSessionWith(peer.deviceId, "manual (chat menu)")
}
