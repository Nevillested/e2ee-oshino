package com.oshinobu.app.media

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Открыть файл во внешнем приложении и сохранить его в "Загрузки". */
object FileActions {
    fun mimeOf(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"

    /** Файл в кэше лежит под служебным именем — для чужого приложения копия под настоящим. */
    private suspend fun namedCopy(context: Context, source: File, name: String): File = withContext(Dispatchers.IO) {
        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        val safeName = name.replace('/', '_').ifBlank { "file" }
        File(dir, safeName).also { source.copyTo(it, overwrite = true) }
    }

    /** "Открыть с помощью…". false — подходящего приложения нет. */
    suspend fun open(context: Context, source: File, name: String): Boolean {
        val copy = namedCopy(context, source, name)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", copy)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeOf(name)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            context.startActivity(Intent.createChooser(view, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    /**
     * Копия в "Загрузки/Oshinobu" (как во Flutter-клиенте); одноимённый файл
     * не затирается — система или мы добавляем " (1)". Возвращает видимый путь.
     */
    suspend fun saveToDownloads(context: Context, source: File, name: String): String = withContext(Dispatchers.IO) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val folder = "${Environment.DIRECTORY_DOWNLOADS}/$APP_FOLDER"
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mimeOf(name))
                put(MediaStore.Downloads.RELATIVE_PATH, folder)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: error("MediaStore insert failed")
            try {
                resolver.openOutputStream(uri)!!.use { out -> source.inputStream().use { it.copyTo(out) } }
                resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            "$folder/$name"
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), APP_FOLDER).apply { mkdirs() }
            var target = File(dir, name)
            var n = 1
            while (target.exists()) target = File(dir, "${name.substringBeforeLast('.')} (${n++})${name.substringAfterLast('.', "").let { if (it.isEmpty()) "" else ".$it" }}")
            source.copyTo(target)
            target.path
        }
    }

    /**
     * Фото/видео в галерею: Pictures/Oshinobu или Movies/Oshinobu. До
     * Android 10 — прямо в общую папку (нужно разрешение на запись) и
     * сообщение медиасканеру.
     */
    suspend fun saveToGallery(context: Context, source: File, name: String, isVideo: Boolean) = withContext(Dispatchers.IO) {
        val mime = mimeOf(name).takeIf { it != "application/octet-stream" } ?: if (isVideo) "video/mp4" else "image/jpeg"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            val folder = "${if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES}/$APP_FOLDER"
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(collection, values) ?: error("MediaStore insert failed")
            try {
                resolver.openOutputStream(uri)!!.use { out -> source.inputStream().use { it.copyTo(out) } }
                resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        } else {
            @Suppress("DEPRECATION")
            val base = Environment.getExternalStoragePublicDirectory(if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES)
            val target = File(File(base, APP_FOLDER).apply { mkdirs() }, name)
            source.copyTo(target, overwrite = true)
            MediaScannerConnection.scanFile(context, arrayOf(target.path), arrayOf(mime), null)
        }
    }

    /** Своя папка в "Загрузках", галерее и видео. */
    private const val APP_FOLDER = "Oshinobu"
}
