package com.oshinobu.demobot

import java.nio.ByteBuffer
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** TOTP (RFC 6238: HMAC-SHA1, шаг 30 с, 6 цифр) — как у аутентификаторов; бот входит сам. */
object Totp {
    fun code(base32Secret: String, epochSeconds: Long = System.currentTimeMillis() / 1000): String {
        val counter = epochSeconds / 30
        val mac = Mac.getInstance("HmacSHA1").apply { init(SecretKeySpec(base32Decode(base32Secret), "HmacSHA1")) }
        val hash = mac.doFinal(ByteBuffer.allocate(8).putLong(counter).array())
        val offset = hash.last().toInt() and 0x0f
        val binary = ((hash[offset].toInt() and 0x7f) shl 24) or
            ((hash[offset + 1].toInt() and 0xff) shl 16) or
            ((hash[offset + 2].toInt() and 0xff) shl 8) or
            (hash[offset + 3].toInt() and 0xff)
        return (binary % 1_000_000).toString().padStart(6, '0')
    }

    /** Секрет из otpauth://-ссылки регистрации (параметр secret). */
    fun secretFromUrl(url: String): String =
        Regex("[?&]secret=([A-Za-z2-7=]+)").find(url)?.groupValues?.get(1) ?: error("в ссылке TOTP нет secret")

    internal fun base32Decode(input: String): ByteArray {
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        val clean = input.trimEnd('=').uppercase().filter { it != ' ' }
        val out = ArrayList<Byte>()
        var buffer = 0
        var bits = 0
        for (c in clean) {
            val v = alphabet.indexOf(c)
            require(v >= 0) { "не base32: $c" }
            buffer = (buffer shl 5) or v
            bits += 5
            if (bits >= 8) {
                bits -= 8
                out += ((buffer shr bits) and 0xff).toByte()
            }
        }
        return out.toByteArray()
    }
}
