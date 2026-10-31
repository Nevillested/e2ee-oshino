import AVKit
import ImageIO
import Lottie
import OshinobuCore
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Скрепка: фото/видео из галереи или любой файл → копия в каталоге отправок → отправка.
struct AttachButton: View {
    @EnvironmentObject private var model: AppModel
    let peer: ChatSummary
    @State private var picked: [PhotosPickerItem] = []
    @State private var showGallery = false
    @State private var showFiles = false
    @State private var tooLarge = false

    var body: some View {
        Menu {
            Button { showGallery = true } label: { Label("media_photo", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("media_file", systemImage: "doc") }
        } label: {
            Image(systemName: "paperclip").font(.title2).foregroundStyle(model.theme.textMuted).frame(width: 34, height: 40)
        }
        .photosPicker(isPresented: $showGallery, selection: $picked, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await sendFiles(urls) }
        }
        .alert("chat_fileTooLarge", isPresented: $tooLarge) { Button("common_done") {} }
        .onChange(of: picked) { items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await send(items) }
        }
    }

    private var outgoing: URL {
        let dir = model.core.dirs.documents.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Выбранное в галерее — одним альбомом (как на Android).
    private func send(_ items: [PhotosPickerItem]) async {
        var files: [OshinobuCore.OutgoingFile] = []
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let stamp = Int(Date().timeIntervalSince1970)
            let raw = outgoing.appendingPathComponent("\(UUID().uuidString).\(ext)")
            do { try data.write(to: raw) } catch { continue }
            if isVideo {
                // HEVC/MOV из галереи iPhone → H.264 MP4: играет на любом Android
                let name = "video_\(stamp).mp4"
                let mp4 = outgoing.appendingPathComponent("\(UUID().uuidString)_\(name)")
                let ok = await transcodeToH264(raw, mp4)
                if ok { try? FileManager.default.removeItem(at: raw) }
                files.append(.init(url: ok ? mp4 : raw, name: ok ? name : "video_\(stamp).\(ext)", isVideo: true, isFile: false))
            } else {
                let name = "photo_\(stamp).\(ext)"
                let url = outgoing.appendingPathComponent("\(UUID().uuidString)_\(name)")
                do { try FileManager.default.moveItem(at: raw, to: url) } catch { continue }
                files.append(.init(url: url, name: name, isVideo: false, isFile: false))
            }
        }
        if !(await model.core.sendMedia(files, to: peer)).isEmpty { tooLarge = true }
    }

    /// Перекодировать видео в H.264/AAC MP4 (до 720p); false — не вышло, шлём как есть.
    private func transcodeToH264(_ src: URL, _ dst: URL) async -> Bool {
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return false }
        export.outputURL = dst
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        return export.status == .completed
    }

    /// Файлы из «Файлов» — копируем к себе (доступ к оригиналу временный).
    private func sendFiles(_ urls: [URL]) async {
        var files: [OshinobuCore.OutgoingFile] = []
        for src in urls {
            let access = src.startAccessingSecurityScopedResource()
            defer { if access { src.stopAccessingSecurityScopedResource() } }
            let dst = outgoing.appendingPathComponent("\(UUID().uuidString)_\(src.lastPathComponent)")
            do { try FileManager.default.copyItem(at: src, to: dst) } catch { continue }
            files.append(.init(url: dst, name: src.lastPathComponent, isVideo: false, isFile: true))
        }
        if !(await model.core.sendMedia(files, to: peer)).isEmpty { tooLarge = true }
    }
}

/// Пузырь вложения: превью фото, либо «скачать» с кольцом прогресса.
struct MediaBubbleContent: View {
    @EnvironmentObject private var model: AppModel
    let message: StoredMessage
    let peerLogin: String
    @State private var image: UIImage?
    @State private var progress: Double?
    @State private var viewing: UIImage?
    @State private var playing: URL?
    @State private var previewing: URL?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(maxWidth: 260, maxHeight: 320).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .blur(radius: message.isSpoiler ? 24 : 0)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(model.theme.surface.opacity(0.6)).frame(width: 220, height: 160)
                    .overlay {
                        if let progress {
                            ProgressView(value: progress, total: 100).progressViewStyle(.circular).tint(model.theme.primary)
                        } else if message.isFile {
                            Label { Text(verbatim: message.fileName ?? "") } icon: { Image(systemName: "doc.fill") }.padding()
                        } else {
                            Image(systemName: message.isVideo ? "play.circle.fill" : "arrow.down.circle.fill").font(.system(size: 44))
                                .foregroundStyle(model.theme.onPrimary.opacity(0.9))
                        }
                    }
            }
            if message.isVideo, image != nil {
                Image(systemName: "play.circle.fill").font(.system(size: 48)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .onTapGesture { Task { await open() } }
        .task(id: message.mediaId) { await load() }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let viewing { PhotoViewer(image: viewing) { self.viewing = nil } }
        }
        .fullScreenCover(isPresented: Binding(get: { playing != nil }, set: { if !$0 { playing = nil } })) {
            if let playing {
                VideoPlayer(player: AVPlayer(url: playing)).ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Button { self.playing = nil } label: {
                            Image(systemName: "xmark").font(.title3.bold()).foregroundStyle(.white).padding(12).background(.black.opacity(0.4), in: Circle())
                        }
                        .padding()
                    }
            }
        }
        .quickLookPreview($previewing)
    }

    private var spec: DownloadSpec? { DownloadSpec.of(message, peerLogin: peerLogin) }

    /// Тап: видео — плеер, файл — Quick Look (оба — после скачивания и расшифровки),
    /// фото — на весь экран в полном размере.
    private func open() async {
        if message.isVideo || message.isFile {
            guard let url = await localFile() else { return }
            if message.isVideo { playing = url } else { previewing = url }
            return
        }
        guard image != nil else { return download(user: true) }
        let url: URL? = message.localPreviewPath.map(URL.init(fileURLWithPath:))
            ?? spec.map { model.core.media.cacheURL(mediaId: $0.mediaId, fileName: $0.fileName) }
        guard let url else { return }
        viewing = await Task.detached { UIImage(contentsOfFile: url.path) }.value
    }

    private func load() async {
        // видео — кадр из своего исходника или из уже скачанной копии
        if message.isVideo {
            let candidates = [message.localSourcePath.map(URL.init(fileURLWithPath:)),
                              spec.map { model.core.media.cacheURL(mediaId: $0.mediaId, fileName: $0.fileName) }].compactMap { $0 }
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                if let frame = await videoFrame(url) { image = frame; return }
            }
        }
        // своё — сразу из локальной копии; чужое — из кэша расшифрованных или скачать
        if let path = message.localPreviewPath, let img = UIImage(contentsOfFile: path) { image = img; return }
        if let spec, !message.isVideo, !message.isFile {
            let cached = model.core.media.cacheURL(mediaId: spec.mediaId, fileName: spec.fileName)
            if let img = await decode(cached) { image = img; return }
        }
        download(user: false)
        guard let id = message.mediaId else { return }
        for await p in model.core.downloads.progress.stream() {
            progress = p[id]
            if p[id] == nil, let spec {
                let cached = model.core.media.cacheURL(mediaId: id, fileName: spec.fileName)
                let img = message.isVideo ? await videoFrame(cached) : await decode(cached)
                if let img { image = img; progress = nil; return }
            }
        }
    }

    /// Свой исходник или расшифрованная копия (скачивается при необходимости).
    private func localFile() async -> URL? {
        if let path = message.localSourcePath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard let spec else { return nil }
        progress = 0
        defer { progress = nil }
        return try? await model.core.downloads.ensureDownloaded(spec)
    }

    /// Мелкое — авто, крупное — по тапу (как на Android: авто до 3 МБ).
    private func download(user: Bool) {
        guard let spec, image == nil else { return }
        Task {
            if user { await model.core.downloads.requestUserDownload(spec) } else { await model.core.downloads.requestAutoDownload(spec) }
        }
    }

    /// Первый кадр видео с учётом поворота — превью в ленте.
    private func videoFrame(_ url: URL) async -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 780, height: 960)
        guard case let (cg, _)? = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Раскодировать в фоне с уменьшением под экран — без рывков ленты.
    private func decode(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path), let img = UIImage(contentsOfFile: url.path) else { return nil }
            return await img.byPreparingThumbnail(ofSize: CGSize(width: 780, height: 960))
        }.value
    }
}

/// Просмотр фото на весь экран: щипок до ×5, сдвиг увеличенного, двойной тап —
/// увеличить/вернуть, свайп вниз — закрыть (фон гаснет вслед за пальцем).
struct PhotoViewer: View {
    let image: UIImage
    let onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dismissDrag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(1 - min(abs(dismissDrag) / 400, 0.8)).ignoresSafeArea()
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dismissDrag)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in scale = min(5, max(1, lastScale * v)) }
                            .onEnded { _ in
                                lastScale = scale
                                if scale == 1 { withAnimation(.spring) { offset = .zero; lastOffset = .zero } }
                            }
                            .simultaneously(with: DragGesture()
                                .onChanged { v in
                                    if scale > 1 {
                                        offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                                    } else {
                                        dismissDrag = v.translation.height
                                    }
                                }
                                .onEnded { v in
                                    if scale > 1 { lastOffset = offset; return }
                                    if abs(v.translation.height) > 120 || abs(v.predictedEndTranslation.height) > 400 {
                                        withAnimation(.easeOut(duration: 0.2)) { dismissDrag = v.translation.height > 0 ? geo.size.height : -geo.size.height }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onClose)
                                    } else {
                                        withAnimation(.spring) { dismissDrag = 0 }
                                    }
                                })
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring) {
                            if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; lastScale = 2.5 }
                        }
                    }
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.title3.bold()).foregroundStyle(.white).padding(12).background(.black.opacity(0.4), in: Circle())
                        }
                    }
                    Spacer()
                }
                .padding()
                .opacity(dismissDrag == 0 ? 1 : 0)
            }
        }
        .statusBarHidden()
    }
}

/// Стикер в ленте: без пузыря, 45% ширины экрана (как на Android). PNG/WebP — картинкой
/// (анимированный WebP — кадрами через ImageIO), TGS — Lottie (gzip-JSON) с повтором.
struct StickerContent: View {
    let stickerId: String
    var side: CGFloat = UIScreen.main.bounds.width * 0.45

    var body: some View {
        StickerImage(stickerId: stickerId).frame(width: side, height: side)
    }
}

/// Картинка стикера любого формата (лента, панель, превью).
struct StickerImage: View {
    @EnvironmentObject private var model: AppModel
    let stickerId: String
    @State private var image: UIImage?
    @State private var lottie: LottieAnimation?
    @State private var animatedURL: URL?

    var body: some View {
        Group {
            if let lottie {
                LottieView(animation: lottie).playing(loopMode: .loop).resizable().scaledToFit()
            } else if let animatedURL {
                AnimatedImageView(url: animatedURL)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: stickerId) {
            guard let url = await model.core.stickers.file(stickerId) else { return }
            if url.pathExtension == "tgs" {
                lottie = await Task.detached {
                    guard let data = try? Data(contentsOf: url), let json = Gzip.decompress(data) else { return nil }
                    return try? LottieAnimation.from(data: json)
                }.value
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 {
                animatedURL = url
            } else {
                image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            }
        }
    }
}

/// Анимированная картинка (WebP/GIF/APNG) — кадры отдаёт ImageIO, по кругу.
struct AnimatedImageView: UIViewRepresentable {
    let url: URL

    final class Coordinator { var stop = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let coordinator = context.coordinator
        CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak view] _, frame, stop in
            guard let view, !coordinator.stop else { stop.pointee = true; return }
            view.image = UIImage(cgImage: frame)
        }
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) { coordinator.stop = true }
}

/// Системное меню «Поделиться» (сохранить в «Файлы», отправить в другое приложение).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Сохранение в «Фото» (только добавление — полный доступ к медиатеке не нужен).
enum PhotoLibrary {
    static func save(_ url: URL, isVideo: Bool) async -> Bool {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized ||
                PHPhotoLibrary.authorizationStatus(for: .addOnly) == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
            }
            return true
        } catch {
            return false
        }
    }
}
