import OshinobuCore
import SwiftUI

/// Главный экран: три вкладки (чаты, настройки, профиль), как на Android.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            NavigationStack { ChatListView() }
                .tabItem { Label("nav_chats", systemImage: "bubble.left.and.bubble.right.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("nav_settings", systemImage: "slider.horizontal.3") }
            NavigationStack { ProfileView() }
                .tabItem { Label("nav_profile", systemImage: "person.crop.circle") }
        }
    }
}

/// Статус соединения вместо заголовка (как на Android).
struct ConnectionStatusText: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let key: LocalizedStringKey = switch model.connection {
        case .waitingForNetwork: "connection_waitingForNetwork"
        case .connecting: "connection_connecting"
        case .connected: "connection_connected"
        case .reconnecting: "connection_reconnecting"
        }
        Text(key).font(.footnote).foregroundStyle(model.theme.textMuted).contentTransition(.opacity)
            .animation(.easeInOut, value: model.connection)
    }
}

struct ChatListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var showTransfers = false
    @State private var searching = false
    @State private var searchError: String?
    @State private var opened: ChatSummary?
    @State private var deleting: ChatSummary?

    var body: some View {
        List {
            if let searchError { Text(searchError).foregroundStyle(.red) }
            ForEach(model.chats) { chat in
                Button { opened = chat } label: { ChatRow(chat: chat) }
                    .listRowBackground(model.theme.background)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = chat } label: { Label("chatMenu_deleteChat", systemImage: "trash") }
                        Button { Task { try? await model.core.setMuted(chat, !chat.muted) } } label: {
                            Label(chat.muted ? "chatMenu_unmute" : "chatMenu_mute", systemImage: chat.muted ? "bell" : "bell.slash")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button { model.core.chats.setChatPinned(chat.peerLogin, pinned: chat.chatPinnedAt == nil) } label: {
                            Label(chat.chatPinnedAt == nil ? "chatMenu_pin" : "chatMenu_unpin", systemImage: chat.chatPinnedAt == nil ? "pin" : "pin.slash")
                        }
                        .tint(model.theme.primary)
                    }
                    .contextMenu {
                        Button { model.core.chats.setChatPinned(chat.peerLogin, pinned: chat.chatPinnedAt == nil) } label: {
                            Label(chat.chatPinnedAt == nil ? "chatMenu_pin" : "chatMenu_unpin", systemImage: "pin")
                        }
                        Button { Task { try? await model.core.setMuted(chat, !chat.muted) } } label: {
                            Label(chat.muted ? "chatMenu_unmute" : "chatMenu_mute", systemImage: "bell.slash")
                        }
                        Button(role: .destructive) { deleting = chat } label: { Label("chatMenu_deleteChat", systemImage: "trash") }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) { ConnectionStatusText() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showTransfers = true } label: { Image(systemName: "arrow.up.arrow.down.circle") }
            }
        }
        .sheet(isPresented: $showTransfers) { TransfersView().environmentObject(model).presentationDetents([.medium, .large]) }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text("newChat_loginHint"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { Task { await openByLogin() } }
        .navigationDestination(item: $opened) { chat in ChatView(peer: chat) }
        .confirmationDialog("chatMenu_deleteChatTitle", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let chat = deleting {
                Button("chatMenu_deleteChatConfirm", role: .destructive) {
                    Task { await model.core.chatService.clearOrDelete(ChatPeer(chat), deleteChat: true, forPeer: true) }
                }
            }
        }
    }

    /// Поиск собеседника по логину → открыть (или создать) чат.
    private func openByLogin() async {
        let login = search.trimmingCharacters(in: .whitespaces)
        guard !login.isEmpty else { return }
        searching = true
        searchError = nil
        defer { searching = false }
        if login.caseInsensitiveCompare(model.core.session.login ?? "") == .orderedSame { return }
        do {
            opened = try await model.core.openChat(login: login)
            search = ""
        } catch {
            searchError = localizedError(error)
        }
    }
}

struct ChatRow: View {
    @EnvironmentObject private var model: AppModel
    let chat: ChatSummary

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(accountId: chat.lastKnownAccountId, login: chat.peerLogin, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chat.peerLogin).font(.headline).foregroundStyle(model.theme.textPrimary).lineLimit(1)
                    if chat.chatPinnedAt != nil { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(model.theme.textMuted) }
                    if chat.muted { Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(model.theme.textMuted) }
                    Spacer()
                    if chat.lastTimestamp > 0 {
                        Text(Date(timeIntervalSince1970: Double(chat.lastTimestamp) / 1000), format: .dateTime.hour().minute())
                            .font(.caption).foregroundStyle(model.theme.textMuted)
                    }
                }
                HStack {
                    if chat.lastMessageIsMine {
                        Image(systemName: chat.lastMessageIsRead ? "checkmark.circle.fill" : "checkmark")
                            .font(.caption2).foregroundStyle(model.theme.primary)
                    }
                    Text(ChatStore.decodePreview(chat.lastMessage) { NSLocalizedString($0.replacingOccurrences(of: ".", with: "_"), comment: "") })
                        .font(.subheadline).foregroundStyle(model.theme.textMuted).lineLimit(1)
                    Spacer()
                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(model.theme.onPrimary)
                            .background(chat.muted ? model.theme.textMuted : model.theme.primary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension ChatSummary: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(peerLogin) }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmLogout = false
    @State private var confirmClearCache = false
    @State private var confirmDeleteAccount = false
    @State private var notice: String?

    var body: some View {
        Form {
            Section("settings_theme") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(AppTheme.all) { t in
                            Button { withAnimation { model.setTheme(t) } } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 12).fill(t.background).frame(width: 64, height: 88)
                                        .overlay(alignment: .bottomTrailing) { Capsule().fill(t.bubbleMine).frame(width: 36, height: 14).padding(8) }
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.theme == t ? t.primary : .clear, lineWidth: 3))
                                    Text(t.titleKey).font(.caption).foregroundStyle(model.theme.textPrimary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("settings_language") {
                Picker("language_title", selection: Binding(get: { model.locale.identifier.hasPrefix("ru") ? "ru" : "en" }, set: { model.setLanguage($0) })) {
                    Text("language_russian").tag("ru")
                    Text("language_english").tag("en")
                }
            }
            Section {
                NavigationLink { PrivacyView() } label: { Label("settings_privacy", systemImage: "hand.raised") }
                NavigationLink { EmailView() } label: { Label("settings_email", systemImage: "envelope") }
                NavigationLink { AppLockSettingsView() } label: { Label("applock_title", systemImage: "lock") }
            }
            Section {
                Button("settings_clearCache") { confirmClearCache = true }
            }
            if let notice { Section { Text(verbatim: notice).foregroundStyle(model.theme.textMuted) } }
            Section {
                Button("settings_logout", role: .destructive) { confirmLogout = true }
                Button("settings_deleteAccount", role: .destructive) { confirmDeleteAccount = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(model.theme.background.ignoresSafeArea())
        .navigationTitle("settings_title")
        .confirmationDialog("settings_clearCacheTitle", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("settings_clearCache", role: .destructive) {
                Task {
                    let freed = await model.core.clearCache()
                    notice = NSLocalizedString(freed > 0 ? "settings_cacheCleared" : "settings_cacheEmpty", comment: "")
                }
            }
        }
        .confirmationDialog("account_deleteTitle", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
            Button("account_deleteConfirm", role: .destructive) {
                Task {
                    if await model.core.deleteAccount() { model.phase = .signedOut }
                    else { notice = NSLocalizedString("account_deleteOfflineError", comment: "") }
                }
            }
        } message: {
            Text("account_deleteBody")
        }
        .confirmationDialog("account_logoutTitle", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("account_logoutConfirm", role: .destructive) { Task { await model.logout() } }
        } message: {
            Text("account_logoutBody")
        }
    }
}
