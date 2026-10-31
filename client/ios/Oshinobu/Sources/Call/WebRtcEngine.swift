import AVFoundation
import OshinobuCore
import WebRTC

/// WebRTC за интерфейсом ядра (как WebRtcEngine.kt на Android). Аудио — в
/// режиме ручного управления: сессию звука активирует CallKit (didActivate).
final class WebRtcEngine: RtcEngine, @unchecked Sendable {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    init() {
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
    }

    func createSession(iceServers: [IceServer], events: RtcEvents) -> RtcSession {
        WebRtcSession(iceServers: iceServers, events: events)
    }

    /// CallKit активировал аудиосессию — можно говорить.
    static func audioActivated(_ session: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(session)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    static func audioDeactivated(_ session: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(session)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }
}

final class WebRtcSession: NSObject, RtcSession, RTCPeerConnectionDelegate, @unchecked Sendable {
    private let pc: RTCPeerConnection
    private weak var events: RtcEvents?
    private var audioTrack: RTCAudioTrack?
    private var videoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var frontCamera = true
    /// Видео собеседника — для экрана звонка.
    private(set) var remoteVideoTrack: RTCVideoTrack?
    private(set) var localVideoTrackForPreview: RTCVideoTrack?

    init(iceServers: [IceServer], events: RtcEvents) {
        self.events = events
        let config = RTCConfiguration()
        config.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        let delegateProxy = DelegateProxy()
        pc = WebRtcEngine.factory.peerConnection(with: config, constraints: constraints, delegate: delegateProxy)!
        super.init()
        delegateProxy.target = self
    }

    var signalingState: SignalingState {
        switch pc.signalingState {
        case .stable: return .stable
        case .haveLocalOffer: return .haveLocalOffer
        default: return .other
        }
    }

    private var mediaConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"], optionalConstraints: nil)
    }

    func createOffer() async throws -> String {
        let sdp = try await pc.offer(for: mediaConstraints)
        try await pc.setLocalDescription(sdp)
        return sdp.sdp
    }

    func createAnswer() async throws -> String {
        let sdp = try await pc.answer(for: mediaConstraints)
        try await pc.setLocalDescription(sdp)
        return sdp.sdp
    }

    func setRemoteDescription(type: String, sdp: String) async throws {
        try await pc.setRemoteDescription(RTCSessionDescription(type: type == "offer" ? .offer : .answer, sdp: sdp))
    }

    func rollback() async throws {
        try await pc.setLocalDescription(RTCSessionDescription(type: .rollback, sdp: ""))
    }

    func addIceCandidate(_ candidate: String, sdpMid: String?, sdpMLineIndex: Int32) async throws {
        try await pc.add(RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
    }

    func startAudio(micEnabled: Bool) async throws {
        let source = WebRtcEngine.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = WebRtcEngine.factory.audioTrack(with: source, trackId: "audio0")
        track.isEnabled = micEnabled
        pc.add(track, streamIds: ["oshinobu"])
        audioTrack = track
    }

    func setMicEnabled(_ enabled: Bool) { audioTrack?.isEnabled = enabled }

    func setVideoEnabled(_ enabled: Bool) async throws {
        if enabled, videoTrack == nil {
            let source = WebRtcEngine.factory.videoSource()
            let capturer = RTCCameraVideoCapturer(delegate: source)
            let track = WebRtcEngine.factory.videoTrack(with: source, trackId: "video0")
            pc.add(track, streamIds: ["oshinobu"]) // первая видеодорожка → renegotiation
            videoTrack = track
            localVideoTrackForPreview = track
            self.capturer = capturer
            NotificationCenter.default.post(name: WebRtcSession.tracksChanged, object: self)
        }
        videoTrack?.isEnabled = enabled
        if enabled { try await startCapture() } else { await capturer?.stopCapture() }
    }

    func switchCamera() async throws -> Bool {
        frontCamera.toggle()
        try await startCapture()
        return frontCamera
    }

    private func startCapture() async throws {
        guard let capturer else { return }
        let position: AVCaptureDevice.Position = frontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }),
              let format = RTCCameraVideoCapturer.supportedFormats(for: device)
                .filter({ CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1280 })
                .max(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width })
        else { return }
        try await capturer.startCapture(with: device, format: format, fps: 30)
    }

    func close() {
        capturer?.stopCapture()
        pc.close()
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        events?.onIceCandidate(candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .connected: events?.onConnected()
        case .failed: events?.onFailed()
        default: break
        }
    }

    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) { events?.onRenegotiationNeeded() }

    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            remoteVideoTrack = track
            NotificationCenter.default.post(name: WebRtcSession.tracksChanged, object: self)
        }
    }

    /// Появилась видеодорожка (своя или собеседника) — экрану звонка пора подключить отрисовку.
    static let tracksChanged = Notification.Name("oshinobu.webrtc.tracksChanged")

    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Делегат нужен при создании соединения, до init — прокси передаёт события сессии.
private final class DelegateProxy: NSObject, RTCPeerConnectionDelegate {
    weak var target: WebRtcSession?
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { target?.peerConnection(pc, didGenerate: candidate) }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) { target?.peerConnection(pc, didChange: newState) }
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) { target?.peerConnectionShouldNegotiate(pc) }
    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        target?.peerConnection(pc, didAdd: rtpReceiver, streams: streams)
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
