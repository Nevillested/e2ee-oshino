package com.oshinobu.core.service

import com.oshinobu.core.net.ConnectionStatus
import com.oshinobu.core.net.Transport
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.MessageStatus
import com.oshinobu.core.storage.SendQueueStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import com.oshinobu.core.optBool
import com.oshinobu.core.optString
import com.oshinobu.core.string
import kotlinx.serialization.json.jsonObject
import java.util.Collections

/**
 * Надёжная исходящая очередь (порт send_queue_processor.dart): готовый
 * конверт сначала ложится на диск, и уходит из очереди ТОЛЬКО по ack
 * сервера. Нет соединения — ждёт реконнекта; ack не пришёл за 8 с —
 * продолжаем слушать опоздавший ack в фоне, а при следующем реконнекте
 * конверт уходит снова (дубли на приёме гасятся по message_id).
 */
class SendQueueProcessor(
    private val store: SendQueueStore,
    private val transport: Transport,
    private val acks: AckRegistry,
    private val chats: ChatStore,
    private val scope: CoroutineScope,
    private val log: Logger = NoopLogger,
    private val ackTimeoutMs: Long = 8_000,
) {
    private val inFlight = Collections.synchronizedSet(HashSet<String>())
    private val onAckedCallbacks = java.util.concurrent.ConcurrentHashMap<String, suspend () -> Unit>()
    private var started = false

    fun start() {
        if (started) return
        started = true
        scope.launch {
            transport.status.collect { if (it == ConnectionStatus.CONNECTED) sweep() }
        }
    }

    /**
     * [messageId]+[peerLogin] — пометить сообщение 'sent' по ack;
     * [onAcked] — доп. действие по ack (только пока процесс жив).
     */
    suspend fun enqueue(
        toDeviceId: String,
        envelope: JsonObject,
        deliveryId: String,
        silent: Boolean = false,
        messageId: String? = null,
        peerLogin: String? = null,
        onAcked: (suspend () -> Unit)? = null,
    ) {
        store.add(deliveryId, toDeviceId, envelope, silent, messageId, peerLogin)
        if (onAcked != null) onAckedCallbacks[deliveryId] = onAcked
        scope.launch { attempt(deliveryId, toDeviceId, envelope, silent, messageId, peerLogin) }
    }

    /** Переотправить всё, что лежит в очереди (на каждый реконнект). */
    suspend fun sweep() {
        val items = store.getAll()
        if (items.isNotEmpty()) log.log("SendQueueProcessor sweep: ${items.size} item(s) pending")
        for (item in items) {
            scope.launch {
                attempt(
                    item.string("id"), item.string("to_device_id"), item["envelope"]!!.jsonObject,
                    item.optBool("silent") ?: false, item.optString("message_id"), item.optString("peer_login"),
                )
            }
        }
    }

    private suspend fun attempt(id: String, toDeviceId: String, envelope: JsonObject, silent: Boolean, messageId: String?, peerLogin: String?) {
        if (!inFlight.add(id)) return // уже в полёте — не дублируем попытку
        try {
            val ack = acks.waiter(id)
            try {
                transport.sendEnvelope(toDeviceId, envelope, id, silent)
            } catch (e: Exception) {
                acks.cancel(id)
                log.log("SendQueueProcessor id=$id not sent (offline): $e")
                return
            }
            try {
                withTimeout(ackTimeoutMs) { ack.await() }
            } catch (_: TimeoutCancellationException) {
                log.log("SendQueueProcessor id=$id no ack within timeout — still listening for a late ack")
                scope.launch {
                    try {
                        ack.await()
                    } catch (_: Exception) {
                        return@launch
                    }
                    finalizeAcked(id, messageId, peerLogin)
                }
                return
            } catch (_: kotlinx.coroutines.CancellationException) {
                return // ожидание отменено (сообщение удалено/отменено)
            }
            finalizeAcked(id, messageId, peerLogin)
        } finally {
            inFlight.remove(id)
        }
    }

    private suspend fun finalizeAcked(id: String, messageId: String?, peerLogin: String?) {
        store.remove(id)
        if (messageId != null && peerLogin != null) chats.updateMessageStatus(peerLogin, messageId, MessageStatus.SENT)
        onAckedCallbacks.remove(id)?.invoke()
    }
}
