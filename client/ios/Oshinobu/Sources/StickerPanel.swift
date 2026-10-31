import OshinobuCore
import SwiftUI

/**
 * Панель стикеров: «Недавние» (открыты по умолчанию), установленные паки (новые первыми)
 * и «+»; под строкой — страницы: свайп по сетке листает к соседнему паку, нажатие на пак
 * открывает его сразу, коротко проявляя (как на Android). Тап по стикеру — отправить.
 */
struct StickerPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let peer: ChatSummary
    @State private var packs: [StickerPackInfo] = []
    @State private var selected = Self.recent
    @State private var uploading = false
    /// Проявление пака, открытого нажатием: 0 → 1 за долю секунды.
    @State private var appear = 1.0

    private static let recent = "recent"
    private var pages: [String] { [Self.recent] + packs.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { tabs in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { uploading = true } label: {
                            Image(systemName: "plus").font(.subheadline.bold()).padding(8).background(model.theme.surface, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("sticker_addPack"))
                        tab(Self.recent) { Text("sticker_recent") }
                        ForEach(packs, id: \.id) { pack in
                            tab(pack.id) { Text(verbatim: pack.title) }
                        }
                    }
                    .padding(12)
                }
                // листают свайпом — строка подтягивает открытый пак в видимую часть
                .onChange(of: selected) { id in withAnimation(.easeOut(duration: 0.2)) { tabs.scrollTo(id, anchor: .center) } }
            }
            TabView(selection: $selected) {
                ForEach(pages, id: \.self) { id in
                    grid(id).tag(id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .opacity(appear)
            .scaleEffect(0.97 + 0.03 * appear)
        }
        .background(model.theme.background.ignoresSafeArea())
        .sheet(isPresented: $uploading) {
            StickerUploadView { pack in
                // свой новый пак — первым в строке
                packs.insert(pack, at: 0)
                open(pack.id)
            }
            .environmentObject(model)
        }
        .task {
            guard let token = model.core.session.token, let mine = try? await model.core.api.getMyStickerPacks(token: token) else { return }
            packs = mine.filter { !$0.deleted }
            // «Недавние» открыты по умолчанию; пусто — первый пак
            if model.core.recentStickers.isEmpty, let first = packs.first?.id { selected = first }
        }
    }

    private func tab<Title: View>(_ id: String, @ViewBuilder label: () -> Title) -> some View {
        Button { open(id) } label: {
            label().font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected == id ? model.theme.primary.opacity(0.2) : model.theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .id(id)
    }

    /// Нажатие на пак: страница меняется без пролистывания через соседние и проявляется —
    /// едва заметно, лишь бы не рывком.
    private func open(_ id: String) {
        guard id != selected else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            appear = 0
            selected = id
        }
        withAnimation(.easeOut(duration: 0.16)) { appear = 1 }
    }

    @ViewBuilder private func grid(_ id: String) -> some View {
        let ids = id == Self.recent ? model.core.recentStickers : packs.first { $0.id == id }?.stickers.map(\.id) ?? []
        ScrollView {
            if ids.isEmpty && id == Self.recent {
                Text("sticker_recentEmpty").foregroundStyle(model.theme.textMuted).padding(40)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(ids, id: \.self) { sticker in
                    StickerCell(stickerId: sticker)
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await model.core.sendSticker(sticker, to: peer) }
                            dismiss()
                        }
                }
            }
            .padding(12)
        }
    }
}

/// Клетка панели: стикер любого формата (пак скачивается при первом показе).
struct StickerCell: View {
    let stickerId: String

    var body: some View {
        StickerImage(stickerId: stickerId).frame(height: 76)
    }
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
                    TextField(String(format: NSLocalizedString("sticker_uploadNameHint", comment: ""), Self.maxTitle), text: $title)
                }
                Section {
                    Text("sticker_uploadRules").font(.footnote).foregroundStyle(model.theme.textMuted)
                    Button { picking = true } label: {
                        Label { Text(verbatim: archive?.lastPathComponent ?? NSLocalizedString("sticker_uploadPick", comment: "")) } icon: { Image(systemName: "doc.zipper") }
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
        func f(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }
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
        func f(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }
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

/// Лист пака (тап по стикеру в ленте): все стикеры; «Добавить»/«Убрать», у автора — «Удалить навсегда».
/// Тап по стикеру — отправить в текущий чат.
struct StickerPackSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let stickerId: String
    let peer: ChatSummary
    @State private var pack: StickerPackInfo?
    @State private var confirmDelete = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            if let pack {
                Text(verbatim: pack.title).font(.headline).padding(.top, 16)
                Text(String(format: NSLocalizedString("sticker_count", comment: ""), pack.stickers.count)).font(.caption).foregroundStyle(model.theme.textMuted)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(pack.stickers, id: \.id) { s in
                            StickerCell(stickerId: s.id).onTapGesture {
                                Task { await model.core.sendSticker(s.id, to: peer) }
                                dismiss()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                HStack(spacing: 12) {
                    Button { Task { await toggleInstall(pack) } } label: {
                        Text(pack.installed ? "sticker_remove" : "sticker_add").frame(maxWidth: .infinity).padding(.vertical, 12)
                            .overlay(Capsule().stroke(model.theme.primary))
                    }
                    if pack.isOwner {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("sticker_deleteForever").frame(maxWidth: .infinity).padding(.vertical, 12).overlay(Capsule().stroke(.red))
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            } else if failed {
                Text("sticker_packDeleted").foregroundStyle(model.theme.textMuted).padding(40)
            } else {
                ProgressView().padding(40)
            }
        }
        .background(model.theme.background.ignoresSafeArea())
        .confirmationDialog("sticker_deleteForeverTitle", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("sticker_deleteForeverConfirm", role: .destructive) {
                Task {
                    if let token = model.core.session.token, let id = pack?.id { try? await model.core.api.deleteStickerPack(token: token, packId: id) }
                    dismiss()
                }
            }
        }
        .task {
            guard let token = model.core.session.token else { return }
            pack = try? await model.core.api.getStickerPackBySticker(token: token, stickerId: stickerId)
            if pack == nil || pack?.deleted == true { failed = true; pack = nil }
        }
    }

    private func toggleInstall(_ p: StickerPackInfo) async {
        guard let token = model.core.session.token else { return }
        do {
            if p.installed { try await model.core.api.uninstallStickerPack(token: token, packId: p.id) }
            else { try await model.core.api.installStickerPack(token: token, packId: p.id) }
            pack = try? await model.core.api.getStickerPack(token: token, packId: p.id)
        } catch {}
    }
}
