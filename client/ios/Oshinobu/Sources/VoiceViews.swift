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
        guard RecordPermissions.granted(camera: false) else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            // вибрация замочка и отмены во время записи: иначе iOS глушит её, пока пишется звук
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
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
