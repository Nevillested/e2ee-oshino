package com.oshinobu.core.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

// WebSocket к серверу — порт client/lib/services/websocket_service.dart.
//
// Внешние кадры сервера: {"Type", "DeliveryId", "Ciphertext", ...}.
//  - "ack"                   — сервер принял наш конверт (DeliveryId);
//  - "presence"/"typing"     — присутствие собеседника;
//  - "block_status_changed"  — кто-то (раз)блокировал;
//  - "profile_updated"       — {AccountId, Field};
//  - "call_*"                — сигнал звонка; ack шлём СРАЗУ, сам сигнал —
//                              в callSignals (Ciphertext → JSON + "type");
//  - остальное с Ciphertext  — зашифрованный конверт сообщения; DeliveryId
//                              подтверждаем только ПОСЛЕ обработки (ackDelivery).

enum class ConnectionStatus { WAITING_FOR_NETWORK, CONNECTING, CONNECTED, RECONNECTING }

class IncomingEnvelope(val envelope: JsonObject, val deliveryId: String?)

data class ProfileChange(val accountId: String, val field: String)

/**
 * То, что сервисам нужно от соединения с сервером. Реализует [WebSocketClient];
 * в тестах — фейковый сервер в памяти.
 */
interface Transport {
    val status: StateFlow<ConnectionStatus>
    val messages: SharedFlow<IncomingEnvelope>
    val acks: SharedFlow<String>
    val isConnected: Boolean
    fun sendEnvelope(toDeviceId: String, envelope: JsonObject, deliveryId: String, silent: Boolean = false)
    fun ackDelivery(deliveryId: String)
}

/** Канал сигналов звонка: входящие уже разобраны в JSON с полем "type". */
interface CallSignaling {
    val callSignals: SharedFlow<JsonObject>
    suspend fun sendCallSignal(toDeviceId: String, type: String, payload: JsonObject): Boolean
}

class WebSocketClient(
    private val api: ApiClient,
    private val scope: CoroutineScope,
    private val okHttp: OkHttpClient = api.versioned(OkHttpClient.Builder().pingInterval(45, TimeUnit.SECONDS).build()),
    private val readyTimeoutMs: Long = 8_000,
    private val reconnectDelayMs: Long = 3_000,
    private val callSignalWaitMs: Long = 5_000,
    private val log: (String) -> Unit = {},
) : Transport, CallSignaling {
    private val _status = MutableStateFlow(ConnectionStatus.CONNECTING)
    override val status: StateFlow<ConnectionStatus> = _status.asStateFlow()

    private fun <T> events() = MutableSharedFlow<T>(extraBufferCapacity = 1024)
    private val _messages = events<IncomingEnvelope>()
    private val _callSignals = events<JsonObject>()
    private val _presence = events<JsonObject>()
    private val _blockStatus = events<Unit>()
    private val _profileChanges = events<ProfileChange>()
    private val _acks = events<String>()
    private val _sessionInvalidated = events<Unit>()

    override val messages: SharedFlow<IncomingEnvelope> = _messages.asSharedFlow()
    override val callSignals: SharedFlow<JsonObject> = _callSignals.asSharedFlow()
    val presenceEvents: SharedFlow<JsonObject> = _presence.asSharedFlow()
    val blockStatusEvents: SharedFlow<Unit> = _blockStatus.asSharedFlow()
    val profileChanges: SharedFlow<ProfileChange> = _profileChanges.asSharedFlow()
    override val acks: SharedFlow<String> = _acks.asSharedFlow()
    val sessionInvalidated: SharedFlow<Unit> = _sessionInvalidated.asSharedFlow()

    private val lock = Any()
    private var socket: WebSocket? = null
    /** Растёт на каждое новое соединение — колбэки старых сокетов игнорируются. */
    private var generation = 0
    private var token: String? = null
    private var deviceId: String? = null
    private var manuallyDisconnected = false
    private var hadNetwork = true
    private var reconnectJob: Job? = null
    private var readyTimeoutJob: Job? = null
    /** Видит ли человек приложение (сообщает Activity); пока не сообщила — нет: процесс мог поднять пуш. */
    private var lastKnownForeground = false

    /**
     * Реально готов к отправке. Объект сокета появляется сразу при открытии, а
     * рукопожатие идёт до readyTimeoutMs — всё это время отправлять нельзя
     * (во Flutter это был КРИТИЧНЫЙ баг: данные тихо терялись).
     */
    override val isConnected: Boolean get() = synchronized(lock) { socket != null } && _status.value == ConnectionStatus.CONNECTED

    private fun setStatus(s: ConnectionStatus) {
        if (_status.value != s) {
            _status.value = s
            log("WS status -> $s")
        }
    }

    fun connect(token: String, deviceId: String) {
        synchronized(lock) {
            this.token = token
            this.deviceId = deviceId
            manuallyDisconnected = false
            closeCurrentLocked()
        }
        openConnection()
    }

    fun disconnect() {
        synchronized(lock) {
            manuallyDisconnected = true
            reconnectJob?.cancel()
            closeCurrentLocked()
        }
    }

    /** Сеть появилась (из ConnectivityManager на Android) — переподключаемся сразу. */
    fun onNetworkAvailable() {
        val wasOffline = synchronized(lock) { (!hadNetwork).also { hadNetwork = true } }
        if (wasOffline) forceReconnect()
    }

    fun onNetworkLost() {
        synchronized(lock) { hadNetwork = false }
        setStatus(ConnectionStatus.WAITING_FOR_NETWORK)
    }

    private fun forceReconnect() {
        synchronized(lock) {
            if (manuallyDisconnected) return
            reconnectJob?.cancel()
            closeCurrentLocked()
        }
        openConnection()
    }

    private fun closeCurrentLocked() {
        generation++
        readyTimeoutJob?.cancel()
        socket?.cancel()
        socket = null
    }

    private fun openConnection() {
        val (gen, request) = synchronized(lock) {
            val t = token ?: return
            val d = deviceId ?: return
            generation++
            generation to Request.Builder()
                .url("${api.config.wsBaseUrl}/ws?device_id=$d")
                .header("Authorization", "Bearer $t")
                .build()
        }
        setStatus(ConnectionStatus.CONNECTING)
        val ws = okHttp.newWebSocket(request, Listener(gen))
        synchronized(lock) {
            if (gen != generation) {
                ws.cancel()
                return
            }
            socket = ws
            readyTimeoutJob = scope.launch {
                delay(readyTimeoutMs)
                if (isCurrent(gen) && _status.value != ConnectionStatus.CONNECTED) {
                    log("WS connect timeout — will retry")
                    scheduleReconnect(gen)
                }
            }
        }
    }

    private fun isCurrent(gen: Int) = synchronized(lock) { gen == generation }

    private fun scheduleReconnect(gen: Int) {
        synchronized(lock) {
            if (gen != generation) return
            generation++
            readyTimeoutJob?.cancel()
            socket?.cancel()
            socket = null
            if (manuallyDisconnected) return
            setStatus(if (hadNetwork) ConnectionStatus.RECONNECTING else ConnectionStatus.WAITING_FOR_NETWORK)
            reconnectJob?.cancel()
            reconnectJob = scope.launch {
                delay(reconnectDelayMs)
                val t = synchronized(lock) { token }
                if (t != null && api.checkSession(t) == false) {
                    // вошли с другого устройства — переподключаться бессмысленно
                    log("WS session invalid — stopping reconnect")
                    synchronized(lock) { manuallyDisconnected = true }
                    _sessionInvalidated.tryEmit(Unit)
                    return@launch
                }
                // гонка с forceReconnect — не плодим второе соединение
                if (synchronized(lock) { socket != null || manuallyDisconnected }) return@launch
                openConnection()
            }
        }
    }

    private inner class Listener(private val gen: Int) : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            if (!isCurrent(gen)) return
            synchronized(lock) { readyTimeoutJob?.cancel() }
            setStatus(ConnectionStatus.CONNECTED)
            sendForegroundState(lastKnownForeground)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (!isCurrent(gen)) return
            try {
                handleFrame(Json.parseToJsonElement(text).jsonObject)
            } catch (e: Exception) {
                log("WS recv: failed to parse frame: $e")
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            log("WS closed code=$code reason=$reason — reconnecting")
            scheduleReconnect(gen)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (response?.code == ApiClient.HTTP_UPGRADE_REQUIRED) {
                // эта версия приложения больше не обслуживается — переподключаться бессмысленно
                log("WS rejected: app version not supported")
                return
            }
            log("WS failure: $t — reconnecting")
            scheduleReconnect(gen)
        }
    }

    private fun JsonObject.str(name: String) = (this[name] as? JsonPrimitive)?.contentOrNull

    private fun handleFrame(outer: JsonObject) {
        val type = outer.str("Type")
        val deliveryId = outer.str("DeliveryId")?.takeIf { it.isNotEmpty() }
        when {
            type == "ack" -> deliveryId?.let { _acks.tryEmit(it) }
            type == "presence" || type == "typing" -> _presence.tryEmit(outer)
            type == "block_status_changed" -> {
                log("WS recv block_status_changed")
                _blockStatus.tryEmit(Unit)
            }
            type == "profile_updated" -> {
                val accountId = outer.str("AccountId")
                val field = outer.str("Field")
                log("WS recv profile_updated account=$accountId field=$field")
                if (accountId != null && field != null) _profileChanges.tryEmit(ProfileChange(accountId, field))
            }
            type != null && type.startsWith("call_") -> {
                // сигналы звонка подтверждаем сразу — их обработка не идемпотентна
                deliveryId?.let { send(ackFrame(it)) }
                log("WS recv $type")
                val payload = outer.str("Ciphertext")?.let { Json.parseToJsonElement(it).jsonObject } ?: JsonObject(emptyMap())
                _callSignals.tryEmit(JsonObject(payload + ("type" to JsonPrimitive(type))))
            }
            else -> outer.str("Ciphertext")?.let {
                _messages.tryEmit(IncomingEnvelope(Json.parseToJsonElement(it).jsonObject, deliveryId))
            }
        }
    }

    private fun ackFrame(deliveryId: String) = buildJsonObject {
        put("Type", "ack")
        put("DeliveryId", deliveryId)
    }

    private fun send(frame: JsonObject): Boolean = synchronized(lock) { socket }?.send(frame.toString()) ?: false

    /** Подтвердить серверу, что входящий конверт обработан (иначе он придёт снова). */
    override fun ackDelivery(deliveryId: String) {
        if (isConnected) send(ackFrame(deliveryId))
    }

    /** Бросает [IllegalStateException], если соединения нет: вызывающий кладёт конверт в очередь. */
    override fun sendEnvelope(toDeviceId: String, envelope: JsonObject, deliveryId: String, silent: Boolean) {
        check(isConnected) { "WebSocket не подключен" }
        send(
            buildJsonObject {
                put("ToDeviceId", toDeviceId)
                put("Ciphertext", envelope.toString())
                put("Type", "message")
                put("DeliveryId", deliveryId)
                put("Silent", silent)
            },
        )
    }

    /**
     * Сигналы звонка не идут через очередь — если соединение как раз
     * переоткрывается, даём ему [callSignalWaitMs], прежде чем сдаться.
     */
    override suspend fun sendCallSignal(toDeviceId: String, type: String, payload: JsonObject): Boolean {
        val frame = buildJsonObject {
            put("ToDeviceId", toDeviceId)
            put("Ciphertext", payload.toString())
            put("Type", type)
        }
        if (isConnected) return send(frame).also { log("WS send $type to=$toDeviceId ok=$it") }
        log("WS send $type: not connected, waiting up to ${callSignalWaitMs}ms")
        val ready = withTimeoutOrNull(callSignalWaitMs) { status.first { it == ConnectionStatus.CONNECTED } } != null
        if (ready && isConnected) return send(frame).also { log("WS send $type to=$toDeviceId ok=$it (after reconnect)") }
        log("WS sendCallSignal type=$type DROPPED — no connection within ${callSignalWaitMs}ms")
        return false
    }

    fun subscribePresence(peerDeviceId: String) {
        send(buildJsonObject { put("Type", "presence_subscribe"); put("ToDeviceId", peerDeviceId) })
    }

    fun unsubscribePresence(peerDeviceId: String) {
        send(buildJsonObject { put("Type", "presence_unsubscribe"); put("ToDeviceId", peerDeviceId) })
    }

    fun sendForegroundState(foreground: Boolean) {
        lastKnownForeground = foreground
        send(buildJsonObject { put("Type", "presence_foreground"); put("Foreground", foreground) })
    }

    fun sendTyping(peerDeviceId: String) {
        send(buildJsonObject { put("Type", "typing"); put("ToDeviceId", peerDeviceId) })
    }
}
