package com.oshinobu.core.service

import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.protocol.MediaRef
import com.oshinobu.core.protocol.MessageType
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.ChunkedUploadSessionStore
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.PeerAccountStore
import com.oshinobu.core.storage.PendingSendJob
import com.oshinobu.core.storage.PendingSendStore
import com.oshinobu.core.storage.Session
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** Строка панели передач: файл в очереди или в загрузке. */
data class UploadRow(
    /** id задания (для отмены/повтора). */
    val jobId: String,
    /** Ключ строки: id сообщения файла (у группы — по строке на файл). */
    val rowKey: String,
    val peerLogin: String,
    /** Имя файла; null — голосовое/видео-кружок (подпись выбирает UI по [kind]). */
    val fileName: String?,
    val kind: String,
    val percent: Double,
    val active: Boolean,
)

enum class RetryOutcome { QUEUED, NOT_FOUND }

/**
 * Очередь отправок, которым нужна загрузка файла или сессия до готового
 * конверта (порт pending_send_retrier.dart). Один рабочий цикл — файлы
 * идут по одному. Задание лежит на диске до успеха; сетевой сбой — задание
 * 'failed' (в чате «!», повтор по кнопке); пропал исходник без возможности
 * докачки — сообщение 'failed' навсегда.
 */
class PendingSendRetrier(
    private val store: PendingSendStore,
    private val chats: ChatStore,
    private val session: Session,
    private val peerAccounts: PeerAccountStore,
    private val chunkedSessions: ChunkedUploadSessionStore,
    private val uploader: MediaUploader,
    private val messenger: PeerMessenger,
    private val cleanup: MessageCleanup,
    private val cancellations: UploadCancellations,
    private val scope: CoroutineScope,
    private val log: Logger = NoopLogger,
) {
    private class PermanentFailure(message: String) : Exception(message)

    private val workerLock = Mutex()
    private var workerRunning = false

    private val _activeJobId = MutableStateFlow<String?>(null)
    private val _progress = MutableStateFlow<Map<String, Double>>(emptyMap())
    private val _jobsChanged = MutableStateFlow(0)

    /** Задание, которое грузится прямо сейчас (для FGS-уведомления "идёт выгрузка"). */
    val activeJobId: StateFlow<String?> = _activeJobId.asStateFlow()

    /** Прогресс по id сообщения/задания, %. */
    val progress: StateFlow<Map<String, Double>> = _progress.asStateFlow()

    /** Счётчик изменений состава очереди — повод перечитать [rows]. */
    val jobsChanged: StateFlow<Int> = _jobsChanged.asStateFlow()

    private fun changed() = _jobsChanged.update { it + 1 }

    private fun reportProgress(id: String, percent: Double) = _progress.update { it + (id to percent) }

    private val started = AtomicBoolean(false)

    fun start() {
        if (!started.compareAndSet(false, true)) return
        scope.launch {
            // медиа в 'sending' без живого задания (процесс убили посреди отправки) → 'failed'
            runCatching { chats.failOrphanedSendingMedia(store.jobs().map { it.id }.toSet()) }
            kick()
        }
    }

    suspend fun enqueue(job: PendingSendJob) {
        store.put(job)
        changed()
        kick()
    }

    /** Повтор по кнопке «Повторить отправку». */
    suspend fun retryNow(id: String): RetryOutcome {
        val job = store.job(id) ?: return RetryOutcome.NOT_FOUND
        store.put(job.withState(PendingSendJob.QUEUED))
        job.messageIds.forEach { chats.markRetrying(job.peerLogin, it, UploadStep.QUEUED) }
        changed()
        kick()
        return RetryOutcome.QUEUED
    }

    /** «Отменить отправку» всего задания: прервать загрузку и убрать пузыри. */
    suspend fun cancelJob(id: String) {
        val job = store.job(id) ?: return
        job.messageIds.forEach { cancellations.cancel(it) }
        cleanup.cancelOutgoing(job.peerLogin, job.messageIds)
        store.remove(id)
        changed()
    }

    /** Отменить один файл из группы — остальные грузятся дальше; отменили все — не уходит ничего, даже подпись. */
    suspend fun cancelGroupItem(jobId: String, messageId: String) {
        val job = store.job(jobId)
        if (job !is PendingSendJob.MediaGroup) return cancelJob(jobId)
        cancellations.cancel(messageId)
        cleanup.cancelOutgoing(job.peerLogin, listOf(messageId))
        val remaining = job.items.filter { it.messageId != messageId }
        if (remaining.isEmpty()) {
            job.textMessageId?.let { cleanup.cancelOutgoing(job.peerLogin, listOf(it)) }
            store.remove(jobId)
        } else {
            store.put(job.copy(items = remaining))
        }
        changed()
        kick()
    }

    /** Строки панели передач (без упавших — у них «!» в чате). Активное задание — сверху. */
    suspend fun rows(): List<UploadRow> {
        val active = _activeJobId.value
        val progress = _progress.value
        return store.jobs().filter { it.state != PendingSendJob.FAILED && !it.legacyNotes }.flatMap { job ->
            val isActive = job.id == active
            when (job) {
                is PendingSendJob.MediaGroup -> job.items.map {
                    UploadRow(job.id, it.messageId, job.peerLogin, it.fileName, MessageType.MEDIA, progress[it.messageId] ?: 0.0, isActive)
                }
                is PendingSendJob.Media -> listOf(
                    UploadRow(job.id, job.id, job.peerLogin, job.item.fileName, MessageType.MEDIA, progress[job.id] ?: 0.0, isActive),
                )
                is PendingSendJob.Recorded -> listOf(
                    UploadRow(
                        job.id, job.id, job.peerLogin, null,
                        if (job.videoNote) MessageType.VIDEO_NOTE else MessageType.VOICE, progress[job.id] ?: 0.0, isActive,
                    ),
                )
                is PendingSendJob.Text -> emptyList()
            }
        }.sortedByDescending { it.active }
    }

    // ---------------- рабочий цикл ----------------

    private fun kick() {
        scope.launch {
            workerLock.withLock {
                if (workerRunning) return@launch
                workerRunning = true
            }
            try {
                while (true) {
                    val next = store.jobs().firstOrNull { it.state != PendingSendJob.FAILED } ?: break
                    _activeJobId.value = next.id
                    changed()
                    attempt(next)
                }
            } finally {
                _activeJobId.value = null
                workerLock.withLock { workerRunning = false }
                changed()
            }
        }
    }

    private suspend fun attempt(job: PendingSendJob) {
        if (job.legacyNotes) {
            // чата «Заметки» в Kotlin нет — задание Flutter-сборки снимаем, данные не трогаем
            log.log("PendingSendRetrier: dropping legacy Notes job ${job.id}")
            store.remove(job.id)
            return
        }
        job.messageIds.forEach { chats.markRetrying(job.peerLogin, it, UploadStep.QUEUED) }
        try {
            when (job) {
                is PendingSendJob.Text -> sendText(job)
                is PendingSendJob.Recorded -> sendRecorded(job)
                is PendingSendJob.Media -> sendMedia(job)
                is PendingSendJob.MediaGroup -> sendGroup(job)
            }
            store.remove(job.id)
        } catch (e: CancellationException) {
            throw e
        } catch (e: UploadCancelledException) {
            store.remove(job.id) // отменено пользователем — следы уже убраны в cancelJob
        } catch (e: PermanentFailure) {
            job.messageIds.forEach { chats.updateMessageStatus(job.peerLogin, it, MessageStatus.FAILED) }
            store.remove(job.id)
            log.error("PendingSendRetrier id=${job.id} permanently abandoned: ${e.message}")
        } catch (e: Exception) {
            job.messageIds.forEach { chats.updateMessageStatus(job.peerLogin, it, MessageStatus.FAILED) }
            store.put(job.withState(PendingSendJob.FAILED))
            log.error("PendingSendRetrier id=${job.id} send-FAILED error=$e — marked failed")
        }
    }

    private suspend fun target(job: PendingSendJob, accountId: String): Pair<String, String> {
        val deviceId = messenger.resolvePeerDeviceId(job.peerLogin, job.peerDeviceId)
        return deviceId to (peerAccounts.get(deviceId) ?: accountId)
    }

    private suspend fun sendText(job: PendingSendJob.Text) {
        val deviceId = messenger.resolvePeerDeviceId(job.peerLogin, job.peerDeviceId)
        val inner = InnerMessage(job.id, MessageType.TEXT, job.sentAt, job.text, replyToMessageId = job.replyToId, replyToPreview = job.replyToPreview)
        messenger.send(deviceId, inner, peerLogin = job.peerLogin)
    }

    /** Исходник на месте, или пропал, но есть начатая чанковая загрузка (её зашифрованная копия). */
    private suspend fun requireSource(messageId: String, path: String): File {
        val file = File(path)
        if (!file.exists() && chunkedSessions.get(messageId) == null) throw PermanentFailure("local file missing: $path")
        return file
    }

    private suspend fun upload(job: PendingSendJob, messageId: String, source: File, size: Long, recipient: String, onProgress: (Double) -> Unit): MediaRef {
        val token = session.token ?: error("not logged in")
        return cancellations.run(messageId) { uploader.upload(job.peerLogin, messageId, source, size, token, recipient, onProgress) }
    }

    private suspend fun sendRecorded(job: PendingSendJob.Recorded) {
        val source = requireSource(job.id, job.filePath)
        val (deviceId, accountId) = target(job, job.peerAccountId)
        val ref = upload(job, job.id, source, job.size, accountId) { reportProgress(job.id, it) }
        val inner = if (job.videoNote) InnerMessage.videoNote(ref, job.durationMs, messageId = job.id) else InnerMessage.voice(ref, job.durationMs, messageId = job.id)
        messenger.send(deviceId, inner, peerLogin = job.peerLogin)
        File(job.filePath).delete() // своя копия записи
    }

    private suspend fun sendMedia(job: PendingSendJob.Media) {
        val item = job.item
        val source = requireSource(job.id, item.filePath)
        val (deviceId, accountId) = target(job, job.peerAccountId)
        val ref = upload(job, job.id, source, item.size, accountId) { reportProgress(job.id, it) }
        val inner = InnerMessage.media(
            ref, item.fileName, isFile = item.isFile, isVideo = item.isVideo, spoiler = item.isSpoiler,
            messageId = job.id, replyToMessageId = job.replyToId, replyToPreview = job.replyToPreview,
        )
        messenger.send(deviceId, inner, peerLogin = job.peerLogin)
        if (item.persisted) File(item.filePath).delete()
    }

    private suspend fun sendGroup(job: PendingSendJob.MediaGroup) {
        val (deviceId, accountId) = target(job, job.peerAccountId)
        val uploaded = mutableListOf<Pair<PendingSendJob.FileItem, MediaRef>>()
        job.items.forEachIndexed { index, item ->
            if (!stillInGroup(job.id, item.messageId)) return@forEachIndexed
            val source = requireSource(item.messageId, item.filePath)
            try {
                val ref = upload(job, item.messageId, source, item.size, accountId) { pct ->
                    reportProgress(item.messageId, pct)
                    reportProgress(job.id, (index + pct / 100) / job.items.size * 100)
                }
                uploaded += item to ref
            } catch (e: UploadCancelledException) {
                log.log("PendingSendRetrier group ${job.id}: item ${item.messageId} cancelled mid-upload")
            }
        }
        if (uploaded.isEmpty()) {
            job.textMessageId?.let { cleanup.cancelOutgoing(job.peerLogin, listOf(it)) }
            return
        }
        val files: List<JsonObject> = uploaded.map { (item, ref) -> groupFileJson(item, ref) }
        // текст подписи и файлы группы помечаются 'sent' по ack ОДНОГО конверта группы
        val statusIds = uploaded.map { it.first.messageId } + listOfNotNull(job.textMessageId)
        messenger.send(
            deviceId,
            InnerMessage.mediaGroup(job.id, files, job.caption, job.textMessageId, messageId = job.id),
            peerLogin = job.peerLogin,
            trackStatus = false,
            onAcked = { statusIds.forEach { chats.updateMessageStatus(job.peerLogin, it, MessageStatus.SENT) } },
        )
        uploaded.filter { it.first.persisted }.forEach { File(it.first.filePath).delete() }
    }

    private suspend fun stillInGroup(jobId: String, messageId: String): Boolean =
        (store.job(jobId) as? PendingSendJob.MediaGroup)?.items?.any { it.messageId == messageId } == true

    /** Элемент 'files' конверта media_group — тот же набор полей, что body у 'media' + message_id. */
    private fun groupFileJson(item: PendingSendJob.FileItem, ref: MediaRef) = buildJsonObject {
        put("message_id", item.messageId)
        put("media_id", ref.mediaId)
        put("key", ref.keyBase64)
        put("nonce", ref.nonceBase64)
        put("mac", ref.macBase64)
        put("file_name", item.fileName)
        put("is_file", item.isFile)
        put("is_video", item.isVideo)
        put("file_size", ref.fileSize)
        put("chunked", ref.chunked)
        put("spoiler", item.isSpoiler)
    }
}
