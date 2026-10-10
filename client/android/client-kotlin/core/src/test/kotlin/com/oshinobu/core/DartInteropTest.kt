package com.oshinobu.core

import com.oshinobu.core.crypto.AlreadyProcessedException
import com.oshinobu.core.crypto.MediaCipher
import com.oshinobu.core.crypto.RatchetState
import com.oshinobu.core.crypto.StoredIdentity
import com.oshinobu.core.crypto.StreamingFileCipher
import com.oshinobu.core.crypto.X25519KeyPair
import com.oshinobu.core.crypto.b64
import com.oshinobu.core.crypto.buildAad
import com.oshinobu.core.crypto.decryptMessage
import com.oshinobu.core.crypto.unb64
import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.protocol.MediaRef
import com.oshinobu.core.protocol.PeerCipher
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * Совместимость протокола с Flutter-клиентом. Пара к
 * client/test/kotlin_interop_test.dart:
 *  - dart_transcript.json пишет НАСТОЯЩИЙ Dart-код — здесь его расшифровываем
 *    и сверяем состояние ratchet после каждого шага;
 *  - kotlin_transcript.json пишем здесь — его проверяет Dart-тест.
 */
class DartInteropTest {
    private val vectorsDir = File("src/test/resources/vectors")
    private val pretty = Json { prettyPrint = true }

    private fun obj(e: JsonElement?) = e!!.jsonObject

    private fun withoutSendingKeys(s: JsonObject) = JsonObject(s - "sending_ratchet_private" - "sending_ratchet_public")

    private fun verifyTranscript(t: JsonObject, source: String) {
        val bobStore = obj(t["bob_store"]).mapValues { it.value.jsonPrimitive.content }
        t["steps"]!!.jsonArray.forEachIndexed { i, el ->
            val step = el.jsonObject
            val env = obj(step["envelope"])
            val before = step["state_before"]?.takeUnless { it is JsonNull }?.jsonObject

            val state = if (before == null) {
                val me = StoredIdentity.fromStore(bobStore)!!
                PeerCipher.startIncomingSession(env, me)!!.first
            } else {
                // формат состояния: Dart-JSON → Kotlin → тот же JSON
                RatchetState.fromJson(before).also { assertEquals(before, it.toJson(), "$source шаг $i: JSON состояния") }
            }

            if (step["expect"]?.jsonPrimitive?.content == "already_processed") {
                assertFailsWith<AlreadyProcessedException>("$source шаг $i: ожидался дубль") { state.nextReceivingKey(env) }
                return@forEachIndexed
            }

            val got = InnerMessage.decode(decryptMessage(state.nextReceivingKey(env), env))
            val want = InnerMessage.decode(step["inner"]!!.jsonPrimitive.content)
            assertEquals(want, got, "$source шаг $i: текст")

            val after = state.toJson()
            val wantAfter = obj(step["state_after"])
            if (before == null) {
                assertEquals(withoutSendingKeys(wantAfter), withoutSendingKeys(after), "$source шаг $i: состояние после X3DH")
            } else {
                assertEquals(wantAfter, after, "$source шаг $i: состояние")
            }
        }

        t["media"]!!.jsonArray.forEach {
            val v = it.jsonObject
            fun f(n: String) = unb64(v[n]!!.jsonPrimitive.content)
            assertContentEquals(f("plain"), MediaCipher.decrypt(f("key"), f("nonce"), f("mac"), f("ciphertext")), "$source media")
        }

        val tmp = Files.createTempDirectory("oshinobu_interop").toFile()
        try {
            t["streaming"]!!.jsonArray.forEachIndexed { n, it ->
                val v = it.jsonObject
                val enc = File(tmp, "s$n.enc").apply { writeBytes(unb64(v["file"]!!.jsonPrimitive.content)) }
                val out = File(tmp, "s$n.out")
                StreamingFileCipher.decryptFile(enc, out, unb64(v["key"]!!.jsonPrimitive.content))
                assertContentEquals(unb64(v["plain"]!!.jsonPrimitive.content), out.readBytes(), "$source streaming $n")
            }
        } finally {
            tmp.deleteRecursively()
        }
    }

    @Test
    fun `Kotlin расшифровывает стенограмму настоящего Dart-кода`() {
        val t = Json.parseToJsonElement(File(vectorsDir, "dart_transcript.json").readText()).jsonObject
        verifyTranscript(t, "dart")
    }

    @Test
    fun `Kotlin пишет стенограмму для Dart-теста`() {
        val bob = StoredIdentity.generate("bob-device", oneTimePrekeyCount = 2)
        val bobStore = bob.toStore()
        val bundle = bob.bundle()
        val aliceId = StoredIdentity.generate("alice-device")

        val (alice, initHeader) = PeerCipher.startOutgoingSession(bundle, "alice-device", aliceId.identityDh)
        lateinit var bobState: RatchetState
        val bobLive = StoredIdentity.fromStore(bobStore)!!
        val steps = mutableListOf<JsonElement>()

        fun deliver(receiver: String, env: JsonObject, inner: InnerMessage) {
            var before: JsonObject? = null
            if (receiver == "bob" && env["ephemeral_pubkey"] != null) {
                val (st, x3dh) = PeerCipher.startIncomingSession(env, bobLive)!!
                x3dh.consumedOneTimePrekey?.let { bobLive.deleteOneTimePrekey(it) }
                bobState = st
            } else {
                before = (if (receiver == "bob") bobState else alice).toJson()
            }
            val st = if (receiver == "bob") bobState else alice
            assertEquals(inner, PeerCipher.open(st, env))
            steps += buildJsonObject {
                put("receiver", receiver)
                put("state_before", before ?: JsonNull)
                put("envelope", env)
                put("inner", inner.encode())
                put("state_after", st.toJson())
            }
        }

        val m1 = InnerMessage.text("Привет из Kotlin! 🚀")
        val m2 = InnerMessage.reaction(m1.messageId, "👍")
        val m3 = InnerMessage.media(
            MediaRef("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", b64(ByteArray(32) { 9 }), b64(ByteArray(12) { 3 }), b64(ByteArray(16) { 4 }), 4242, false),
            fileName = "документ.pdf",
            isFile = true,
        )
        val e1 = PeerCipher.seal(alice, m1, "alice-device", initHeader)
        val e2 = PeerCipher.seal(alice, m2, "alice-device")
        val e3 = PeerCipher.seal(alice, m3, "alice-device")
        deliver("bob", e1, m1)
        deliver("bob", e3, m3)
        deliver("bob", e2, m2)
        steps += buildJsonObject {
            put("receiver", "bob")
            put("state_before", bobState.toJson())
            put("envelope", e3)
            put("expect", "already_processed")
        }

        val r1 = InnerMessage.readReceipt(listOf(m1.messageId, m3.messageId))
        val r2 = InnerMessage.text("ответ", replyToMessageId = m1.messageId, replyToPreview = "Привет")
        val f1 = PeerCipher.seal(bobState, r1, "bob-device")
        val f2 = PeerCipher.seal(bobState, r2, "bob-device")
        deliver("alice", f2, r2)
        deliver("alice", f1, r1)

        val m4 = InnerMessage.edit(m1.messageId, "исправлено")
        deliver("bob", PeerCipher.seal(alice, m4, "alice-device"), m4)
        val r3 = InnerMessage.delete(listOf(r2.messageId))
        deliver("alice", PeerCipher.seal(bobState, r3, "bob-device"), r3)

        val media = listOf("hello".toByteArray(), ByteArray(1000) { (it * 31).toByte() }).map { plain ->
            val enc = MediaCipher.encrypt(plain)
            buildJsonObject {
                put("plain", b64(plain)); put("key", b64(enc.key)); put("nonce", b64(enc.nonce))
                put("mac", b64(enc.mac)); put("ciphertext", b64(enc.ciphertext))
            }
        }
        val tmp = Files.createTempDirectory("oshinobu_interop").toFile()
        val streaming = try {
            listOf(0, 100).map { size ->
                val plain = ByteArray(size) { (it * 7).toByte() }
                val input = File(tmp, "p$size").apply { writeBytes(plain) }
                val output = File(tmp, "e$size")
                val key = StreamingFileCipher.encryptFile(input, output)
                buildJsonObject { put("plain", b64(plain)); put("key", b64(key)); put("file", b64(output.readBytes())) }
            }
        } finally {
            tmp.deleteRecursively()
        }

        val transcript = buildJsonObject {
            put("bob_store", JsonObject(bobStore.mapValues { JsonPrimitive(it.value) }))
            put("bob_bundle", bundle)
            put("steps", kotlinx.serialization.json.JsonArray(steps))
            put("media", kotlinx.serialization.json.JsonArray(media))
            put("streaming", kotlinx.serialization.json.JsonArray(streaming))
        }
        verifyTranscript(Json.parseToJsonElement(transcript.toString()).jsonObject, "kotlin(self)")
        vectorsDir.mkdirs()
        File(vectorsDir, "kotlin_transcript.json").writeText(pretty.encodeToString(JsonObject.serializer(), transcript))
    }

    @Test
    fun `строка AAD совпадает с Dart посимвольно`() {
        val aad = buildAad(
            mapOf(
                "ratchet_pubkey" to JsonPrimitive("UFVC"),
                "message_number" to JsonPrimitive(7),
                "sender_device_id" to JsonPrimitive("dev"),
                "used_one_time_prekey" to JsonNull,
            ),
        )
        assertEquals(
            "sender_device_id=dev|ratchet_pubkey=UFVC|message_number=7|ephemeral_pubkey=null|" +
                "sender_identity_dh_pubkey=null|used_one_time_prekey=null",
            aad.toString(Charsets.UTF_8),
        )
    }

    @Test
    fun `X25519 и публичный ключ из приватного`() {
        val a = X25519KeyPair.generate()
        val b = X25519KeyPair.generate()
        assertContentEquals(a.sharedSecret(b.publicKey), b.sharedSecret(a.publicKey))
        assertContentEquals(a.publicKey, X25519KeyPair.fromPrivate(a.privateKey).publicKey)
    }
}
