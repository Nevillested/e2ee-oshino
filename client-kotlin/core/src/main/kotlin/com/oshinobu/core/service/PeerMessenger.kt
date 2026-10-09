package com.oshinobu.core.service

import com.oshinobu.core.crypto.b64
import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.protocol.PeerCipher
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.KeyStore
import com.oshinobu.core.storage.PeerAccountStore
import com.oshinobu.core.storage.PeerIdentityStore
import com.oshinobu.core.storage.Session
import com.oshinobu.core.storage.SessionStore
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Зашифровать сообщение собеседнику и поставить в надёжную очередь. Один
 * путь вместо трёх почти одинаковых во Flutter (peer_messenger.dart,
 * control_message_sender.dart, message_resend.dart):
 *  - обычное сообщение: [send] с messageId/peerLogin — по ack станет 'sent';
 *  - служебное (реакция, правка, квитанция…): silent = true, без звука/пуша.
 *
 * Нет сессии с устройством — берём prekey-бандл и поднимаем X3DH; первое
 * сообщение новой сессии несёт X3DH-поля в заголовке.
 */
class PeerMessenger(
    private val api: ApiClient,
    private val session: Session,
    private val keys: KeyStore,
    private val sessions: SessionStore,
    private val peerAccounts: PeerAccountStore,
    private val peerIdentities: PeerIdentityStore,
    private val chats: ChatStore,
    private val queue: SendQueueProcessor,
    private val sendLock: KeyedMutex,
    private val log: Logger = NoopLogger,
) {
    suspend fun send(
        peerDeviceId: String,
        inner: InnerMessage,
        peerLogin: String? = null,
        silent: Boolean = false,
        trackStatus: Boolean = !silent,
        onAcked: (suspend () -> Unit)? = null,
    ) {
        require(peerDeviceId.isNotEmpty()) { "нет device_id собеседника" }
        sendLock.run(peerDeviceId) {
            val envelope = sealLocked(peerDeviceId, inner.encode())
            queue.enqueue(
                toDeviceId = peerDeviceId,
                envelope = envelope,
                deliveryId = inner.messageId,
                silent = silent,
                messageId = if (trackStatus) inner.messageId else null,
                peerLogin = if (trackStatus) peerLogin else null,
                onAcked = onAcked,
            )
        }
    }

    /**
     * Сигнал звонка: тот же ratchet, что у сообщений, но конверт уходит не
     * в очередь, а сразу по WebSocket (call_service.dart, _encryptCallSignal).
     */
    suspend fun sealCallSignal(peerDeviceId: String, payload: JsonObject): JsonObject =
        sendLock.run(peerDeviceId) { sealLocked(peerDeviceId, payload.toString()) }

    /**
     * Зашифровать [plaintext] следующим ключом сессии с устройством (нет
     * сессии — X3DH по prekey-бандлу). Состояние сохраняется ДО отправки:
     * ключ уже израсходован. Вызывать под [sendLock] этого устройства.
     */
    private suspend fun sealLocked(peerDeviceId: String, plaintext: String): JsonObject {
        val myDeviceId = keys.deviceId() ?: error("устройство не зарегистрировано")
        var state = sessions.get(peerDeviceId)
        val initHeader: Map<String, JsonElement>?
        if (state == null) {
            val token = session.token ?: error("нет токена")
            val bundle = api.getPrekeyBundle(token, peerDeviceId)
            bundle["account_id"]?.jsonPrimitive?.content?.let { peerAccounts.save(peerDeviceId, it) }
            peerIdentities.save(peerDeviceId, bundle["identity_dh_pubkey"]!!.jsonPrimitive.content)
            val me = keys.getOrCreateIdentity()
            val (fresh, header) = PeerCipher.startOutgoingSession(bundle, myDeviceId, me.identityDh)
            state = fresh
            initHeader = header
            sessions.savePendingInit(peerDeviceId, header)
            log.log("PeerMessenger: fresh X3DH session to=$peerDeviceId")
        } else {
            initHeader = sessions.pendingInit(peerDeviceId)
        }
        val envelope = PeerCipher.sealText(state, plaintext, myDeviceId, initHeader)
        sessions.save(peerDeviceId, state)
        return envelope
    }

    /** Служебное сообщение; ошибки только в журнал (как ControlMessageSender). */
    suspend fun sendControl(peerDeviceId: String, inner: InnerMessage) {
        if (peerDeviceId.isEmpty()) return
        try {
            send(peerDeviceId, inner, silent = true)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            log.log("ControlMessageSender send-FAILED to=$peerDeviceId type=${inner.type} error=$e")
        }
    }

    /** Актуальный device_id собеседника по логину (и запомнить его в чате); при ошибке — [fallback]. */
    suspend fun resolvePeerDeviceId(peerLogin: String, fallback: String): String {
        try {
            val token = session.token ?: return fallback
            val devices = api.getDevicesByLogin(token, peerLogin).devices
            val id = devices.firstOrNull()?.get("device_id")?.jsonPrimitive?.content
            if (id != null) {
                chats.setLastKnownDeviceId(peerLogin, id)
                return id
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
        }
        return fallback
    }
}

/** Регистрация устройства и пополнение одноразовых prekey (device_setup.dart, prekey_replenisher.dart). */
class DeviceSetup(private val api: ApiClient, private val keys: KeyStore, private val log: Logger = NoopLogger) {
    private companion object {
        const val LOW_WATERMARK = 5
        const val TARGET_POOL = 20
    }

    /** Первый вход на этом устройстве: ключи → /register-device → prekeys → сохранить device_id. */
    suspend fun ensureDeviceRegistered(token: String) {
        if (keys.deviceId() != null) return
        val me = keys.getOrCreateIdentity()
        val deviceId = api.registerDevice(token, b64(me.identity.publicKey), b64(me.identityDh.publicKey), b64(me.identityDhSignature))
        val (spk, spkSig) = keys.createSignedPrekey(me.identity)
        val otps = keys.createOneTimePrekeys(TARGET_POOL)
        api.uploadPrekeys(token, deviceId, b64(spk), b64(spkSig), otps.map { b64(it) })
        // device_id — последним: пока его нет, при следующем запуске регистрация повторится
        keys.saveDeviceId(deviceId)
    }

    /** На сервере осталось ≤ 5 одноразовых ключей — догоняем до 20. Ошибки только в журнал. */
    suspend fun ensurePrekeysTopped(token: String, deviceId: String) {
        try {
            val remaining = api.getPrekeyCount(token, deviceId) ?: return
            if (remaining > LOW_WATERMARK) return
            val needed = TARGET_POOL - remaining
            if (needed <= 0) return
            val identity = keys.loadIdentity() ?: return
            val spk = identity.signedPrekey ?: return
            val fresh = keys.createOneTimePrekeys(needed)
            api.uploadPrekeys(token, deviceId, b64(spk.publicKey), b64(identity.identity.sign(spk.publicKey)), fresh.map { b64(it) })
            log.log("PrekeyReplenisher topped up $needed one-time prekeys (had $remaining)")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            log.log("PrekeyReplenisher failed: $e")
        }
    }
}
