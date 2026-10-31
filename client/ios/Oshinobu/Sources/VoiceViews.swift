import AVFoundation
import OshinobuCore
import SwiftUI

/// Запись голосового: удерживать кнопку микрофона, отпустить — отправить,
/// увести палец влево — отменить (как на Android). AAC в .m4a.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var timer: Timer?

    func start(dir: URL) async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("voice_\(UUID().uuidString).m4a")
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            guard r.record() else { return false }
            recorder = r
            startedAt = Date()
            recording = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsed = Date().timeIntervalSince(self?.startedAt ?? Date()) }
            }
            return true
        } catch {
            return false
        }
    }

    /// Остановить; nil — запись отменена или слишком короткая.
    func stop(cancel: Bool) -> (URL, Int64)? {
        timer?.invalidate()
        timer = nil
        recording = false
        guard let r = recorder, let started = startedAt else { return nil }
        recorder = nil
        r.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let durationMs = Int64(Date().timeIntervalSince(started) * 1000)
        elapsed = 0
        if cancel || durationMs < 700 {
            try? FileManager.default.removeItem(at: r.url)
            return nil
        }
        return (r.url, durationMs)
    }
}

struct MicButton: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var recorder = VoiceRecorder()
    let peer: ChatSummary
    @State private var dragX: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            if recorder.recording {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(String(format: "%d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).monospacedDigit()
                Text("chat_swipeLeftToCancel").font(.caption).foregroundStyle(model.theme.textMuted).opacity(dragX < -20 ? 0.4 : 1)
            }
            Image(systemName: "mic.fill").font(.title2)
                .foregroundStyle(recorder.recording ? model.theme.onPrimary : model.theme.textMuted)
                .frame(width: 40, height: 40)
                .background(recorder.recording ? model.theme.primary : .clear, in: Circle())
                .scaleEffect(recorder.recording ? 1.3 : 1)
                .animation(.spring(duration: 0.25), value: recorder.recording)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !recorder.recording && dragX == 0 {
                                dragX = -0.001
                                Task { _ = await recorder.start(dir: model.core.dirs.documents.appendingPathComponent("outgoing")) }
                            }
                            dragX = min(0, v.translation.width)
                        }
                        .onEnded { _ in
                            let cancel = dragX < -80
                            dragX = 0
                            if case let (url, ms)? = recorder.stop(cancel: cancel) {
                                Task { await model.core.sendRecorded(url, durationMs: ms, videoNote: false, to: peer) }
                            }
                        }
                )
        }
    }
}

/// Голосовое в пузыре: пауза/воспроизведение и длительность; файл — скачать и расшифровать при первом нажатии.
struct VoiceBubbleContent: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let peerLogin: String
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var loading = false

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await toggle() } } label: {
                ZStack {
                    if loading { ProgressView() } else { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3) }
                }
                .frame(width: 40, height: 40)
                .background((message.isMine ? model.theme.onBubbleMine : model.theme.primary).opacity(0.2), in: Circle())
            }
            .buttonStyle(.plain)
            Image(systemName: "waveform").font(.title2).opacity(0.7)
            Text(String(format: "%d:%02d", Int((message.durationMs ?? 0) / 1000) / 60, Int((message.durationMs ?? 0) / 1000) % 60))
                .font(.caption).monospacedDigit()
        }
    }

    private func toggle() async {
        if let player, playing {
            player.pause()
            playing = false
            return
        }
        if player == nil {
            guard let url = await localFile() else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
        }
        player?.play()
        playing = true
        // конец воспроизведения — значок обратно
        let duration = player?.duration ?? 0
        Task {
            try? await Task.sleep(for: .seconds(max(0, duration - (player?.currentTime ?? 0))))
            if player?.isPlaying == false { playing = false }
        }
    }

    private func localFile() async -> URL? {
        if let path = message.localSourcePath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard let spec = DownloadSpec.of(message, peerLogin: peerLogin) else { return nil }
        loading = true
        defer { loading = false }
        return try? await model.core.downloads.ensureDownloaded(spec)
    }
}

/// Кружок (видеосообщение): круглое видео, по тапу — воспроизведение со звуком / пауза.
/// Кадр обрезается по центру до квадрата, как при записи на Android.
struct VideoNoteContent: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let peerLogin: String
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var loading = false

    var body: some View {
        let side = UIScreen.main.bounds.width * 0.55
        ZStack {
            if let player {
                PlayerLayerView(player: player).frame(width: side, height: side)
            } else {
                model.theme.surface
            }
            if loading { ProgressView() } else if !playing {
                Image(systemName: "play.fill").font(.title).foregroundStyle(.white).padding(14).background(.black.opacity(0.35), in: Circle())
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .onTapGesture { Task { await toggle() } }
    }

    private func toggle() async {
        if let player {
            if playing { player.pause() } else { player.play() }
            playing.toggle()
            return
        }
        loading = true
        defer { loading = false }
        let url: URL?
        if let path = message.localSourcePath, FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else if let spec = DownloadSpec.of(message, peerLogin: peerLogin) {
            url = try? await model.core.downloads.ensureDownloaded(spec)
        } else {
            url = nil
        }
        guard let url else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let p = AVPlayer(url: url)
        // доиграл — к началу, значок обратно
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero)
            playing = false
        }
        player = p
        p.play()
        playing = true
    }
}

/// AVPlayerLayer с заполнением (resizeAspectFill) — без растягивания кадра.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.videoGravity = .resizeAspectFill
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) { v.playerLayer.player = player }
}
