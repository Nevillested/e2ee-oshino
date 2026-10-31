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
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("transfers_upload").tag(0)
                    Text("transfers_download").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(12)
                List {
                    section(tab == 0 ? "transfers_textQueue" : "transfers_manualQueue", tab == 0 ? textRows : manualRows)
                    section(tab == 0 ? "transfers_fileQueue" : "transfers_autoQueue", tab == 0 ? fileRows : autoRows)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .animation(.default, value: textRows.map(\.id) + fileRows.map(\.id) + manualRows.map(\.id) + autoRows.map(\.id))
            }
            .background(model.theme.background.ignoresSafeArea())
            .navigationTitle("transfers_title")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await followUploads() }
        .task { for await q in model.core.downloads.queues.stream() { rebuildDownloads(q) } }
        .task { for await p in model.core.downloads.progress.stream() { percents = p } }
        .task { for await p in model.core.uploadProgress.stream() { uploadPercents = p } }
    }

    private func section(_ title: LocalizedStringKey, _ rows: [Row]) -> some View {
        Section(title) {
            if rows.isEmpty {
                Text("transfers_empty").foregroundStyle(model.theme.textMuted)
            }
            ForEach(rows) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: r.label).lineLimit(1).truncationMode(.middle).foregroundStyle(model.theme.textPrimary)
                        Text(verbatim: r.peer).font(.caption).foregroundStyle(model.theme.textMuted)
                    }
                    Spacer()
                    if let key = r.progressKey, let pct = (r.upload ? uploadPercents : percents)[key] {
                        Text("\(Int(pct))%").font(.caption.monospacedDigit()).foregroundStyle(model.theme.primary)
                    }
                    Button { Task { await r.cancel() } } label: { Image(systemName: "xmark").foregroundStyle(model.theme.textMuted) }
                        .buttonStyle(.borderless)
                }
                .listRowBackground(model.theme.surface)
            }
        }
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
                    let label = m.fileName ?? NSLocalizedString(m.isVideoNote ? "media_videoNote" : "media_voiceNote", comment: "")
                    files.append(Row(id: "f:\(id)", label: label, peer: login, progressKey: id, upload: true) { core.cancelOutgoing(login, [id]) })
                } else if !m.isSticker {
                    texts.append(Row(id: "t:\(id)", label: NSLocalizedString("transfers_textMessage", comment: ""), peer: login, progressKey: nil) {
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
                Row(id: "\(prefix):\(s.mediaId)", label: s.fileName ?? NSLocalizedString("transfers_download", comment: ""), peer: s.peerLogin,
                    progressKey: q.active.contains(s.mediaId) ? s.mediaId : nil) { await downloads.cancel(s.mediaId) }
            }
        }
        manualRows = rows("m", q.manual)
        autoRows = rows("a", q.auto)
    }
}
