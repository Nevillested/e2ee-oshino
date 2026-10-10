package com.oshinobu.core.service

import com.oshinobu.core.net.ApiClient
import com.oshinobu.core.net.CallSignaling
import com.oshinobu.core.optBool
import com.oshinobu.core.optInt
import com.oshinobu.core.optString
import com.oshinobu.core.protocol.InnerMessage
import com.oshinobu.core.storage.ChatStore
import com.oshinobu.core.storage.Session
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID

enum class CallState { IDLE, OUTGOING_RINGING, INCOMING_RINGING, CONNECTED }

data class IceServer(val urls: List<String>, val username: String? = null, val credential: String? = null)

enum class SignalingState { STABLE, HAVE_LOCAL_OFFER, OTHER }

/** WebRTC-соединение одного звонка (на Android — org.webrtc в модуле :app). */
interface RtcSession {
    val signalingState: SignalingState

    /** Создать offer и поставить его локальным описанием; вернуть SDP. */
    suspend fun createOffer(): String

    /** Создать answer и поставить его локальным описанием; вернуть SDP. */
    suspend fun createAnswer(): String

    /** [type] — "offer" или "answer". */
    suspend fun setRemoteDescription(type: String, sdp: String)

    /** Откат своего offer при встречном (perfect negotiation, вежливая сторона). */
    suspend fun rollback()

    suspend fun addIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int)

    /** Микрофон в соединение. */
    suspend fun startAudio(micEnabled: Boolean)

    fun setMicEnabled(enabled: Boolean)

    /** Камера вкл/выкл; в первый раз за звонок добавляет видеодорожку (→ renegotiation). */
    suspend fun setVideoEnabled(enabled: Boolean)

    /** Сменить камеру; true — теперь фронтальная. */
    suspend fun switchCamera(): Boolean

    fun close()
}

/** События соединения — из потоков WebRTC; менеджер сам переносит их к себе. */
interface RtcEvents {
    fun onIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int)
    fun onConnected()
    fun onFailed()
    fun onRenegotiationNeeded()
}

fun interface RtcEngine {
    fun createSession(iceServers: List<IceServer>, events: RtcEvents): RtcSession
}

/** С кем звонок. login/accountId выясняются по device_id, если звонок входящий. */
data class CallPeer(val deviceId: String, val login: String? = null, val accountId: String? = null)

data class IncomingCall(val callId: String, val peer: CallPeer)

/**
 * Звонки (порт call_service.dart): сигнальный протокол поверх зашифрованного
 * канала (сигналы шифруются той же сессией ratchet, что и сообщения), само
 * медиа — WebRTC за интерфейсом [RtcEngine].
 *
 *  - исходящий: offer → (answer) → connected; отмена — call_cancel;
 *  - входящий: offer → incomingRinging → accept (answer) / decline (call_reject);
 *    второй звонок поверх идущего — call_busy;
 *  - смена дорожек посреди звонка — renegotiation по правилу perfect
 *    negotiation (вежливая сторона — принимающая);
 *  - по окончании — запись звонка в чат; если сервер сказал, что собеседник
 *    недоступен, — ему уходит "пропущенный звонок".
 *
 * Вся работа идёт на одном последовательном диспетчере — как в однопоточном
 * Dart, без гонок между сигналами и действиями пользователя.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class CallManager(
    private val signaling: CallSignaling,
    private val messenger: PeerMessenger,
    private val router: MessageRouter,
    private val api: ApiClient,
    private val session: Session,
    private val chats: ChatStore,
    private val engine: RtcEngine,
    private val scope: CoroutineScope,
    private val log: Logger = NoopLogger,
    private val now: () -> Long = System::currentTimeMillis,
    private val endReasonDelayMs: Long = 1_800,
    /** Сколько звонить без ответа — столько же, сколько callRingTTL на сервере и звонок по пушу. */
    private val ringTimeoutMs: Long = 120_000,
    /** Сколько ждать один шаг установки соединения (WebRTC), прежде чем считать, что он завис. */
    private val stepTimeoutMs: Long = 20_000,
) {
    private companion object {
        /** Эти сигналы принимаются только от собеседника текущего звонка. */
        val REQUIRES_ACTIVE_PEER = setOf("call_answer", "call_ice", "call_video_state", "call_reject", "call_busy", "call_cancel", "call_end")
        const val STUN = "stun:stun.l.google.com:19302"
    }

    private val dispatcher = Dispatchers.Default.limitedParallelism(1)

    private val _state = MutableStateFlow(CallState.IDLE)
    private val _status = MutableStateFlow<String?>(null)
    private val _peer = MutableStateFlow<CallPeer?>(null)
    private val _connectedAt = MutableStateFlow<Long?>(null)
    private val _micEnabled = MutableStateFlow(true)
    private val _videoEnabled = MutableStateFlow(false)
    private val _remoteVideoEnabled = MutableStateFlow(false)
    private val _usingFrontCamera = MutableStateFlow(true)
    private val _incoming = MutableSharedFlow<IncomingCall>(extraBufferCapacity = 4)
    private val _openCallScreen = MutableSharedFlow<Unit>(extraBufferCapacity = 4)

    val state: StateFlow<CallState> = _state.asStateFlow()

    /** Этап установки соединения или причина завершения — ключ локализации ("call.ringing"…). */
    val status: StateFlow<String?> = _status.asStateFlow()
    val peer: StateFlow<CallPeer?> = _peer.asStateFlow()

    /** Когда соединение установилось (для таймера разговора). */
    val connectedAt: StateFlow<Long?> = _connectedAt.asStateFlow()
    val micEnabled: StateFlow<Boolean> = _micEnabled.asStateFlow()
    val videoEnabled: StateFlow<Boolean> = _videoEnabled.asStateFlow()
    val remoteVideoEnabled: StateFlow<Boolean> = _remoteVideoEnabled.asStateFlow()
    val usingFrontCamera: StateFlow<Boolean> = _usingFrontCamera.asStateFlow()

    /** Входящий звонок — показать экран входящего. */
    val incomingCalls: SharedFlow<IncomingCall> = _incoming.asSharedFlow()

    /** Звонок принят без экрана входящего (кнопкой в уведомлении) — открыть экран звонка. */
    val openCallScreen: SharedFlow<Unit> = _openCallScreen.asSharedFlow()

    val callId: String? get() = currentCallId

    private var rtc: RtcSession? = null
    private var currentCallId: String? = null
    private var pendingOfferSdp: String? = null
    private var remoteDescriptionSet = false
    private val pendingCandidates = ArrayList<Triple<String, String?, Int>>()
    private var startedAt: Long? = null
    private var isOutgoing = false
    private var makingOffer = false
    private var accepting = false
    private var autoAcceptPending = false
    private var started = false
    private var ringTimeout: Job? = null

    /** Вежливая сторона уступает при встречных offer — это принимающая звонок. */
    private val polite: Boolean get() = !isOutgoing

    private suspend fun <T> onCallThread(block: suspend () -> T): T = withContext(dispatcher) { block() }

    fun start() {
        if (started) return
        started = true
        scope.launch(dispatcher) { signaling.callSignals.collect { runCatchingLogged("handleSignal") { handleSignal(it) } } }
    }

    private suspend fun runCatchingLogged(what: String, block: suspend () -> Unit) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("CallManager $what FAILED: $e")
        }
    }

    private fun setState(s: CallState) {
        log.log("CallManager state ${_state.value} -> $s")
        _state.value = s
    }

    // ---------------- действия пользователя ----------------

    suspend fun startCall(peer: CallPeer) = onCallThread {
        if (_state.value != CallState.IDLE) return@onCallThread
        log.log("CallManager startCall to=${peer.deviceId}")
        currentCallId = UUID.randomUUID().toString()
        _peer.value = peer
        resetMediaFlags()
        remoteDescriptionSet = false
        pendingCandidates.clear()
        startedAt = now()
        _connectedAt.value = null
        isOutgoing = true
        setState(CallState.OUTGOING_RINGING)
        try {
            _status.value = "call.securingConnection"
            // собеседник мог переустановить приложение, пока у нас открыт чат: звоним на его
            // нынешнее устройство — старое не в сети, и пуш туда уже не придёт
            peer.login?.let { login ->
                val current = messenger.resolvePeerDeviceId(login, peer.deviceId)
                if (current != peer.deviceId) {
                    log.log("CallManager startCall: peer device changed ${peer.deviceId} -> $current")
                    _peer.value = peer.copy(deviceId = current)
                }
            }
            val session = createSession()
            step("call.enablingMic") { session.startAudio(_micEnabled.value) }
            val offer = step("call.buildingOffer") { session.createOffer() }
            if (!send("call_offer", buildJsonObject { put("sdp", offer) })) {
                // сервер offer не получил — собеседнику не позвонит никто, гудеть незачем;
                // в историю такой звонок не пишем: он никуда не ушёл
                log.log("CallManager startCall: offer not sent — no connection")
                startedAt = null
                endWithReason("call.noConnection")
                return@onCallThread
            }
            _status.value = "call.ringing"
            armRingTimeout()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("CallManager startCall FAILED: $e")
            resetLocal()
        }
    }

    suspend fun acceptCall() = onCallThread { acceptLocked() }

    private suspend fun acceptLocked() {
        val offer = pendingOfferSdp
        if (offer == null || accepting || _state.value == CallState.CONNECTED) {
            log.log("CallManager accept SKIP pendingOffer=${offer != null} accepting=$accepting state=${_state.value}")
            return
        }
        accepting = true
        try {
            resetMediaFlags()
            _status.value = "call.securingConnection"
            val session = createSession()
            step("call.securingConnection") { session.setRemoteDescription("offer", offer) }
            remoteDescriptionSet = true
            flushPendingCandidates(session)
            step("call.enablingMic") { session.startAudio(_micEnabled.value) }
            val answer = step("call.buildingAnswer") { session.createAnswer() }
            send("call_answer", buildJsonObject { put("sdp", answer) })
            _status.value = "call.connecting"
            setState(CallState.CONNECTED)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("CallManager accept FAILED: $e")
            send("call_end", JsonObject(emptyMap()))
            resetLocal()
        } finally {
            accepting = false
        }
    }

    suspend fun declineCall() = onCallThread {
        if (_state.value == CallState.IDLE) return@onCallThread
        send("call_reject", JsonObject(emptyMap()))
        resetLocal()
    }

    suspend fun cancelCall() = onCallThread {
        if (_state.value == CallState.IDLE) return@onCallThread
        send("call_cancel", JsonObject(emptyMap()))
        resetLocal()
    }

    suspend fun endCall(notifyRemote: Boolean = true) = onCallThread {
        if (_state.value == CallState.IDLE) return@onCallThread
        if (notifyRemote) send("call_end", JsonObject(emptyMap()))
        resetLocal()
    }

    /** Красная кнопка: пока исходящий не ответили — отмена, иначе — завершение. */
    suspend fun hangUp() {
        if (_state.value == CallState.OUTGOING_RINGING) cancelCall() else endCall()
    }

    /**
     * "Ответить" нажали в уведомлении, когда приложение не было на связи:
     * offer ещё придёт после подключения — принять его сразу, без экрана входящего.
     */
    suspend fun requestAutoAccept() = onCallThread {
        if (_state.value == CallState.INCOMING_RINGING && pendingOfferSdp != null) autoAcceptAndOpen() else autoAcceptPending = true
    }

    private suspend fun autoAcceptAndOpen() {
        resolvePeer()
        acceptLocked()
        _openCallScreen.tryEmit(Unit)
    }

    suspend fun toggleMic() = onCallThread {
        _micEnabled.value = !_micEnabled.value
        rtc?.setMicEnabled(_micEnabled.value)
    }

    suspend fun toggleVideo() = onCallThread {
        val session = rtc ?: return@onCallThread
        val enabled = !_videoEnabled.value
        try {
            session.setVideoEnabled(enabled)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("CallManager toggleVideo FAILED: $e")
            return@onCallThread
        }
        _videoEnabled.value = enabled
        send("call_video_state", buildJsonObject { put("enabled", enabled) })
    }

    suspend fun switchCamera() = onCallThread {
        val session = rtc ?: return@onCallThread
        if (!_videoEnabled.value) return@onCallThread
        try {
            _usingFrontCamera.value = session.switchCamera()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("CallManager switchCamera FAILED: $e")
        }
    }

    // ---------------- соединение ----------------

    private suspend fun iceServers(): List<IceServer> {
        val stun = IceServer(listOf(STUN))
        val token = session.token ?: return listOf(stun)
        val creds = api.getTurnCredentials(token) ?: return listOf(stun)
        val urls = creds["urls"]?.let { el ->
            runCatching { el.jsonArray.map { it.jsonPrimitive.content } }.getOrElse { listOf(el.jsonPrimitive.content) }
        } ?: return listOf(stun)
        return listOf(stun, IceServer(urls, creds.optString("username"), creds.optString("password")))
    }

    /**
     * Шаг установки соединения: этап — на экран и в журнал. WebRTC не ответил
     * за [stepTimeoutMs] — ошибка (звонок завершается, журнал уходит в
     * диагностику), а не вечное "формируем ответ".
     */
    private suspend fun <T> step(status: String, block: suspend () -> T): T {
        _status.value = status
        log.log("CallManager step $status")
        return try {
            withTimeout(stepTimeoutMs) { block() }
        } catch (e: TimeoutCancellationException) {
            throw IllegalStateException("WebRTC step $status timed out after ${stepTimeoutMs}ms")
        }
    }

    private suspend fun createSession(): RtcSession {
        val events = object : RtcEvents {
            override fun onIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int) {
                scope.launch(dispatcher) {
                    send(
                        "call_ice",
                        buildJsonObject {
                            put("candidate", candidate)
                            put("sdpMid", sdpMid)
                            put("sdpMLineIndex", sdpMLineIndex)
                        },
                    )
                }
            }

            override fun onConnected() {
                scope.launch(dispatcher) {
                    if (_connectedAt.value == null) _connectedAt.value = now()
                    if (_state.value != CallState.CONNECTED && _state.value != CallState.IDLE) setState(CallState.CONNECTED)
                }
            }

            override fun onFailed() {
                scope.launch(dispatcher) {
                    log.log("CallManager connection FAILED — ending call")
                    if (_state.value != CallState.IDLE) {
                        send("call_end", JsonObject(emptyMap()))
                        resetLocal()
                    }
                }
            }

            override fun onRenegotiationNeeded() {
                scope.launch(dispatcher) { if (_state.value == CallState.CONNECTED) renegotiate() }
            }
        }
        val servers = iceServers()
        log.log("CallManager createSession ice=${servers.size}")
        val session = engine.createSession(servers, events)
        rtc = session
        return session
    }

    private suspend fun renegotiate() {
        val session = rtc ?: return
        makingOffer = true
        try {
            val offer = session.createOffer()
            send(
                "call_offer",
                buildJsonObject {
                    put("sdp", offer)
                    put("renegotiation", true)
                },
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("CallManager renegotiate FAILED (signaling=${session.signalingState}): $e")
        } finally {
            makingOffer = false
        }
    }

    private suspend fun flushPendingCandidates(session: RtcSession) {
        for ((c, mid, index) in pendingCandidates) session.addIceCandidate(c, mid, index)
        pendingCandidates.clear()
    }

    private fun resetMediaFlags() {
        _micEnabled.value = true
        _videoEnabled.value = false
        _remoteVideoEnabled.value = false
        _usingFrontCamera.value = true
    }

    // ---------------- сигналы ----------------

    /** false — сигнал не ушёл на сервер (нет соединения или не зашифровался). */
    private suspend fun send(type: String, payload: JsonObject): Boolean {
        val to = _peer.value?.deviceId ?: return false
        return sendTo(to, type, payload, currentCallId)
    }

    private suspend fun sendTo(toDeviceId: String, type: String, payload: JsonObject, callId: String?): Boolean {
        val envelope = try {
            messenger.sealCallSignal(toDeviceId, JsonObject(payload + ("type" to JsonPrimitive(type))))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("CallManager encrypt-FAILED type=$type to=$toDeviceId: $e — dropped")
            return false
        }
        return signaling.sendCallSignal(toDeviceId, type, JsonObject(envelope + ("call_id" to JsonPrimitive(callId))))
    }

    private suspend fun handleSignal(envelope: JsonObject) {
        val type = envelope.optString("type") ?: return
        if (type == "call_unavailable") {
            if (_state.value != CallState.IDLE) resetLocal(peerWasUnavailable = true)
            return
        }
        val sender = envelope.optString("sender_device_id")
        if (sender == null) {
            // сервер отклонил звонок за собеседника (кнопка в уведомлении, когда его
            // приложение было не на связи) — такой сигнал не зашифрован и без отправителя
            if (_state.value == CallState.OUTGOING_RINGING && (type == "call_reject" || type == "call_busy")) {
                endWithReason(if (type == "call_busy") "call.busy" else "call.declined")
            }
            return
        }
        val activePeer = _peer.value?.deviceId
        if (type in REQUIRES_ACTIVE_PEER && sender != activePeer) {
            log.log("CallManager IGNORING $type from=$sender — active peer=$activePeer")
            return
        }
        val payload = router.openCallSignal(sender, envelope) ?: run {
            log.log("CallManager $type from=$sender: decrypt failed, dropped")
            return
        }
        val callId = envelope.optString("call_id")
        log.log("CallManager signal $type from=$sender state=${_state.value} signaling=${rtc?.signalingState}")
        when (type) {
            "call_offer" -> onOffer(sender, callId, payload)
            "call_answer" -> {
                val sdp = payload.optString("sdp") ?: return
                val session = rtc ?: return
                if (session.signalingState != SignalingState.HAVE_LOCAL_OFFER) {
                    log.log("CallManager call_answer while ${session.signalingState} — duplicate/stale, ignored")
                    return
                }
                session.setRemoteDescription("answer", sdp)
                remoteDescriptionSet = true
                flushPendingCandidates(session)
            }
            "call_ice" -> {
                val candidate = payload.optString("candidate") ?: return
                val mid = payload.optString("sdpMid")
                val index = payload.optInt("sdpMLineIndex") ?: 0
                val session = rtc
                if (remoteDescriptionSet && session != null) session.addIceCandidate(candidate, mid, index)
                else pendingCandidates += Triple(candidate, mid, index)
            }
            "call_video_state" -> _remoteVideoEnabled.value = payload.optBool("enabled") ?: false
            "call_reject" -> endWithReason("call.declined")
            "call_busy" -> endWithReason("call.busy")
            "call_cancel", "call_end" -> resetLocal()
        }
    }

    private suspend fun onOffer(sender: String, callId: String?, payload: JsonObject) {
        val sdp = payload.optString("sdp") ?: return
        if (payload.optBool("renegotiation") == true) {
            if (sender != _peer.value?.deviceId) return
            val session = rtc ?: return
            val collision = makingOffer || session.signalingState != SignalingState.STABLE
            if (collision && !polite) {
                log.log("CallManager renegotiation offer collision — impolite side, ignoring theirs")
                return
            }
            try {
                if (collision) session.rollback()
                session.setRemoteDescription("offer", sdp)
                val answer = session.createAnswer()
                send("call_answer", buildJsonObject { put("sdp", answer) })
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.error("CallManager renegotiation FAILED: $e")
            }
            return
        }
        if (_state.value != CallState.IDLE) {
            sendTo(sender, "call_busy", JsonObject(emptyMap()), callId)
            return
        }
        currentCallId = callId
        _peer.value = CallPeer(sender)
        pendingOfferSdp = sdp
        startedAt = now()
        _connectedAt.value = null
        isOutgoing = false
        remoteDescriptionSet = false
        pendingCandidates.clear()
        setState(CallState.INCOMING_RINGING)
        armRingTimeout()
        if (autoAcceptPending) {
            autoAcceptPending = false
            autoAcceptAndOpen()
        } else {
            _incoming.tryEmit(IncomingCall(callId.orEmpty(), CallPeer(sender)))
            scope.launch(dispatcher) { resolvePeer() }
        }
    }

    /**
     * Дозвон не вечный. Сервер сам отвечает call_unavailable, только если
     * offer не дошёл; если дошёл, а собеседник молчит (или его приложение
     * упало), без этого исходящий гудел бы, а входящий звонил бы бесконечно.
     * Исходящий: отмена у собеседника, "не отвечает" и пропущенный ему.
     * Входящий: ждём чуть дольше звонящего — обычно раньше придёт его отмена.
     */
    private fun armRingTimeout() {
        ringTimeout?.cancel()
        val callId = currentCallId
        val ringing = _state.value
        val timeout = if (ringing == CallState.OUTGOING_RINGING) ringTimeoutMs else ringTimeoutMs + 5_000
        ringTimeout = scope.launch(dispatcher) {
            delay(timeout)
            if (_state.value != ringing || currentCallId != callId) return@launch
            log.log("CallManager ring timeout state=$ringing")
            ringTimeout = null
            if (ringing == CallState.OUTGOING_RINGING) {
                send("call_cancel", JsonObject(emptyMap()))
                _status.value = "call.noAnswer"
                delay(endReasonDelayMs)
                resetLocal(peerWasUnavailable = true)
            } else {
                resetLocal()
            }
        }
    }

    /** Логин/аккаунт собеседника входящего звонка — по его device_id. */
    private suspend fun resolvePeer() {
        val p = _peer.value ?: return
        if (p.login != null) return
        val token = session.token ?: return
        val owner = api.getDeviceOwnerInfo(token, p.deviceId) ?: return
        if (_peer.value?.deviceId == p.deviceId) _peer.value = p.copy(login = owner.login, accountId = owner.accountId)
    }

    private suspend fun endWithReason(reasonKey: String) {
        _status.value = reasonKey
        delay(endReasonDelayMs)
        resetLocal()
    }

    private suspend fun resetLocal(peerWasUnavailable: Boolean = false) {
        if (_state.value == CallState.IDLE && rtc == null) return
        ringTimeout?.cancel() // сам таймер перед сбросом уже обнулил ссылку на себя
        ringTimeout = null
        logCall(peerWasUnavailable)
        rtc?.close()
        rtc = null
        pendingOfferSdp = null
        remoteDescriptionSet = false
        pendingCandidates.clear()
        currentCallId = null
        resetMediaFlags()
        _peer.value = null
        _status.value = null
        _connectedAt.value = null
        setState(CallState.IDLE)
    }

    /**
     * Запись о звонке в чат: отвечен (с длительностью), без ответа (исходящий)
     * или пропущен (входящий). Недоступному собеседнику — "пропущенный звонок".
     */
    private suspend fun logCall(peerWasUnavailable: Boolean) {
        val peerDeviceId = _peer.value?.deviceId ?: return
        val started = startedAt ?: return
        startedAt = null
        val connected = _connectedAt.value
        val outcome = when {
            connected != null -> "answered"
            isOutgoing -> "no_answer"
            else -> "missed"
        }
        try {
            val token = session.token ?: return
            val owner = api.getDeviceOwnerInfo(token, peerDeviceId) ?: return
            chats.addCallLog(
                owner.login,
                direction = if (isOutgoing) "outgoing" else "incoming",
                outcome = outcome,
                timestamp = started,
                durationSeconds = connected?.let { (now() - it) / 1000 },
                accountId = owner.accountId,
                callId = currentCallId,
            )
            if (peerWasUnavailable && isOutgoing) {
                // обычное (не тихое) сообщение — с пушем, чтобы собеседник узнал о звонке
                messenger.send(peerDeviceId, InnerMessage.missedCall(started, currentCallId), trackStatus = false)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.log("CallManager call log FAILED: $e")
        }
    }
}
