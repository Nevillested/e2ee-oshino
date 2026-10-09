package com.oshinobu.app.ui.chat

import com.oshinobu.core.OshinobuCore
import com.oshinobu.core.service.DownloadFailedException
import com.oshinobu.core.service.DownloadSpec
import com.oshinobu.core.storage.StoredMessage
import java.io.File

/** Файл вложения переписки с [peerLogin]: уже на устройстве или через очередь скачивания. */
class MediaResolver(private val core: OshinobuCore, private val peerLogin: String, private val labels: MediaLabels) {
    /**
     * Расшифрованный кэш или — для своих — исходник, который отправляли
     * (у фото это сам файл превью).
     */
    fun localFile(msg: StoredMessage): File? {
        msg.mediaId?.let { id -> core.media.cacheFile(id).takeIf { it.exists() }?.let { return it } }
        if (!msg.isMine) return null
        if (!msg.isVideo && !msg.isVideoNote && !msg.isFile) {
            msg.localPreviewPath?.let(::File)?.takeIf { it.exists() }?.let { return it }
        }
        return msg.localSourcePath?.let(::File)?.takeIf { it.exists() }
    }

    fun spec(msg: StoredMessage): DownloadSpec? = DownloadSpec.of(msg, peerLogin, labels.of(msg))

    /** Файл для показа: с устройства или дождавшись скачивания. */
    suspend fun file(msg: StoredMessage, userInitiated: Boolean): File {
        localFile(msg)?.let { return it }
        val spec = spec(msg) ?: throw DownloadFailedException("no media reference")
        return core.downloads.ensureDownloaded(spec, userInitiated)
    }
}
