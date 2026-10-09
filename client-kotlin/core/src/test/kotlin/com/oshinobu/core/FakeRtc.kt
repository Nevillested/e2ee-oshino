package com.oshinobu.core

import com.oshinobu.core.service.IceServer
import com.oshinobu.core.service.RtcEngine
import com.oshinobu.core.service.RtcEvents
import com.oshinobu.core.service.RtcSession
import com.oshinobu.core.service.SignalingState
import java.util.concurrent.CopyOnWriteArrayList

/**
 * WebRTC без медиа: только автомат offer/answer. Соединение "устанавливается",
 * как только у стороны есть и своё, и чужое описание; каждый createOffer
 * выдаёт один ICE-кандидат; первое включение камеры просит renegotiation.
 */
class FakeRtcEngine : RtcEngine {
    val sessions = CopyOnWriteArrayList<FakeRtcSession>()

    override fun createSession(iceServers: List<IceServer>, events: RtcEvents): RtcSession =
        FakeRtcSession(events).also { sessions += it }

    val last: FakeRtcSession get() = sessions.last()
}

class FakeRtcSession(private val events: RtcEvents) : RtcSession {
    @Volatile override var signalingState = SignalingState.STABLE
        private set
    val remoteCandidates = CopyOnWriteArrayList<String>()
    val remoteDescriptions = CopyOnWriteArrayList<String>()
    @Volatile var micOn = false
        private set
    @Volatile var videoOn = false
        private set
    @Volatile var closed = false
    private var hasVideoTrack = false
    private var offers = 0
    private var connected = false

    override suspend fun createOffer(): String {
        signalingState = SignalingState.HAVE_LOCAL_OFFER
        val sdp = "offer-${++offers}"
        events.onIceCandidate("candidate-of-$sdp", "0", 0)
        return sdp
    }

    override suspend fun createAnswer(): String {
        check(signalingState == SignalingState.OTHER) { "answer без чужого offer" }
        signalingState = SignalingState.STABLE
        connect()
        return "answer"
    }

    override suspend fun setRemoteDescription(type: String, sdp: String) {
        remoteDescriptions += "$type:$sdp"
        signalingState = if (type == "offer") SignalingState.OTHER else SignalingState.STABLE
        if (type == "answer") connect()
    }

    override suspend fun rollback() {
        signalingState = SignalingState.STABLE
    }

    override suspend fun addIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int) {
        check(remoteDescriptions.isNotEmpty()) { "кандидат раньше удалённого описания" }
        remoteCandidates += candidate
    }

    override suspend fun startAudio(micEnabled: Boolean) {
        micOn = micEnabled
    }

    override fun setMicEnabled(enabled: Boolean) {
        micOn = enabled
    }

    override suspend fun setVideoEnabled(enabled: Boolean) {
        videoOn = enabled
        if (enabled && !hasVideoTrack) {
            hasVideoTrack = true
            events.onRenegotiationNeeded()
        }
    }

    override suspend fun switchCamera(): Boolean = false

    override fun close() {
        closed = true
    }

    private fun connect() {
        if (connected) return
        connected = true
        events.onConnected()
    }
}
