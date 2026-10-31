import AVFoundation
import OshinobuCore
import SwiftUI

/// Запись кружка: фронтальная камера (зеркально — как видно в превью), звук, до 60 с.
@MainActor
final class VideoNoteRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var startedAt: Date?
    private var timer: Timer?
    private var finish: ((URL?, Int64) -> Void)?
    private var cancelled = false

    /// Камера и микрофон; false — нет доступа.
    func prepare() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video), await AVCaptureDevice.requestAccess(for: .audio) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let cameraIn = try? AVCaptureDeviceInput(device: camera), session.canAddInput(cameraIn) else { return false }
        session.addInput(cameraIn)
        if let mic = AVCaptureDevice.default(for: .audio), let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.maxRecordedDuration = CMTime(seconds: 60, preferredTimescale: 600)
        if let connection = output.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            // H.264, а не HEVC по умолчанию: кружок должен играть на любом Android
            if output.availableVideoCodecTypes.contains(.h264) {
                output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
            }
        }
        let s = session
        Task.detached { s.startRunning() }
        return true
    }

    func start(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("vnote_\(UUID().uuidString).mp4")
        cancelled = false
        output.startRecording(to: url, recordingDelegate: self)
        startedAt = Date()
        recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(self?.startedAt ?? Date()) }
        }
    }

    /// Остановить; [completion] — файл и длительность (nil — отменено/слишком коротко).
    func stop(cancel: Bool, completion: @escaping (URL?, Int64) -> Void) {
        cancelled = cancel
        finish = completion
        timer?.invalidate()
        recording = false
        output.stopRecording()
    }

    func shutdown() {
        let s = session
        Task.detached { s.stopRunning() }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            let durationMs = Int64(Date().timeIntervalSince(startedAt ?? Date()) * 1000)
            if cancelled || durationMs < 700 {
                try? FileManager.default.removeItem(at: url)
                finish?(nil, 0)
            } else {
                finish?(url, durationMs)
            }
            finish = nil
        }
    }
}

/// Превью камеры в круге.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}
}

/// Кнопка кружка: удерживать — запись с превью по центру экрана, отпустить — отправить, влево — отменить.
struct VideoNoteButton: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var recorder = VideoNoteRecorder()
    let peer: ChatSummary
    @State private var showing = false
    @State private var dragX: CGFloat = 0

    var body: some View {
        Image(systemName: "video.circle.fill").font(.system(size: 30))
            .foregroundStyle(recorder.recording ? model.theme.primary : model.theme.textMuted)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !showing {
                            showing = true
                            Task {
                                if await recorder.prepare() {
                                    recorder.start(dir: model.core.dirs.documents.appendingPathComponent("outgoing"))
                                } else {
                                    showing = false
                                }
                            }
                        }
                        dragX = min(0, v.translation.width)
                    }
                    .onEnded { _ in
                        let cancel = dragX < -80
                        dragX = 0
                        recorder.stop(cancel: cancel) { url, ms in
                            showing = false
                            recorder.shutdown()
                            if let url { Task { await model.core.sendRecorded(url, durationMs: ms, videoNote: true, to: peer) } }
                        }
                    }
            )
            .overlay {
                if showing {
                    // превью — над лентой
                    Color.clear.overlay(alignment: .center) {
                        VStack(spacing: 12) {
                            CameraPreview(session: recorder.session)
                                .frame(width: 260, height: 260).clipShape(Circle())
                                .overlay(Circle().stroke(model.theme.primary, lineWidth: 3))
                            Text(String(format: "%d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60))
                                .monospacedDigit().foregroundStyle(.white)
                        }
                        .offset(y: -360)
                        .allowsHitTesting(false)
                    }
                }
            }
    }
}
