import OshinobuCore
import SwiftUI

/// Обои чата: картинка заполняет экран, её двигают и масштабируют пальцами;
/// на сервер уходит видимый кадр JPEG (длинная сторона ≤ 1920, как на Android).
struct WallpaperEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let peerLogin: String
    let peerAccountId: String

    /// Увеличение сверх «заполнить экран».
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var forPeer = true
    @State private var busy = false
    @State private var failed = false

    private static let maxZoom: CGFloat = 4
    private static let maxSide: CGFloat = 1920

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let k = scale(viewport, zoom * pinch)
            let o = clamp(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), k, viewport)
            ZStack(alignment: .bottom) {
                Image(uiImage: image).resizable()
                    .frame(width: image.size.width * k, height: image.size.height * k)
                    .offset(o)
                    .frame(width: viewport.width, height: viewport.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(SimultaneousGesture(
                        MagnificationGesture()
                            .updating($pinch) { v, s, _ in s = v }
                            .onEnded { v in
                                zoom = min(max(zoom * v, 1), Self.maxZoom)
                                offset = clamp(offset, scale(viewport, zoom), viewport)
                            },
                        DragGesture()
                            .updating($drag) { v, s, _ in s = v.translation }
                            .onEnded { v in
                                offset = clamp(CGSize(width: offset.width + v.translation.width, height: offset.height + v.translation.height),
                                               scale(viewport, zoom), viewport)
                            }))
                controls(viewport)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .alert("error_wallpaperFailed", isPresented: $failed) { Button("OK") {} }
    }

    private func controls(_ viewport: CGSize) -> some View {
        VStack(spacing: 12) {
            Text("chat_wallpaperHint").font(.footnote).foregroundStyle(.white.opacity(0.85))
            Toggle(isOn: $forPeer) { Text(verbatim: "\(NSLocalizedString("chat_wallpaperAlsoFor", comment: "")) \(peerLogin)") }
                .tint(model.theme.primary).foregroundStyle(.white)
            HStack(spacing: 12) {
                Button { dismiss() } label: { Text("common_cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.white)
                Button { Task { await apply(viewport) } } label: {
                    Group { if busy { ProgressView() } else { Text("chat_wallpaperSet") } }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(model.theme.primary).disabled(busy)
            }
        }
        .padding(16).padding(.bottom, 24)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    /// Масштаб «заполнить экран» × увеличение (в допустимых пределах).
    private func scale(_ viewport: CGSize, _ z: CGFloat) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 1 }
        let cover = max(viewport.width / image.size.width, viewport.height / image.size.height)
        return cover * min(max(z, 1), Self.maxZoom)
    }

    /// Сдвиг не даёт открыть край картинки.
    private func clamp(_ o: CGSize, _ k: CGFloat, _ viewport: CGSize) -> CGSize {
        let maxX = max(0, (image.size.width * k - viewport.width) / 2)
        let maxY = max(0, (image.size.height * k - viewport.height) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }

    private func apply(_ viewport: CGSize) async {
        busy = true
        defer { busy = false }
        let k = scale(viewport, zoom)
        let o = clamp(offset, k, viewport)
        let jpeg = await Task.detached(priority: .userInitiated) { [image] in Self.crop(image, viewport: viewport, k: k, offset: o) }.value
        do {
            guard let jpeg else { throw ApiError("error.wallpaperFailed") }
            try await model.core.wallpapers.set(peerAccountId, jpeg: jpeg, forPeer: forPeer)
            dismiss()
        } catch {
            failed = true
        }
    }

    /// Видимый кадр в пикселях исходника → JPEG 85%.
    private static func crop(_ image: UIImage, viewport: CGSize, k: CGFloat, offset: CGSize) -> Data? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let left = (viewport.width - image.size.width * k) / 2 + offset.width
        let top = (viewport.height - image.size.height * k) / 2 + offset.height
        let rect = CGRect(x: -left / k, y: -top / k, width: viewport.width / k, height: viewport.height / k)
        var out = CGSize(width: rect.width * image.scale, height: rect.height * image.scale)
        let longest = max(out.width, out.height)
        if longest > maxSide { out = CGSize(width: out.width * maxSide / longest, height: out.height * maxSide / longest) }
        out = CGSize(width: out.width.rounded(), height: out.height.rounded())
        let s = out.width / rect.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: out, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(x: -rect.minX * s, y: -rect.minY * s, width: image.size.width * s, height: image.size.height * s))
        }
    }
}
