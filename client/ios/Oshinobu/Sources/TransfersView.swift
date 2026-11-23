import OshinobuCore
import SwiftUI

/**
 * «Передачи» (как TransfersPanel на Android): вкладка «Отправка» — тексты и файлы
 * в пути, «Скачивание» — ручная и автоматическая очереди. Любую строку можно отменить.
 */
struct TransfersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0
    @State private var textRows: [Row] = []
    @State private var fileRows: [Row] = []
    @State private var manualRows: [Row] = []
    @State private var autoRows: [Row] = []
    @State private var percents: [String: Double] = [:]
    @State private var uploadPercents: [String: Double] = [:]

    struct Row: Identifiable {
        let id: String
        let label: String
        let peer: String
        /// mediaId (скачивание) или message_id (выгрузка) для процента; nil — без процента.
        let progressKey: String?
        var upload = false
        let cancel: () async -> Void
    }

    var body: some View {
        let screen = UIScreen.main.bounds.size
        VStack(spacing: 0) {
            TabSplit(active: tab) { tab = $0 }
            model.theme.textMuted.opacity(0.18).frame(height: 1)
            HStack(spacing: 0) {
                let upload = tab == 0
                column(upload ? "transfers_textQueue" : "transfers_manualQueue", upload ? textRows : manualRows)
                model.theme.textMuted.opacity(0.18).frame(width: 1)
                column(upload ? "transfers_fileQueue" : "transfers_autoQueue", upload ? fileRows : autoRows)
            }
        }
        .frame(width: screen.width * 5 / 6, height: screen.height * 5 / 6)
        .background(model.theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task { await followUploads() }
        .task { for await q in model.core.downloads.queues.stream() { rebuildDownloads(q) } }
        .task { for await p in model.core.downloads.progress.stream() { percents = p } }
        .task { for await p in model.core.uploadProgress.stream() { uploadPercents = p } }
    }

    private func column(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: tr(title).uppercased()).font(.roboto(10.5, .bold)).tracking(0.4).foregroundStyle(model.theme.textMuted)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { r in
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: r.label).font(.roboto(12.5)).foregroundStyle(model.theme.textPrimary).lineLimit(1)
                                Text(verbatim: r.peer).font(.roboto(10.5)).foregroundStyle(model.theme.textMuted).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let key = r.progressKey, let pct = (r.upload ? uploadPercents : percents)[key] {
                                Text(verbatim: "\(Int(pct))%").font(.roboto(11)).foregroundStyle(model.theme.primary).padding(.leading, 4)
                            }
                            MIcon(.close, size: 16, tint: model.theme.textMuted).padding(4)
                                .onTapGesture { Task { await r.cancel() } }
                        }
                        .padding(.leading, 12).padding(.trailing, 2).padding(.vertical, 5)
                    }
                }
                .animation(.default, value: rows.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Отправка: свои сообщения «отправляется»/«в очереди» во всех чатах; пересчёт по изменениям хранилища.
    private func followUploads() async {
        rebuildUploads()
        for await _ in model.core.chats.changes.stream() { rebuildUploads() }
    }

    private func rebuildUploads() {
        let core = model.core
        var texts: [Row] = []
        var files: [Row] = []
        for chat in core.chats.knownPeers() {
            for m in core.chats.messages(chat.peerLogin) where m.isMine && (m.status == MessageStatus.sending || m.status == MessageStatus.queued) {
                let login = chat.peerLogin
                let id = m.messageId
                if m.isMedia {
                    let label = m.fileName ?? tr(m.isVideoNote ? "media_videoNote" : "media_voiceNote")
                    files.append(Row(id: "f:\(id)", label: label, peer: login, progressKey: id, upload: true) { core.cancelOutgoing(login, [id]) })
                } else if !m.isSticker {
                    texts.append(Row(id: "t:\(id)", label: tr("transfers_textMessage"), peer: login, progressKey: nil) {
                        core.cancelOutgoing(login, [id])
                    })
                }
            }
        }
        textRows = texts
        fileRows = files
    }

    private func rebuildDownloads(_ q: DownloadQueues) {
        let downloads = model.core.downloads
        func rows(_ prefix: String, _ specs: [DownloadSpec]) -> [Row] {
            specs.map { s in
                Row(id: "\(prefix):\(s.mediaId)", label: s.fileName ?? tr("transfers_download"), peer: s.peerLogin,
                    progressKey: q.active.contains(s.mediaId) ? s.mediaId : nil) { await downloads.cancel(s.mediaId) }
            }
        }
        manualRows = rows("m", q.manual)
        autoRows = rows("a", q.auto)
    }
}

/// Две вкладки, разделённые наклонной чертой; активная подсвечена.
private struct TabSplit: View {
    @EnvironmentObject private var model: AppModel
    let active: Int
    let onTab: (Int) -> Void

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let mid = size.width / 2, slant: CGFloat = 16
                let top = mid + slant, bottom = mid - slant
                var path = Path()
                if active == 0 {
                    path.addLines([.zero, CGPoint(x: top, y: 0), CGPoint(x: bottom, y: size.height), CGPoint(x: 0, y: size.height)])
                } else {
                    path.addLines([CGPoint(x: top, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: bottom, y: size.height)])
                }
                path.closeSubpath()
                ctx.fill(path, with: .color(model.theme.primary.opacity(0.13)))
                var line = Path()
                line.move(to: CGPoint(x: top, y: 0))
                line.addLine(to: CGPoint(x: bottom, y: size.height))
                ctx.stroke(line, with: .color(model.theme.primary.opacity(0.55)), lineWidth: 2)
            }
            HStack(spacing: 0) {
                ForEach(0..<2) { i in
                    Text(i == 0 ? "transfers_upload" : "transfers_download").font(.roboto(13.5, active == i ? .bold : .regular))
                        .foregroundStyle(active == i ? model.theme.primary : model.theme.textMuted.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { onTab(i) }
                }
            }
        }
        .frame(height: 46)
    }
}
