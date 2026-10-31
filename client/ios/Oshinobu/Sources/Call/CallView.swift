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
    @Published var speaker = false
    @Published var remoteVideo = false
    private var tasks: [Task<Void, Never>] = []

    func follow(_ calls: CallManager) {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in for await v in calls.state.stream() { self?.state = v } })
        tasks.append(Task { [weak self] in for await v in calls.status.stream() { self?.status = v } })
        tasks.append(Task { [weak self] in for await v in calls.peer.stream() { self?.peer = v } })
        tasks.append(Task { [weak self] in for await v in calls.connectedAt.stream() { self?.connectedAt = v } })
        tasks.append(Task { [weak self] in for await v in calls.micEnabled.stream() { self?.mic = v } })
        tasks.append(Task { [weak self] in for await v in calls.videoEnabled.stream() { self?.video = v } })
        tasks.append(Task { [weak self] in for await v in calls.remoteVideoEnabled.stream() { self?.remoteVideo = v } })
    }
}

/// Экран звонка поверх приложения (входящий в фоне показывает CallKit).
struct CallView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var call: CallViewModel

    var body: some View {
        ZStack {
            if call.state == .connected && (call.video || call.remoteVideo) {
                CallVideoLayer(showLocal: call.video)
            }
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.background.ignoresSafeArea())
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 20) {
            Spacer()
            Circle().fill(model.theme.primary.opacity(0.25)).frame(width: 140, height: 140)
                .overlay(Text((call.peer?.login ?? "?").prefix(1).uppercased()).font(.system(size: 56, weight: .bold)).foregroundStyle(model.theme.primary))
            Text(call.peer?.login ?? NSLocalizedString("call_otherParty", comment: "")).font(.title.bold()).foregroundStyle(model.theme.textPrimary)
            statusLine.font(.headline).foregroundStyle(model.theme.textMuted)
            Spacer()
            if call.state == .incomingRinging {
                HStack(spacing: 80) {
                    RoundButton(icon: "phone.down.fill", color: .red) { Task { await model.core.calls.declineCall() } }
                    RoundButton(icon: "phone.fill", color: .green) { Task { await model.core.calls.acceptCall() } }
                }
            } else {
                HStack(spacing: 28) {
                    RoundButton(icon: call.mic ? "mic.fill" : "mic.slash.fill", color: call.mic ? model.theme.surface : model.theme.primary) {
                        Task { await model.core.calls.toggleMic() }
                    }
                    VStack(spacing: 10) {
                        // Bluetooth / наушники / динамик — системный выбор выхода (как в «Телефоне»)
                        AudioRoutePicker().frame(width: 64, height: 64).background(model.theme.surface, in: Circle())
                        RoundButton(icon: "speaker.wave.2.fill", color: call.speaker ? model.theme.primary : model.theme.surface) {
                            call.speaker.toggle()
                            model.callController.setSpeaker(call.speaker)
                        }
                    }
                    VStack(spacing: 10) {
                        if call.video {
                            RoundButton(icon: "arrow.triangle.2.circlepath.camera", color: model.theme.surface) {
                                Task { await model.core.calls.switchCamera() }
                            }
                        }
                        RoundButton(icon: call.video ? "video.fill" : "video.slash.fill", color: call.video ? model.theme.primary : model.theme.surface) {
                            Task { await model.core.calls.toggleVideo() }
                        }
                    }
                    RoundButton(icon: "phone.down.fill", color: .red) { Task { await model.core.calls.hangUp() } }
                }
            }
        }
        .padding(.bottom, 48)
    }

    /// Этап/причина — ключ ядра ("call.ringing") → строка ("call_ringing"); в разговоре — таймер.
    @ViewBuilder private var statusLine: some View {
        if let since = call.connectedAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(0, Int(ctx.date.timeIntervalSince1970) - Int(since / 1000))
                Text(String(format: "%d:%02d", s / 60, s % 60)).monospacedDigit()
            }
        } else if let key = call.status {
            Text(NSLocalizedString(key.replacingOccurrences(of: ".", with: "_"), comment: ""))
        } else if call.state == .incomingRinging {
            Text("call_incoming")
        }
    }
}

struct RoundButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2).foregroundStyle(.white).frame(width: 64, height: 64).background(color, in: Circle())
        }
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

/// Видео собеседника на весь экран и своё окошком в углу.
struct CallVideoLayer: View {
    @EnvironmentObject private var model: AppModel
    @State private var remote: RTCVideoTrack?
    @State private var local: RTCVideoTrack?
    let showLocal: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let remote {
                PipAnchorView(track: remote).ignoresSafeArea()
                RtcVideoView(track: remote).ignoresSafeArea()
            }
            if showLocal, let local {
                RtcVideoView(track: local, mirrored: true)
                    .frame(width: 110, height: 160).clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 60).padding(.trailing, 16)
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: WebRtcSession.tracksChanged)) { _ in Task { await refresh() } }
    }

    private func refresh() async {
        guard let s = await model.core.calls.session as? WebRtcSession else { return }
        remote = s.remoteVideoTrack
        local = s.localVideoTrackForPreview
    }
}

/// Невидимый якорь PiP под видео собеседника (система берёт его рамку для анимации окна).
struct PipAnchorView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> CallPipAnchor { CallPipAnchor() }
    func updateUIView(_ v: CallPipAnchor, context: Context) { v.attach(track) }
    static func dismantleUIView(_ v: CallPipAnchor, coordinator: ()) { v.detach() }
}

/// Системный выбор аудиовыхода звонка.
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
