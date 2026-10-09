package com.oshinobu.app.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.util.LruCache
import androidx.exifinterface.media.ExifInterface
import com.oshinobu.core.service.VideoThumbnailer
import java.io.File
import java.util.UUID

/**
 * Декодирование картинок для показа в чате: уменьшение до нужного размера
 * (inSampleSize — без загрузки полного кадра в память), поворот по EXIF,
 * общий кэш в памяти (лента прокручивается — не декодируем заново).
 */
object MediaDecoding {
    private val cache = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }

    private fun key(file: File, maxPx: Int) = "${file.path}|${file.length()}|$maxPx"

    fun cached(file: File, maxPx: Int): Bitmap? = cache.get(key(file, maxPx))

    /** Картинка не больше [maxPx] по длинной стороне; null — не картинка/битый файл. Вызывать вне главного потока. */
    fun decodeImage(file: File, maxPx: Int): Bitmap? {
        cache.get(key(file, maxPx))?.let { return it }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPx) sample *= 2
        val decoded = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val rotated = rotateByExif(file, decoded)
        cache.put(key(file, maxPx), rotated)
        return rotated
    }

    private fun rotateByExif(file: File, bitmap: Bitmap): Bitmap {
        val orientation = runCatching {
            ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    /** Кадр из видео (первая секунда), уменьшенный до [maxPx]. */
    fun videoFrame(file: File, maxPx: Int): Bitmap? {
        cache.get(key(file, maxPx))?.let { return it }
        val retriever = MediaMetadataRetriever()
        val frame = try {
            retriever.setDataSource(file.path)
            retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        } ?: return null
        val scale = maxPx.toFloat() / maxOf(frame.width, frame.height)
        val result = if (scale < 1f) Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt(), (frame.height * scale).toInt(), true) else frame
        cache.put(key(file, maxPx), result)
        return result
    }

    /** Длительность медиафайла в мс (для записанных голосовых/кружков). */
    fun durationMs(file: File): Long? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.path)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }
}

/**
 * Превью-кадр видео для пузыря отправки — JPEG в support/video_thumbs (как у
 * Flutter-клиента): не во временной папке, которую система вправе очистить.
 */
class AndroidVideoThumbnailer(supportDir: File) : VideoThumbnailer {
    private val dir = File(supportDir, "video_thumbs")

    override fun thumbnail(video: File): File? {
        val frame = MediaDecoding.videoFrame(video, 720) ?: return null
        dir.mkdirs()
        val out = File(dir, "vthumb_${UUID.randomUUID()}.jpg")
        return runCatching {
            out.outputStream().use { frame.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            out
        }.getOrNull()
    }
}
