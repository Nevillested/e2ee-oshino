package com.oshinobu.core

import com.oshinobu.core.crypto.Ed25519KeyPair
import com.oshinobu.core.crypto.RatchetState
import com.oshinobu.core.crypto.X25519KeyPair
import com.oshinobu.core.storage.AppLockStore
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.InMemorySecureStore
import com.oshinobu.core.storage.KeyStore
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.SendQueueStore
import com.oshinobu.core.storage.SessionStore
import com.oshinobu.core.storage.StoredMessage
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Совместимость локального хранилища с Flutter-клиентом. Пара к
 * client/test/kotlin_storage_interop_test.dart: Kotlin-сборка ставится
 * поверх Flutter и работает прямо с его записями secure storage.
 */
class StorageInteropTest {
    private val vectorsDir = File("src/test/resources/vectors")
    private val pretty = Json { prettyPrint = true }

    private suspend fun view(chats: ChatStore): JsonObject {
        val peers = chats.getKnownPeers()
        return buildJsonObject {
            put("peers", JsonArray(peers.map { it.toJson() }))
            put("messages", JsonObject(peers.associate { p -> p.peerLogin to JsonArray(chats.getMessages(p.peerLogin).map { it.toJson() }) }))
        }
    }

    @Test
    fun `Kotlin читает хранилище, записанное Flutter`() = runBlocking {
        val t = Json.parseToJsonElement(File(vectorsDir, "storage_dart.json").readText()).jsonObject
        val secure = InMemorySecureStore(t["secure"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content })
        val chats = ChatStore(secure)

        // как видит Dart, минус чат «Заметки» — Kotlin его скрывает
        val dartView = t["view"]!!.jsonObject
        val wantPeers = dartView["peers"]!!.jsonArray.filter {
            it.jsonObject["login"]!!.jsonPrimitive.content != ChatStore.LEGACY_NOTES_LOGIN
        }
        val got = view(chats)
        assertEquals(JsonArray(wantPeers), got["peers"])
        for (p in wantPeers) {
            val login = p.jsonObject["login"]!!.jsonPrimitive.content
            assertEquals(dartView["messages"]!!.jsonObject[login], got["messages"]!!.jsonObject[login], "история $login")
        }
        assertTrue(chats.getKnownPeers().none { it.peerLogin == ChatStore.LEGACY_NOTES_LOGIN })

        // надгробие 'ghost' из Flutter-удаления: такое сообщение больше не добавится
        chats.addMessage("bob", StoredMessage("ghost", "поздний дубль", false, 5000))
        assertTrue(chats.getMessages("bob").none { it.messageId == "ghost" })

        val pin = t["pin"]!!.jsonPrimitive.content
        val lock = AppLockStore(secure)
        assertTrue(lock.verifyPin(pin))
        assertFalse(lock.verifyPin("0000"))
        assertTrue(lock.load().hasPin)

        val keys = KeyStore(secure)
        assertEquals("my-device", keys.deviceId())
        val identity = assertNotNull(keys.loadIdentity())
        assertEquals(3, identity.oneTimePrekeys.size)
        assertNotNull(identity.signedPrekey)
        assertTrue(Ed25519KeyPair.verify(identity.identity.publicKey, identity.identityDh.publicKey, identity.identityDhSignature))
        assertEquals(t["ratchet_json"], SessionStore(secure).get("peer-device")!!.toJson())
        assertEquals(listOf("q1"), SendQueueStore(secure).getAll().map { it["id"]!!.jsonPrimitive.content })
    }

    @Test
    fun `Kotlin пишет хранилище для Flutter`() = runBlocking {
        val secure = InMemorySecureStore()
        val keys = KeyStore(secure)
        keys.createSignedPrekey(keys.getOrCreateIdentity().identity)
        keys.createOneTimePrekeys(2)
        keys.saveDeviceId("kotlin-device")

        val chats = ChatStore(secure)
        chats.addMessage("dave", StoredMessage("k1", "Привет из Kotlin", false, 1000), accountId = "acc-dave", incrementUnread = true)
        chats.addMessage(
            "dave",
            StoredMessage(
                "k2", "подпись", true, 2000, isMedia = true, isVideo = true, fileSize = 999, mediaId = "media-k", mediaKeyBase64 = "a2V5",
                mediaNonceBase64 = "bm9uY2U=", mediaMacBase64 = "bWFj", status = MessageStatus.SENDING, isSpoiler = true,
            ),
        )
        chats.updateMessageStatus("dave", "k2", MessageStatus.SENT)
        chats.setReaction("dave", "k1", isMine = false, emoji = "🔥")
        chats.addCallLog("dave", "outgoing", "answered", 3000, durationSeconds = 42, callId = "call-k")
        chats.addUndecryptableNotice("dave", "undecryptable_k", 3500)
        chats.addMessage("dave", StoredMessage("k3", "в корзину", true, 4000))
        chats.deleteMessages("dave", listOf("k3"))
        chats.markMessagesRead("dave", listOf("k2"))
        chats.setPinned("dave", "k2")
        chats.addMessage("erin", StoredMessage("e1", "yo", true, 600))
        chats.setChatPinned("erin", true)

        val ratchet = RatchetState.initAsSender(ByteArray(32) { 6 }, X25519KeyPair.generate())
        ratchet.nextSendingKey()
        SessionStore(secure).save("peer-device", ratchet)
        AppLockStore(secure).setPin("13579")
        SendQueueStore(secure).add("q1", "peer-device", JsonObject(mapOf("nonce" to JsonPrimitive("n"))), messageId = "k2", peerLogin = "dave")

        val out = buildJsonObject {
            put("secure", JsonObject(secure.readAll().mapValues { JsonPrimitive(it.value) }))
            put("view", view(chats))
            put("ratchet_json", ratchet.toJson())
            put("pin", "13579")
            put("device_id", "kotlin-device")
        }
        vectorsDir.mkdirs()
        File(vectorsDir, "storage_kotlin.json").writeText(pretty.encodeToString(JsonObject.serializer(), out))
    }
}
