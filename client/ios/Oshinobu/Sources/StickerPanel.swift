import OshinobuCore
import SwiftUI

private let recentPage = "recent"

/// Панель стикеров (Stickers.kt на Android): сверху — строка-пузырь (прокручивается вбок): «Недавние»
/// (часы), установленные паки — миниатюрой первого стикера (долгое нажатие — убрать из панели) и «+»;
/// под ней — сетка выбранного. Свайп по сетке — соседний пак; нажатие на пак — сразу, с коротким проявлением.
struct StickerPanel: View {
    @EnvironmentObject private var model: AppModel
    let bottomPadding: CGFloat
    let onSend: (String) -> Void
    let onPreview: (String?) -> Void
    /// Паки — из памяти сразу, с сервера — следом (строка паков не появляется с запозданием).
    @State private var packs: [StickerPackInfo] = StickerPanel.cachedPacks
    @State private var recent: [String] = []
    @State private var selected = recentPage
    @MainActor static var cachedPacks: [StickerPackInfo] = []
    @State private var uploading = false
    @State private var appear: CGFloat = 1

    private var pages: [String] { [recentPage] + packs.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { tabs in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        packTab(recentPage) { MIcon(.oSchedule, tint: selected == recentPage ? model.theme.primary : model.theme.textMuted) }
                        ForEach(packs, id: \.id) { pack in
                            packTab(pack.id, onLongPress: { askRemove(pack) }) {
                                if let first = pack.stickers.first { StickerImage(stickerId: first.id) }
                            }
                        }
                        packTab("add", action: { uploading = true }) { MIcon(.add, tint: model.theme.primary) }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(height: 52)
                .background(model.theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                .noSwipeBack()
                .padding(.horizontal, 8)
                .padding(.top, 8)
                // листают свайпом — строка подтягивает открытый пак в видимую часть
                .onChange(of: selected) { _, id in withAnimation(.easeOut(duration: 0.2)) { tabs.scrollTo(id) } }
            }
            TabView(selection: $selected) {
                ForEach(pages, id: \.self) { id in grid(id).tag(id) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .noSwipeBack()
            .opacity(appear)
            .scaleEffect(0.97 + 0.03 * appear)
        }
        .sheet(isPresented: $uploading) {
            StickerUploadView { pack in
                packs.insert(pack, at: 0)
                open(pack.id)
            }
            .environmentObject(model)
        }
        .task { await reload() }
    }

    private func reload() async {
        recent = model.core.recentStickers
        guard let token = model.core.session.token, let mine = try? await model.core.api.getMyStickerPacks(token: token) else { return }
        packs = mine.filter { !$0.deleted }
        StickerPanel.cachedPacks = packs
        for p in packs { await model.core.stickers.remember(p) }
        if !pages.contains(selected) { selected = recentPage }
    }

    /// Кнопка строки паков: выбранная — подсвеченная.
    private func packTab<C: View>(_ id: String, action: (() -> Void)? = nil, onLongPress: (() -> Void)? = nil, @ViewBuilder content: () -> C) -> some View {
        let on = selected == id
        return content()
            .padding(6)
            .frame(width: 42, height: 42)
            .background(on ? model.theme.primary.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .animation(.easeInOut(duration: 0.2), value: on)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { if let action { action() } else { open(id) } }
            .onLongPressGesture(minimumDuration: 0.5) { onLongPress?() }
            .id(id)
    }

    /// Нажатие на пак: страница меняется без пролистывания через соседние и проявляется.
    private func open(_ id: String) {
        guard id != selected else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            appear = 0
            selected = id
        }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.16)) { appear = 1 }
    }

    @ViewBuilder private func grid(_ id: String) -> some View {
        let ids = id == recentPage ? recent : packs.first { $0.id == id }?.stickers.map(\.id) ?? []
        if id == recentPage && ids.isEmpty {
            Text("sticker_recentEmpty").font(.roboto(13)).foregroundStyle(model.theme.textMuted).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, bottomPadding)
        } else {
            StickerGrid(ids: ids, bottomPadding: bottomPadding, onSend: { sticker in
                onSend(sticker)
                recent = model.core.recentStickers
            }, onPreview: onPreview)
        }
    }

    private func askRemove(_ pack: StickerPackInfo) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        model.popups.show {
            AppDialog(title: "sticker_removeFromPanelTitle", onDismiss: { model.popups.dismiss() }) {
                Text(verbatim: String(format: tr("sticker_removeFromPanelBody"), pack.title))
            } buttons: {
                DialogButton("common_cancel") { model.popups.dismiss() }
                DialogButton("sticker_remove", color: errorRed) {
                    model.popups.dismiss()
                    Task {
                        guard let token = model.core.session.token else { return }
                        do {
                            try await model.core.api.uninstallStickerPack(token: token, packId: pack.id)
                            packs.removeAll { $0.id == pack.id }
                            if selected == pack.id { selected = recentPage }
                        } catch {
                            model.toasts.show(tr("error_stickersFailed"))
                        }
                    }
                }
            }
        }
    }
}

/// Сетка стикеров по 5: нажатие — отправить, долгое нажатие — превью; не отрывая пальца, можно вести им
/// по сетке — превью переключается на стикер под пальцем (с лёгкой вибрацией на каждое переключение).
struct StickerGrid: View {
    let ids: [String]
    var bottomPadding: CGFloat = 8
    let onSend: ((String) -> Void)?
    let onPreview: (String?) -> Void
    @State private var frames: [String: CGRect] = [:]
    @State private var previewed: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    StickerImage(stickerId: id)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(4)
                        .contentShape(Rectangle())
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[id] = $0 }
                        .gesture(PressGestures(onTap: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onSend?(id)
                        }, onLong: { point in
                            guard let point else { return show(nil) }
                            // первое касание — этот стикер; дальше — тот, над которым палец (между ячейками — текущий)
                            if previewed == nil { return show(id) }
                            if let hit = frames.first(where: { ids.contains($0.key) && $0.value.contains(point) })?.key { show(hit) }
                        }))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, bottomPadding)
        }
    }

    private func show(_ next: String?) {
        guard next != previewed else { return }
        if next != nil {
            if previewed == nil { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } else { UISelectionFeedbackGenerator().selectionChanged() }
        }
        previewed = next
        onPreview(next)
    }
}

/// Увеличенный стикер поверх чата на время долгого нажатия: появляется «пружиной» из маленького,
/// при переключении на другой стикер — сменяется с коротким «хлопком».
struct StickerPreviewOverlay: View {
    let stickerId: String?
    @State private var shown: String?

    var body: some View {
        ZStack {
            Color.black.opacity(stickerId != nil ? 0.45 : 0).ignoresSafeArea().animation(.easeOut(duration: 0.18), value: stickerId != nil)
            if let id = stickerId ?? shown, stickerId != nil {
                StickerImage(stickerId: id).frame(width: 240, height: 240)
                    .id(id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: stickerId)
        .allowsHitTesting(false)
        .onChange(of: stickerId) { _, id in if let id { shown = id } }
    }
}

/// Стикер под пальцем — для превью на слое поверх всей шторки (затемняется и её ручка).
@MainActor
final class StickerPreviewState: ObservableObject {
    @Published var id: String?
}

private struct StickerPreviewHost: View {
    @ObservedObject var state: StickerPreviewState
    var body: some View { StickerPreviewOverlay(stickerId: state.id) }
}

/// Загрузка своего пака: название, ZIP, живые шаги сервера; готово — пак в панели.
struct StickerUploadView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onDone: (StickerPackInfo) -> Void
    @State private var title = ""
    @State private var archive: URL?
    @State private var picking = false
    @State private var status: String?
    @State private var progress: Double?
    @State private var error: String?
    @State private var busy = false

    private static let maxTitle = 50

    /// Латиница, кириллица, цифры и пробелы, без пробелов по краям (как сервер).
    private var titleValid: Bool {
        !title.isEmpty && title.count <= Self.maxTitle && title.trimmingCharacters(in: .whitespaces) == title &&
            title.range(of: "^[A-Za-zА-Яа-яЁё0-9 ]+$", options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("sticker_uploadName") {
                    TextField(String(format: tr("sticker_uploadNameHint"), Self.maxTitle), text: $title)
                }
                Section {
                    Text("sticker_uploadRules").font(.footnote).foregroundStyle(model.theme.textMuted)
                    Button { picking = true } label: {
                        Label { Text(verbatim: archive?.lastPathComponent ?? tr("sticker_uploadPick")) } icon: { Image(systemName: "doc.zipper") }
                    }
                }
                if let status {
                    Section {
                        Text(verbatim: status)
                        if let progress { ProgressView(value: progress) } else if busy { ProgressView() }
                    }
                }
                if let error { Section { Text(verbatim: error).foregroundStyle(.red) } }
                Section {
                    Button { Task { await upload() } } label: { HStack { Spacer(); Text("sticker_uploadStart").bold(); Spacer() } }
                        .disabled(busy || !titleValid || archive == nil)
                }
            }
            .navigationTitle("sticker_uploadTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common_cancel") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.zip]) { result in
                guard case .success(let src) = result else { return }
                let access = src.startAccessingSecurityScopedResource()
                defer { if access { src.stopAccessingSecurityScopedResource() } }
                let dst = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-upload.zip")
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { archive = dst }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func upload() async {
        guard let token = model.core.session.token, let archive else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let pack = try await model.core.api.uploadStickerPack(token: token, title: title, archive: archive) { e in
                Task { @MainActor in show(e) }
            }
            onDone(pack)
            dismiss()
        } catch let e as ApiClient.StickerUploadError {
            error = message(e)
            status = nil
        } catch {
            self.error = localizedError(error)
            status = nil
        }
    }

    private func show(_ e: ApiClient.StickerUploadEvent) {
        func f(_ key: String, _ args: CVarArg...) -> String { String(format: tr(key), arguments: args) }
        let fraction = e.index.flatMap { i in e.total.map { $0 > 0 ? Double(i) / Double($0) : 0 } }
        let suffix = e.name.map { "\n\($0)" } ?? ""
        switch e.stage {
        case "received": status = f("sticker_stageReceived"); progress = nil
        case "unpacking": status = f("sticker_stageUnpacking"); progress = nil
        case "counting": status = f("sticker_stageCounting", e.count ?? 0); progress = nil
        case "checking": status = f("sticker_stageChecking", e.index ?? 0, e.total ?? 0) + suffix; progress = fraction
        case "converting": status = f("sticker_stageConverting", e.index ?? 0, e.total ?? 0) + suffix; progress = fraction
        case "saving": status = f("sticker_stageSaving", e.index ?? 0, e.total ?? 0); progress = fraction
        case "registering": status = f("sticker_stageRegistering"); progress = nil
        default: break
        }
    }

    /// Причина отказа — по коду сервера (как uploadError на Android).
    private func message(_ e: ApiClient.StickerUploadError) -> String {
        func f(_ key: String, _ args: CVarArg...) -> String { String(format: tr(key), arguments: args) }
        let name = e.fileName ?? ""
        let limit = e.limit ?? 0
        switch e.code {
        case "title.invalid": return f("sticker_err_titleInvalid", limit > 0 ? limit : Self.maxTitle)
        case "pack.quota": return f("sticker_err_quota", limit)
        case "archive.tooLarge": return f("sticker_err_archiveTooLarge", limit)
        case "archive.invalid": return f("sticker_err_archiveInvalid")
        case "archive.empty": return f("sticker_err_archiveEmpty")
        case "archive.tooMany": return f("sticker_err_archiveTooMany", limit)
        case "file.webm": return f("sticker_err_webm", name)
        case "file.unsupported": return f("sticker_err_unsupported", name)
        case "file.tooLarge": return f("sticker_err_tooLarge", name, limit)
        case "file.corrupt": return f("sticker_err_corrupt", name)
        case "file.badDimensions": return f("sticker_err_dimensions", name, limit)
        case "file.badCodec": return f("sticker_err_badCodec", name)
        case "file.hasAudio": return f("sticker_err_hasAudio", name)
        case "file.badDuration": return f("sticker_err_badDuration", name, limit)
        case "file.convertFailed": return f("sticker_err_convertFailed", name)
        case "file.convertTooLarge": return f("sticker_err_convertTooLarge", name, limit)
        default: return f("sticker_err_server")
        }
    }
}

/// Лист пака (нажатие на стикер в ленте) — как StickerPackSheet на Android: название, число стикеров, сетка
/// (нажатие — отправить, долгое — превью); «Добавить»/«Убрать», у автора — ещё «Удалить навсегда».
struct StickerPackSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var cover: SheetCover
    @Environment(\.sheetClose) private var close
    @StateObject private var previewState = StickerPreviewState()
    let stickerId: String
    let peer: ChatSummary?
    /// Известный пак — сразу (паки панели в памяти), свежий с сервера — следом, без загрузки на экране.
    @State private var pack: StickerPackInfo?

    init(stickerId: String, peer: ChatSummary?) {
        self.stickerId = stickerId
        self.peer = peer
        _pack = State(initialValue: StickerPanel.cachedPacks.first { $0.stickers.contains { $0.id == stickerId } })
    }
    @State private var deleted = false
    @State private var failed = false
    @State private var busy = false
    @State private var confirming: StickerPackInfo?
    @State private var showLoader = false

    var body: some View {
        ZStack {
            if deleted || failed {
                Text(deleted ? "sticker_packDeleted" : "error_stickersFailed").font(.roboto(16)).foregroundStyle(model.theme.textMuted)
                    .multilineTextAlignment(.center).padding(24)
            } else if let p = pack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: p.title).font(.roboto(18, .semibold)).foregroundStyle(model.theme.textPrimary).lineLimit(1).padding(.horizontal, 20)
                    Text(verbatim: String(format: tr("sticker_count"), p.stickers.count)).font(.roboto(13)).foregroundStyle(model.theme.textMuted)
                        .padding(.horizontal, 20)
                    StickerGrid(ids: p.stickers.map(\.id), onSend: peer.map { target in
                        { (id: String) in
                            Task { await model.core.sendSticker(id, to: target) }
                            close()
                        }
                    }, onPreview: { previewState.id = $0 })
                    let label: LocalizedStringKey = p.installed ? "sticker_remove" : "sticker_add"
                    Group {
                        if p.isOwner {
                            HStack(spacing: 10) {
                                SecondaryButton(label, enabled: !busy) { toggleInstall(p) }
                                Button { if !busy { confirmDelete(p) } } label: {
                                    Text("sticker_deleteForever").font(.roboto(14, .semibold)).foregroundStyle(errorRed).lineLimit(1)
                                        .frame(maxWidth: .infinity, minHeight: 52)
                                        .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(errorRed, lineWidth: 1))
                                }
                                .buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: cardRadius), color: errorRed))
                            }
                        } else if p.installed {
                            SecondaryButton(label, enabled: !busy) { toggleInstall(p) }
                        } else {
                            PrimaryButton(label, loading: busy) { toggleInstall(p) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            } else if showLoader {
                // пак с диска приходит за доли секунды — кошка только для пака, которого на телефоне нет
                AppLoadingIndicator(size: 56)
            }
            if let p = confirming {
                // окно — внутри листа: общий слой окон приложения лежит под листом
                Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { confirming = nil }
                AppDialog(title: "sticker_deleteForeverTitle", onDismiss: { confirming = nil }) {
                    Text(verbatim: String(format: tr("sticker_deleteForeverBody"), p.title))
                } buttons: {
                    DialogButton("common_cancel") { confirming = nil }
                    DialogButton("sticker_deleteForeverConfirm", color: errorRed) {
                        confirming = nil
                        Task {
                            if let token = model.core.session.token { try? await model.core.api.deleteStickerPack(token: token, packId: p.id) }
                            close()
                        }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: confirming?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { cover.view = AnyView(StickerPreviewHost(state: previewState)) }
        .task {
            if pack == nil { pack = await model.core.stickers.pack(of: stickerId) }
            if pack == nil {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    showLoader = true
                }
            }
            guard let token = model.core.session.token else { return }
            do {
                let p = try await model.core.api.getStickerPackBySticker(token: token, stickerId: stickerId)
                if let p, !p.deleted { await model.core.stickers.remember(p) }
                if p == nil || p?.deleted == true { deleted = true } else { pack = p }
            } catch {
                failed = pack == nil
            }
        }
    }

    private func toggleInstall(_ p: StickerPackInfo) {
        guard let token = model.core.session.token else { return }
        busy = true
        Task {
            do {
                if p.installed { try await model.core.api.uninstallStickerPack(token: token, packId: p.id) }
                else { try await model.core.api.installStickerPack(token: token, packId: p.id) }
                pack = try? await model.core.api.getStickerPack(token: token, packId: p.id)
            } catch {
                model.toasts.show(tr("error_stickersFailed"))
            }
            busy = false
        }
    }

    private func confirmDelete(_ p: StickerPackInfo) { confirming = p }
}
