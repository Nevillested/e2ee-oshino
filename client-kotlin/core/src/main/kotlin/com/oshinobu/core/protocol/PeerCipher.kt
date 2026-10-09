package com.oshinobu.core.protocol

import com.oshinobu.core.crypto.LocalIdentity
import com.oshinobu.core.crypto.RatchetState
import com.oshinobu.core.crypto.X25519KeyPair
import com.oshinobu.core.crypto.X3dhIncoming
import com.oshinobu.core.crypto.decryptMessage
import com.oshinobu.core.crypto.encryptMessage
import com.oshinobu.core.crypto.establishIncomingRoot
import com.oshinobu.core.crypto.establishOutgoingRoot
import com.oshinobu.core.crypto.unb64
import com.oshinobu.core.string
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Сборка и вскрытие конверта — чистая криптографическая часть того, что во
// Flutter делают services/peer_messenger.dart (исходящее) и
// services/message_router.dart (входящее). Хранилище, сеть, повторы и
// самолечение сессии сюда НЕ входят — это уровень сервисов.
//
// Конверт на проводе: { nonce, ciphertext, mac, ratchet_pubkey,
// message_number, sender_device_id [, sender_identity_dh_pubkey,
// ephemeral_pubkey, used_one_time_prekey] } — все заголовочные поля входят
// в AAD (см. MessageCipher.kt).

object PeerCipher {
    /**
     * Новая исходящая сессия по prekey-бандлу собеседника. Вернувшиеся
     * initHeader-поля нужно передать в [seal] для ПЕРВОГО сообщения этой сессии.
     */
    fun startOutgoingSession(bundle: JsonObject, myDeviceId: String, myIdentityDh: X25519KeyPair): Pair<RatchetState, Map<String, JsonElement>> {
        val out = establishOutgoingRoot(bundle, myDeviceId, myIdentityDh)
        return RatchetState.initAsSender(out.rootKey, out.ephemeralKeyPair) to out.initHeader
    }

    /**
     * Шифрует [inner] следующим ключом [state] (state при этом продвигается —
     * сохранить его до отправки, как делает Dart-клиент).
     */
    fun seal(state: RatchetState, inner: InnerMessage, myDeviceId: String, initHeader: Map<String, JsonElement>? = null): JsonObject =
        sealText(state, inner.encode(), myDeviceId, initHeader)

    /**
     * То же для произвольного открытого текста — сигналы звонка шифруются
     * тем же ratchet, но внутри у них просто JSON `{type, ...}`, не [InnerMessage].
     */
    fun sealText(state: RatchetState, plaintext: String, myDeviceId: String, initHeader: Map<String, JsonElement>? = null): JsonObject {
        val next = state.nextSendingKey()
        val headerFields = LinkedHashMap<String, JsonElement>().apply {
            putAll(next.header)
            put("sender_device_id", JsonPrimitive(myDeviceId))
            if (initHeader != null) putAll(initHeader)
        }
        val encrypted = encryptMessage(next.messageKey, plaintext, headerFields)
        return JsonObject(encrypted + headerFields)
    }

    /** Расшифровка входящего конверта текущим состоянием. Состояние продвигается. */
    fun open(state: RatchetState, envelope: JsonObject): InnerMessage {
        val key = state.nextReceivingKey(envelope)
        return InnerMessage.decode(decryptMessage(key, envelope))
    }

    /** Свежая входящая сессия из X3DH-полей конверта; null — их там нет. */
    fun startIncomingSession(envelope: JsonObject, me: LocalIdentity): Pair<RatchetState, X3dhIncoming>? {
        val incoming = establishIncomingRoot(envelope, me) ?: return null
        val ephemeral = unb64(envelope.string("ephemeral_pubkey"))
        return RatchetState.initAsReceiver(incoming.rootKey, ephemeral) to incoming
    }
}
