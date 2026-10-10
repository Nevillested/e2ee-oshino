package com.oshinobu.core.service

import com.oshinobu.core.crypto.MediaCipher
import com.oshinobu.core.crypto.StreamingFileCipher
import com.oshinobu.core.crypto.b64
import com.oshinobu.core.crypto.unb64
import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.protocol.MediaRef
import com.oshinobu.core.storage.AppDirs
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.ChunkedUploadSessionStore
import com.oshinobu.core.storage.MediaFiles
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import java.io.File
import java.io.RandomAccessFile

/** Ключи локализации этапов загрузки, показываемых под пузырём (переводит UI). */
object UploadStep {
    const val QUEUED = "chat.queued"
    const val ENCRYPTING = "chat.encrypting"
    const val UPLOADING = "chat.uploading"
}

/**
 * Шифрует и грузит один файл на сервер (порт media_upload.dart).
 *
 * До 20 МБ — целиком: один AES-GCM, один multipart-запрос. Больше —
 * потоковое шифрование блоками в постоянный файл `chunked_uploads/enc_<id>.bin`
 * и загрузка частями по 8 МБ ПОСЛЕДОВАТЕЛЬНО, с докачкой: сессия
 * (media_id/upload_id/ключ) сохраняется, после перезапуска сервер говорит,
 * какие части уже есть, и грузятся только недостающие. Каждый сетевой шаг —
 * до 5 попыток с паузой 2 → 30 с.
 *
 * После загрузки исходник копируется в кэш расшифрованных файлов — свой же
 * файл не придётся скачивать обратно.
 */
class MediaUploader(
    private val api: ApiClient,
    private val chats: ChatStore,
    private val dirs: AppDirs,
    private val chunkedSessions: ChunkedUploadSessionStore,
    private val media: MediaFiles,
    private val log: Logger = NoopLogger,
    private val stepAttempts: Int = 5,
    private val firstRetryDelayMs: Long = 2_000,
) {
    fun encryptedTempFile(messageId: String) = File(File(dirs.support, "chunked_uploads").apply { mkdirs() }, "enc_$messageId.bin")

    suspend fun upload(
        peerLogin: String,
        messageId: String,
        source: File,
        size: Long,
        token: String,
        recipientAccountId: String,
        onProgress: (Double) -> Unit = {},
    ): MediaRef {
        chats.updateProcessingStep(peerLogin, messageId, UploadStep.ENCRYPTING)
        val ref = if (size > StreamingFileCipher.STREAMING_THRESHOLD_BYTES) {
            uploadChunked(peerLogin, messageId, source, size, token, recipientAccountId, onProgress)
        } else {
            uploadWhole(peerLogin, messageId, source, size, token, recipientAccountId, onProgress)
        }
        chats.updateMediaInfo(peerLogin, messageId, ref.mediaId, ref.keyBase64, ref.nonceBase64, ref.macBase64)
        return ref
    }

    private suspend fun uploadWhole(
        peerLogin: String, messageId: String, source: File, size: Long, token: String, recipient: String, onProgress: (Double) -> Unit,
    ): MediaRef {
        val plain = source.readBytes()
        val encrypted = MediaCipher.encrypt(plain)
        chats.updateProcessingStep(peerLogin, messageId, UploadStep.UPLOADING)
        val temp = File(dirs.temp, "enc_$messageId.bin").apply { writeBytes(encrypted.ciphertext) }
        val mediaId = try {
            api.uploadEncryptedMediaFile(token, temp, recipient, onProgress)
        } finally {
            temp.delete()
        }
        runCatching { media.cacheFile(mediaId).writeBytes(plain) }
        return MediaRef(mediaId, b64(encrypted.key), b64(encrypted.nonce), b64(encrypted.mac), size, chunked = false)
    }

    private class ChunkedSession(val mediaId: String, val uploadId: String, val partSize: Int, val key: ByteArray, val confirmed: Set<Int>)

    private suspend fun uploadChunked(
        peerLogin: String, messageId: String, source: File, size: Long, token: String, recipient: String, onProgress: (Double) -> Unit,
    ): MediaRef {
        val encFile = encryptedTempFile(messageId)
        val session = resumeSession(messageId, encFile, token) ?: startSession(messageId, source, encFile, token)
        chats.updateProcessingStep(peerLogin, messageId, UploadStep.UPLOADING)

        val total = encFile.length()
        val partSize = session.partSize.toLong()
        val partCount = ((total + partSize - 1) / partSize).toInt()
        fun partLen(pn: Int) = minOf(partSize, total - (pn - 1) * partSize).toInt()

        var confirmedBytes = session.confirmed.filter { it in 1..partCount }.sumOf { partLen(it).toLong() }
        onProgress(confirmedBytes * 100.0 / total)
        for (pn in 1..partCount) {
            if (pn in session.confirmed) continue
            val chunk = readPart(encFile, (pn - 1) * partSize, partLen(pn))
            retryStep("part $pn") { api.uploadChunkedPart(token, session.mediaId, session.uploadId, pn, chunk) }
            confirmedBytes += chunk.size
            onProgress(confirmedBytes * 100.0 / total)
        }
        retryStep("complete") { api.completeChunkedUpload(token, session.mediaId, session.uploadId, recipient) }

        chunkedSessions.clear(messageId)
        encFile.delete()
        runCatching { source.copyTo(media.cacheFile(session.mediaId), overwrite = true) }
        return MediaRef(session.mediaId, b64(session.key), null, null, size, chunked = true)
    }

    /** Продолжить прерванную загрузку: сессия сохранена и зашифрованный файл на месте. */
    private suspend fun resumeSession(messageId: String, encFile: File, token: String): ChunkedSession? {
        val saved = chunkedSessions.get(messageId) ?: return null
        if (!encFile.exists()) {
            chunkedSessions.clear(messageId)
            return null
        }
        return try {
            val confirmed = retryStep("list-parts") { api.listChunkedParts(token, saved.mediaId, saved.uploadId) }
            ChunkedSession(saved.mediaId, saved.uploadId, saved.partSize, unb64(saved.keyBase64), confirmed)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // сессия на сервере протухла — начинаем с нуля
            log.log("MediaUploader: resume of $messageId failed ($e) — starting over")
            chunkedSessions.clear(messageId)
            null
        }
    }

    private suspend fun startSession(messageId: String, source: File, encFile: File, token: String): ChunkedSession {
        val key = StreamingFileCipher.encryptFile(source, encFile)
        val init = retryStep("init") { api.initChunkedUpload(token, encFile.length()) }
        chunkedSessions.save(messageId, ChunkedUploadSessionStore.Entry(init.mediaId, init.uploadId, init.partSize, b64(key)))
        return ChunkedSession(init.mediaId, init.uploadId, init.partSize, key, emptySet())
    }

    private fun readPart(file: File, offset: Long, length: Int): ByteArray = RandomAccessFile(file, "r").use { raf ->
        raf.seek(offset)
        ByteArray(length).also { raf.readFully(it) }
    }

    /** Один сетевой шаг чанковой загрузки: до [stepAttempts] попыток с нарастающей паузой. */
    private suspend fun <T> retryStep(label: String, step: suspend () -> T): T {
        var delayMs = firstRetryDelayMs
        var attempt = 1
        while (true) {
            try {
                return step()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (attempt >= stepAttempts) {
                    log.error("MediaUploader[$label] failed after $attempt attempts: $e")
                    throw e
                }
                log.log("MediaUploader[$label] attempt $attempt/$stepAttempts failed: $e — retry in ${delayMs}ms")
                delay(delayMs)
                delayMs = (delayMs * 2).coerceAtMost(30_000)
                attempt++
            }
        }
    }
}
