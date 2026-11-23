import AVFoundation
import OshinobuCore
import SwiftUI

// Воспроизведение голосовых и видеосообщений — как у Android (ui/chat/Playback.kt): один плеер на всё
// приложение, новое останавливает прежнее. Живёт дольше экрана чата: вышли в список — звук продолжается
// (панель сверху, видео — плавающим окошком), остановка — крестиком.

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var activeId: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var positionMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var failedId: String?
    /// Играет видеосообщение (а не голосовое).
    @Published private(set) var isVideo = false
    /// Плеер играющего — к нему цепляются картинки видео (в ленте и в окошке).
    @Published private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusTask: Task<Void, Never>?

    /// Начать id с начала (или продолжить, если это уже активное).
    func play(_ id: String, file: URL, video: Bool = false) {
        if activeId == id, player != nil {
            resume()
            return
        }
        stop()
        failedId = nil
        let file = Self.playable(file, video: video)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: video ? .moviePlayback : .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: file)
        let p = AVPlayer(playerItem: item)
        player = p
        activeId = id
        isVideo = video
        positionMs = 0
        durationMs = 0
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self, self.player === p else { return }
                self.positionMs = Int64(max(0, t.seconds) * 1000)
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { self.durationMs = Int64(d * 1000) }
            }
        }
        statusTask = Task { [weak self] in
            for await status in item.publisher(for: \.status).values {
                guard let self else { return }
                if status == .failed {
                    self.failedId = id
                    self.stop()
                    return
                }
            }
        }
        p.play()
        isPlaying = true
    }

    /// AVPlayer узнаёт формат по расширению, а у вложений с Android имени файла нет — в кэше они
    /// «.bin». Такой файл отдаём плееру жёсткой ссылкой с расширением записи (m4a / mp4).
    static func playable(_ file: URL, video: Bool) -> URL {
        let known = ["m4a", "mp4", "mov", "aac", "mp3", "wav", "caf", "3gp", "m4v"]
        guard !known.contains(file.pathExtension.lowercased()) else { return file }
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("play_\(file.deletingPathExtension().lastPathComponent).\(video ? "mp4" : "m4a")")
        if !FileManager.default.fileExists(atPath: link.path) {
            if (try? FileManager.default.linkItem(at: file, to: link)) == nil { try? FileManager.default.copyItem(at: file, to: link) }
        }
        return link
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
    }

    func togglePlayPause() { if isPlaying { pause() } else { resume() } }

    func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusTask?.cancel()
        player?.pause()
        player = nil
        activeId = nil
        isPlaying = false
        positionMs = 0
        isVideo = false
    }
}

private func formatDuration(_ ms: Int64) -> String {
    let s = ms / 1000
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

/// Голосовое: кнопка play/pause, полоса прогресса, длительность (во время отправки — этап и процент).
struct VoicePlayer: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var media: ChatMedia
    @EnvironmentObject private var playback: PlaybackCoordinator
    let message: StoredMessage
    @State private var loading = false

    var body: some View {
        let m = message
        let accent = m.isMine ? model.theme.onBubbleMine : model.theme.primary
        let active = playback.activeId == m.messageId
        let playing = active && playback.isPlaying
        let total = active && playback.durationMs > 0 ? playback.durationMs : m.durationMs ?? 0
        let position = active ? playback.positionMs : 0
        let progress = total > 0 ? min(1, max(0, Double(position) / Double(total))) : 0
        let upload = media.uploadPhase(m)
        let step = upload.map { u in u.percent.map { "\(Int($0))%" } ?? u.text }
        HStack(spacing: 0) {
            ZStack {
                Circle().fill(accent.opacity(0.18))
                if loading {
                    Text(verbatim: "\(Int(media.downloadPhase(m)?.percent ?? 0))%").font(.roboto(8, .bold)).foregroundStyle(accent)
                } else {
                    MIcon(playing ? .pause : .playArrow, size: 20, tint: accent)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .tapZone()
            .onTapGesture { if !loading && step == nil { toggle(active: active, playing: playing) } }
            Spacer().frame(width: 8)
            VStack(alignment: .leading, spacing: 4) {
                if step != nil {
                    IndeterminateBar(color: accent)
                } else {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(accent.opacity(0.2))
                            Capsule().fill(accent).frame(width: g.size.width * progress)
                        }
                    }
                    .frame(height: 3)
                }
                Text(verbatim: step ?? formatDuration(active ? position : total))
                    .font(.roboto(11)).foregroundStyle(accent.opacity(0.85)).lineLimit(1)
            }
        }
        .frame(width: 200)
    }

    private func toggle(active: Bool, playing: Bool) {
        if playing { return playback.pause() }
        if active { return playback.resume() }
        loading = true
        Task {
            let file = try? await media.file(message)
            loading = false
            if let file { playback.play(message.messageId, file: file) }
        }
    }
}

/// Бегущая полоса (LinearProgressIndicator без прогресса) — пока голосовое отправляется.
private struct IndeterminateBar: View {
    let color: Color
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = CGFloat(tl.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 1.8) / 1.8)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.2))
                    Capsule().fill(color).frame(width: g.size.width * 0.4).offset(x: (t * 1.4 - 0.4) * g.size.width)
                }
                .clipped()
            }
        }
        .frame(height: 3)
    }
}

/// Картинка играющего видео: кадр обрезается по центру до места (как при записи).
struct VideoNoteSurface: UIViewRepresentable {
    let player: AVPlayer?

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

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// Видео-кружок (скруглённый квадрат 200, без пузыря): превью-кадр, по тапу — воспроизведение
/// с увеличением до ширины чата (220 мс); повторный тап — пауза.
struct VideoNotePlayer: View {
    @EnvironmentObject private var media: ChatMedia
    @EnvironmentObject private var playback: PlaybackCoordinator
    let message: StoredMessage
    let expandedSize: CGFloat
    @State private var loading = false
    @State private var thumb: UIImage?

    var body: some View {
        let m = message
        let active = playback.activeId == m.messageId
        let upload = m.isMine ? media.uploadPhase(m) : nil
        let size = active ? expandedSize : 200
        ZStack {
            Color.black
            if let thumb { Image(uiImage: thumb).resizable().scaledToFill().frame(width: size, height: size).clipped() }
            if active { VideoNoteSurface(player: playback.player) }
            if let upload {
                MediaStatusOverlay(text: upload.text, percent: upload.percent)
            } else if loading {
                MediaStatusOverlay(text: tr("media_downloading"), percent: media.downloadPhase(m)?.percent)
            } else if playback.failedId == m.messageId {
                MediaStatusOverlay(text: tr("media_playbackFailed"), percent: nil)
            } else if !(active && playback.isPlaying) {
                MIcon(.playArrow, size: 28, tint: .white).frame(width: 46, height: 46).background(Color.black.opacity(0.45), in: Circle())
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let d = m.durationMs {
                Text(verbatim: formatDuration(active ? playback.positionMs : d)).font(.roboto(11)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22), value: active)
        // тап забираем всегда — даже пока видео грузится или отправляется: иначе он открыл бы меню
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .tapZone()
        .onTapGesture { if !loading && upload == nil { toggle(active) } }
        .task(id: "\(m.messageId)|\(media.version)") { await loadThumb() }
    }

    private func toggle(_ active: Bool) {
        if active { return playback.togglePlayPause() }
        loading = true
        Task {
            let file = try? await media.file(message)
            loading = false
            if let file { playback.play(message.messageId, file: file, video: true) }
        }
    }

    private func loadThumb() async {
        if thumb != nil { return }
        if let p = message.localPreviewPath, let img = UIImage(contentsOfFile: p) {
            thumb = img
            return
        }
        guard let url = media.localFile(message) else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: PlaybackCoordinator.playable(url, video: true)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        // первые кадры кружка тёмные — камера ещё разгоняется; превью — с полсекунды
        if let (cg, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) { thumb = UIImage(cgImage: cg) }
    }
}

/// Панель под шапкой, пока что-то играет: play/pause и полная остановка.
struct MediaControlBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackCoordinator

    var body: some View {
        HStack(spacing: 0) {
            IconButtonM(playback.isPlaying ? .pause : .playArrow, tint: model.theme.primary) { playback.togglePlayPause() }
            Text("chat_mediaBarPlaying").font(.roboto(13)).foregroundStyle(model.theme.textMuted).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButtonM(.close, tint: model.theme.textMuted) { playback.stop() }
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// Видеосообщение, пока смотрим список чатов: окошко 132 поверх, его можно перетаскивать по экрану;
/// тап — пауза/продолжить. Появляется и исчезает — уменьшаясь и затухая.
struct FloatingVideoNote: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var offset: CGPoint?
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { g in
            let size: CGFloat = 132, margin: CGFloat = 12
            let maxX = max(margin, g.size.width - size - margin), maxY = max(margin, g.size.height - size - margin)
            let at = offset ?? CGPoint(x: maxX, y: margin)
            ZStack(alignment: .topLeading) {
                if playback.activeId != nil && playback.isVideo {
                    ZStack {
                        Color.black
                        VideoNoteSurface(player: playback.player)
                        if !playback.isPlaying {
                            MIcon(.playArrow, size: 24, tint: .white).frame(width: 40, height: 40).background(Color.black.opacity(0.45), in: Circle())
                        }
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .offset(x: at.x, y: at.y)
                    .gesture(DragGesture()
                        .onChanged { v in
                            let base = dragStart ?? at
                            if dragStart == nil { dragStart = at }
                            offset = CGPoint(x: min(maxX, max(margin, base.x + v.translation.width)), y: min(maxY, max(margin, base.y + v.translation.height)))
                        }
                        .onEnded { _ in dragStart = nil })
                    .onTapGesture { playback.togglePlayPause() }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center).combined(with: .opacity).animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22)),
                        removal: .scale(scale: 0.6, anchor: .center).combined(with: .opacity).animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26))))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
    }
}
