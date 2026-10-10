package com.oshinobu.core.service

import com.oshinobu.core.crypto.AlreadyProcessedException
import com.oshinobu.core.crypto.RatchetState
import com.oshinobu.core.crypto.b64
import com.oshinobu.core.crypto.decryptMessage
import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.IncomingEnvelope
import com.oshinobu.core.net.Transport
import com.oshinobu.core.optBool
import com.oshinobu.core.optLong
import com.oshinobu.core.optObjects
import com.oshinobu.core.optString
import com.oshinobu.core.optStrings
import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.protocol.MessageType
import com.oshinobu.core.protocol.PeerCipher
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.KeyStore
import com.oshinobu.core.storage.PeerAccountStore
import com.oshinobu.core.storage.PeerIdentityStore
import com.oshinobu.core.storage.Prefs
import com.oshinobu.core.storage.Session
import com.oshinobu.core.storage.SessionStore
import com.oshinobu.core.storage.StoredMessage
import com.oshinobu.core.string
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Побочные эффекты входящих, которые зависят от платформы. */
interface RouterHost {
    /** Логин чата, открытого прямо сейчас на экране (или null). */
    val openChatPeerLogin: String?
    val isAppInForeground: Boolean
    fun playMessageSound()
    /** Общее уведомление "новое сообщение" без содержимого — когда приложение свёрнуто. */
    fun showBackgroundMessageNotification()
    /** Короткая вибрация на чужую реакцию в открытом чате. */
    fun vibrate()
}

data class IncomingReaction(val peerLogin: String, val messageId: String)
data class IncomingDelete(val peerLogin: String, val targetIds: List<String>)

/** Владелец устройства-отправителя. */
data class DeviceOwnerRef(val accountId: String, val login: String)

/**
 * Единая точка входа для всех входящих конвертов (порт message_router.dart):
 * расшифровка, самолечение сессии, разбор по типу, ack серверу.
 *
 * Правила подтверждения (ack) — сердце надёжности:
 *  - успешно обработанное — ack;
 *  - дубль уже расшифрованного (AlreadyProcessed) — ack, сессию не трогаем;
 *  - сообщение под ключом прошлой эпохи ratchet — ack без счётчика сбоев
 *    (это либо поздний повтор прочитанного, либо необратимо потерянное);
 *  - сбой на ТЕКУЩЕМ ключе — без ack (сервер передоставит), после 3 подряд —
 *    ack + session_reset обеим сторонам;
 *  - нет сессии и нет X3DH-полей — 2 минуты ждём гонку доставки, потом ack.
 * Окончательно потерянное входящее сообщение становится заглушкой
 * "Не удалось дешифровать сообщение" в чате.
 */
class MessageRouter(
    private val transport: Transport,
    private val api: ApiClient,
    private val session: Session,
    private val keys: KeyStore,
    private val sessions: SessionStore,
    private val peerAccounts: PeerAccountStore,
    private val peerIdentities: PeerIdentityStore,
    private val chats: ChatStore,
    private val prefs: Prefs,
    private val queue: SendQueueProcessor,
    private val cleanup: MessageCleanup,
    private val sendLock: KeyedMutex,
    private val host: RouterHost,
    private val scope: CoroutineScope,
    private val log: Logger = NoopLogger,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private companion object {
        const val SESSION_RESET_TYPE = "session_reset"
        const val RESET_FAILURE_THRESHOLD = 3
        const val RESET_COOLDOWN_MS = 30_000L
        const val NO_SESSION_GIVE_UP_MS = 2 * 60_000L
        const val MAX_REMEMBERED_NONCES = 500

        /** Служебные типы: без звука и уведомления. */
        val SILENT_TYPES = setOf(
            MessageType.REACTION, MessageType.PIN, MessageType.EDIT, MessageType.DELETE,
            MessageType.CLEAR_CHAT, MessageType.DELETE_CHAT, MessageType.READ_RECEIPT,
        )

        fun failureCountKey(deviceId: String) = "session_reset_failcount:$deviceId"
        fun lastResetKey(deviceId: String) = "session_reset_last_request:$deviceId"
        fun noSessionFirstSeenKey(deviceId: String) = "no_session_first_seen:$deviceId"
        fun decryptedNoncesKey(deviceId: String) = "decrypted_nonces:$deviceId"
    }

    private val _reactions = MutableSharedFlow<IncomingReaction>(extraBufferCapacity = 64)
    private val _deletes = MutableSharedFlow<IncomingDelete>(extraBufferCapacity = 64)

    /** Чужая реакция поставлена — повод для анимации на пузыре. */
    val incomingReactions: SharedFlow<IncomingReaction> = _reactions.asSharedFlow()

    /** Собеседник удалил сообщения у обоих — открытый чат показывает анимацию до удаления. */
    val incomingDeletes: SharedFlow<IncomingDelete> = _deletes.asSharedFlow()

    private val ownerCache = ConcurrentHashMap<String, DeviceOwnerRef>()
    private var started = false

    fun start() {
        if (started) return
        started = true
        scope.launch { transport.messages.collect { handleIncoming(it) } }
    }

    /** Обработка одного входящего (публично — для тестов и для пуш-пробуждения). */
    suspend fun handleIncoming(incoming: IncomingEnvelope) {
        val senderDeviceId = incoming.envelope.optString("sender_device_id") ?: return
        sendLock.run(senderDeviceId) {
            try {
                process(senderDeviceId, incoming.envelope, incoming.deliveryId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.error("Router FAILED from=$senderDeviceId deliveryId=${incoming.deliveryId ?: "-"} error=$e")
            }
        }
    }

    private fun ack(deliveryId: String?) {
        if (deliveryId != null) transport.ackDelivery(deliveryId)
    }

    private suspend fun process(senderDeviceId: String, envelope: JsonObject, deliveryId: String?) {
        if (envelope.optString("type") == SESSION_RESET_TYPE) {
            // собеседник нашёл рассинхрон при чтении НАШИХ сообщений — начинаем с чистого листа
            log.log("Router session_reset received from=$senderDeviceId — clearing local session state")
            sessions.clear(senderDeviceId)
            clearFailureCount(senderDeviceId)
            ack(deliveryId)
            return
        }

        val inner = decrypt(senderDeviceId, envelope, deliveryId) ?: return
        val owner = resolveOwner(senderDeviceId)
        if (owner == null) {
            log.log("Router DROP from=$senderDeviceId reason=resolve-owner-failed")
            return
        }
        val chatIsOpen = host.openChatPeerLogin == owner.login
        apply(inner, owner, chatIsOpen)
        ack(deliveryId)

        if (!chatIsOpen && inner.type !in SILENT_TYPES && !chats.isChatMuted(owner.login)) {
            host.playMessageSound()
            if (!host.isAppInForeground) host.showBackgroundMessageNotification()
        }
    }

    // ---------------- расшифровка и самолечение ----------------

    /** null — расшифровать не удалось; ack/заглушка/сброс уже сделаны здесь по правилам выше. */
    private suspend fun decrypt(senderDeviceId: String, envelope: JsonObject, deliveryId: String?): InnerMessage? {
        var state = sessions.get(senderDeviceId)
        var isFreshSession = false
        if (state == null) {
            val fresh = establishFreshIncoming(senderDeviceId, envelope)
            if (fresh == null) {
                // нет сессии и нет X3DH: возможно, сообщение с инициализацией ещё в пути
                val gaveUp = giveUpIfNoSessionTooLong(senderDeviceId)
                log.log("Router DROP from=$senderDeviceId reason=no-session-and-no-handshake${if (gaveUp) " (gave up)" else ""}")
                if (gaveUp) {
                    ack(deliveryId)
                    recordUndecryptable(senderDeviceId, envelope)
                }
                return null
            }
            clearNoSessionFirstSeen(senderDeviceId)
            state = fresh
            isFreshSession = true
        }

        val raw = try {
            decryptMessage(state.nextReceivingKey(envelope), envelope)
        } catch (e: AlreadyProcessedException) {
            // безобидный дубль — сессия здорова, НЕ считаем сбоем
            log.log("Router IGNORING duplicate from=$senderDeviceId ${e.message}")
            ack(deliveryId)
            return null
        } catch (e: Exception) {
            log.error("Router decrypt-FAILED from=$senderDeviceId error=$e isFreshSession=$isFreshSession")
            // конверт мог нести X3DH-поля новой сессии, которую собеседник уже поднял
            val fresh = if (isFreshSession) null else establishFreshIncoming(senderDeviceId, envelope)
            if (fresh == null) {
                handleUnrecoverable(senderDeviceId, envelope, deliveryId, state)
                return null
            }
            try {
                decryptMessage(fresh.nextReceivingKey(envelope), envelope).also { state = fresh }
            } catch (e2: Exception) {
                // свежий 3-DH root не совпал с 4-DH собеседника (наш одноразовый ключ уже израсходован)
                log.error("Router: fresh X3DH re-decrypt ALSO failed ($e2) from=$senderDeviceId")
                if (onDecryptFailure(senderDeviceId, deliveryId)) recordUndecryptable(senderDeviceId, envelope)
                return null
            }
        }

        clearFailureCount(senderDeviceId)
        clearNoSessionFirstSeen(senderDeviceId)
        sessions.save(senderDeviceId, state!!)
        sessions.clearPendingInit(senderDeviceId)
        rememberDecrypted(senderDeviceId, envelope)
        return InnerMessage.decode(raw)
    }

    private suspend fun handleUnrecoverable(senderDeviceId: String, envelope: JsonObject, deliveryId: String?, state: RatchetState) {
        val incomingKey = envelope.optString("ratchet_pubkey")
        val currentKey = state.receivingRatchetPublicKey?.let { b64(it) }
        if (incomingKey != null && currentKey != null && incomingKey != currentKey) {
            // ключ прошлой эпохи: штатно необратимо — сессию не трогаем, сбоем не считаем
            log.log("Router giving up on stale-ratchet-key delivery from=$senderDeviceId (session left untouched)")
            ack(deliveryId)
            recordUndecryptable(senderDeviceId, envelope, requireKnownHistory = true)
            return
        }
        if (onDecryptFailure(senderDeviceId, deliveryId)) recordUndecryptable(senderDeviceId, envelope)
    }

    private suspend fun establishFreshIncoming(senderDeviceId: String, envelope: JsonObject): RatchetState? {
        val me = keys.loadIdentity() ?: return null
        val (state, x3dh) = PeerCipher.startIncomingSession(envelope, me) ?: return null
        x3dh.consumedOneTimePrekey?.let { keys.deleteOneTimePrekey(it) }
        if (x3dh.missingOneTimePrekey) {
            log.log("X3DH: sender claims a one-time prekey we no longer have — 3-DH only")
        }
        val newIdentityDh = envelope.string("sender_identity_dh_pubkey")
        val previous = peerIdentities.get(senderDeviceId)
        if (previous != null && previous != newIdentityDh) {
            // переустановка или подмена ключа — сами не отличим, но фиксируем громко
            log.error("Router SECURITY-WARNING identity_dh_pubkey CHANGED for from=$senderDeviceId")
        }
        peerIdentities.save(senderDeviceId, newIdentityDh)
        return state
    }

    /**
     * Подряд идущие сбои расшифровки (счётчик на диске — переживает убийство
     * процесса). На пороге: ack этой доставки и session_reset (не чаще раза в
     * 30 с). true — доставка признана окончательно потерянной.
     */
    private suspend fun onDecryptFailure(senderDeviceId: String, deliveryId: String?): Boolean {
        val count = (prefs.getLong(failureCountKey(senderDeviceId)) ?: 0) + 1
        prefs.setLong(failureCountKey(senderDeviceId), count)
        log.log("Router decrypt-failure-count from=$senderDeviceId count=$count")
        if (count < RESET_FAILURE_THRESHOLD) return false

        ack(deliveryId)
        val last = prefs.getLong(lastResetKey(senderDeviceId))
        if (last == null || now() - last >= RESET_COOLDOWN_MS) {
            prefs.setLong(lastResetKey(senderDeviceId), now())
            log.log("Router auto session-reset for=$senderDeviceId after $count consecutive decrypt failures")
            resetSessionWith(senderDeviceId, "auto ($count decrypt failures)")
        }
        return true
    }

    /**
     * Расшифровать сигнал звонка (внутри — JSON `{type, ...}`). Сессия у
     * звонков и сообщений общая, поэтому сбои и успехи участвуют в том же
     * самолечении. null — дубль или не удалось.
     */
    suspend fun openCallSignal(senderDeviceId: String, envelope: JsonObject): JsonObject? =
        sendLock.run(senderDeviceId) { openCallSignalLocked(senderDeviceId, envelope) }

    private suspend fun openCallSignalLocked(senderDeviceId: String, envelope: JsonObject): JsonObject? {
        try {
            val state = sessions.get(senderDeviceId) ?: establishFreshIncoming(senderDeviceId, envelope)
            if (state == null) {
                log.log("Router call signal from=$senderDeviceId: no session and no handshake")
                return null
            }
            val raw = decryptMessage(state.nextReceivingKey(envelope), envelope)
            sessions.save(senderDeviceId, state)
            sessions.clearPendingInit(senderDeviceId)
            clearFailureCount(senderDeviceId)
            return Json.parseToJsonElement(raw).jsonObject
        } catch (e: AlreadyProcessedException) {
            log.log("Router duplicate call signal from=$senderDeviceId ${e.message} — ignored")
            return null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("Router call signal decrypt-FAILED from=$senderDeviceId error=$e")
            onDecryptFailure(senderDeviceId, null)
            return null
        }
    }

    /**
     * Стереть сессию у себя и попросить собеседника сделать то же — следующая
     * отправка любой из сторон поднимет свежий X3DH. Также по кнопке
     * "Сбросить шифрование" и при очистке чата у обоих.
     */
    suspend fun resetSessionWith(deviceId: String, reason: String) {
        log.log("Router resetSessionWith device=$deviceId reason=$reason")
        sessions.clear(deviceId)
        val myDeviceId = keys.deviceId() ?: return
        queue.enqueue(
            toDeviceId = deviceId,
            envelope = buildJsonObject {
                put("type", SESSION_RESET_TYPE)
                put("sender_device_id", myDeviceId)
            },
            deliveryId = UUID.randomUUID().toString(),
            silent = true,
        )
    }

    private fun clearFailureCount(deviceId: String) = prefs.remove(failureCountKey(deviceId))

    private fun giveUpIfNoSessionTooLong(deviceId: String): Boolean {
        val firstSeen = prefs.getLong(noSessionFirstSeenKey(deviceId))
        if (firstSeen == null) {
            prefs.setLong(noSessionFirstSeenKey(deviceId), now())
            return false
        }
        return now() - firstSeen > NO_SESSION_GIVE_UP_MS
    }

    private fun clearNoSessionFirstSeen(deviceId: String) = prefs.remove(noSessionFirstSeenKey(deviceId))

    // ---------------- заглушка "не удалось дешифровать" ----------------

    /** Журнал nonce расшифрованных конвертов: отличает повтор прочитанного от настоящей потери. */
    private fun rememberDecrypted(deviceId: String, envelope: JsonObject) {
        val nonce = envelope.optString("nonce") ?: return
        val list = prefs.getStringList(decryptedNoncesKey(deviceId)).orEmpty()
        if (nonce in list) return
        prefs.setStringList(decryptedNoncesKey(deviceId), (list + nonce).takeLast(MAX_REMEMBERED_NONCES))
    }

    /**
     * Заглушка на месте окончательно потерянного конверта; id из nonce —
     * повторы того же конверта не плодят пузырей. [requireKnownHistory]: без
     * журнала nonce (первый запуск после обновления) повтор от потери не
     * отличить — молчим.
     */
    private suspend fun recordUndecryptable(deviceId: String, envelope: JsonObject, requireKnownHistory: Boolean = false) {
        val nonce = envelope.optString("nonce") ?: return
        val decrypted = prefs.getStringList(decryptedNoncesKey(deviceId))
        if (decrypted != null && nonce in decrypted) return
        if (requireKnownHistory && decrypted == null) return
        val owner = resolveOwner(deviceId) ?: return
        chats.addUndecryptableNotice(
            owner.login, "undecryptable_$nonce", now(), owner.accountId,
            incrementUnread = host.openChatPeerLogin != owner.login,
        )
    }

    // ---------------- владелец устройства ----------------

    /** device_id → (account_id, login): память → диск (PeerAccountStore + список чатов) → сеть. */
    suspend fun resolveOwner(deviceId: String): DeviceOwnerRef? {
        ownerCache[deviceId]?.let { return it }
        peerAccounts.get(deviceId)?.let { accountId ->
            chats.getKnownPeers().firstOrNull { it.lastKnownAccountId == accountId }?.let {
                return DeviceOwnerRef(accountId, it.peerLogin).also { ref -> ownerCache[deviceId] = ref }
            }
        }
        val token = session.token ?: return null
        val info = api.getDeviceOwnerInfo(token, deviceId) ?: return null
        peerAccounts.save(deviceId, info.accountId)
        return DeviceOwnerRef(info.accountId, info.login).also { ownerCache[deviceId] = it }
    }

    // ---------------- применение расшифрованного ----------------

    private suspend fun apply(inner: InnerMessage, owner: DeviceOwnerRef, chatIsOpen: Boolean) {
        val login = owner.login
        val unread = !chatIsOpen
        when (inner.type) {
            MessageType.TEXT -> chats.addMessage(
                login,
                StoredMessage(
                    inner.messageId, inner.body, false, inner.sentAt,
                    groupId = inner.groupId, replyToMessageId = inner.replyToMessageId, replyToPreview = inner.replyToPreview,
                ),
                owner.accountId, unread,
            )
            MessageType.MEDIA -> chats.addMessage(
                login,
                mediaMessage(inner.messageId, inner.bodyJson(), inner.sentAt, inner.groupId)
                    .copy(replyToMessageId = inner.replyToMessageId, replyToPreview = inner.replyToPreview),
                owner.accountId, unread,
            )
            MessageType.VOICE, MessageType.VIDEO_NOTE -> {
                val b = inner.bodyJson()
                val videoNote = inner.type == MessageType.VIDEO_NOTE
                chats.addMessage(
                    login,
                    StoredMessage(
                        inner.messageId, "", false, inner.sentAt,
                        isMedia = true, isVoice = !videoNote, isVideoNote = videoNote,
                        fileSize = b.optLong("file_size") ?: 0, chunked = b.optBool("chunked") ?: false,
                        durationMs = b.optLong("duration_ms"),
                        mediaId = b.string("media_id"), mediaKeyBase64 = b.string("key"),
                        mediaNonceBase64 = b.optString("nonce"), mediaMacBase64 = b.optString("mac"),
                        groupId = inner.groupId, replyToMessageId = inner.replyToMessageId, replyToPreview = inner.replyToPreview,
                    ),
                    owner.accountId, unread,
                )
            }
            MessageType.MEDIA_GROUP -> {
                val b = inner.bodyJson()
                val caption = b.optString("caption")
                val textMessageId = b.optString("text_message_id")
                val messages = buildList {
                    if (!caption.isNullOrEmpty() && textMessageId != null) {
                        add(StoredMessage(textMessageId, caption, false, inner.sentAt, groupId = inner.groupId))
                    }
                    b.optObjects("files").forEach { f -> add(mediaMessage(f.string("message_id"), f, inner.sentAt, inner.groupId)) }
                }
                chats.addMessages(login, messages, owner.accountId, unread)
            }
            MessageType.CALL_MISSED -> {
                // звонок не дошёл живьём (мы были офлайн) — подстраховка через офлайн-очередь
                val b = inner.bodyJson()
                chats.addCallLog(
                    login, "incoming", "missed", b.optLong("called_at") ?: inner.sentAt,
                    accountId = owner.accountId, incrementUnread = unread, callId = b.optString("call_id"),
                )
            }
            MessageType.REACTION -> {
                val b = inner.bodyJson()
                val target = b.optString("target_id") ?: return
                val emoji = b.optString("emoji")
                chats.setReaction(login, target, isMine = false, emoji = emoji)
                if (emoji != null) _reactions.tryEmit(IncomingReaction(login, target))
                if (chatIsOpen) host.vibrate()
            }
            MessageType.PIN -> {
                val b = inner.bodyJson()
                chats.setPinned(login, if (b.optBool("pinned") == true) b.optString("target_id") else null)
            }
            MessageType.EDIT -> {
                val b = inner.bodyJson()
                val target = b.optString("target_id")
                val text = b.optString("text")
                if (target != null && text != null) chats.editMessageText(login, target, text)
            }
            MessageType.DELETE -> {
                val targets = inner.bodyJson().optStrings("target_ids")
                if (targets.isNotEmpty()) _deletes.tryEmit(IncomingDelete(login, targets))
                val toPurge = chats.getMessages(login).filter { it.messageId in targets }
                chats.deleteMessages(login, targets)
                cleanup.purgeAll(toPurge)
            }
            MessageType.CLEAR_CHAT -> {
                val all = chats.getMessages(login)
                chats.clearHistory(login)
                cleanup.purgeAll(all)
            }
            MessageType.DELETE_CHAT -> {
                val all = chats.getMessages(login)
                chats.removeChat(login)
                cleanup.purgeAll(all)
            }
            MessageType.READ_RECEIPT -> chats.markMessagesRead(login, inner.bodyJson().optStrings("target_ids"))
            else -> log.log("Router: unknown inner type=${inner.type} — ignored")
        }
    }

    /** Входящее фото/видео/файл (body 'media' или элемент 'media_group'). */
    private fun mediaMessage(messageId: String, b: JsonObject, sentAt: Long, groupId: String?) = StoredMessage(
        messageId = messageId,
        text = "",
        isMine = false,
        timestamp = sentAt,
        isMedia = true,
        isFile = b.optBool("is_file") ?: false,
        isVideo = b.optBool("is_video") ?: false,
        fileSize = b.optLong("file_size") ?: 0,
        chunked = b.optBool("chunked") ?: false,
        isSpoiler = b.optBool("spoiler") ?: false,
        mediaId = b.string("media_id"),
        mediaKeyBase64 = b.string("key"),
        mediaNonceBase64 = b.optString("nonce"),
        mediaMacBase64 = b.optString("mac"),
        fileName = b.optString("file_name"),
        groupId = groupId,
    )
}
