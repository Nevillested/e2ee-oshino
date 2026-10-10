package com.oshinobu.oshinobu_client

import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Аппаратный AES-256-GCM для файлов, потоково (chunked). Точная копия
 * формата из client/lib/crypto/streaming_file_cipher.dart, чтобы файл,
 * зашифрованный тут, читался старым Dart-расшифровщиком у собеседника (и
 * наоборот):
 *
 *   на каждый блок:  [4 байта BE = len(ciphertext+tag)] [ciphertext] [tag(16)]
 *   nonce блока   =  0x00000000 || uint64_be(index)          (12 байт)
 *   AAD блока     =  UTF-8("<index>:<0|1>")   1 = последний блок
 *   plaintext-блок = CHUNK байт, последний короче; файл, кратный CHUNK,
 *                    завершается ПУСТЫМ блоком с флагом «последний».
 *
 * Чистый Dart-AES давал ~4 МБ/с (288 МБ шифровались ~70 c) — тут те же
 * 288 МБ за пару секунд, потому что `javax.crypto` уходит в аппаратный
 * AES процессора. Вся работа — на отдельном Executor-потоке, MethodChannel
 * .Result отдаётся обратно в main looper.
 */
object FileCipher {
    private const val CHUNK = 4 * 1024 * 1024
    private const val TAG_BYTES = 16
    private const val TAG_BITS = 128

    // Верхняя граница длины блока при расшифровке — защита от OOM на
    // повреждённом/чужом заголовке. Намного больше любого разумного размера
    // блока (другой клиент вправе резать иначе — формат самоописательный).
    private const val MAX_BLOCK = 64 * 1024 * 1024 + 1024

    private val exec = Executors.newSingleThreadExecutor { r ->
        Thread(r, "oshinobu-file-cipher").apply { priority = Thread.NORM_PRIORITY }
    }
    private val main = Handler(Looper.getMainLooper())

    /** Шифрует [inputPath] в [outputPath]. success = base64 случайного 32-байтного ключа. */
    fun encrypt(inputPath: String, outputPath: String, result: MethodChannel.Result) {
        exec.execute {
            try {
                val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                FileInputStream(inputPath).use { fis ->
                    BufferedOutputStream(FileOutputStream(outputPath), 1 shl 20).use { out ->
                        val buf = ByteArray(CHUNK)
                        var index = 0L
                        while (true) {
                            val n = fillFully(fis, buf)
                            val isLast = n < CHUNK
                            cipher.init(
                                Cipher.ENCRYPT_MODE,
                                SecretKeySpec(key, "AES"),
                                GCMParameterSpec(TAG_BITS, nonceFor(index)),
                            )
                            cipher.updateAAD(aadFor(index, isLast))
                            val sealed = cipher.doFinal(buf, 0, n) // ciphertext||tag
                            writeInt32BE(out, sealed.size)
                            out.write(sealed)
                            index++
                            if (isLast) break
                        }
                    }
                }
                val keyB64 = Base64.encodeToString(key, Base64.NO_WRAP)
                main.post { result.success(keyB64) }
            } catch (e: Throwable) {
                safeDelete(outputPath)
                main.post { result.error("file_cipher_encrypt", e.message, null) }
            }
        }
    }

    /** Расшифровывает [inputPath] в [outputPath] ключом [keyB64]. Бросает на обрыв/подмену. */
    fun decrypt(inputPath: String, outputPath: String, keyB64: String, result: MethodChannel.Result) {
        exec.execute {
            try {
                val key = Base64.decode(keyB64, Base64.NO_WRAP)
                val total = File(inputPath).length()
                var offset = 0L
                var index = 0L
                var sawLast = false
                val encCipher = Cipher.getInstance("AES/GCM/NoPadding")
                DataInputStream(BufferedInputStream(FileInputStream(inputPath), 1 shl 20)).use { ins ->
                    BufferedOutputStream(FileOutputStream(outputPath), 1 shl 20).use { out ->
                        while (offset < total) {
                            val len = try {
                                ins.readInt()
                            } catch (e: EOFException) {
                                throw IOException("повреждённый файл: неполный заголовок блока")
                            }
                            offset += 4
                            if (len < TAG_BYTES || len > MAX_BLOCK) {
                                throw IOException("повреждённый файл: недопустимая длина блока $len")
                            }
                            val payload = ByteArray(len)
                            try {
                                ins.readFully(payload)
                            } catch (e: EOFException) {
                                throw IOException("повреждённый файл: блок обрезан")
                            }
                            offset += len

                            val plain = openBlock(encCipher, key, index, payload)
                            out.write(plain.first)
                            sawLast = plain.second
                            index++
                        }
                    }
                }
                if (!sawLast) throw IOException("файл повреждён или обрезан — нет завершающего блока")
                main.post { result.success(null) }
            } catch (e: Throwable) {
                safeDelete(outputPath)
                main.post { result.error("file_cipher_decrypt", e.message, null) }
            }
        }
    }

    /** Пробует AAD «последний=нет», затем «последний=да». Возвращает (plaintext, isLast). */
    private fun openBlock(
        cipher: Cipher,
        key: ByteArray,
        index: Long,
        payload: ByteArray,
    ): Pair<ByteArray, Boolean> {
        for (isLast in booleanArrayOf(false, true)) {
            try {
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    SecretKeySpec(key, "AES"),
                    GCMParameterSpec(TAG_BITS, nonceFor(index)),
                )
                cipher.updateAAD(aadFor(index, isLast))
                return Pair(cipher.doFinal(payload), isLast)
            } catch (_: AEADBadTagException) {
                // не тот флаг — пробуем следующий
            }
        }
        throw IOException("блок $index не расшифровывается (обрыв, подмена или неверный ключ)")
    }

    private fun nonceFor(index: Long): ByteArray {
        val nonce = ByteArray(12)
        ByteBuffer.wrap(nonce).apply {
            position(4)
            putLong(index) // ByteBuffer по умолчанию big-endian
        }
        return nonce
    }

    private fun aadFor(index: Long, isLast: Boolean): ByteArray =
        "$index:${if (isLast) 1 else 0}".toByteArray(Charsets.UTF_8)

    private fun fillFully(ins: InputStream, buf: ByteArray): Int {
        var total = 0
        while (total < buf.size) {
            val n = ins.read(buf, total, buf.size - total)
            if (n < 0) break
            total += n
        }
        return total
    }

    private fun writeInt32BE(out: OutputStream, value: Int) {
        out.write((value ushr 24) and 0xFF)
        out.write((value ushr 16) and 0xFF)
        out.write((value ushr 8) and 0xFF)
        out.write(value and 0xFF)
    }

    private fun safeDelete(path: String) {
        try {
            File(path).delete()
        } catch (_: Throwable) {
        }
    }
}
