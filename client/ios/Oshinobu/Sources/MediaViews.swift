import AVKit
import ImageIO
import Lottie
import OshinobuCore
import Photos
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Фото на весь экран (PhotoViewerDialog на Android): щипок — масштаб до ×5, перетаскивание при увеличении,
/// двойной тап — сброс, тап — закрыть.
struct PhotoViewer: View {
    let image: UIImage
    let onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
        }
        .contentShape(Rectangle())
        .gesture(MagnifyGesture()
            .onChanged { v in
                scale = min(5, max(1, baseScale * v.magnification))
                if scale <= 1 { offset = .zero }
            }
            .onEnded { _ in
                baseScale = scale
                baseOffset = offset
            })
        .simultaneousGesture(scale > 1 ? DragGesture()
            .onChanged { v in offset = CGSize(width: baseOffset.width + v.translation.width, height: baseOffset.height + v.translation.height) }
            .onEnded { _ in baseOffset = offset } : nil)
        .onTapGesture(count: 2) {
            scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
        }
        .onTapGesture(perform: onClose)
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
/// Уже раскрытые стикеры — в памяти: панель и строка паков открываются сразу, без пустых клеток.
@MainActor
private enum StickerMemory {
    enum Item { case image(UIImage), lottie(LottieAnimation), animated(URL) }
    static var items: [String: Item] = [:]
}

struct StickerImage: View {
    @EnvironmentObject private var model: AppModel
    let stickerId: String
    @State private var image: UIImage?
    @State private var lottie: LottieAnimation?
    @State private var animatedURL: URL?

    init(stickerId: String) {
        self.stickerId = stickerId
        switch StickerMemory.items[stickerId] {
        case let .image(i)?: _image = State(initialValue: i)
        case let .lottie(l)?: _lottie = State(initialValue: l)
        case let .animated(u)?: _animatedURL = State(initialValue: u)
        case nil: break
        }
    }

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
            guard StickerMemory.items[stickerId] == nil, let url = await model.core.stickers.file(stickerId) else { return }
            if url.pathExtension == "tgs" {
                lottie = await Task.detached {
                    guard let data = try? Data(contentsOf: url), let json = Gzip.decompress(data) else { return nil }
                    return try? LottieAnimation.from(data: json)
                }.value
                if let lottie { StickerMemory.items[stickerId] = .lottie(lottie) }
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 {
                animatedURL = url
                StickerMemory.items[stickerId] = .animated(url)
            } else {
                image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
                if let image { StickerMemory.items[stickerId] = .image(image) }
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
