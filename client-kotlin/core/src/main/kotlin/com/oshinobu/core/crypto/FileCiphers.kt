package com.oshinobu.core.crypto

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
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// Шифрование вложений.
//
// Мелкие файлы (≤ 20 МБ) — целиком одним AES-256-GCM (порт
// client/lib/crypto/media_cipher.dart): ключ/nonce/mac едут в конверте.
//
// Большие — потоково блоками по 4 МБ (порт StreamingFileCipher.dart и
// android/.../FileCipher.kt, формат байт-в-байт):
//   блок:  [4 байта BE = len(ciphertext+tag)] [ciphertext] [tag(16)]
//   nonce  = 0x00000000 || uint64_be(index)
//   AAD    = UTF-8("<index>:<0|1>"), 1 = последний блок; файл, кратный
//            4 МБ, завершается ПУСТЫМ последним блоком.

class EncryptedFile(val key: ByteArray, val nonce: ByteArray, val mac: ByteArray, val ciphertext: ByteArray)

object MediaCipher {
    fun encrypt(plain: ByteArray): EncryptedFile {
        val key = randomBytes(32)
        val box = AesGcm.encrypt(key, plain)
        return EncryptedFile(key, box.nonce, box.mac, box.ciphertext)
    }

    fun decrypt(key: ByteArray, nonce: ByteArray, mac: ByteArray, ciphertext: ByteArray): ByteArray =
        AesGcm.decrypt(key, SealedBox(nonce, ciphertext, mac))
}

object StreamingFileCipher {
    const val CHUNK_SIZE = 4 * 1024 * 1024
    /** Порог, с которого файл шифруется потоково и грузится частями. */
    const val STREAMING_THRESHOLD_BYTES = 20L * 1024 * 1024
    private const val TAG_BYTES = 16
    private const val MAX_BLOCK = 64 * 1024 * 1024 + 1024

    /** Шифрует [input] в [output], возвращает случайный 32-байтный ключ файла. */
    fun encryptFile(input: File, output: File, onProgress: ((Double) -> Unit)? = null): ByteArray {
        val key = randomBytes(32)
        val total = input.length()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        try {
            FileInputStream(input).use { ins ->
                BufferedOutputStream(FileOutputStream(output), 1 shl 20).use { out ->
                    val buf = ByteArray(CHUNK_SIZE)
                    var index = 0L
                    var processed = 0L
                    while (true) {
                        val n = fillFully(ins, buf)
                        val isLast = n < CHUNK_SIZE
                        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, nonceFor(index)))
                        cipher.updateAAD(aadFor(index, isLast))
                        val sealed = cipher.doFinal(buf, 0, n)
                        writeInt32BE(out, sealed.size)
                        out.write(sealed)
                        index++
                        processed += n
                        onProgress?.invoke(if (total == 0L) 100.0 else processed * 100.0 / total)
                        if (isLast) break
                    }
                }
            }
        } catch (e: Throwable) {
            output.delete()
            throw e
        }
        return key
    }

    /** Бросает [IOException] на обрыв, подмену или неверный ключ. */
    fun decryptFile(input: File, output: File, key: ByteArray, onProgress: ((Double) -> Unit)? = null) {
        val total = input.length()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        try {
            var offset = 0L
            var index = 0L
            var sawLast = false
            DataInputStream(BufferedInputStream(FileInputStream(input), 1 shl 20)).use { ins ->
                BufferedOutputStream(FileOutputStream(output), 1 shl 20).use { out ->
                    while (offset < total) {
                        val len = try {
                            ins.readInt()
                        } catch (_: EOFException) {
                            throw IOException("повреждённый файл: неполный заголовок блока")
                        }
                        offset += 4
                        if (len < TAG_BYTES || len > MAX_BLOCK) throw IOException("повреждённый файл: недопустимая длина блока $len")
                        val payload = ByteArray(len)
                        try {
                            ins.readFully(payload)
                        } catch (_: EOFException) {
                            throw IOException("повреждённый файл: блок обрезан")
                        }
                        offset += len
                        val (plain, isLast) = openBlock(cipher, key, index, payload)
                        out.write(plain)
                        sawLast = isLast
                        index++
                        onProgress?.invoke(if (total == 0L) 100.0 else offset * 100.0 / total)
                    }
                }
            }
            if (!sawLast) throw IOException("файл повреждён или обрезан — нет завершающего блока")
        } catch (e: Throwable) {
            output.delete()
            throw e
        }
    }

    private fun openBlock(cipher: Cipher, key: ByteArray, index: Long, payload: ByteArray): Pair<ByteArray, Boolean> {
        for (isLast in booleanArrayOf(false, true)) {
            try {
                cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, nonceFor(index)))
                cipher.updateAAD(aadFor(index, isLast))
                return cipher.doFinal(payload) to isLast
            } catch (_: AEADBadTagException) {
            }
        }
        throw IOException("блок $index не расшифровывается (обрыв, подмена или неверный ключ)")
    }

    private fun nonceFor(index: Long): ByteArray = ByteArray(12).also { ByteBuffer.wrap(it).putLong(4, index) }

    private fun aadFor(index: Long, isLast: Boolean): ByteArray = "$index:${if (isLast) 1 else 0}".toByteArray(Charsets.UTF_8)

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
}
