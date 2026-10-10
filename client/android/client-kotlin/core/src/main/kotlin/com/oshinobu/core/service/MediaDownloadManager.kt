package com.oshinobu.core.service

import com.oshinobu.core.crypto.MediaCipher
import com.oshinobu.core.crypto.StreamingFileCipher
import com.oshinobu.core.crypto.unb64
import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.optBool
import com.oshinobu.core.optLong
import com.oshinobu.core.optString
import com.oshinobu.core.storage.DownloadQueueStore
import com.oshinobu.core.storage.MediaFiles
import com.oshinobu.core.storage.Session
import com.oshinobu.core.storage.StoredMessage
import com.oshinobu.core.string
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.io.IOException

/** Что скачать и как расшифровать (JSON-формат — тот же, что в очередях Flutter-клиента). */
data class DownloadSpec(
    val mediaId: String,
    val keyBase64: String,
    val chunked: Boolean,
    val nonceBase64: String?,
    val macBase64: String?,
    /** Размер ОТКРЫТОГО файла — по нему решается, годится ли файл в авто-очередь. */
    val plaintextSize: Long,
    val peerLogin: String,
    /** Подпись строки в панели передач (имя файла или тип). */
    val label: String,
) {
    fun toJson() = buildJsonObject {
        put("mediaId", mediaId); put("key", keyBase64); put("chunked", chunked); put("nonce", nonceBase64)
        put("mac", macBase64); put("size", plaintextSize); put("peer", peerLogin); put("label", label)
    }

    companion object {
        fun fromJson(j: JsonObject) = DownloadSpec(
            j.string("mediaId"), j.string("key"), j.optBool("chunked") ?: false, j.optString("nonce"), j.optString("mac"),
            j.optLong("size") ?: 0, j.optString("peer") ?: "", j.optString("label") ?: "",
        )

        /** Спецификация для медиа-сообщения истории (у которого уже есть media_id и ключ). */
        fun of(msg: StoredMessage, peerLogin: String, label: String): DownloadSpec? {
            val mediaId = msg.mediaId ?: return null
            val key = msg.mediaKeyBase64 ?: return null
            return DownloadSpec(mediaId, key, msg.chunked, msg.mediaNonceBase64, msg.mediaMacBase64, msg.fileSize, peerLogin, label)
        }
    }
}

data class DownloadRow(val mediaId: String, val peerLogin: String, val label: String, val percent: Double, val active: Boolean)

data class DownloadSnapshot(val manual: List<DownloadRow>, val auto: List<DownloadRow>)

class DownloadFailedException(message: String) : IOException(message)

/**
 * Скачивание и расшифровка вложений (порт media_download_manager.dart).
 *
 * Две очереди, каждая качает по одному файлу:
 *  - ручная — по тапу пользователя (и ожидание файла экраном [ensureDownloaded]);
 *  - авто — мелкие (< 3 МБ) файлы в видимой части чата, фоном.
 * Обе переживают перезапуск ([DownloadQueueStore]); недокачанный хвост лежит
 * на диске и докачивается по Range. После сбоя — 20 с без авто-повторов.
 * Расшифрованный файл — в кэше ([MediaFiles.cacheFile]); серверу сообщаем,
 * что получатель файл забрал ([ApiClient.confirmMediaReceived]).
 */
class MediaDownloadManager(
    private val api: ApiClient,
    private val session: Session,
    private val media: MediaFiles,
    private val queueStore: DownloadQueueStore,
    private val scope: CoroutineScope,
    private val log: Logger = NoopLogger,
    private val now: () -> Long = System::currentTimeMillis,
    private val networkRetries: Int = 3,
    private val firstRetryDelayMs: Long = 2_000,
) {
    companion object {
        const val AUTO_DOWNLOAD_LIMIT_BYTES = 3L * 1024 * 1024
        private const val FAIL_COOLDOWN_MS = 20_000L
    }

    private sealed interface Outcome {
        data object Completed : Outcome
        data object Cancelled : Outcome
        data object Forgotten : Outcome
        data class Failed(val error: Throwable) : Outcome
    }

    private inner class Lane {
        val queue = ArrayDeque<String>()
        var active: String? = null
        var activeJob: Job? = null
        var running = false
    }

    private val lock = Mutex()
    private val manual = Lane()
    private val auto = Lane()
    private val specs = HashMap<String, DownloadSpec>()
    private val userCancelled = HashSet<String>()
    private val forgotten = HashSet<String>()
    private val failedAt = HashMap<String, Long>()
    private val waiters = HashMap<String, MutableList<CompletableDeferred<File>>>()

    private val _progress = MutableStateFlow<Map<String, Double>>(emptyMap())
    private val _snapshot = MutableStateFlow(DownloadSnapshot(emptyList(), emptyList()))
    private val _downloadingManually = MutableStateFlow(false)
    private val _done = MutableSharedFlow<String>(extraBufferCapacity = 64)
    private val _failed = MutableSharedFlow<String>(extraBufferCapacity = 64)

    val progress: StateFlow<Map<String, Double>> = _progress.asStateFlow()
    val snapshot: StateFlow<DownloadSnapshot> = _snapshot.asStateFlow()

    /** Идёт ручное скачивание — повод держать уведомление "передача файлов" (FGS). */
    val downloadingManually: StateFlow<Boolean> = _downloadingManually.asStateFlow()

    /** Файл скачан и расшифрован. */
    val done: SharedFlow<String> = _done.asSharedFlow()
    val failed: SharedFlow<String> = _failed.asSharedFlow()

    /** Восстановить очереди после перезапуска и продолжить. */
    suspend fun init() {
        val (savedManual, savedAuto) = queueStore.load()
        lock.withLock {
            fun restore(list: List<JsonObject>, lane: Lane) = list.forEach {
                runCatching { DownloadSpec.fromJson(it) }.getOrNull()?.let { spec ->
                    specs[spec.mediaId] = spec
                    if (spec.mediaId !in lane.queue) lane.queue.addLast(spec.mediaId)
                }
            }
            restore(savedManual, manual)
            restore(savedAuto, auto)
            publishLocked()
        }
        kick(manual)
        kick(auto)
    }

    fun isQueuedOrActive(mediaId: String): Boolean = mediaId in manual.queue || mediaId in auto.queue

    /** Пользователь нажал "скачать". */
    suspend fun requestUserDownload(spec: DownloadSpec) {
        lock.withLock {
            specs[spec.mediaId] = spec
            userCancelled.remove(spec.mediaId)
            failedAt.remove(spec.mediaId)
            auto.queue.remove(spec.mediaId)
            if (spec.mediaId !in manual.queue) manual.queue.addLast(spec.mediaId)
            publishLocked()
        }
        persist()
        kick(manual)
    }

    /** Эти вложения сейчас видны на экране — мелкие уходят в авто-очередь. */
    suspend fun setVisible(visible: Iterable<DownloadSpec>) {
        var added = false
        lock.withLock {
            for (s in visible) {
                specs[s.mediaId] = s
                if (s.plaintextSize >= AUTO_DOWNLOAD_LIMIT_BYTES) continue
                if (s.mediaId in userCancelled || inCooldown(s.mediaId)) continue
                if (s.mediaId in manual.queue || s.mediaId in auto.queue) continue
                if (media.cacheFile(s.mediaId).exists()) continue
                auto.queue.addLast(s.mediaId)
                added = true
            }
            if (added) publishLocked()
        }
        if (added) {
            persist()
            kick(auto)
        }
    }

    /** Пользователь отменил скачивание: прервать, снести хвост, не качать автоматически. */
    suspend fun cancelUserDownload(mediaId: String) = stop(mediaId) { userCancelled += it }

    /** Сообщение удалено — забыть всё о его файле. */
    suspend fun forget(mediaId: String) = stop(mediaId) { forgotten += it; userCancelled -= it }

    private suspend fun stop(mediaId: String, mark: (String) -> Unit) {
        val idle = lock.withLock {
            mark(mediaId)
            _progress.update { it - mediaId }
            manual.queue.remove(mediaId)
            auto.queue.remove(mediaId)
            val lane = listOf(manual, auto).firstOrNull { it.active == mediaId }
            lane?.activeJob?.cancel()
            publishLocked()
            lane == null
        }
        if (idle) {
            // не качалось прямо сейчас — убираем хвост и будим ожидающих здесь же
            media.partialFile(mediaId).delete()
            lock.withLock {
                forgotten -= mediaId
                failWaitersLocked(mediaId, DownloadFailedException("cancelled"))
            }
        }
        persist()
    }

    /**
     * Файл, готовый к показу: из кэша или дождавшись скачивания.
     * [userInitiated] = false — фоновый запрос (превью): не обходит кулдаун и отмену пользователя.
     */
    suspend fun ensureDownloaded(spec: DownloadSpec, userInitiated: Boolean = true): File {
        val cached = media.cacheFile(spec.mediaId)
        if (cached.exists()) return cached
        val waiter = CompletableDeferred<File>()
        val lane = lock.withLock {
            val id = spec.mediaId
            if (!userInitiated && id !in manual.queue && manual.active != id && auto.active != id &&
                (inCooldown(id) || id in userCancelled)
            ) {
                throw DownloadFailedException("download on cooldown")
            }
            specs[id] = spec
            userCancelled.remove(id)
            waiters.getOrPut(id) { mutableListOf() } += waiter
            val target = if (userInitiated) {
                failedAt.remove(id)
                auto.queue.remove(id)
                if (id !in manual.queue) manual.queue.addLast(id)
                manual
            } else {
                if (id !in manual.queue && id !in auto.queue) auto.queue.addLast(id)
                auto
            }
            publishLocked()
            target
        }
        persist()
        kick(lane)
        return waiter.await()
    }

    // ---------------- рабочие циклы ----------------

    private fun kick(lane: Lane) {
        scope.launch {
            lock.withLock {
                if (lane.running) return@launch
                lane.running = true
            }
            try {
                while (true) {
                    val spec = lock.withLock {
                        while (lane.queue.isNotEmpty() && specs[lane.queue.first()] == null) lane.queue.removeFirst()
                        val id = lane.queue.firstOrNull() ?: return@withLock null
                        lane.active = id
                        publishLocked()
                        specs.getValue(id)
                    } ?: break
                    // отдельная задача: её отмена (cancel/forget) не трогает сам цикл
                    val result = supervisorScope {
                        val work = async { download(spec) }
                        lock.withLock { lane.activeJob = work }
                        runCatching { work.await() }
                    }
                    currentCoroutineContext().ensureActive() // отменили весь менеджер — не "ошибка скачивания"
                    val outcome = lock.withLock {
                        when {
                            spec.mediaId in forgotten -> Outcome.Forgotten
                            result.isSuccess -> Outcome.Completed
                            spec.mediaId in userCancelled -> Outcome.Cancelled
                            else -> Outcome.Failed(result.exceptionOrNull()!!)
                        }
                    }
                    finish(lane, spec.mediaId, outcome)
                }
            } finally {
                lock.withLock {
                    lane.running = false
                    lane.active = null
                    lane.activeJob = null
                    publishLocked()
                }
            }
        }
    }

    private suspend fun finish(lane: Lane, mediaId: String, outcome: Outcome) {
        if (outcome == Outcome.Forgotten || outcome == Outcome.Cancelled) media.partialFile(mediaId).delete()
        lock.withLock {
            lane.queue.remove(mediaId)
            lane.active = null
            lane.activeJob = null
            when (outcome) {
                Outcome.Completed -> {
                    failedAt.remove(mediaId)
                    _progress.update { it + (mediaId to 100.0) }
                    resolveWaitersLocked(mediaId, media.cacheFile(mediaId))
                    _done.tryEmit(mediaId)
                }
                Outcome.Cancelled -> {
                    _progress.update { it - mediaId }
                    failWaitersLocked(mediaId, DownloadFailedException("cancelled"))
                }
                Outcome.Forgotten -> {
                    forgotten.remove(mediaId)
                    specs.remove(mediaId)
                    _progress.update { it - mediaId }
                    failWaitersLocked(mediaId, DownloadFailedException("message deleted"))
                }
                is Outcome.Failed -> {
                    log.error("MediaDownloadManager id=$mediaId failed: ${outcome.error}")
                    failedAt[mediaId] = now()
                    _progress.update { it - mediaId }
                    failWaitersLocked(mediaId, DownloadFailedException("download failed"))
                    _failed.tryEmit(mediaId)
                }
            }
            publishLocked()
        }
        persist()
    }

    private suspend fun download(spec: DownloadSpec) {
        val id = spec.mediaId
        val cache = media.cacheFile(id)
        if (cache.exists()) return
        val token = session.token ?: throw DownloadFailedException("not logged in")
        val partial = media.partialFile(id)

        var encTotal = 0L
        var delayMs = firstRetryDelayMs
        for (attempt in 1..networkRetries) {
            try {
                encTotal = api.downloadEncryptedMediaResumable(token, id, partial) { pct -> _progress.update { it + (id to pct) } }
                break
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (attempt == networkRetries) throw e
                delay(delayMs)
                delayMs = (delayMs * 2).coerceAtMost(20_000)
            }
        }
        val have = if (partial.exists()) partial.length() else 0
        if (encTotal > 0 && have < encTotal) throw DownloadFailedException("incomplete ($have/$encTotal)")

        try {
            if (spec.chunked) {
                StreamingFileCipher.decryptFile(partial, cache, unb64(spec.keyBase64))
            } else {
                val plain = MediaCipher.decrypt(unb64(spec.keyBase64), unb64(spec.nonceBase64!!), unb64(spec.macBase64!!), partial.readBytes())
                cache.writeBytes(plain)
            }
        } catch (e: Exception) {
            cache.delete()
            // хвост полный, а расшифровка не прошла — байты битые, в следующий раз качаем заново
            if (encTotal > 0 && have >= encTotal) partial.delete()
            throw e
        }
        partial.delete()
        // файл у получателя — сервер может убрать его из буфера в архив
        scope.launch { api.confirmMediaReceived(token, id) }
    }

    // ---------------- состояние ----------------

    private fun inCooldown(mediaId: String) = failedAt[mediaId]?.let { now() - it < FAIL_COOLDOWN_MS } ?: false

    private fun resolveWaitersLocked(mediaId: String, file: File) = waiters.remove(mediaId)?.forEach { it.complete(file) }

    private fun failWaitersLocked(mediaId: String, error: Throwable) = waiters.remove(mediaId)?.forEach { it.completeExceptionally(error) }

    private fun publishLocked() {
        val progress = _progress.value
        fun rows(lane: Lane) = lane.queue.mapNotNull { id ->
            specs[id]?.let { DownloadRow(id, it.peerLogin, it.label, progress[id] ?: 0.0, id == lane.active) }
        }
        _snapshot.value = DownloadSnapshot(rows(manual), rows(auto))
        _downloadingManually.value = manual.queue.isNotEmpty()
    }

    private suspend fun persist() {
        val (m, a) = lock.withLock {
            manual.queue.mapNotNull { specs[it]?.toJson() } to auto.queue.mapNotNull { specs[it]?.toJson() }
        }
        queueStore.save(m, a)
    }
}
