import Combine
import OshinobuCore
import SwiftUI

// Панель эмодзи и стикеров на месте клавиатуры — как у Android (ui/chat/EmojiKeyboard.kt, Stickers.kt EmojiPanel).
// Переход эмодзи ↔ клавиатура не двигает поле ввода: панель занимает ровно высоту клавиатуры;
// клавиатура при переключении наезжает на панель или уезжает с неё, а из покоя панель выезжает сама.

/// Клавиатура системы: текущая высота (от низа экрана) и последняя известная — для высоты панели.
@MainActor
final class KeyboardObserver: ObservableObject {
    @Published private(set) var height: CGFloat = 0
    @Published private(set) var lastHeight: CGFloat
    private var bag: Set<AnyCancellable> = []

    init() {
        let saved = UserDefaults.standard.double(forKey: "ui_keyboard_height")
        lastHeight = saved > 120 ? saved : 336
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] n in self?.update(n) }
            .store(in: &bag)
    }

    private func update(_ n: Notification) {
        guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let screen = UIScreen.main.bounds.height
        let h = n.name == UIResponder.keyboardWillHideNotification ? 0 : max(0, screen - end.minY)
        let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        withAnimation(.easeOut(duration: duration)) { height = h }
        if h > 120, abs(h - lastHeight) > 1 {
            lastHeight = h
            UserDefaults.standard.set(Double(h), forKey: "ui_keyboard_height")
        }
    }
}

/// Режим панели у поля ввода (EmojiKeyboardState на Android).
@MainActor
final class EmojiKeyboardState: ObservableObject {
    @Published private(set) var emojiMode = false
    /// Вкладка панели — стикеры: запоминается, с неё панель и открывается.
    @Published private(set) var stickersPage: Bool
    /// Возвращаемся к клавиатуре: место панели держится, пока она не поднимется.
    @Published var awaitingKeyboard = false
    private let withStickers: Bool

    init(withStickers: Bool) {
        self.withStickers = withStickers
        stickersPage = withStickers && UserDefaults.standard.bool(forKey: "ui_stickers_panel_last")
    }

    func selectPage(_ stickers: Bool) {
        guard stickers != stickersPage else { return }
        stickersPage = stickers
        if withStickers { UserDefaults.standard.set(stickers, forKey: "ui_stickers_panel_last") }
    }

    /// Кнопка эмодзи/клавиатура у поля; focus — сфокусировать или снять фокус с поля.
    func toggle(focus: (Bool) -> Void) {
        if emojiMode {
            awaitingKeyboard = true
            emojiMode = false
            focus(true)
        } else {
            focus(false)
            emojiMode = true
        }
    }

    /// Поле получило фокус (нажатие на него): клавиатура поднимается на место панели.
    func onFieldFocused() {
        if emojiMode {
            awaitingKeyboard = true
            emojiMode = false
        }
    }

    func closeEmoji() { emojiMode = false }
}

/// Место под полем ввода: от низа экрана до поля = max(клавиатура, панель эмодзи, половина отступа жестовой полосы).
/// Панель лежит сверху этого места и видна только в режиме эмодзи.
struct EmojiKeyboardArea<Stickers: View>: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var state: EmojiKeyboardState
    @ObservedObject var keyboard: KeyboardObserver
    let bottomInset: CGFloat
    let onEmoji: (String) -> Void
    var stickers: ((CGFloat) -> Stickers)?
    /// Клавиатура — этого поля: при окне или шторке поверх (их поля ввода) место под полем не растёт.
    var followsKeyboard = true
    @State private var reserve: CGFloat = 0

    var body: some View {
        let height = max(followsKeyboard ? keyboard.height : 0, reserve, bottomInset / 2)
        ZStack(alignment: .top) {
            if reserve > 0 {
                EmojiPanel(height: keyboard.lastHeight, bottomInset: bottomInset, onEmoji: onEmoji, stickers: stickers,
                           stickersPage: state.stickersPage, onPage: state.selectPage)
            }
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .clipped()
        .onChange(of: target) { _, t in
            // переключение клавиатура ↔ эмодзи место не меняет; из покоя панель выезжает за 220 мс
            if keyboard.height > 0 { reserve = t } else { withAnimation(.easeOut(duration: 0.22)) { reserve = t } }
        }
        .onChange(of: keyboard.height) { _, h in
            if state.awaitingKeyboard && h >= keyboard.lastHeight - 4 { state.awaitingKeyboard = false }
        }
        .onChange(of: state.awaitingKeyboard) { _, waiting in
            // аппаратная клавиатура не поднимется — не ждём дольше 1,5 с
            guard waiting else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { state.awaitingKeyboard = false }
        }
    }

    private var target: CGFloat { state.emojiMode || state.awaitingKeyboard ? keyboard.lastHeight : 0 }
}

/// Панель на месте клавиатуры, той же высоты, со скруглёнными верхними углами. Со стикерами внизу по центру —
/// овал «Эмодзи | Стикеры»: стикеры въезжают справа, эмодзи уходят влево, и обратно.
struct EmojiPanel<Stickers: View>: View {
    @EnvironmentObject private var model: AppModel
    let height: CGFloat
    let bottomInset: CGFloat
    let onEmoji: (String) -> Void
    var stickers: ((CGFloat) -> Stickers)?
    let stickersPage: Bool
    let onPage: (Bool) -> Void
    @State private var stickersOpened: Bool
    @State private var shift: CGFloat

    init(height: CGFloat, bottomInset: CGFloat, onEmoji: @escaping (String) -> Void, stickers: ((CGFloat) -> Stickers)?,
         stickersPage: Bool, onPage: @escaping (Bool) -> Void) {
        self.height = height
        self.bottomInset = bottomInset
        self.onEmoji = onEmoji
        self.stickers = stickers
        self.stickersPage = stickersPage
        self.onPage = onPage
        // открытая вкладка — с первого кадра (иначе на кадр мелькали эмодзи, потом стикеры)
        _stickersOpened = State(initialValue: stickersPage)
        _shift = State(initialValue: stickersPage ? 1 : 0)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let stickers {
                let reserve = bottomInset + 56
                PanelPager(shift: shift, stickersOpened: stickersOpened,
                           emoji: { EmojiPicker(onEmoji: onEmoji, bottomPadding: reserve) },
                           stickers: { stickers(reserve) })
                PanelSwitch(page: stickersPage ? 1 : 0) { page in
                    if page == 1 { stickersOpened = true }
                    onPage(page == 1)
                }
                .padding(.bottom, bottomInset + 8)
            } else {
                EmojiPicker(onEmoji: onEmoji, bottomPadding: 8)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(model.theme.surface)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
        .onChange(of: stickersPage) { _, page in
            // стикеры, открытые впервые, сначала встают справа за краем — со следующего кадра въезжают
            DispatchQueue.main.async { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.28)) { shift = page ? 1 : 0 } }
        }
    }
}

/// Две страницы панели по анимируемому сдвигу 0 (эмодзи) … 1 (стикеры): эмодзи уезжают влево,
/// стикеры въезжают справа, и обратно. Эмодзи, уехавшие целиком, не рисуются (как на Android).
private struct PanelPager<Emoji: View, Stickers: View>: View, Animatable {
    var shift: CGFloat
    let stickersOpened: Bool
    @ViewBuilder var emoji: () -> Emoji
    @ViewBuilder var stickers: () -> Stickers

    var animatableData: CGFloat {
        get { shift }
        set { shift = newValue }
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                if shift < 1 { emoji().offset(x: -shift * g.size.width) }
                if stickersOpened { stickers().offset(x: (1 - shift) * g.size.width) }
            }
        }
    }
}

/// Все эмодзи сеткой по 10 в ряд.
struct EmojiPicker: View {
    let onEmoji: (String) -> Void
    var bottomPadding: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let cell = (g.size.width - 16) / 10
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 0), count: 10), spacing: 0) {
                    ForEach(allEmojis, id: \.self) { e in
                        Text(verbatim: e).font(.system(size: cell * 0.55)).frame(width: cell, height: cell)
                            .contentShape(Rectangle())
                            .onTapGesture { onEmoji(e) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, bottomPadding)
            }
        }
    }
}

/// Овал из двух подписей, как панель вкладок на главном экране.
private struct PanelSwitch: View {
    @EnvironmentObject private var model: AppModel
    let page: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button(0, "sticker_tabEmoji")
            button(1, "sticker_tabStickers")
        }
        .padding(4)
        .background(model.theme.background.opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(model.theme.textMuted.opacity(0.18), lineWidth: 1))
    }

    private func button(_ i: Int, _ label: LocalizedStringKey) -> some View {
        let selected = page == i
        return Text(label).font(.roboto(13, selected ? .semibold : .regular))
            .foregroundStyle(selected ? model.theme.primary : model.theme.textPrimary)
            .padding(.horizontal, 18).padding(.vertical, 7)
            .background(Capsule().fill(selected ? model.theme.primary.opacity(0.16) : .clear))
            .animation(.easeInOut(duration: 0.22), value: selected)
            .contentShape(Capsule())
            .onTapGesture { onSelect(i) }
    }
}
