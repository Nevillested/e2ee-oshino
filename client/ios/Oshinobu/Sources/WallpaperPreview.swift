import OshinobuCore
import SwiftUI

// Обои чата — как у Android (ui/chat/ChatWallpaper.kt): выбранная картинка сразу ложится фоном чата,
// пальцы двигают и масштабируют её (лента в это время не листается), двойной тап — как было; снизу —
// «Установить также у <собеседник>», «Установить как фон чата» и «Отмена». На сервер уходит видимый
// кадр JPEG (длинная сторона ≤ 1920).

/// Во сколько раз можно увеличить сверх «заполнить экран».
private let wallpaperMaxZoom: CGFloat = 5
/// Длинная сторона обоев: хватает на экран любого телефона, а JPEG — сотни КБ.
private let wallpaperMaxSide: CGFloat = 1920

/// Выбранная картинка до установки и её кадр: картинка всегда заполняет экран чата (zoom 1 — «заполнить»),
/// offset — сдвиг от центра. Пустых полей не бывает: сдвиг и масштаб ограничены.
@MainActor
final class WallpaperDraft: ObservableObject {
    let image: UIImage
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var offset: CGSize = .zero
    /// Размер экрана чата — по нему «заполнить» и вырезается кадр (пока не измерен — картинку не видно).
    @Published var viewport: CGSize = .zero

    init(image: UIImage) { self.image = image }

    private var coverScale: CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 1 }
        return max(viewport.width / image.size.width, viewport.height / image.size.height)
    }

    private func clamp(_ o: CGSize, _ z: CGFloat) -> CGSize {
        let k = coverScale * z
        let maxX = max(0, (image.size.width * k - viewport.width) / 2), maxY = max(0, (image.size.height * k - viewport.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }

    /// Жест: сдвиг pan и масштаб zoomChange вокруг точки centroid (координаты экрана чата).
    func transform(centroid: CGPoint, pan: CGSize, zoomChange: CGFloat) {
        let newZoom = min(wallpaperMaxZoom, max(1, zoom * zoomChange))
        // точка под пальцами остаётся под пальцами
        let px = centroid.x - viewport.width / 2, py = centroid.y - viewport.height / 2
        let r = newZoom / zoom
        offset = clamp(CGSize(width: (offset.width - px) * r + px + pan.width, height: (offset.height - py) * r + py + pan.height), newZoom)
        zoom = newZoom
    }

    func reset() {
        zoom = 1
        offset = .zero
    }

    /// Где рисовать картинку: прямоугольник в координатах экрана чата.
    var placement: CGRect {
        let k = coverScale * zoom
        let w = image.size.width * k, h = image.size.height * k
        return CGRect(x: (viewport.width - w) / 2 + offset.width, y: (viewport.height - h) / 2 + offset.height, width: w, height: h)
    }

    /// Видимый кадр → JPEG 85% (не больше 1920 по длинной стороне).
    func croppedJpeg() async -> Data? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let k = coverScale * zoom, place = placement, image = image, viewport = viewport
        return await Task.detached(priority: .userInitiated) {
            let rect = CGRect(x: -place.minX / k, y: -place.minY / k, width: viewport.width / k, height: viewport.height / k)
            var out = CGSize(width: rect.width * image.scale, height: rect.height * image.scale)
            let longest = max(out.width, out.height)
            if longest > wallpaperMaxSide { out = CGSize(width: out.width * wallpaperMaxSide / longest, height: out.height * wallpaperMaxSide / longest) }
            out = CGSize(width: out.width.rounded(), height: out.height.rounded())
            let s = out.width / rect.width
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: out, format: format).jpegData(withCompressionQuality: 0.85) { _ in
                image.draw(in: CGRect(x: -rect.minX * s, y: -rect.minY * s, width: image.size.width * s, height: image.size.height * s))
            }
        }.value
    }
}

/// Картинка-превью фоном чата в своём кадре.
struct WallpaperDraftImage: View {
    @ObservedObject var draft: WallpaperDraft

    var body: some View {
        GeometryReader { g in
            let place = draft.placement
            Image(uiImage: draft.image).resizable()
                .frame(width: place.width, height: place.height)
                .position(x: place.midX, y: place.midY)
                .onAppear { draft.viewport = g.size }
                .onChange(of: g.size) { _, size in draft.viewport = size }
        }
        .clipped()
    }
}

/// Слой жестов над чатом на время превью: двумя пальцами — масштаб, одним — сдвиг, двойной тап — как было.
struct WallpaperGestures: View {
    @ObservedObject var draft: WallpaperDraft
    @State private var lastMagnification: CGFloat = 1
    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(SimultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        draft.transform(centroid: v.startLocation, pan: .zero, zoomChange: v.magnification / lastMagnification)
                        lastMagnification = v.magnification
                    }
                    .onEnded { _ in lastMagnification = 1 },
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let pan = CGSize(width: v.translation.width - lastTranslation.width, height: v.translation.height - lastTranslation.height)
                        draft.transform(centroid: v.location, pan: pan, zoomChange: 1)
                        lastTranslation = v.translation
                    }
                    .onEnded { _ in lastTranslation = .zero }))
            .onTapGesture(count: 2) { draft.reset() }
    }
}

/// Превью обоев — вместо поля ввода.
struct WallpaperPreviewBar: View {
    @EnvironmentObject private var model: AppModel
    let peerAccountId: String
    let peerLogin: String
    let canSetForPeer: Bool
    @Binding var forPeer: Bool
    let busy: Bool
    let onSet: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("chat_wallpaperHint").font(.roboto(13)).foregroundStyle(model.theme.textMuted).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.bottom, 8)
            if canSetForPeer {
                Button { forPeer.toggle() } label: {
                    HStack(spacing: 0) {
                        CheckboxM(checked: forPeer).frame(width: 48, height: 48)
                        Text("chat_wallpaperAlsoFor").font(.roboto(16)).foregroundStyle(model.theme.textPrimary)
                        Spacer().frame(width: 6)
                        PeerAvatar(accountId: peerAccountId, size: 20)
                        Spacer().frame(width: 4)
                        PeerName(accountId: peerAccountId, login: peerLogin).font(.roboto(16, .semibold)).foregroundStyle(model.theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy)
                Gap(8)
            }
            PrimaryButton("chat_wallpaperSet", loading: busy, action: onSet)
            Gap(8)
            SecondaryButton("common_cancel", enabled: !busy, action: onCancel)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12 + windowSafeArea.bottom)
        .background(model.theme.surface, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
        // касания сквозь панель в ленту не проходят
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}
