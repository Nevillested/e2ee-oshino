import AVFoundation
import AVKit
import OshinobuCore
import Photos
import SwiftUI
import UniformTypeIdentifiers

// Вложения — как у Android (ui/chat/Attachments.kt, GallerySheet.kt): скрепка → развилка со стрелками
// «Медиафайлы» / «Документы»; медиафайлы — своя галерея плитками (камера, выбор с номером, просмотр,
// спойлер, подпись), отправка — альбомом.

/// Скрепка в поле ввода.
struct AttachButton: View {
    @EnvironmentObject private var model: AppModel
    let peer: ChatSummary
    @State private var frame: CGRect = .zero
    @State private var files = false

    var body: some View {
        Button {
            let anchor = CGPoint(x: frame.midX, y: frame.midY)
            // развилка — поверх чата, клавиатура остаётся на месте (и поле ввода над ней)
            model.popups.show(dim: false, keepsKeyboard: true) {
                AttachLauncher(anchor: anchor) { choice in
                    model.popups.dismiss()
                    // галерея и «Файлы» на Android — отдельные окна: клавиатура поля ввода уходит
                    if choice != nil {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    switch choice {
                    case .media:
                        model.popups.show(dim: false) {
                            BottomSheetM(fraction: 0.75) { GallerySheet(peer: peer) }
                        }
                    case .files: files = true
                    case nil: break
                    }
                }
            }
        } label: {
            MIcon(.attachFile, tint: model.theme.textMuted).frame(width: 36, height: 40)
                .accessibilityIdentifier("attachButton")
        }
        .buttonStyle(RippleStyle(shape: Circle(), color: model.theme.textPrimary))
        .globalFrame($frame)
        .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await sendDocuments(urls) }
        }
    }

    /// Файлы из «Файлов» — копируем к себе (доступ к оригиналу временный).
    private func sendDocuments(_ urls: [URL]) async {
        var list: [OshinobuCore.OutgoingFile] = []
        for src in urls {
            let access = src.startAccessingSecurityScopedResource()
            defer { if access { src.stopAccessingSecurityScopedResource() } }
            let dst = MediaExport.outgoingDir(model.core).appendingPathComponent("\(UUID().uuidString)_\(src.lastPathComponent)")
            do { try FileManager.default.copyItem(at: src, to: dst) } catch { continue }
            list.append(.init(url: dst, name: src.lastPathComponent, isVideo: false, isFile: true))
        }
        if !(await model.core.sendMedia(list, to: peer)).isEmpty { model.toasts.show(tr("chat_fileTooLarge")) }
    }
}

enum AttachChoice { case media, files }

/// Развилка по скрепке: экран затемняется, скрепка остаётся яркой, от неё под 45° выезжают две стрелки —
/// влево к «Медиафайлы», вправо к «Документы». Нажатие мимо — всё сворачивается; результат — после анимации.
struct AttachLauncher: View {
    @EnvironmentObject private var model: AppModel
    let anchor: CGPoint
    let onResult: (AttachChoice?) -> Void
    @State private var t: CGFloat = 0
    @State private var closing = false

    private let arrowLength: CGFloat = 70
    private let circle: CGFloat = 48

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            let a = CGPoint(x: anchor.x - origin.x, y: anchor.y - origin.y)
            let diag = arrowLength * 0.70710677
            let margin: CGFloat = 28
            let left = CGPoint(x: min(max(margin, a.x - diag), g.size.width - margin), y: a.y - diag)
            let right = CGPoint(x: min(max(margin, a.x + diag), g.size.width - margin), y: a.y - diag)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55 * t)))
                    for target in [left, right] { drawArrow(ctx, from: a, to: pullBack(a, target, by: circle / 2 + 6)) }
                }
                .contentShape(Rectangle())
                .onTapGesture { close(nil) }
                // яркий клон скрепки поверх затемнения
                MIcon(.attachFile, tint: .white).opacity(t).position(a)
                choice(.oPermMedia, at: left, .media).accessibilityIdentifier("attachMedia")
                choice(.oInsertDriveFile, at: right, .files)
            }
        }
        .onAppear { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.32)) { t = 1 } }
    }

    private func choice(_ icon: MaterialIcon, at center: CGPoint, _ value: AttachChoice) -> some View {
        MIcon(icon, size: 22, tint: model.theme.onPrimary)
            .frame(width: circle, height: circle)
            .background(model.theme.primary, in: Circle())
            .scaleEffect(0.4 + 0.6 * t)
            .opacity(t)
            .position(center)
            .onTapGesture { close(value) }
    }

    private func close(_ result: AttachChoice?) {
        guard !closing else { return }
        closing = true
        withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.24)) { t = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onResult(result) }
    }

    /// Конец стрелки отступает от центра кружка, чтобы наконечник упирался в него, а не прятался под ним.
    private func pullBack(_ start: CGPoint, _ end: CGPoint, by: CGFloat) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
        guard length > by else { return start }
        return CGPoint(x: end.x - dx * by / length, y: end.y - dy * by / length)
    }

    /// Белая стрелка, растущая с t.
    private func drawArrow(_ ctx: GraphicsContext, from start: CGPoint, to end: CGPoint) {
        guard t > 0 else { return }
        let color = Color.white.opacity(t)
        let tip = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        var line = Path()
        line.move(to: start)
        line.addLine(to: tip)
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        guard t >= 0.15 else { return }
        let angle = atan2(end.y - start.y, end.x - start.x), head: CGFloat = 10, spread: CGFloat = 0.5
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x - head * cos(angle - spread), y: tip.y - head * sin(angle - spread)))
        p.addLine(to: CGPoint(x: tip.x - head * cos(angle + spread), y: tip.y - head * sin(angle + spread)))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }
}

// MARK: - выгрузка из галереи в файлы для отправки

enum MediaExport {
    static func outgoingDir(_ core: OshinobuCore) -> URL {
        let dir = core.dirs.documents.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Фото — JPEG (откроется на любом Android), видео — H.264/AAC MP4 до 720p.
    static func export(_ asset: PHAsset, to dir: URL, spoiler: Bool) async -> OshinobuCore.OutgoingFile? {
        let stamp = Int(Date().timeIntervalSince1970)
        if asset.mediaType == .video {
            guard let av = await avAsset(asset) else { return nil }
            let name = "video_\(stamp).mp4"
            let dst = dir.appendingPathComponent("\(UUID().uuidString)_\(name)")
            guard await transcodeToH264(av, dst) else { return nil }
            return .init(url: dst, name: name, isVideo: true, isFile: false, isSpoiler: spoiler)
        }
        guard let data = await imageData(asset), let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        let name = "photo_\(stamp).jpg"
        let dst = dir.appendingPathComponent("\(UUID().uuidString)_\(name)")
        do { try jpeg.write(to: dst) } catch { return nil }
        return .init(url: dst, name: name, isVideo: false, isFile: false, isSpoiler: spoiler)
    }

    private static func imageData(_ asset: PHAsset) async -> Data? {
        await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in cont.resume(returning: data) }
        }
    }

    static func avAsset(_ asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { cont in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in cont.resume(returning: av) }
        }
    }

    /// Перекодировать видео в H.264/AAC MP4 (до 720p): играет на любом Android.
    static func transcodeToH264(_ asset: AVAsset, _ dst: URL) async -> Bool {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return false }
        export.shouldOptimizeForNetworkUse = true
        do {
            try await export.export(to: dst, as: .mp4)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - галерея

/// Галерея устройства: что разрешено и что в ней (новые первыми).
@MainActor
final class DeviceGallery: ObservableObject {
    enum Access { case none, partial, full }

    @Published private(set) var access: Access = .none
    @Published private(set) var items: [PHAsset]?
    let thumbnails = PHCachingImageManager()

    func load() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        access = status == .authorized ? .full : status == .limited ? .partial : .none
        guard access != .none else {
            items = []
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in list.append(a) }
        items = list
    }
}

/// Своя галерея: шторка с сеткой фото и видео, первая плитка — живая камера. Кружок в углу плитки —
/// выбор с номером порядка, нажатие по плитке — просмотр на весь экран. С выбором — счётчик,
/// «скрыть под спойлером» и подпись; отправка — альбомом.
struct GallerySheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var cover: SheetCover
    @EnvironmentObject private var header: SheetHeader
    @Environment(\.sheetClose) private var close
    @Environment(\.sheetPull) private var sheetPull
    let peer: ChatSummary
    @StateObject private var gallery = DeviceGallery()
    @State private var selected: [PHAsset] = []
    @State private var spoiler = false
    @State private var previewIndex: Int?
    @State private var sending = false
    @State private var caption = ""
    @State private var menu = false

    var body: some View {
        VStack(spacing: 0) {
            if gallery.access == .partial {
                Button { presentLimitedPicker() } label: {
                    HStack(spacing: 8) {
                        MIcon(.oInfo, size: 16, tint: model.theme.primary)
                        Text("media_limitedAccess").font(.roboto(12)).foregroundStyle(model.theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(model.theme.primary.opacity(0.15))
                }
                .buttonStyle(.plain)
            }

            ZStack(alignment: .bottom) {
                if let items = gallery.items {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                            CameraTile(live: cover.view == nil) { openCamera() }
                            ForEach(Array(items.enumerated()), id: \.element.localIdentifier) { i, asset in
                                let order = selected.firstIndex(of: asset).map { $0 + 1 }
                                GalleryTile(asset: asset, manager: gallery.thumbnails, order: order, blurred: spoiler && order != nil,
                                            onOpen: { previewIndex = i }, onToggle: { toggle(asset) })
                            }
                        }
                        .padding(.bottom, selected.isEmpty ? 0 : 72)
                        // сетка у верха — палец вниз тянет всю шторку
                        .background(ScrollPullsSheet(pull: sheetPull))
                    }
                } else {
                    AppLoadingIndicator(size: 64).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !selected.isEmpty {
                    // клавиатуру под подписью раскладывает сама подпись — шторка остаётся на месте
                    CaptionBar(text: $caption, sending: sending, onSend: send)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selected.isEmpty)
        .ignoresSafeArea(.keyboard)
        // «Выбрано: N» — в строке ручки шторки: плитки не съезжают и лишнего места нет
        .onChange(of: selected.count, initial: true) { _, _ in updateHeader() }
        .onChange(of: spoiler) { _, _ in updateHeader() }
        .onChange(of: menu) { _, _ in updateHeader() }
        .task { await gallery.load() }
        .fullScreenCover(item: Binding(get: { previewIndex.map(PreviewStart.init) }, set: { previewIndex = $0?.index })) { start in
            GalleryPreview(items: gallery.items ?? [], start: start.index, selected: selected, caption: $caption, sending: sending,
                           onToggle: toggle, onSend: { current in
                               if selected.isEmpty { selected.append(current) }
                               send()
                           }, onClose: { previewIndex = nil })
                .environmentObject(model)
        }
    }

    /// Съёмка — поверх шторки во весь экран; разрешения нет — системный запрос, разрешили — съёмка.
    private func openCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showCamera()
        case .notDetermined: Task { if await AVCaptureDevice.requestAccess(for: .video) { showCamera() } }
        // отказано раньше — как на Android: повторный запрос система не показывает, съёмки нет
        default: break
        }
    }

    private func showCamera() {
        let core = model.core, peer = peer
        cover.view = AnyView(CameraCaptureView(onClose: { cover.view = nil }) { url, caption in
            // снимок уходит сразу: шторка под съёмкой убирается без анимации, фото падает в чат
            close(animated: false) {
                Task { _ = await core.sendMedia([.init(url: url, name: "photo_\(Int(Date().timeIntervalSince1970)).jpg", isVideo: false, isFile: false)],
                                                 to: peer, caption: caption) }
            }
        }
        .environmentObject(model))
    }

    private func updateHeader() {
        header.view = selected.isEmpty ? nil : AnyView(selectionBar.environmentObject(model))
    }

    /// «Выбрано: N» и меню со спойлером.
    private var selectionBar: some View {
        HStack(spacing: 0) {
            Text(verbatim: "\(tr("media_selectedCount")): \(selected.count)").font(.roboto(18, .semibold)).foregroundStyle(model.theme.textPrimary)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.25), value: selected.count)
            Spacer()
            IconButtonM(.moreVert) { menu.toggle() }
                .overlay(alignment: .topTrailing) {
                    if menu {
                        Button {
                            menu = false
                            spoiler.toggle()
                        } label: {
                            HStack(spacing: 12) {
                                MIcon(spoiler ? .checkBox : .checkBoxOutlineBlank, tint: model.theme.textMuted)
                                Text("media_hideWithSpoiler").font(.roboto(14, .medium)).foregroundStyle(model.theme.textPrimary).fixedSize()
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 48)
                        }
                        .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
                        .padding(.vertical, 8)
                        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: cardRadius))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                        .offset(y: 44)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .topTrailing)))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: menu)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
    }

    private func toggle(_ asset: PHAsset) {
        if let i = selected.firstIndex(of: asset) { selected.remove(at: i) } else { selected.append(asset) }
        if selected.isEmpty { spoiler = false }
    }

    private func send() {
        guard !sending else { return }
        sending = true
        let ordered = selected, text = caption.trimmingCharacters(in: .whitespacesAndNewlines), spoiler = spoiler
        let core = model.core, peer = peer, toasts = model.toasts
        Task {
            let dir = MediaExport.outgoingDir(core)
            var files: [OshinobuCore.OutgoingFile] = []
            for asset in ordered { if let f = await MediaExport.export(asset, to: dir, spoiler: spoiler) { files.append(f) } }
            close {
                Task { if !files.isEmpty, !(await core.sendMedia(files, to: peer, caption: text)).isEmpty { toasts.show(tr("chat_fileTooLarge")) } }
            }
        }
    }

    private func presentLimitedPicker() {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in Task { await gallery.load() } }
    }
}

private struct PreviewStart: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Кружок выбора с номером порядка.
struct OrderBadge: View {
    @EnvironmentObject private var model: AppModel
    let order: Int?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(order != nil ? model.theme.primary : Color.black.opacity(0.45))
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if let order { Text(verbatim: "\(order)").font(.roboto(size / 2, .bold)).foregroundStyle(model.theme.onPrimary) }
        }
        .frame(width: size, height: size)
    }
}

private struct GalleryTile: View {
    @EnvironmentObject private var model: AppModel
    let asset: PHAsset
    let manager: PHCachingImageManager
    let order: Int?
    let blurred: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    @State private var thumb: UIImage?

    var body: some View {
        GeometryReader { g in
            ZStack {
                model.theme.surface
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                        .blur(radius: blurred ? 12 : 0)
                }
                if blurred { Color.black.opacity(0.35) }
                if asset.mediaType == .video {
                    MIcon(.playCircleFilled, size: 20, tint: .white).padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                // зона выбора — квадрат 44 вокруг кружка в углу, остальное — просмотр
                Color.clear.contentShape(Rectangle())
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) { OrderBadge(order: order, size: 24).padding(6) }
                    .onTapGesture(perform: onToggle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .animation(.easeInOut(duration: 0.2), value: blurred)
        }
        .aspectRatio(1, contentMode: .fit)
        .border(Color.black.opacity(0.26), width: 0.5)
        .task(id: asset.localIdentifier) {
            let side = UIScreen.main.bounds.width / 3 * UIScreen.main.scale
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            for await image in thumbnails(CGSize(width: side, height: side), options) { thumb = image }
        }
    }

    private func thumbnails(_ size: CGSize, _ options: PHImageRequestOptions) -> AsyncStream<UIImage> {
        AsyncStream { cont in
            let id = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                if let image { cont.yield(image) }
                if (info?[PHImageResultIsDegradedKey] as? Bool) != true { cont.finish() }
            }
            cont.onTermination = { [manager] _ in manager.cancelImageRequest(id) }
        }
    }
}

/// Плитка с живым превью задней камеры (без разрешения — просто значок).
private struct CameraTile: View {
    @EnvironmentObject private var model: AppModel
    /// Живое превью — пока съёмка не открыта (камера одна).
    let live: Bool
    let onTap: () -> Void
    @StateObject private var preview = CameraTilePreview()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            model.theme.surface
            if preview.running && live { CameraPreview(session: preview.session) }
            MIcon(.cameraAlt, size: 20, tint: .white).padding(6)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .border(Color.black.opacity(0.26), width: 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            preview.stop()
            onTap()
        }
        .onAppear { preview.start() }
        .onDisappear { preview.stop() }
        .onChange(of: live) { _, now in if now { preview.start() } }
    }
}

@MainActor
private final class CameraTilePreview: ObservableObject {
    let session = AVCaptureSession()
    @Published var running = false
    private var configured = false

    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .medium
            if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            configured = true
        }
        let s = session
        Task {
            await Task.detached { s.startRunning() }.value
            running = s.isRunning
        }
    }

    func stop() {
        let s = session
        running = false
        Task.detached { s.stopRunning() }
    }
}

/// Съёмка фото из галереи (CameraCapture.kt): превью камеры во весь экран, затвор, смена камеры.
/// После снимка — он на весь экран с подписью; крестик — переснять.
private struct CameraCaptureView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void
    let onSend: (URL, String) -> Void
    @StateObject private var camera = PhotoCamera()
    @State private var shot: URL?
    @State private var image: UIImage?
    @State private var caption = ""

    var body: some View {
        ZStack {
            Color.black
            if let shot {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                VStack {
                    HStack {
                        RoundIcon(.close) {
                            try? FileManager.default.removeItem(at: shot)
                            self.shot = nil
                            image = nil
                        }
                        Spacer()
                    }
                    .padding(.top, windowSafeArea.top + 8).padding(.leading, 8)
                    Spacer()
                    CaptionBar(text: $caption, sending: false) { onSend(shot, caption.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
            } else {
                CameraPreview(session: camera.session)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        RoundIcon(.close, action: onClose)
                        Spacer()
                        Button { capture() } label: {
                            ZStack {
                                Circle().strokeBorder(.white, lineWidth: 4)
                                if camera.capturing { AppLoadingIndicator(size: 64) }
                            }
                            .frame(width: 72, height: 72)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        RoundIcon(.cameraswitch) { camera.flip() }
                        Spacer()
                    }
                    .padding(.bottom, windowSafeArea.bottom + 24)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private func capture() {
        let dir = MediaExport.outgoingDir(model.core)
        camera.capture(to: dir) { url in
            guard let url else { return }
            shot = url
            Task { image = await Task.detached { UIImage(contentsOfFile: url.path) }.value }
        }
    }
}

/// Круглая кнопка на тёмной подложке (съёмка).
private struct RoundIcon: View {
    let icon: MaterialIcon
    let action: () -> Void

    init(_ icon: MaterialIcon, action: @escaping () -> Void) {
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MIcon(icon, tint: .white).frame(width: 52, height: 52).background(Color.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(RippleStyle(shape: Circle(), color: .white))
    }
}

/// Камера для фото: задняя по умолчанию, смена на фронтальную; снимок — JPEG в папку отправок.
@MainActor
private final class PhotoCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var position = AVCaptureDevice.Position.back
    @Published private(set) var capturing = false
    private var pending: ((URL?) -> Void, URL)?

    func start() {
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .photo
            attach(position)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            configured = true
        }
        let s = session
        Task.detached { s.startRunning() }
    }

    func stop() {
        let s = session
        Task.detached { s.stopRunning() }
    }

    func flip() {
        position = position == .back ? .front : .back
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        attach(position)
        session.commitConfiguration()
    }

    private func attach(_ position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        self.input = input
    }

    func capture(to dir: URL, done: @escaping (URL?) -> Void) {
        guard !capturing else { return }
        capturing = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pending = (done, dir.appendingPathComponent("\(UUID().uuidString).jpg"))
        output.connection(with: .video)?.videoRotationAngle = 90
        output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            capturing = false
            guard let (done, url) = pending else { return }
            pending = nil
            if let data, (try? data.write(to: url)) != nil { done(url) } else { done(nil) }
        }
    }
}

/// Предпросмотр из галереи на весь экран: листание, выбор (кружок справа вверху), видео, подпись и «отправить»;
/// закрывается свайпом вверх или вниз.
private struct GalleryPreview: View {
    @EnvironmentObject private var model: AppModel
    let items: [PHAsset]
    let start: Int
    let selected: [PHAsset]
    @Binding var caption: String
    let sending: Bool
    let onToggle: (PHAsset) -> Void
    let onSend: (PHAsset) -> Void
    let onClose: () -> Void
    @State private var page = 0
    @State private var dismissY: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(Double(min(1, max(0.3, 1 - abs(dismissY) / 1500)))).ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(items.indices, id: \.self) { i in
                    PreviewPage(asset: items[i], current: page == i).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dismissY)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in if abs(v.translation.height) > abs(v.translation.width) { dismissY = v.translation.height } }
                    .onEnded { _ in
                        if abs(dismissY) > 120 {
                            withAnimation(.easeIn(duration: 0.2)) { dismissY = dismissY > 0 ? 3000 : -3000 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onClose)
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) { dismissY = 0 }
                        }
                    }
            )
            if items.indices.contains(page) {
                let item = items[page]
                VStack {
                    HStack {
                        IconButtonM(.arrowBack, tint: .white, action: onClose)
                        Spacer()
                        OrderBadge(order: selected.firstIndex(of: item).map { $0 + 1 }, size: 28).padding(.trailing, 14)
                            .onTapGesture { onToggle(item) }
                    }
                    .padding(4)
                    .padding(.top, windowSafeArea.top)
                    Spacer()
                    CaptionBar(text: $caption, sending: sending) { onSend(item) }
                        .opacity(1 - min(1, abs(dismissY) / 600))
                }
            }
        }
        // весь экран — без отступов системы, как экран съёмки: фото по центру экрана, подпись — у самого
        // низа, место клавиатуры раскладывает она сама (иначе отступ жестовой полосы добавлялся к нему)
        .ignoresSafeArea()
        .onAppear { page = start }
        .presentationBackground(.clear)
    }
}

private struct PreviewPage: View {
    let asset: PHAsset
    let current: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if asset.mediaType == .video {
                if let player { VideoPlayer(player: player) } else { AppLoadingIndicator(size: 64) }
            } else if let image {
                ZoomableImage(image: image)
            } else {
                AppLoadingIndicator(size: 64)
            }
        }
        .task(id: asset.localIdentifier) {
            if asset.mediaType == .video {
                if let av = await MediaExport.avAsset(asset) { player = AVPlayer(playerItem: AVPlayerItem(asset: av)) }
            } else {
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                let side = min(2560, 1600 * UIScreen.main.scale)
                image = await withCheckedContinuation { cont in
                    PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit,
                                                          options: options) { img, _ in cont.resume(returning: img) }
                }
            }
        }
        .onChange(of: current) { _, now in if !now { player?.pause() } }
    }
}

/// Фото с масштабом щипком и двойным нажатием.
struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(MagnifyGesture()
                .onChanged { scale = max(1, min(5, base * $0.magnification)) }
                .onEnded { _ in
                    base = scale
                    if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } }
                })
            .simultaneousGesture(scale > 1 ? DragGesture()
                .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width, height: lastOffset.height + $0.translation.height) }
                .onEnded { _ in lastOffset = offset } : nil)
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if scale > 1 { scale = 1; base = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; base = 2.5 }
                }
            }
    }
}

/// Подпись к выбранному (CaptionBar на Android): эмодзи/клавиатура, поле, «отправить». Под ней — место
/// клавиатуры: либо клавиатура, либо панель эмодзи той же высоты (без стикеров). Стоит у низа экрана,
/// экран под клавиатуру не ужимается — место раскладывает сама подпись.
struct CaptionBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var text: String
    let sending: Bool
    let onSend: () -> Void
    @StateObject private var emoji = EmojiKeyboardState(withStickers: false)
    @StateObject private var keyboard = KeyboardObserver()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconButtonM(emoji.emojiMode ? .keyboard : .oEmojiEmotions, tint: model.theme.textMuted) {
                    emoji.toggle { focused = $0 }
                }
                .accessibilityIdentifier("captionEmoji")
                TextField(text: $text, prompt: Text("chat_captionHint").foregroundStyle(model.theme.textMuted), axis: .vertical) { EmptyView() }
                    .lineLimit(1...4)
                    .font(.roboto(16)).tracking(0)
                    .foregroundStyle(model.theme.textPrimary)
                    .tint(model.theme.primary)
                    .focused($focused)
                    .onChange(of: focused) { _, now in if now { emoji.onFieldFocused() } }
                    .padding(.vertical, 12)
                if sending {
                    AppLoadingIndicator(size: 24).padding(10)
                } else {
                    IconButtonM(.send, tint: model.theme.primary, action: onSend)
                }
            }
            .padding(.horizontal, 2)
            .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            EmojiKeyboardArea<EmptyView>(state: emoji, keyboard: keyboard, bottomInset: windowSafeArea.bottom,
                                         onEmoji: { text += $0 }, stickers: nil)
        }
    }
}
