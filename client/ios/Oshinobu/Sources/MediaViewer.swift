import AVFoundation
import OshinobuCore
import SwiftUI

// Просмотр фото и видео чата на весь экран — как у Android (ui/chat/MediaViewerScreen.kt, MediaControls.kt):
// свайп в стороны — соседние, свайп вверх/вниз — закрыть (фон и шапка гаснут вслед за пальцем:
// под ними виден чат); фото — щипок до ×5 и двойной тап для увеличения вокруг точки (пока
// увеличено, листание и закрытие свайпом выключены); видео — тап пауза/продолжить и полоса
// перемотки. Шапка: «назад» слева, «⋮ → сохранить в галерею» справа.

/// Листаются фото и видео (не файлы, не голосовые, не кружки).
private func viewable(_ m: StoredMessage) -> Bool { m.isMedia && !m.isFile && !m.isVoice && !m.isVideoNote }

struct MediaViewerScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.navBack) private var navBack
    let peerLogin: String
    let messageId: String
    @State private var items: [StoredMessage]?
    @State private var index = 0
    /// Сдвиг листалки пальцем (pt) и закрытия свайпом.
    @State private var dragX: CGFloat = 0
    @State private var dismiss: CGFloat = 0
    @State private var zoomed = false
    @State private var axis: Axis?

    var body: some View {
        // при свайпе фон и шапка гаснут полностью, вместе с уезжающим фото
        let fade = min(1, abs(dismiss) / 400)
        GeometryReader { g in
            ZStack(alignment: .top) {
                Color.black.opacity(1 - fade)
                if let items, !items.isEmpty {
                    ZStack {
                        // рядом с текущей держим соседние: при листании они уже готовы
                        ForEach(max(0, index - 1)...min(items.count - 1, index + 1), id: \.self) { i in
                            MediaPage(message: items[i], peerLogin: peerLogin, current: i == index, onZoomChanged: { zoomed = $0 })
                                .frame(width: g.size.width, height: g.size.height)
                                .offset(x: CGFloat(i - index) * g.size.width + dragX)
                                .id(items[i].messageId)
                        }
                    }
                    .offset(y: dismiss)
                    .contentShape(Rectangle())
                    // рядом с жестами страницы (щипок, двойной тап), а не вместо них
                    .simultaneousGesture(zoomed ? nil : pagerGesture(width: g.size.width, count: items.count))
                    ViewerTopBar(message: items[index], peerLogin: peerLogin, onBack: navBack)
                        .padding(.top, windowSafeArea.top)
                        .opacity(1 - fade)
                } else if items == nil {
                    AppLoadingIndicator(size: 64).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea()
        .task {
            let list = model.core.chats.messages(peerLogin).filter(viewable)
            if list.isEmpty {
                navBack()
                return
            }
            index = list.firstIndex { $0.messageId == messageId } ?? 0
            items = list
        }
    }

    /// Один палец (viewerGestures + HorizontalPager): по горизонтали — листание с доводкой до соседней
    /// страницы (дальше половины или броском), по вертикали — закрытие свайпом (дальше 120 pt).
    private func pagerGesture(width: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                if axis == nil { axis = abs(v.translation.height) > abs(v.translation.width) ? .vertical : .horizontal }
                if axis == .vertical {
                    dismiss = v.translation.height
                } else {
                    var dx = v.translation.width
                    // за первой и последней — упор, страница едва тянется
                    if (index == 0 && dx > 0) || (index == count - 1 && dx < 0) { dx /= 3 }
                    dragX = dx
                }
            }
            .onEnded { v in
                defer { axis = nil }
                if axis == .vertical {
                    if abs(dismiss) > 120 {
                        withAnimation(.linear(duration: 0.2)) { dismiss = dismiss > 0 ? 3000 : -3000 } completion: { navBack() }
                    } else {
                        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)) { dismiss = 0 }
                    }
                    return
                }
                let velocity = v.velocity.width
                var target = index
                if dragX < -width / 2 || velocity < -400 { target = min(count - 1, index + 1) }
                else if dragX > width / 2 || velocity > 400 { target = max(0, index - 1) }
                // текущая страница сменяется сразу, сдвиг пересчитывается от неё — без скачка
                dragX += CGFloat(target - index) * width
                index = target
                withAnimation(.interpolatingSpring(stiffness: 400, damping: 40)) { dragX = 0 }
            }
    }
}

private struct ViewerTopBar: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let peerLogin: String
    let onBack: () -> Void
    @State private var moreFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 0) {
            IconButtonM(.arrowBack, tint: .white, action: onBack)
            Spacer()
            IconButtonM(.moreVert, tint: .white) {
                model.popups.menu(at: moreFrame, trailing: true) {
                    MenuItemM("mediaViewer_saveToGallery", icon: .download) { save() }
                }
            }
            .globalFrame($moreFrame)
        }
        .padding(4)
    }

    private func save() {
        let m = message, core = model.core, peerLogin = peerLogin, toasts = model.toasts
        Task {
            guard let url = try? await ChatMedia.file(m, peerLogin: peerLogin, core: core) else {
                toasts.show(tr("mediaViewer_saveFailed"))
                return
            }
            let ok = await PhotoLibrary.save(url, isVideo: m.isVideo)
            toasts.show(tr(ok ? "mediaViewer_saved" : "mediaViewer_saveFailed"))
        }
    }
}

/// Страница: файл качается (кольцо с процентом), готов или не получился.
private struct MediaPage: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let peerLogin: String
    let current: Bool
    let onZoomChanged: (Bool) -> Void
    @State private var file: URL?
    @State private var failed = false
    @State private var percent: Double?

    var body: some View {
        ZStack {
            if let file {
                if message.isVideo {
                    VideoPage(url: file, current: current)
                } else {
                    ZoomablePhoto(url: file, onZoomChanged: onZoomChanged)
                }
            } else if failed {
                MIcon(.brokenImage, size: 64, tint: .white.opacity(0.54))
            } else if let percent {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 4)
                    Circle().trim(from: 0, to: percent / 100).stroke(Color.white, lineWidth: 4).rotationEffect(.degrees(-90))
                }
                .frame(width: 40, height: 40)
            } else {
                AppLoadingIndicator(size: 64)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: message.messageId) {
            let core = model.core
            let progress = Task { @MainActor in
                guard let id = message.mediaId else { return }
                for await p in model.core.downloads.progress.stream() { percent = p[id] }
            }
            defer { progress.cancel() }
            do { file = try await ChatMedia.file(message, peerLogin: peerLogin, core: core) } catch { failed = true }
        }
    }
}

/// Фото с масштабом: щипок — до ×5, при увеличении — сдвиг одним пальцем, двойной тап — увеличить
/// вокруг точки или вернуть исходный размер (как в Телеге).
private struct ZoomablePhoto: View {
    let url: URL
    let onZoomChanged: (Bool) -> Void
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: g.size.width, height: g.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(MagnifyGesture()
                .onChanged { v in apply(min(5, max(1, baseScale * v.magnification)), offset, g.size) }
                .onEnded { _ in
                    baseScale = scale
                    baseOffset = offset
                })
            .simultaneousGesture(scale > 1 ? DragGesture()
                .onChanged { v in apply(scale, CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height), g.size) }
                .onEnded { _ in baseOffset = offset } : nil)
            .onTapGesture(count: 2, coordinateSpace: .local) { tap in
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.25)) {
                    if scale > 1 {
                        apply(1, .zero, g.size)
                    } else {
                        apply(2.5, CGSize(width: (g.size.width / 2 - tap.x) * 1.5, height: (g.size.height / 2 - tap.y) * 1.5), g.size)
                    }
                }
                baseScale = scale
                baseOffset = offset
            }
        }
        .task(id: url) {
            image = await Task.detached(priority: .userInitiated) {
                guard let img = UIImage(contentsOfFile: url.path) else { return nil }
                return await img.byPreparingThumbnail(ofSize: CGSize(width: 2560, height: 2560)) ?? img
            }.value
        }
    }

    private func apply(_ s: CGFloat, _ o: CGSize, _ size: CGSize) {
        let maxX = size.width * (s - 1) / 2, maxY = size.height * (s - 1) / 2
        scale = s
        offset = CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
        onZoomChanged(s > 1)
    }
}

/// Видео: тап — пауза/продолжить; текущая страница играет, ушедшая — на паузе; снизу — перемотка.
private struct VideoPage: View {
    let url: URL
    let current: Bool
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var endObserver: Any?

    var body: some View {
        ZStack {
            if let player { FitPlayerView(player: player) }
            if !playing {
                MIcon(.playArrow, size: 40, tint: .white).frame(width: 64, height: 64).background(Color.black.opacity(0.45), in: Circle())
                    .allowsHitTesting(false)
            }
            if let player { VideoSeekBar(player: player).frame(maxHeight: .infinity, alignment: .bottom) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let player else { return }
            if playing { player.pause() } else {
                if let item = player.currentItem, item.currentTime() >= item.duration { player.seek(to: .zero) }
                player.play()
            }
            playing.toggle()
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                Task { @MainActor in playing = false }
            }
            if current {
                p.play()
                playing = true
            }
        }
        .onChange(of: current) { _, now in
            if now { player?.play(); playing = true } else { player?.pause(); playing = false }
        }
        .onDisappear {
            player?.pause()
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        }
    }
}

/// Видео целиком, по центру (VideoView на Android).
private struct FitPlayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) { v.playerLayer.player = player }
}

/// Полоса перемотки: текущее время, ползунок (тянуть — перемотка), длительность.
/// Пока длительность неизвестна — не видна.
struct VideoSeekBar: View {
    @EnvironmentObject private var model: AppModel
    let player: AVPlayer
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var dragging: Double?

    var body: some View {
        Group {
            if duration > 0 {
                let shown = dragging ?? position
                HStack(spacing: 0) {
                    Text(verbatim: clock(shown)).font(.roboto(12)).foregroundStyle(.white).monospacedDigit()
                    Slider(value: Binding(get: { min(duration, max(0, shown)) }, set: { dragging = $0 }), in: 0...duration) { editing in
                        if !editing, let d = dragging {
                            player.seek(to: CMTime(seconds: d, preferredTimescale: 600))
                            position = d
                            dragging = nil
                        }
                    }
                    .tint(model.theme.primary)
                    .padding(.horizontal, 8)
                    Text(verbatim: clock(duration)).font(.roboto(12)).foregroundStyle(.white).monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .padding(.bottom, windowSafeArea.bottom)
                .background(Color.black.opacity(0.45))
            }
        }
        .task {
            while !Task.isCancelled {
                if dragging == nil { position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
                if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let mm = String(format: "%02d", (s % 3600) / 60), ss = String(format: "%02d", s % 60)
        return h > 0 ? "\(h):\(mm):\(ss)" : "\(mm):\(ss)"
    }
}
