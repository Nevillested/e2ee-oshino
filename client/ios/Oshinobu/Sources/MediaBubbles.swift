import AVFoundation
import OshinobuCore
import SwiftUI

// Вложения в ленте — как у Android (ui/chat/MediaBubbles.kt, MediaResolver.kt): фото и видео —
// квадратом с плашкой размера, файл — строкой (в альбоме — плиткой), альбом — одним пузырём
// с плитками по 2–3 в ряд; свои в процессе отправки — превью и этап, чужие крупные — «скачать»,
// мелкие докачиваются сами; спойлер — размытие с мерцающими частицами.

/// Этап отправки/скачивания вложения, как его видит пузырь.
struct TransferPhase {
    let text: String
    let percent: Double?
}

/// Вложения чата: где лежит файл, что качается и выгружается (MediaResolver + части ChatViewModel).
@MainActor
final class ChatMedia: ObservableObject {
    let core: OshinobuCore
    let peerLogin: String
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var queues = DownloadQueues()
    @Published private(set) var uploadProgress: [String: Double] = [:]
    /// Скачивание не удалось — «повторить» вместо «скачать».
    @Published private(set) var failed: Set<String> = []
    /// Растёт с каждым докачанным файлом — миниатюры перечитываются.
    @Published private(set) var version = 0
    private var tasks: [Task<Void, Never>] = []

    init(core: OshinobuCore, peerLogin: String) {
        self.core = core
        self.peerLogin = peerLogin
        let downloads = core.downloads
        tasks = [
            Task { [weak self] in for await p in downloads.progress.stream() { self?.downloadProgress = p } },
            Task { [weak self] in for await q in downloads.queues.stream() { self?.queues = q } },
            Task { [weak self] in for await p in core.uploadProgress.stream() { self?.uploadProgress = p } },
            Task { [weak self] in
                for await id in downloads.done.stream() {
                    self?.failed.remove(id)
                    self?.version += 1
                }
            },
            Task { [weak self] in for await id in downloads.failed.stream() { self?.failed.insert(id) } },
        ]
    }

    deinit { tasks.forEach { $0.cancel() } }

    func spec(_ m: StoredMessage) -> DownloadSpec? { DownloadSpec.of(m, peerLogin: peerLogin) }

    /// Расшифрованный кэш или — для своих — исходник, который отправляли (у фото это сам файл превью).
    nonisolated static func localFile(_ m: StoredMessage, peerLogin: String, core: OshinobuCore) -> URL? {
        let fm = FileManager.default
        if let spec = DownloadSpec.of(m, peerLogin: peerLogin) {
            let cached = core.media.cacheURL(mediaId: spec.mediaId, fileName: spec.fileName)
            if fm.fileExists(atPath: cached.path) { return cached }
        }
        guard m.isMine else { return nil }
        if !m.isVideo && !m.isVideoNote && !m.isFile, let p = m.localPreviewPath, fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        if let p = m.localSourcePath, fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return nil
    }

    func localFile(_ m: StoredMessage) -> URL? { Self.localFile(m, peerLogin: peerLogin, core: core) }

    /// Файл для показа: с устройства или дождавшись скачивания.
    func file(_ m: StoredMessage) async throws -> URL { try await Self.file(m, peerLogin: peerLogin, core: core) }

    static func file(_ m: StoredMessage, peerLogin: String, core: OshinobuCore) async throws -> URL {
        if let local = localFile(m, peerLogin: peerLogin, core: core) { return local }
        guard let spec = DownloadSpec.of(m, peerLogin: peerLogin) else { throw DownloadFailedError(reason: "no media reference") }
        return try await core.downloads.ensureDownloaded(spec)
    }

    func requestDownload(_ m: StoredMessage) {
        guard let spec = spec(m) else { return }
        failed.remove(spec.mediaId)
        Task { await core.downloads.requestUserDownload(spec) }
    }

    func autoDownload(_ m: StoredMessage) {
        guard let spec = spec(m) else { return }
        Task { await core.downloads.requestAutoDownload(spec) }
    }

    func cancelDownload(_ m: StoredMessage) {
        guard let id = m.mediaId else { return }
        Task { await core.downloads.cancel(id) }
    }

    /// Этап своей отправки: «Загрузка…» с процентом; клиент дослал всё — сервер ещё сохраняет файл.
    func uploadPhase(_ m: StoredMessage) -> TransferPhase? {
        guard let step = m.processingStep else { return nil }
        let percent = uploadProgress[m.messageId]
        if let percent, percent >= 100 { return TransferPhase(text: tr("chat_savingOnServer"), percent: nil) }
        return TransferPhase(text: tr(step), percent: percent)
    }

    /// Скачивание: идёт (с процентом), ждёт в очереди или nil — не качается.
    func downloadPhase(_ m: StoredMessage) -> TransferPhase? {
        guard let id = m.mediaId, (queues.manual + queues.auto).contains(where: { $0.mediaId == id }) else { return nil }
        return queues.active.contains(id)
            ? TransferPhase(text: tr("media_downloading"), percent: downloadProgress[id] ?? 0)
            : TransferPhase(text: tr("chat_queued"), percent: nil)
    }
}

/// Уже раскодированные миниатюры — в памяти: возврат из просмотра не оставляет плитки пустыми.
private let thumbCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.totalCostLimit = 64 * 1024 * 1024
    return c
}()

/// Миниатюра вложения: ещё читается / готова / файла на устройстве нет.
private enum Thumb {
    case loading, ready(UIImage), missing
}

private func decodeThumb(_ m: StoredMessage, local: URL?, px: CGFloat) async -> UIImage? {
    let size = CGSize(width: px, height: px)
    if m.isVideo {
        if let p = m.localPreviewPath, let img = UIImage(contentsOfFile: p) { return await img.byPreparingThumbnail(ofSize: size) ?? img }
        guard let local else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: local))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        guard let (cg, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: cg)
    }
    guard let local, let img = UIImage(contentsOfFile: local.path) else { return nil }
    return await img.byPreparingThumbnail(ofSize: size) ?? img
}

/// Плашка размера поверх плитки медиа (левый нижний угол).
struct SizePlaque: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(.roboto(10, .medium)).foregroundStyle(.white).tracking(0)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Затемнение поверх плитки: кольцо прогресса (или кошка), подпись, крестик отмены.
struct MediaStatusOverlay: View {
    let text: String
    let percent: Double?
    var onCancel: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 4) {
                ZStack {
                    if let percent {
                        Circle().stroke(Color.white.opacity(0.25), lineWidth: 3).frame(width: 36, height: 36)
                        Circle().trim(from: 0, to: min(1, max(0, percent / 100)))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                            .rotationEffect(.degrees(-90)).frame(width: 36, height: 36)
                    } else {
                        AppLoadingIndicator(size: 56)
                    }
                    if let onCancel { MIcon(.close, size: 18, tint: .white).contentShape(Rectangle()).tapZone().onTapGesture(perform: onCancel) }
                }
                Text(verbatim: percent.map { "\(text) \(Int($0))%" } ?? text)
                    .font(.roboto(11)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
            }
            .padding(6)
        }
    }
}

/// Значок «play» поверх кадра видео.
private struct PlayBadge: View {
    var body: some View {
        MIcon(.playArrow, size: 22, tint: .white).frame(width: 38, height: 38).background(Color.black.opacity(0.38), in: Circle())
    }
}

/// Вложение в пузыре: файл — строкой (или плиткой в альбоме), фото/видео — квадратом side с плашкой размера.
struct AttachmentBubble: View {
    @EnvironmentObject private var media: ChatMedia
    let message: StoredMessage
    let side: CGFloat
    let revealed: Bool
    let onReveal: () -> Void
    let onOpenViewer: (StoredMessage) -> Void
    let onOpenFile: (StoredMessage) -> Void
    let onSaveFile: (StoredMessage) -> Void

    var body: some View {
        if message.isFile {
            FileAttachment(message: message, side: side, onOpenFile: onOpenFile, onSaveFile: onSaveFile)
        } else {
            MediaTile(message: message, side: side, revealed: revealed, onReveal: onReveal, onOpenViewer: onOpenViewer)
                .overlay(alignment: .bottomLeading) {
                    if message.fileSize > 0 { SizePlaque(text: formatFileSize(message.fileSize) { tr($0) }).padding(6) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct MediaTile: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var media: ChatMedia
    let message: StoredMessage
    let side: CGFloat
    let revealed: Bool
    let onReveal: () -> Void
    let onOpenViewer: (StoredMessage) -> Void
    @State private var thumb = Thumb.loading

    var body: some View {
        let m = message
        let sendingOrFailed = m.isMine && (m.status == MessageStatus.sending || m.status == MessageStatus.queued || m.status == MessageStatus.failed)
        let upload = sendingOrFailed ? media.uploadPhase(m) : nil
        let download = media.downloadPhase(m)
        let hiddenSpoiler = m.isSpoiler && !revealed
        ZStack {
            model.theme.surface
            switch thumb {
            case let .ready(image):
                SpoilerImage(image: image, hidden: hiddenSpoiler)
                    .contentShape(Rectangle())
                    .tapZone().onTapGesture {
                        guard !sendingOrFailed else { return }
                        if hiddenSpoiler { onReveal() } else { onOpenViewer(m) }
                    }
                if m.isVideo && !hiddenSpoiler { PlayBadge().allowsHitTesting(false) }
            default:
                if sendingOrFailed {
                    MIcon(.insertDriveFile, size: 40, tint: model.theme.textMuted)
                } else if case .loading = thumb, download == nil {
                    // миниатюра ещё читается с диска — пусто, а не «скачать»: файл, может быть, уже есть
                    EmptyView()
                } else if let download {
                    MediaStatusOverlay(text: download.text, percent: download.percent) { media.cancelDownload(m) }
                } else if let id = m.mediaId, media.failed.contains(id) {
                    MIcon(.refresh, size: side / 3, tint: Color(hex: 0xFF5252))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                        .tapZone().onTapGesture { media.requestDownload(m) }
                } else if !m.isMine && m.fileSize < MediaDownloadManager.autoDownloadLimitBytes {
                    // мелкое чужое вложение: авто-очередь заберёт его, как только пузырь окажется на экране
                    MediaStatusOverlay(text: tr("chat_queued"), percent: nil)
                } else {
                    MIcon(.download, size: 32, tint: model.theme.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(model.theme.textMuted.opacity(0.35), lineWidth: 1))
                        .contentShape(Rectangle())
                        .tapZone().onTapGesture { media.requestDownload(m) }
                }
            }
            if let upload { MediaStatusOverlay(text: upload.text, percent: upload.percent) }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: "\(m.messageId)|\(m.mediaId ?? "")|\(media.version)|\(m.localPreviewPath ?? "")") { await load() }
    }

    private func load() async {
        let m = message
        let px = min(1440, side * 2 * UIScreen.main.scale)
        let key = "\(m.messageId)|\(m.mediaId ?? "")|\(Int(px))" as NSString
        if let cached = thumbCache.object(forKey: key) {
            thumb = .ready(cached)
            return
        }
        let local = media.localFile(m)
        let image = await Task.detached(priority: .userInitiated) { await decodeThumb(m, local: local, px: px) }.value
        if let image {
            thumbCache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
            thumb = .ready(image)
        } else {
            thumb = .missing
            if !m.isMine, m.fileSize < MediaDownloadManager.autoDownloadLimitBytes { media.autoDownload(m) }
        }
    }
}

/// Фото под спойлером: размытие и мерцающие частицы; раскрытие — плавно (450 мс).
private struct SpoilerImage: View {
    let image: UIImage
    let hidden: Bool
    @State private var veil: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            ZStack {
                Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                    .blur(radius: 24 * veil)
                if veil > 0 {
                    Color.black.opacity(0.25 * veil)
                    SpoilerParticles().opacity(veil)
                }
            }
        }
        .clipped()
        .onAppear { veil = hidden ? 1 : 0 }
        .onChange(of: hidden) { _, now in withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.45)) { veil = now ? 1 : 0 } }
    }
}

/// Мерцающие частицы поверх скрытого под спойлером: 70 точек, круг — 3 с.
struct SpoilerParticles: View {
    @State private var particles: [(CGFloat, CGFloat, CGFloat)] = (0..<70).map { _ in (.random(in: 0...1), .random(in: 0...1), .random(in: 0...1)) }
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = CGFloat(tl.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 3) / 3)
            Canvas { ctx, size in
                for (x, y, phase) in particles {
                    let p = (t + phase).truncatingRemainder(dividingBy: 1)
                    let dx = sin((p + phase) * 6.283) * 6
                    let a = 1 - abs(p * 2 - 1)
                    let cy = (y + p * 0.08).truncatingRemainder(dividingBy: 1) * size.height
                    let c = CGPoint(x: x * size.width + dx, y: cy)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)), with: .color(.white.opacity(0.8 * a)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private func iconForFileName(_ name: String?) -> MaterialIcon {
    switch (name.map { ($0 as NSString).pathExtension.lowercased() }) ?? "" {
    case "pdf": .pictureAsPdf
    case "doc", "docx", "odt", "rtf": .description
    case "xls", "xlsx", "csv", "ods": .tableChart
    case "ppt", "pptx", "odp": .slideshow
    case "txt": .article
    case "zip", "rar", "7z", "tar", "gz": .folderZip
    case "mp3", "wav", "m4a", "aac", "flac", "ogg": .audiotrack
    case "mp4", "mov", "avi", "mkv", "webm", "3gp": .videocam
    case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp": .image
    case "apk": .android
    case "json", "xml", "html", "css", "js", "dart", "py", "java", "kt", "c", "cpp": .code
    default: .insertDriveFile
    }
}

/// «⋮» у скачанного файла: сохранить на устройство.
private struct SaveFileMenu: View {
    @EnvironmentObject private var model: AppModel
    let tint: Color
    let badge: Bool
    let onSave: () -> Void
    @State private var frame: CGRect = .zero

    var body: some View {
        MIcon(.moreVert, size: badge ? 14 : 18, tint: tint)
            .padding(badge ? 3 : 6)
            .background(badge ? Color.black.opacity(0.45) : .clear, in: Circle())
            .contentShape(Circle())
            .globalFrame($frame)
            .tapZone().onTapGesture {
                model.popups.menu(at: frame) { MenuItemM("chat_saveToDevice", action: onSave) }
            }
    }
}

/// Файл: иконка по расширению, имя, размер и этап (отправка/скачивание с процентом).
/// В альбоме (side < 200) — компактная плитка.
private struct FileAttachment: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var media: ChatMedia
    let message: StoredMessage
    let side: CGFloat
    let onOpenFile: (StoredMessage) -> Void
    let onSaveFile: (StoredMessage) -> Void

    var body: some View {
        let m = message
        let sending = m.isMine && m.processingStep != nil
        let failed = m.isMine && m.status == MessageStatus.failed
        let local = media.localFile(m) != nil
        let needsDownload = !sending && !failed && !local
        let download = needsDownload ? media.downloadPhase(m) : nil
        let upload = sending ? media.uploadPhase(m) : nil
        let status = upload ?? (failed ? TransferPhase(text: tr("error_uploadFailed"), percent: nil) : download)
        let icon: MaterialIcon = failed ? .errorOutline : iconForFileName(m.fileName)
        let tappable = !sending && !failed && download == nil
        let canSave = tappable && !needsDownload
        let cancel: (() -> Void)? = download != nil ? { media.cancelDownload(m) } : nil
        let onTap = { if needsDownload { media.requestDownload(m) } else { onOpenFile(m) } }
        let sizeText = formatFileSize(m.fileSize) { tr($0) }
        let _ = media.version
        if side < 200 {
            ZStack {
                model.theme.surface
                if download != nil {
                    AppLoadingIndicator(size: 22)
                } else {
                    MIcon(icon, size: 32, tint: failed ? Color(hex: 0xFF5252) : model.theme.textMuted)
                }
            }
            .frame(width: side, height: side)
            .overlay(alignment: .topTrailing) {
                if let cancel {
                    MIcon(.close, size: 12, tint: .white).padding(2).background(Color.black.opacity(0.45), in: Circle()).padding(2)
                        .tapZone().onTapGesture(perform: cancel)
                }
                if canSave { SaveFileMenu(tint: .white, badge: true) { onSaveFile(m) }.padding(2) }
            }
            .overlay(alignment: .bottom) {
                if m.fileSize > 0 { Text(verbatim: sizeText).font(.roboto(9)).foregroundStyle(model.theme.textMuted).lineLimit(1).padding(.bottom, 3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .tapZone().onTapGesture { if let cancel { cancel() } else if tappable { onTap() } }
        } else {
            let textColor = m.isMine ? model.theme.onBubbleMine : model.theme.textPrimary
            HStack(spacing: 0) {
                ZStack {
                    if download != nil {
                        AppLoadingIndicator(size: 20)
                    } else {
                        MIcon(needsDownload && !failed ? .download : icon, size: 28, tint: failed ? Color(hex: 0xFF5252) : textColor)
                    }
                }
                .frame(width: 28, height: 28)
                Spacer().frame(width: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: m.fileName ?? m.text).font(.roboto(16)).foregroundStyle(textColor).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                    Text(verbatim: status.map { s in s.percent.map { "\(s.text) \(Int($0))% · \(sizeText)" } ?? "\(s.text) · \(sizeText)" } ?? sizeText)
                        .font(.roboto(11)).foregroundStyle(failed ? Color(hex: 0xFF5252) : textColor.opacity(0.7)).lineLimit(1)
                }
                if let cancel { MIcon(.close, size: 18, tint: textColor.opacity(0.7)).padding(6).tapZone().onTapGesture(perform: cancel) }
                if canSave { SaveFileMenu(tint: textColor, badge: false) { onSaveFile(m) } }
            }
            .contentShape(Rectangle())
            .tapZone().onTapGesture { if tappable { onTap() } }
        }
    }
}

/// Альбом: одно вложение — крупно (180), несколько — плитками по 2–3 в ряд (70…130).
struct MediaGrid: View {
    let media: [StoredMessage]
    let maxWidth: CGFloat
    let revealed: Set<String>
    let onReveal: (String) -> Void
    let onOpenViewer: (StoredMessage) -> Void
    let onOpenFile: (StoredMessage) -> Void
    let onSaveFile: (StoredMessage) -> Void

    var body: some View {
        if media.count == 1, let m = media.first {
            tile(m, 180).clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            let spacing: CGFloat = 3
            let columns = media.count >= 3 ? 3 : 2
            let side = min(130, max(70, floor((maxWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns))))
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(stride(from: 0, to: media.count, by: columns)), id: \.self) { start in
                    HStack(spacing: spacing) {
                        ForEach(media[start..<min(media.count, start + columns)], id: \.messageId) { m in
                            tile(m, side).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }

    private func tile(_ m: StoredMessage, _ side: CGFloat) -> some View {
        AttachmentBubble(message: m, side: side, revealed: revealed.contains(m.messageId), onReveal: { onReveal(m.messageId) },
                         onOpenViewer: onOpenViewer, onOpenFile: onOpenFile, onSaveFile: onSaveFile)
    }
}
