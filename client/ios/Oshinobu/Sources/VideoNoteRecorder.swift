// AVCaptureSession запускается и останавливается на своей очереди — так рекомендует Apple
@preconcurrency import AVFoundation
import OshinobuCore
import SwiftUI

/// Запись кружка (Recording.kt на Android): фронтальная камера (зеркально — как видно в превью), звук,
/// до 5 мин. Кадры и звук пишет AVAssetWriter, а не AVCaptureMovieFileOutput: тот останавливает запись,
/// как только меняется камера, — а камеру переключают прямо во время записи, и кружок пропадал.
@MainActor
final class VideoNoteRecorder: ObservableObject {
    let session = AVCaptureSession()
    private let writer = NoteWriter()
    private var configured = false
    private var front = true
    /// Запуск, остановка и перенастройка камеры — по очереди на одном потоке (как sessionQueue у Apple):
    /// остановка прошлого кружка, догнавшая запуск нового, оставляла чёрный квадрат.
    nonisolated private let sessionQueue = DispatchQueue(label: "vnote.session")

    /// Есть и фронтальная, и основная камера.
    var canFlip: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
            && AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    /// Смена камеры во время записи: вход меняется в той же сессии, кадры идут в тот же файл.
    func flipCamera() {
        let toFront = !front
        guard let next = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: toFront ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: next) else { return }
        front = toFront
        let s = session, writer = writer
        sessionQueue.async {
            s.beginConfiguration()
            if let current = s.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) {
                s.removeInput(current)
            }
            if s.canAddInput(input) { s.addInput(input) }
            writer.orient(mirrored: toFront)
            s.commitConfiguration()
        }
    }

    /// Сессия настроена и камера запущена; false — нет доступа или камеры. Разрешения спрашивает
    /// кнопка записи заранее (системное окно посреди удержания ломает жест).
    func prepare() async -> Bool {
        guard RecordPermissions.granted(camera: true) else { return false }
        // звук кружка — своя аудиосессия, настроенная до запуска камеры: менять её посреди работы
        // камеры нельзя (запись сразу падала с -11805); вибрация замочка и отмены — разрешена
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try? audio.setActive(true)
        let s = session, writer = writer, needsConfig = !configured
        // каждый кружок начинается с фронтальной камеры, как на Android
        let resetToFront = !front
        front = true
        let ok = await withCheckedContinuation { cont in
            sessionQueue.async {
                if needsConfig, !Self.configure(s, writer) { return cont.resume(returning: false) }
                if resetToFront, let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                   let input = try? AVCaptureDeviceInput(device: cam) {
                    s.beginConfiguration()
                    s.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }.forEach(s.removeInput)
                    if s.canAddInput(input) { s.addInput(input) }
                    writer.orient(mirrored: true)
                    s.commitConfiguration()
                }
                if !s.isRunning { s.startRunning() }
                cont.resume(returning: s.isRunning)
            }
        }
        if ok { configured = true }
        return ok
    }

    nonisolated private static func configure(_ s: AVCaptureSession, _ writer: NoteWriter) -> Bool {
        s.beginConfiguration()
        defer { s.commitConfiguration() }
        // аудиосессию настраивает prepare() — камера её не перенастраивает
        s.automaticallyConfiguresApplicationAudioSession = false
        // SD, как на Android (Quality.SD): кружку больше не нужно
        s.sessionPreset = s.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let cameraIn = try? AVCaptureDeviceInput(device: camera), s.canAddInput(cameraIn) else { return false }
        s.addInput(cameraIn)
        if let mic = AVCaptureDevice.default(for: .audio), let micIn = try? AVCaptureDeviceInput(device: mic), s.canAddInput(micIn) {
            s.addInput(micIn)
        }
        return writer.attach(to: s)
    }

    func start(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writer.start(dir.appendingPathComponent("vnote_\(UUID().uuidString).mp4"))
    }

    /// Остановить; completion — файл и длительность (nil — отменено, слишком коротко или не записалось).
    func stop(cancel: Bool, completion: @escaping (URL?, Int64) -> Void) {
        writer.stop(cancel: cancel) { url, ms in
            Task { @MainActor in
                if let url, ms >= 700 { completion(url, ms) } else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    completion(nil, 0)
                }
            }
        }
    }

    func shutdown() {
        let s = session
        sessionQueue.async { s.stopRunning() }
    }
}

/// Кадры и звук с камеры → MP4 (H.264 + AAC) через AVAssetWriter; всё — на своей очереди.
private final class NoteWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private let queue = DispatchQueue(label: "vnote.writer")
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var url: URL?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var recording = false
    private var firstTime: CMTime?
    private var lastTime: CMTime?

    func attach(to s: AVCaptureSession) -> Bool {
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.setSampleBufferDelegate(self, queue: queue)
        audioOut.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(videoOut) else { return false }
        s.addOutput(videoOut)
        if s.canAddOutput(audioOut) { s.addOutput(audioOut) }
        orient(mirrored: true)
        return true
    }

    /// Кадр — вертикальный; фронтальная камера пишется зеркально, как её показывает превью
    /// (видеосообщение у получателя выглядит так, как его видел автор).
    func orient(mirrored: Bool) {
        guard let c = videoOut.connection(with: .video) else { return }
        if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        if c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirrored
        }
    }

    func start(_ url: URL) {
        queue.async {
            try? FileManager.default.removeItem(at: url)
            self.url = url
            self.writer = nil
            self.firstTime = nil
            self.lastTime = nil
            self.recording = true
        }
    }

    func stop(cancel: Bool, completion: @escaping @Sendable (URL?, Int64) -> Void) {
        queue.async {
            self.recording = false
            guard let writer = self.writer, writer.status == .writing, let url = self.url else {
                self.writer?.cancelWriting()
                completion(nil, 0)
                return
            }
            let ms = self.durationMs
            self.writer = nil
            if cancel {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                return completion(nil, 0)
            }
            self.videoIn?.markAsFinished()
            self.audioIn?.markAsFinished()
            // писатель живёт только на этой очереди; завершение читает его статус один раз
            nonisolated(unsafe) let finished = writer
            writer.finishWriting {
                completion(finished.status == .completed ? url : nil, ms)
            }
        }
    }

    private var durationMs: Int64 {
        guard let a = firstTime, let b = lastTime else { return 0 }
        return Int64(max(0, (b - a).seconds) * 1000)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, let url else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if output === videoOut {
            if writer == nil {
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
                guard startWriter(url, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), at: time) else {
                    recording = false
                    return
                }
            }
            if let v = videoIn, v.isReadyForMoreMediaData, v.append(sample) { lastTime = time }
        } else if output === audioOut, writer != nil, let firstTime, time >= firstTime {
            if let a = audioIn, a.isReadyForMoreMediaData { a.append(sample) }
        }
    }

    /// Файл заводится по первому кадру — его размер и время начала.
    private func startWriter(_ url: URL, width: Int, height: Int, at time: CMTime) -> Bool {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        // H.264, а не HEVC: кружок должен играть на любом Android
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_200_000],
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        audio.expectsMediaDataInRealTime = true
        guard w.canAdd(video) else { return false }
        w.add(video)
        if w.canAdd(audio) { w.add(audio) }
        guard w.startWriting() else { return false }
        w.startSession(atSourceTime: time)
        writer = w
        videoIn = video
        audioIn = audio
        firstTime = time
        lastTime = time
        return true
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

/// Разрешения на запись: микрофон (голосовое) и камера (кружок).
enum RecordPermissions {
    static func granted(camera: Bool) -> Bool {
        let mic = AVAudioApplication.shared.recordPermission == .granted
        return mic && (!camera || AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
    }

    /// Системные запросы недостающих разрешений (как запуск запроса на Android — запись при этом не начинается).
    static func request(camera: Bool) async {
        if AVAudioApplication.shared.recordPermission != .granted { _ = await AVAudioApplication.requestRecordPermission() }
        if camera && AVCaptureDevice.authorizationStatus(for: .video) != .authorized { _ = await AVCaptureDevice.requestAccess(for: .video) }
    }
}
