package com.oshinobu.app.media

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.LruCache
import android.util.Size
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Фото или видео из галереи устройства. */
data class GalleryItem(val id: Long, val uri: Uri, val isVideo: Boolean, val sortKey: Long, val durationMs: Long?)

/** Насколько приложению открыта галерея. */
enum class GalleryAccess { NONE, PARTIAL, FULL }

/** Галерея устройства через MediaStore: список, миниатюры, разрешения, подписка на изменения. */
object DeviceGallery {
    private val thumbs = object : LruCache<Long, Bitmap>((Runtime.getRuntime().maxMemory() / 16).toInt()) {
        override fun sizeOf(key: Long, value: Bitmap) = value.allocationByteCount
    }

    /** Что запрашивать: на Android 14 — с частичным доступом, на 13 — фото и видео, раньше — чтение памяти. */
    val permissions: Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    fun access(context: Context): GalleryAccess {
        fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= 33 && granted(Manifest.permission.READ_MEDIA_IMAGES) -> GalleryAccess.FULL
            Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> GalleryAccess.PARTIAL
            Build.VERSION.SDK_INT < 33 && granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> GalleryAccess.FULL
            else -> GalleryAccess.NONE
        }
    }

    /** Все фото и видео, новые первыми (по более поздней из дат создания и изменения). */
    suspend fun load(context: Context): List<GalleryItem> = withContext(Dispatchers.IO) {
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.DATE_ADDED,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Video.VideoColumns.DURATION,
        )
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE}=? OR ${MediaStore.Files.FileColumns.MEDIA_TYPE}=?"
        val args = arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(), MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString())
        val items = ArrayList<GalleryItem>()
        context.contentResolver.query(MediaStore.Files.getContentUri("external"), projection, selection, args, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val video = c.getInt(1) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                val base = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                items += GalleryItem(
                    id, ContentUris.withAppendedId(base, id), video,
                    maxOf(c.getLong(2), c.getLong(3)),
                    if (video && !c.isNull(4)) c.getLong(4) else null,
                )
            }
        }
        items.sortedByDescending { it.sortKey }
    }

    fun cachedThumbnail(item: GalleryItem): Bitmap? = thumbs.get(item.id)

    /** Миниатюра ~256 px (кэш в памяти). */
    suspend fun thumbnail(context: Context, item: GalleryItem): Bitmap? = withContext(Dispatchers.IO) {
        thumbs.get(item.id)?.let { return@withContext it }
        val bitmap = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                context.contentResolver.loadThumbnail(item.uri, Size(256, 256), null)
            } else if (item.isVideo) {
                @Suppress("DEPRECATION")
                MediaStore.Video.Thumbnails.getThumbnail(context.contentResolver, item.id, MediaStore.Video.Thumbnails.MINI_KIND, null)
            } else {
                @Suppress("DEPRECATION")
                MediaStore.Images.Thumbnails.getThumbnail(context.contentResolver, item.id, MediaStore.Images.Thumbnails.MINI_KIND, null)
            }
        }.getOrNull()
        bitmap?.also { thumbs.put(item.id, it) }
    }

    /** Галерея изменилась (новый снимок и т.п.) — [onChange]; вернуть функцию отписки. */
    fun observe(context: Context, onChange: () -> Unit): () -> Unit {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) = onChange()
        }
        context.contentResolver.registerContentObserver(MediaStore.Files.getContentUri("external"), true, observer)
        return { context.contentResolver.unregisterContentObserver(observer) }
    }
}
