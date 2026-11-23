import OshinobuCore
import SwiftUI

/// «Тема» из настроек (ui/home/ThemeScreen.kt): экран, который выглядит как переписка с воображаемым
/// Бобом, а снизу — ряд тем. Нажатие на тему сразу перекрашивает всё приложение и эту переписку тоже.
struct ThemeScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.navBack) private var navBack

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            previewMessages.frame(maxHeight: .infinity, alignment: .bottom)
            previewComposer
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AppTheme.all) { t in
                        ThemeTile(theme: t, selected: t == model.theme) { withAnimation { model.setTheme(t) } }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(model.theme.surface.ignoresSafeArea(edges: .bottom))
            .noSwipeBack()
        }
        .background(model.theme.chatBackground.ignoresSafeArea())
    }

    /// Шапка как в чате: назад (работает), Боб «в сети», звонок и меню (для вида).
    private var previewHeader: some View {
        HStack(spacing: 8) {
            HeaderPill {
                HStack(spacing: 0) {
                    PillIcon(.arrowBack) { navBack() }
                    PillIcon(.swapVert) {}
                }
            }
            HeaderPill {
                HStack(spacing: 8) {
                    AvatarImage(data: nil, size: 32)
                    VStack(spacing: 0) {
                        Text("themePreview_peerName").font(.roboto(16, .medium)).foregroundStyle(model.theme.textPrimary).lineBox(16)
                        Text("presence_online").font(.roboto(12)).foregroundStyle(model.theme.textPrimary.opacity(0.7)).lineBox(12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity)
            HeaderPill {
                HStack(spacing: 0) {
                    PillIcon(.oCall) {}
                    PillIcon(.moreVert) {}
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Восемь сообщений, по очереди — от Боба и ему; время — сегодняшнее утро.
    private var previewMessages: some View {
        let start = Calendar.current.date(bySettingHour: 10, minute: 12, second: 0, of: Date()) ?? Date()
        return GeometryReader { g in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(1...8, id: \.self) { i in
                    let mine = i % 2 == 0
                    let message = previewMessage(i, mine: mine, start: start)
                    HStack {
                        if mine { Spacer(minLength: 0) }
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(verbatim: message.text).font(.roboto(16)).foregroundStyle(mine ? model.theme.onBubbleMine : model.theme.textPrimary)
                                .lineBox(16).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                            MetaRow(message: message)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(mine ? model.theme.bubbleMine : model.theme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: min(280, g.size.width - 32), alignment: mine ? .trailing : .leading)
                        if !mine { Spacer(minLength: 0) }
                    }
                    .padding(.vertical, 6)
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 16)
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
        .clipped()
    }

    private func previewMessage(_ i: Int, mine: Bool, start: Date) -> StoredMessage {
        var m = StoredMessage(messageId: "preview-\(i)", text: tr("themePreview_msg\(i)"), isMine: mine,
                              timestamp: Int64((start.timeIntervalSince1970 + Double(i - 1) * 60) * 1000))
        m.status = i == 8 ? MessageStatus.sent : MessageStatus.read
        return m
    }

    /// Поле ввода — для вида.
    private var previewComposer: some View {
        HStack(spacing: 12) {
            MIcon(.oEmojiEmotions, tint: model.theme.textMuted)
            Text("chat_messageHint").font(.roboto(16)).foregroundStyle(model.theme.textMuted).frame(maxWidth: .infinity, alignment: .leading)
            MIcon(.attachFile, tint: model.theme.textMuted)
            Spacer().frame(width: 4)
            MIcon(.oMic, tint: model.theme.textMuted)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(minHeight: 52)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

/// Плитка темы — крошечная переписка в её цветах (фон, чужой и свой пузырь, полоска поля ввода)
/// и название под ней; выбранная — в рамке акцента текущей темы.
struct ThemeTile: View {
    @EnvironmentObject private var model: AppModel
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 6).fill(theme.surface).frame(width: 40, height: 12)
                    RoundedRectangle(cornerRadius: 6).fill(theme.bubbleMine).frame(width: 46, height: 12).frame(maxWidth: .infinity, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 6).fill(theme.surface).frame(width: 32, height: 12)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 3).fill(theme.primary).frame(width: 6, height: 6)
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 14)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(7)
                .background(theme.chatBackground, in: RoundedRectangle(cornerRadius: 11))
                .padding(selected ? 3 : 1)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? model.theme.primary : model.theme.textMuted.opacity(0.35), lineWidth: selected ? 3 : 1))
                .frame(width: 78, height: 104)
                Text(theme.titleKey).font(.roboto(12, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? model.theme.primary : model.theme.textPrimary)
                    .multilineTextAlignment(.center).lineLimit(2).lineSpacing(24 - 12 * 1.172).lineBox(12)
                    .padding(.top, 6).padding(.bottom, 2)
            }
            .frame(width: 78)
        }
        .buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: 14), color: model.theme.textPrimary))
    }
}
