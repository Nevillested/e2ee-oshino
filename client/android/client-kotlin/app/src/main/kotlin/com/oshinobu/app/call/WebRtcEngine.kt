package com.oshinobu.app.call

import android.content.Context
import com.oshinobu.core.service.IceServer
import com.oshinobu.core.service.Logger
import com.oshinobu.core.service.RtcEngine
import com.oshinobu.core.service.RtcEvents
import com.oshinobu.core.service.RtcSession
import com.oshinobu.core.service.SignalingState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import org.webrtc.AddIceObserver
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.CandidatePairChangeEvent
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.IceCandidateErrorEvent
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import org.webrtc.audio.JavaAudioDeviceModule
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * WebRTC на Android (org.webrtc — та же сборка, что под flutter_webrtc).
 * Одна фабрика на процесс; видео — дорожки для экрана звонка
 * ([localVideo]/[remoteVideo]) и общий EGL-контекст для их отрисовки.
 *
 * Журнал — всё, что нужно, чтобы понять, почему звонок не соединился:
 * этапы соединения, типы найденных ICE-кандидатов и выбранная пара (без
 * IP-адресов), ошибки TURN/STUN, ошибки микрофона и динамика (ошибкой —
 * с отправкой журнала).
 */
class WebRtcEngine(private val context: Context, private val log: Logger) : RtcEngine {
    val egl: EglBase by lazy { EglBase.create() }

    private val factory: PeerConnectionFactory by lazy {
        val started = System.currentTimeMillis()
        log.log("WebRTC factory init")
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions())
        val audio = JavaAudioDeviceModule.builder(context)
            .setUseHardwareAcousticEchoCanceler(true)
            .setUseHardwareNoiseSuppressor(true)
            .setAudioRecordErrorCallback(object : JavaAudioDeviceModule.AudioRecordErrorCallback {
                override fun onWebRtcAudioRecordInitError(message: String?) = log.error("WebRTC mic init error: $message")
                override fun onWebRtcAudioRecordStartError(code: JavaAudioDeviceModule.AudioRecordStartErrorCode?, message: String?) =
                    log.error("WebRTC mic start error $code: $message")
                override fun onWebRtcAudioRecordError(message: String?) = log.error("WebRTC mic error: $message")
            })
            .setAudioTrackErrorCallback(object : JavaAudioDeviceModule.AudioTrackErrorCallback {
                override fun onWebRtcAudioTrackInitError(message: String?) = log.error("WebRTC speaker init error: $message")
                override fun onWebRtcAudioTrackStartError(code: JavaAudioDeviceModule.AudioTrackStartErrorCode?, message: String?) =
                    log.error("WebRTC speaker start error $code: $message")
                override fun onWebRtcAudioTrackError(message: String?) = log.error("WebRTC speaker error: $message")
            })
            .setAudioRecordStateCallback(object : JavaAudioDeviceModule.AudioRecordStateCallback {
                override fun onWebRtcAudioRecordStart() = log.log("WebRTC mic started")
                override fun onWebRtcAudioRecordStop() = log.log("WebRTC mic stopped")
            })
            .setAudioTrackStateCallback(object : JavaAudioDeviceModule.AudioTrackStateCallback {
                override fun onWebRtcAudioTrackStart() = log.log("WebRTC speaker started")
                override fun onWebRtcAudioTrackStop() = log.log("WebRTC speaker stopped")
            })
            .createAudioDeviceModule()
        PeerConnectionFactory.builder()
            .setAudioDeviceModule(audio)
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
            .createPeerConnectionFactory()
            .also { log.log("WebRTC factory ready in ${System.currentTimeMillis() - started}ms") }
    }

    private val _localVideo = MutableStateFlow<VideoTrack?>(null)
    private val _remoteVideo = MutableStateFlow<VideoTrack?>(null)

    /** Своя камера (когда включена). */
    val localVideo: StateFlow<VideoTrack?> = _localVideo.asStateFlow()

    /** Видео собеседника (дорожка есть, даже если он её выключил — смотреть на флаг звонка). */
    val remoteVideo: StateFlow<VideoTrack?> = _remoteVideo.asStateFlow()

    override fun createSession(iceServers: List<IceServer>, events: RtcEvents): RtcSession = Session(iceServers, events)

    private inner class Session(iceServers: List<IceServer>, private val events: RtcEvents) : RtcSession, PeerConnection.Observer {
        private val pc: PeerConnection = factory.createPeerConnection(
            PeerConnection.RTCConfiguration(
                iceServers.map { s ->
                    PeerConnection.IceServer.builder(s.urls).apply {
                        s.username?.let(::setUsername)
                        s.credential?.let(::setPassword)
                    }.createIceServer()
                },
            ).apply { sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN },
            this,
        ) ?: error("WebRTC: не удалось создать соединение")

        init {
            log.log("WebRTC peer connection created, ice servers: ${iceServers.joinToString { s -> s.urls.joinToString("|") { it.substringBefore('?') } }}")
        }

        private var audioSource: AudioSource? = null
        private var audioTrack: AudioTrack? = null
        private var videoSource: VideoSource? = null
        private var videoTrack: VideoTrack? = null
        private var capturer: CameraVideoCapturer? = null
        private var captureHelper: SurfaceTextureHelper? = null
        private var capturing = false
        @Volatile private var closed = false

        override val signalingState: SignalingState
            get() = when (pc.signalingState()) {
                PeerConnection.SignalingState.STABLE -> SignalingState.STABLE
                PeerConnection.SignalingState.HAVE_LOCAL_OFFER -> SignalingState.HAVE_LOCAL_OFFER
                else -> SignalingState.OTHER
            }

        private suspend fun create(offer: Boolean): String {
            val sdp = suspendCancellableCoroutine { cont ->
                val observer = object : SdpObserver {
                    override fun onCreateSuccess(desc: SessionDescription) = cont.resume(desc)
                    override fun onCreateFailure(error: String?) = cont.resumeWithException(IllegalStateException("createSdp: $error"))
                    override fun onSetSuccess() = Unit
                    override fun onSetFailure(error: String?) = Unit
                }
                if (offer) pc.createOffer(observer, MediaConstraints()) else pc.createAnswer(observer, MediaConstraints())
            }
            setDescription(local = true, sdp)
            return sdp.description
        }

        private suspend fun setDescription(local: Boolean, desc: SessionDescription) = suspendCancellableCoroutine { cont ->
            val observer = object : SdpObserver {
                override fun onCreateSuccess(desc: SessionDescription) = Unit
                override fun onCreateFailure(error: String?) = Unit
                override fun onSetSuccess() = cont.resume(Unit)
                override fun onSetFailure(error: String?) = cont.resumeWithException(IllegalStateException("setDescription: $error"))
            }
            if (local) pc.setLocalDescription(observer, desc) else pc.setRemoteDescription(observer, desc)
        }

        override suspend fun createOffer(): String = create(offer = true)

        override suspend fun createAnswer(): String = create(offer = false)

        override suspend fun setRemoteDescription(type: String, sdp: String) =
            setDescription(local = false, SessionDescription(SessionDescription.Type.fromCanonicalForm(type), sdp))

        override suspend fun rollback() = setDescription(local = true, SessionDescription(SessionDescription.Type.ROLLBACK, ""))

        override suspend fun addIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int) {
            log.log("WebRTC remote candidate ${describeCandidate(candidate)}")
            pc.addIceCandidate(
                IceCandidate(sdpMid ?: "", sdpMLineIndex, candidate),
                object : AddIceObserver {
                    override fun onAddSuccess() = Unit
                    override fun onAddFailure(error: String?) = log.log("WebRTC remote candidate rejected: $error")
                },
            )
        }

        override suspend fun startAudio(micEnabled: Boolean) {
            val source = factory.createAudioSource(MediaConstraints())
            val track = factory.createAudioTrack("audio0", source)
            track.setEnabled(micEnabled)
            pc.addTrack(track, listOf("stream0"))
            audioSource = source
            audioTrack = track
        }

        override fun setMicEnabled(enabled: Boolean) {
            audioTrack?.setEnabled(enabled)
        }

        override suspend fun setVideoEnabled(enabled: Boolean) {
            if (enabled && videoTrack == null) {
                val enumerator = Camera2Enumerator(context)
                val front = enumerator.deviceNames.firstOrNull(enumerator::isFrontFacing) ?: enumerator.deviceNames.firstOrNull()
                    ?: error("нет камеры")
                val cam = enumerator.createCapturer(front, null)
                val helper = SurfaceTextureHelper.create("CallCapture", egl.eglBaseContext)
                val source = factory.createVideoSource(false)
                cam.initialize(helper, context, source.capturerObserver)
                val track = factory.createVideoTrack("video0", source)
                pc.addTrack(track, listOf("stream0"))
                capturer = cam
                captureHelper = helper
                videoSource = source
                videoTrack = track
                _localVideo.value = track
            }
            val cam = capturer ?: return
            if (enabled && !capturing) cam.startCapture(1280, 720, 30)
            if (!enabled && capturing) cam.stopCapture()
            capturing = enabled
            videoTrack?.setEnabled(enabled)
        }

        override suspend fun switchCamera(): Boolean {
            val cam = capturer ?: return true
            return suspendCancellableCoroutine { cont ->
                cam.switchCamera(object : CameraVideoCapturer.CameraSwitchHandler {
                    override fun onCameraSwitchDone(isFrontCamera: Boolean) = cont.resume(isFrontCamera)
                    override fun onCameraSwitchError(error: String?) = cont.resumeWithException(IllegalStateException("switchCamera: $error"))
                })
            }
        }

        override fun close() {
            if (closed) return
            closed = true
            _localVideo.value = null
            _remoteVideo.value = null
            runCatching { if (capturing) capturer?.stopCapture() }
            capturer?.dispose()
            captureHelper?.dispose()
            videoSource?.dispose()
            audioSource?.dispose()
            pc.dispose()
        }

        // ---- PeerConnection.Observer ----

        override fun onIceCandidate(candidate: IceCandidate) {
            log.log("WebRTC local candidate ${describeCandidate(candidate.sdp)}")
            events.onIceCandidate(candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex)
        }

        override fun onIceCandidateError(event: IceCandidateErrorEvent) {
            // адрес — свой локальный, в журнал не пишем; url — какой STUN/TURN не ответил
            log.log("WebRTC ICE server error ${event.errorCode} ${event.errorText} at ${event.url.substringBefore('?')}")
        }

        override fun onSelectedCandidatePairChanged(event: CandidatePairChangeEvent) {
            log.log("WebRTC selected pair local=${describeCandidate(event.local.sdp)} remote=${describeCandidate(event.remote.sdp)}")
        }

        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
            log.log("WebRTC connection $newState")
            when (newState) {
                PeerConnection.PeerConnectionState.CONNECTED -> events.onConnected()
                PeerConnection.PeerConnectionState.FAILED -> events.onFailed()
                else -> Unit
            }
        }

        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) {
            log.log("WebRTC ICE $newState")
            if (newState == PeerConnection.IceConnectionState.CONNECTED || newState == PeerConnection.IceConnectionState.COMPLETED) events.onConnected()
        }

        override fun onRenegotiationNeeded() {
            if (!closed) events.onRenegotiationNeeded()
        }

        override fun onTrack(transceiver: RtpTransceiver) {
            (transceiver.receiver.track() as? VideoTrack)?.let { _remoteVideo.value = it }
        }

        override fun onSignalingChange(newState: PeerConnection.SignalingState) = log.log("WebRTC signaling $newState")
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState) = log.log("WebRTC ICE gathering $newState")
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
        override fun onAddStream(stream: MediaStream) = Unit
        override fun onRemoveStream(stream: MediaStream) = Unit
        override fun onDataChannel(channel: DataChannel) = Unit
        override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) = Unit
    }
}

/**
 * Кандидат для журнала — только тип (host/srflx/relay), протокол и для
 * relay — транспорт до TURN, без адресов и портов: "relay udp".
 */
private fun describeCandidate(sdp: String): String {
    val parts = sdp.substringAfter("candidate:").split(' ')
    val protocol = parts.getOrNull(2)?.lowercase() ?: "?"
    val type = parts.getOrNull(parts.indexOf("typ") + 1)?.takeIf { parts.contains("typ") } ?: "?"
    return "$type $protocol"
}
