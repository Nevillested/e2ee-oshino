import AVKit
import OshinobuCore
import SwiftUI
import WebRTC

/// Состояние звонка из ядра — для SwiftUI.
@MainActor
final class CallViewModel: ObservableObject {
    @Published var state: CallState = .idle
    @Published var status: String?
    @Published var peer: CallPeer?
    @Published var connectedAt: Int64?
    @Published var mic = true
    @Published var video = false
    @Published var remoteVideo = false
    @Published var front = true
    /// Экран звонка свёрнут («свернуть»): вернуться — полосой над списком чатов или в чате.
    @Published var minimized = false
    private var tasks: [Task<Void, Never>] = []

    func follow(_ calls: CallManager) {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            for await v in calls.state.stream() {
                self?.state = v
                if v == .idle { self?.minimized = false }
            }
        })
        tasks.append(Task { [weak self] in for await v in calls.status.stream() { self?.status = v } })
        tasks.append(Task { [weak self] in for await v in calls.peer.stream() { self?.peer = v } })
        tasks.append(Task { [weak self] in for await v in calls.connectedAt.stream() { self?.connectedAt = v } })
        tasks.append(Task { [weak self] in for await v in calls.micEnabled.stream() { self?.mic = v } })
        tasks.append(Task { [weak self] in for await v in calls.videoEnabled.stream() { self?.video = v } })
        tasks.append(Task { [weak self] in for await v in calls.remoteVideoEnabled.stream() { self?.remoteVideo = v } })
        tasks.append(Task { [weak self] in for await v in calls.usingFrontCamera.stream() { self?.front = v } })
    }
}

private let endRed = Color(hex: 0xE53935)
private let acceptGreen = Color(hex: 0x43A047)

/// Длительность разговора (тикает раз в секунду) или этап соединения.
struct CallStatusText: View {
    @ObservedObject var call: CallViewModel

    var body: some View {
        if call.state == .connected, let since = call.connectedAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(0, Int(ctx.date.timeIntervalSince1970) - Int(since / 1000))
                Text(verbatim: "\(s / 60):" + String(format: "%02d", s % 60)).monospacedDigit()
            }
        } else if let key = call.status {
            Text(verbatim: tr(key.replacingOccurrences(of: ".", with: "_")))
        } else {
            Text("call_dialing")
        }
    }
}

/// Экраны звонка поверх приложения (CallScreens.kt): входящий — свой экран, остальное — разговор.
/// Появляются и уходят сразу, без анимации; входящий в фоне показывает CallKit.
struct CallScreens: View {
    @ObservedObject var call: CallViewModel

    var body: some View {
        if call.state == .incomingRinging {
            IncomingCallScreen(call: call)
        } else if call.state != .idle && !call.minimized {
            CallScreen(call: call)
        }
    }
}

private struct RoundCallButton: View {
    let icon: MaterialIcon
    let background: Color
    let tint: Color
    var size: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MIcon(icon, tint: tint).frame(width: size, height: size).background(background, in: Circle())
        }
        .buttonStyle(RippleStyle(shape: Circle(), color: tint))
    }
}

/// Входящий звонок: кто звонит, «отклонить» и «ответить».
private struct IncomingCallScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var call: CallViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            PeerAvatar(accountId: call.peer?.accountId, size: 112)
            Gap(20)
            Group {
                if let login = call.peer?.login { PeerName(accountId: call.peer?.accountId, login: login) } else { Text("common_unknown") }
            }
            .font(.roboto(24)).tracking(0).foregroundStyle(model.theme.textPrimary)
            Gap(8)
            Text("call_incoming").font(.roboto(16)).foregroundStyle(model.theme.textMuted)
            Spacer()
            HStack {
                RoundCallButton(icon: .callEnd, background: endRed, tint: .white, size: 64) { Task { await model.core.calls.declineCall() } }
                Spacer()
                RoundCallButton(icon: .call, background: acceptGreen, tint: .white, size: 64) {
                    Task {
                        guard await AVAudioApplication.requestRecordPermission() else { return }
                        await model.core.calls.acceptCall()
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.background.ignoresSafeArea())
    }
}

/// Разговор: видео собеседника во весь экран (или аватар, имя и статус), своё видео в перетаскиваемом
/// окошке, кнопки микрофона, камеры (и её смены), звука (список выходов при Bluetooth) и завершения.
private struct CallScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var call: CallViewModel
    @StateObject private var audio = CallAudioRoutes()
    @State private var remote: RTCVideoTrack?
    @State private var local: RTCVideoTrack?

    var body: some View {
        GeometryReader { g in
            ZStack {
                model.theme.background
                if call.remoteVideo, let remote {
                    PipAnchorView(track: remote)
                    RtcVideoView(track: remote)
                    VStack(spacing: 0) {
                        name.font(.roboto(14)).foregroundStyle(.white)
                        CallStatusText(call: call).font(.roboto(12)).foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, windowSafeArea.top + 12)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(spacing: 0) {
                        PeerAvatar(accountId: call.peer?.accountId, size: 96)
                        Gap(16)
                        name.font(.roboto(22)).foregroundStyle(model.theme.textPrimary)
                        Gap(8)
                        CallStatusText(call: call).font(.roboto(16)).foregroundStyle(model.theme.textMuted)
                    }
                }
                if call.state == .connected || call.state == .outgoingRinging {
                    SelfView(video: call.video, track: local, front: call.front, area: g.size)
                }
                IconButtonM(.closeFullscreen) { call.minimized = true }
                    .padding(.top, windowSafeArea.top + 8).padding(.trailing, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                buttons
                    .padding(.bottom, windowSafeArea.bottom + 32)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
        .task { await refreshTracks() }
        .onReceive(NotificationCenter.default.publisher(for: WebRtcSession.tracksChanged)) { _ in Task { await refreshTracks() } }
        // видео в разговоре — экран не гаснет
        .onChange(of: call.video || call.remoteVideo, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder private var name: some View {
        if let peer = call.peer { PeerName(accountId: peer.accountId, login: peer.login ?? "") } else { Text(verbatim: "") }
    }

    private var buttons: some View {
        let idle = model.theme.surface
        let calls = model.core.calls
        return HStack(alignment: .bottom, spacing: 0) {
            Spacer()
            RoundCallButton(icon: call.mic ? .mic : .micOff, background: call.mic ? idle : model.theme.primary,
                            tint: call.mic ? model.theme.textPrimary : model.theme.onPrimary) { Task { await calls.toggleMic() } }
            Spacer()
            VStack(spacing: 8) {
                if call.video {
                    RoundCallButton(icon: .cameraswitch, background: call.front ? idle : model.theme.primary,
                                    tint: call.front ? model.theme.textPrimary : model.theme.onPrimary) { Task { await calls.switchCamera() } }
                }
                RoundCallButton(icon: .videocamOff, background: call.video ? model.theme.primary : idle,
                                tint: call.video ? model.theme.onPrimary : model.theme.textPrimary) {
                    Task {
                        if !call.video, !(await AVCaptureDevice.requestAccess(for: .video)) { return }
                        await calls.toggleVideo()
                    }
                }
            }
            Spacer()
            if audio.routes.contains(.bluetooth) {
                RoundCallButton(icon: audio.route.icon, background: model.theme.primary, tint: model.theme.onPrimary) { showOutputs() }
            } else {
                let speaker = audio.route == .speaker
                RoundCallButton(icon: .volumeUp, background: speaker ? model.theme.primary : idle,
                                tint: speaker ? model.theme.onPrimary : model.theme.textPrimary) { audio.select(speaker ? .earpiece : .speaker) }
            }
            Spacer()
            RoundCallButton(icon: .callEnd, background: endRed, tint: .white) { Task { await calls.hangUp() } }
            Spacer()
        }
    }

    /// Список выходов звука — шторкой.
    private func showOutputs() {
        let audio = audio
        model.popups.show(dim: false) {
            BottomSheetM(background: model.theme.surface) {
                OutputList(audio: audio)
            }
        }
    }

    private func refreshTracks() async {
        guard let s = await model.core.calls.rtcSession as? WebRtcSession else { return }
        remote = s.remoteVideoTrack
        local = s.localVideoTrackForPreview
    }
}

private struct OutputList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var audio: CallAudioRoutes

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("call_outputDevices").font(.roboto(18, .semibold)).tracking(0).foregroundStyle(model.theme.textPrimary)
                .padding(.horizontal, 20).padding(.vertical, 8)
            ForEach(audio.routes, id: \.self) { r in
                let current = r == audio.route
                Button {
                    model.popups.dismiss(animated: false)
                    audio.select(r)
                } label: {
                    HStack(spacing: 16) {
                        MIcon(r.icon, tint: current ? model.theme.primary : model.theme.textPrimary)
                        Text(r.label).font(.roboto(16)).foregroundStyle(current ? model.theme.primary : model.theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if current { MIcon(.check, tint: model.theme.primary) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }
                .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
            }
            Gap(8)
        }
    }
}

/// Своё видео (или «камера выключена») в окошке 100×140, которое можно перетащить.
private struct SelfView: View {
    @EnvironmentObject private var model: AppModel
    let video: Bool
    let track: RTCVideoTrack?
    let front: Bool
    let area: CGSize
    @State private var offset = CGSize(width: 16, height: 60)
    @State private var base: CGSize?

    var body: some View {
        let top = windowSafeArea.top, bottom = windowSafeArea.bottom
        let x = min(max(0, offset.width), area.width - 100), y = min(max(0, offset.height), area.height - top - bottom - 140)
        ZStack {
            model.theme.surface
            if video, let track {
                RtcVideoView(track: track, mirrored: front).id(front)
            } else {
                Text("call_cameraOff").font(.roboto(11)).foregroundStyle(model.theme.textMuted).multilineTextAlignment(.center).padding(8)
            }
        }
        .frame(width: 100, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .offset(x: x, y: y + top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .gesture(DragGesture()
            .onChanged { v in
                let b = base ?? offset
                if base == nil { base = offset }
                offset = CGSize(width: b.width + v.translation.width, height: b.height + v.translation.height)
            }
            .onEnded { _ in base = nil })
    }
}

/// Полоса «вернуться к звонку» над списком чатов и в чате с тем, с кем идёт разговор (peerLogin nil — при любом).
struct OngoingCallBanner: View {
    @EnvironmentObject private var call: CallViewModel
    let peerLogin: String?

    var body: some View {
        if call.state != .idle && (peerLogin == nil || call.peer?.login == peerLogin) {
            let ink = Color.black.opacity(0.87)
            HStack(spacing: 8) {
                MIcon(.call, size: 18, tint: ink)
                Text("call_returnToScreen").font(.roboto(16, .semibold)).tracking(0).foregroundStyle(ink)
                CallStatusText(call: call).font(.roboto(16, .semibold)).foregroundStyle(ink)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(hex: 0xCCFF90))
            .contentShape(Rectangle())
            .onTapGesture { call.minimized = false }
        }
    }
}

/// Выход звука звонка: телефон, динамик, проводные наушники, Bluetooth.
enum AudioOutput: Hashable {
    case earpiece, speaker, wiredHeadset, bluetooth

    var icon: MaterialIcon {
        switch self {
        case .bluetooth: .bluetoothAudio
        case .speaker: .volumeUp
        case .wiredHeadset: .headset
        case .earpiece: .hearing
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .bluetooth: "call_outputBluetooth"
        case .speaker: "call_outputSpeaker"
        case .wiredHeadset: "call_outputWiredHeadset"
        case .earpiece: "call_outputEarpiece"
        }
    }
}

/// Доступные выходы и текущий (CallAudio на Android); следит за сменой маршрута.
@MainActor
final class CallAudioRoutes: ObservableObject {
    @Published private(set) var routes: [AudioOutput] = []
    @Published private(set) var route: AudioOutput = .earpiece
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func refresh() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        var list: [AudioOutput] = []
        if inputs.contains(where: { $0.portType == .headsetMic }) { list.append(.wiredHeadset) } else { list.append(.earpiece) }
        list.append(.speaker)
        if inputs.contains(where: { [.bluetoothHFP, .bluetoothLE].contains($0.portType) }) { list.append(.bluetooth) }
        routes = list
        let out = session.currentRoute.outputs.first?.portType
        route = switch out {
        case .builtInSpeaker: .speaker
        case .headphones, .headsetMic: .wiredHeadset
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: .bluetooth
        default: list.contains(.wiredHeadset) ? .wiredHeadset : .earpiece
        }
    }

    func select(_ r: AudioOutput) {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        switch r {
        case .speaker:
            try? session.overrideOutputAudioPort(.speaker)
        case .bluetooth:
            try? session.overrideOutputAudioPort(.none)
            try? session.setPreferredInput(inputs.first { [.bluetoothHFP, .bluetoothLE].contains($0.portType) })
        case .wiredHeadset:
            try? session.overrideOutputAudioPort(.none)
            try? session.setPreferredInput(inputs.first { $0.portType == .headsetMic })
        case .earpiece:
            try? session.overrideOutputAudioPort(.none)
            try? session.setPreferredInput(inputs.first { $0.portType == .builtInMic })
        }
        refresh()
    }
}

/// Отрисовка видеодорожки WebRTC (Metal).
struct RtcVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    var mirrored = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = .scaleAspectFill
        if mirrored { v.transform = CGAffineTransform(scaleX: -1, y: 1) }
        track.add(v)
        context.coordinator.track = track
        return v
    }

    func updateUIView(_ v: RTCMTLVideoView, context: Context) {}

    static func dismantleUIView(_ v: RTCMTLVideoView, coordinator: Coordinator) { coordinator.track?.remove(v) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var track: RTCVideoTrack? }
}

/// Невидимый якорь PiP под видео собеседника (система берёт его рамку для анимации окна).
struct PipAnchorView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> CallPipAnchor { CallPipAnchor() }
    func updateUIView(_ v: CallPipAnchor, context: Context) { v.attach(track) }
    static func dismantleUIView(_ v: CallPipAnchor, coordinator: ()) { v.detach() }
}
