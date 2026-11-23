import Lottie
import SwiftUI
import UIKit

// Общие элементы интерфейса — те же, что у Android (ui/Components.kt и Material 3 в Compose):
// шрифт Roboto, значки Material Icons, размеры панелей, полей, кнопок и диалогов.

/// Строки на языке интерфейса приложения (он выбирается в настройках, а не в системе).
enum L10n {
    nonisolated(unsafe) private static var bundle: Bundle = .main

    static func setLanguage(_ tag: String) {
        bundle = Bundle.main.path(forResource: tag, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    static func string(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
}

/// Перевод по ключу Android: "error.loginTaken" и "error_loginTaken" — одна строка.
/// Нет перевода — сам ключ (как ошибка без строки на Android).
func tr(_ key: String) -> String {
    let k = key.replacingOccurrences(of: ".", with: "_")
    let s = L10n.string(k)
    return s == k ? key : s
}

/// Красный цвет ошибок — один на всё приложение.
let errorRed = Color(hex: 0xE53935)

/// Скругление карточек, полей и диалогов во всём приложении (CardShape на Android).
let cardRadius: CGFloat = 14

extension Font {
    /// Roboto — шрифт Android. Размер — как sp в Compose (тоже растёт с системным размером текста).
    static func roboto(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Roboto", size: size, relativeTo: .body).weight(weight)
    }
}

extension View {
    /// Высота строки как в Compose: текст по умолчанию (bodyLarge) — строка 24 при любом размере шрифта.
    /// Roboto сама по себе даёт ~1,17 размера — добираем поровну сверху и снизу.
    func lineBox(_ size: CGFloat, _ lineHeight: CGFloat = 24) -> some View {
        padding(.vertical, max(0, (lineHeight - size * 1.172) / 2))
    }
}

/// Значок Material Icons (как Icon(Icons.Filled.X) в Compose).
struct MIcon: View {
    let icon: MaterialIcon
    var size: CGFloat = 24
    var tint: Color?

    init(_ icon: MaterialIcon, size: CGFloat = 24, tint: Color? = nil) {
        self.icon = icon
        self.size = size
        self.tint = tint
    }

    var body: some View {
        Text(verbatim: icon.glyph)
            .font(.custom(icon.outlined ? "MaterialIconsOutlined-Regular" : "MaterialIcons-Regular", fixedSize: size))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Сдвиг пальца, после которого это уже не нажатие, а жест (touch slop на Android ≈ 8 dp).
/// Нажатие как в Compose: срабатывает, только если палец почти не сдвинулся (свайп и прокрутка —
/// не нажатие); пока палец на месте — подсветка формы (рябь Material).
private struct PressBody<S: Shape>: View {
    @Environment(\.isEnabled) private var enabled
    let configuration: PrimitiveButtonStyleConfiguration
    let shape: S
    let color: Color
    let fill: Bool
    @State private var moved = false

    var body: some View {
        // Обычная кнопка SwiftUI: уступает прокрутке и работает и поверх ленты (шапка чата). Свои жесты
        // нажатия забирали касание у прокрутки (ряды не листались), а UIKit-распознаватель над лентой
        // не получал касаний. Сдвиг пальца следит пассивный наблюдатель: свайп по кнопке — не нажатие.
        Button {
            if enabled && !moved { configuration.trigger() }
        } label: {
            configuration.label.contentShape(shape)
        }
        .buttonStyle(Highlight(shape: shape, color: color, fill: fill))
        .gesture(MoveWatcher { moved = $0 })
    }

    private struct Highlight: ButtonStyle {
        let shape: S
        let color: Color
        let fill: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            configuration.label
                .background {
                    if fill {
                        Rectangle().fill(color.opacity(pressed ? 0.10 : 0))
                    } else {
                        shape.fill(color.opacity(pressed ? 0.12 : 0))
                    }
                }
                .animation(.easeOut(duration: pressed ? 0.05 : 0.25), value: pressed)
        }
    }
}

/// Нажатие с подсветкой формы (круглые значки, капсулы).
struct RippleStyle<S: Shape>: PrimitiveButtonStyle {
    let shape: S
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, shape: shape, color: color, fill: false)
    }
}

/// Строка списка с подсветкой нажатия на всю ширину.
struct RowRippleStyle: PrimitiveButtonStyle {
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, shape: Rectangle(), color: color, fill: true)
    }
}

/// IconButton Compose: круг 48×48, значок 24.
struct IconButtonM: View {
    @EnvironmentObject private var model: AppModel
    let icon: MaterialIcon
    var tint: Color?
    var size: CGFloat = 24
    let action: () -> Void

    init(_ icon: MaterialIcon, tint: Color? = nil, size: CGFloat = 24, action: @escaping () -> Void) {
        self.icon = icon
        self.tint = tint
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            MIcon(icon, size: size, tint: tint ?? model.theme.textPrimary).frame(width: 48, height: 48)
        }
        .buttonStyle(RippleStyle(shape: Circle(), color: model.theme.textPrimary))
    }
}

/// TopAppBar Compose (64): слева «назад» (если есть) и заголовок, справа — действия.
struct TopBar<Title: View, Actions: View>: View {
    @EnvironmentObject private var model: AppModel
    var onBack: (() -> Void)?
    var centered = false
    @ViewBuilder var title: () -> Title
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ZStack {
            if centered {
                title().font(.roboto(22)).tracking(0).foregroundStyle(model.theme.textPrimary).lineLimit(1).padding(.horizontal, 56)
            }
            HStack(spacing: 0) {
                if let onBack {
                    IconButtonM(.arrowBack, action: onBack).padding(.leading, 4)
                }
                if !centered {
                    title().font(.roboto(22)).tracking(0).foregroundStyle(model.theme.textPrimary).lineLimit(1)
                        .padding(.leading, onBack == nil ? 16 : 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) { actions() }.padding(.trailing, 4)
            }
        }
        .frame(height: 64)
        .background(model.theme.background)
    }
}

extension TopBar where Actions == EmptyView {
    init(onBack: (() -> Void)? = nil, centered: Bool = false, @ViewBuilder title: @escaping () -> Title) {
        self.init(onBack: onBack, centered: centered, title: title, actions: { EmptyView() })
    }
}

/// Экран с заголовком по центру, стрелкой «назад» и прокручиваемым содержимым
/// (формы входа, восстановления, настроек) — FormScreen на Android.
struct FormScreen<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.navBack) private var navBack
    let title: LocalizedStringKey
    var showBack = true
    @ViewBuilder var content: () -> Content
    @StateObject private var keyboard = KeyboardObserver()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(onBack: showBack ? { navBack() } : nil, centered: true) { Text(title) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            // форма прокручивается над клавиатурой
            .contentMargins(.bottom, max(0, keyboard.height - windowSafeArea.bottom), for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(model.theme.background.ignoresSafeArea())
    }
}

/// Поле ввода форм входа — заливка цветом поверхности, без рамки, скругление 14, высота 56.
struct AuthTextField: View {
    enum Kind { case text, number, password, lettersCode }
    @EnvironmentObject private var model: AppModel
    @Binding var text: String
    let hint: LocalizedStringKey
    var kind: Kind = .text
    var contentType: UITextContentType?
    @State private var hidden = true

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if kind == .password && hidden {
                    SecureField(text: $text, prompt: Text(hint).foregroundStyle(model.theme.textMuted)) { EmptyView() }
                } else {
                    TextField(text: $text, prompt: Text(hint).foregroundStyle(model.theme.textMuted)) { EmptyView() }
                }
            }
            .font(.roboto(16))
            .foregroundStyle(model.theme.textPrimary)
            .textContentType(contentType)
            .keyboardType(kind == .number ? .numberPad : kind == .lettersCode ? .asciiCapable : .default)
            .textInputAutocapitalization(kind == .lettersCode ? .characters : .never)
            .autocorrectionDisabled()
            .padding(.leading, 16)
            .padding(.trailing, kind == .password ? 0 : 16)
            if kind == .password {
                IconButtonM(hidden ? .visibilityOff : .visibility, tint: model.theme.textMuted) { hidden.toggle() }
                    .padding(.trailing, 4)
            }
        }
        .frame(minHeight: 56)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: cardRadius))
        .tint(model.theme.primary)
    }
}

/// Основная кнопка: на всю ширину, высота 52, во время loading — кошка вместо текста.
struct PrimaryButton: View {
    @EnvironmentObject private var model: AppModel
    let title: LocalizedStringKey
    var loading = false
    var enabled = true
    let action: () -> Void

    init(_ title: LocalizedStringKey, loading: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.loading = loading
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        let active = enabled && !loading
        Button(action: action) {
            ZStack {
                if loading { AppLoadingIndicator(size: 22) } else { Text(title).font(.roboto(17, .semibold)) }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .foregroundStyle(active ? model.theme.onPrimary : model.theme.textPrimary.opacity(0.38))
            .background(active ? model.theme.primary : model.theme.textPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: cardRadius))
        }
        .buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: cardRadius), color: model.theme.onPrimary))
        .disabled(!active)
    }
}

/// Второстепенная кнопка с рамкой акцентного цвета.
struct SecondaryButton: View {
    @EnvironmentObject private var model: AppModel
    let title: LocalizedStringKey
    var enabled = true
    let action: () -> Void

    init(_ title: LocalizedStringKey, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.roboto(14, .semibold))
                .foregroundStyle(enabled ? model.theme.primary : model.theme.textPrimary.opacity(0.38))
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: cardRadius).strokeBorder(model.theme.primary, lineWidth: 1))
        }
        .buttonStyle(RippleStyle(shape: RoundedRectangle(cornerRadius: cardRadius), color: model.theme.primary))
        .disabled(!enabled)
    }
}

/// TextButton Compose: текст акцентного цвета 14 medium, высота 40.
struct TextButtonM: View {
    @EnvironmentObject private var model: AppModel
    let title: LocalizedStringKey
    var color: Color?
    var fillWidth = false
    var enabled = true
    let action: () -> Void

    init(_ title: LocalizedStringKey, color: Color? = nil, fillWidth: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.fillWidth = fillWidth
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        let c = color ?? model.theme.primary
        Button(action: action) {
            Text(title).font(.roboto(14, .medium)).foregroundStyle(enabled ? c : model.theme.textPrimary.opacity(0.38))
                .padding(.horizontal, 12)
                .frame(maxWidth: fillWidth ? .infinity : nil, minHeight: 40)
        }
        .buttonStyle(RippleStyle(shape: Capsule(), color: c))
        .disabled(!enabled)
    }
}

/// Строка ошибки под формой (отступ 14 сверху).
struct ErrorLine: View {
    let text: String?

    var body: some View {
        if let text {
            Text(verbatim: text).font(.roboto(16)).foregroundStyle(errorRed).padding(.top, 14)
        }
    }
}

struct MutedText: View {
    @EnvironmentObject private var model: AppModel
    let text: LocalizedStringKey
    var size: CGFloat = 14

    init(_ text: LocalizedStringKey, size: CGFloat = 14) {
        self.text = text
        self.size = size
    }

    var body: some View { Text(text).font(.roboto(size)).foregroundStyle(model.theme.textMuted) }
}

/// Вертикальный отступ между элементами формы.
struct Gap: View {
    var height: CGFloat = 14
    init(_ height: CGFloat = 14) { self.height = height }
    var body: some View { Color.clear.frame(height: height) }
}

/// Индикатор ожидания для всего приложения: кошка, сворачивающаяся клубком
/// (Lottie, LottieFiles — Lottie Simple License; Resources/Raw/loading_cat.json, тот же файл, что у Android).
struct AppLoadingIndicator: View {
    var size: CGFloat = 24

    var body: some View {
        LottieView(animation: .named("loading_cat"))
            .looping()
            .resizable()
            .frame(width: size, height: size)
    }
}

struct FullScreenLoading: View {
    var body: some View {
        AppLoadingIndicator(size: 64).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - диалоги, меню, всплывающие подсказки

/// AlertDialog Material 3: карточка поверхности со скруглением 14 поверх затемнения;
/// заголовок 24, текст, кнопки-тексты справа. Нажатие мимо — onDismiss.
struct AppDialog<Body: View, Buttons: View>: View {
    @EnvironmentObject private var model: AppModel
    var title: LocalizedStringKey?
    let onDismiss: () -> Void
    @ViewBuilder var content: () -> Body
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.roboto(24)).tracking(0).foregroundStyle(model.theme.textPrimary).padding(.bottom, 16)
            }
            content().font(.roboto(14)).foregroundStyle(model.theme.textMuted)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons()
            }
            .padding(.top, 24)
        }
        .padding(24)
        .frame(maxWidth: 560)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: cardRadius))
        .padding(.horizontal, 48)
    }
}

/// Пункт выпадающего меню (DropdownMenuItem): высота 48, текст 14 medium.
struct MenuItemM: View {
    @EnvironmentObject private var model: AppModel
    let title: LocalizedStringKey
    var icon: MaterialIcon?
    var danger = false
    let action: () -> Void

    init(_ title: LocalizedStringKey, icon: MaterialIcon? = nil, danger: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.danger = danger
        self.action = action
    }

    var body: some View {
        let color = danger ? errorRed : model.theme.textPrimary
        Button {
            model.popups.dismiss()
            action()
        } label: {
            HStack(spacing: 12) {
                if let icon { MIcon(icon, size: 24, tint: danger ? errorRed : model.theme.textMuted) }
                Text(title).font(.roboto(14, .medium)).foregroundStyle(color).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 112, maxWidth: 280, minHeight: 48)
        }
        .buttonStyle(RowRippleStyle(color: model.theme.textPrimary))
    }
}

struct MenuDividerM: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { model.theme.textMuted.opacity(0.2).frame(height: 1).padding(.vertical, 8) }
}

/**
 * Слой всплывающих окон поверх всего приложения (Popup/Dialog в Compose): диалог с
 * затемнением или выпадающее меню у элемента. Нажатие мимо закрывает.
 * Содержимое — самостоятельные View со своим состоянием.
 */
@MainActor
final class PopupHost: ObservableObject {
    struct Menu {
        /// Рамка элемента, к которому привязано меню (в координатах окна).
        let anchor: CGRect
        /// Сдвиг меню по горизонтали от левого края элемента (или от правого — при trailing).
        let offsetX: CGFloat
        let trailing: Bool
        let content: AnyView
    }

    @Published private(set) var dialog: AnyView?
    /// Слои поверх окна (шторка выбора из диалога настроек) — закрываются по одному.
    @Published private(set) var overlays: [AnyView] = []
    @Published private(set) var menu: Menu?
    /// Своё затемнение у окна (например, меню вложений анимирует его само).
    @Published private(set) var dialogDims = true

    /// Окно не перекрывает работу с клавиатурой экрана под ним (развилка вложений): поле ввода
    /// чата остаётся над клавиатурой.
    @Published private(set) var keepsKeyboard = false

    func show<D: View>(dim: Bool = true, keepsKeyboard: Bool = false, @ViewBuilder _ dialog: () -> D) {
        menu = nil
        overlays = []
        dialogDims = dim
        self.keepsKeyboard = keepsKeyboard
        self.dialog = AnyView(dialog())
    }

    /// Показать поверх открытого окна, не закрывая его (рисует своё затемнение само).
    func showOver<D: View>(@ViewBuilder _ layer: () -> D) {
        menu = nil
        overlays.append(AnyView(layer()))
    }

    func dismissOver(animated: Bool = true) {
        var t = Transaction()
        t.disablesAnimations = !animated
        withTransaction(t) { _ = overlays.popLast() }
    }

    func menu<I: View>(at anchor: CGRect, offsetX: CGFloat = 0, trailing: Bool = false, @ViewBuilder _ items: () -> I) {
        menu = Menu(anchor: anchor, offsetX: offsetX, trailing: trailing, content: AnyView(items()))
    }

    /// animated: false — убрать сразу (окно уже закрыто чем-то поверх).
    func dismiss(animated: Bool = true) {
        var t = Transaction()
        t.disablesAnimations = !animated
        withTransaction(t) {
            dialog = nil
            overlays = []
            menu = nil
        }
    }
}

/// Закрыть шторку: animated — уехать вниз (300 мс), затем then; без анимации — сразу.
struct SheetCloseAction {
    fileprivate let run: (Bool, @escaping () -> Void) -> Void
    func callAsFunction(animated: Bool = true, then: @escaping () -> Void = {}) { run(animated, then) }
}

/// Содержимое тянет шторку: сдвиг вниз от начала и отпускание (скорость, pt/с).
struct SheetPullAction {
    let changed: (CGFloat) -> Void
    let end: (CGFloat) -> Void
    init(_ changed: @escaping (CGFloat) -> Void, end: @escaping (CGFloat) -> Void) {
        self.changed = changed
        self.end = end
    }
}

private struct SheetPullKey: EnvironmentKey {
    static let defaultValue: SheetPullAction? = nil
}

private struct SheetCloseKey: EnvironmentKey {
    static let defaultValue = SheetCloseAction { _, then in then() }
}

/// Открыто ли окно или шторка поверх экрана (общий слой окон).
struct PopupAware<Content: View>: View {
    @ObservedObject var popups: PopupHost
    @ViewBuilder var content: (Bool) -> Content

    var body: some View { content(popups.dialog != nil && !popups.keepsKeyboard) }
}

/// Содержимое строки ручки шторки (по краям от ручки) — например, «Выбрано: N» галереи.
@MainActor
final class SheetHeader: ObservableObject {
    @Published var view: AnyView?
}

/// Слой поверх шторки во весь экран (съёмка, предпросмотр) — как Dialog поверх ModalBottomSheet.
@MainActor
final class SheetCover: ObservableObject {
    @Published var view: AnyView?
}

extension EnvironmentValues {
    var sheetPull: SheetPullAction? {
        get { self[SheetPullKey.self] }
        set { self[SheetPullKey.self] = newValue }
    }

    var sheetClose: SheetCloseAction {
        get { self[SheetCloseKey.self] }
        set { self[SheetCloseKey.self] = newValue }
    }
}

/// Нижняя шторка Material 3 (ModalBottomSheet) во всю ширину: верхние углы 28, ручка 32×4,
/// затемнение 0,32; выезжает и уезжает за 300 мс (FastOutSlowIn); тянется вниз за ручку и шапку —
/// дальше 56 pt или броском (125 pt/с) — закрывается. Показывается через `popups.show(dim: false)`.
struct BottomSheetM<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    /// Высота содержимого — доля экрана под строкой состояния; nil — по содержимому (плюс жестовая полоса).
    var fraction: CGFloat?
    /// Фон шторки; nil — фон темы.
    var background: Color?
    /// Шторка — слой поверх окна (`popups.showOver`), закрывается только она.
    var layered = false
    @ViewBuilder var content: () -> Content
    @StateObject private var cover = SheetCover()
    @StateObject private var header = SheetHeader()
    @State private var shown = false
    @State private var drag: CGFloat = 0
    @State private var closing = false
    @State private var height: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let top = windowSafeArea.top
            ZStack(alignment: .bottom) {
                Color.black.opacity(shown ? 0.32 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { close(animated: true) {} }
                VStack(spacing: 0) {
                    Capsule().fill(model.theme.textMuted.opacity(0.4)).frame(width: 32, height: 4).frame(maxWidth: .infinity).frame(height: 48)
                        .contentShape(Rectangle())
                        .gesture(dragGesture)
                        .overlay {
                            if let view = header.view { view.transition(.opacity) }
                        }
                        .animation(.easeInOut(duration: 0.2), value: header.view != nil)
                        .zIndex(1)
                    if let fraction {
                        content().frame(height: (g.size.height - top) * fraction)
                    } else {
                        content().padding(.bottom, windowSafeArea.bottom)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(background ?? model.theme.background)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .offset(y: shown ? max(0, drag) : max(height, g.size.height))
                if let view = cover.view { view.transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.15), value: cover.view != nil)
        }
        .ignoresSafeArea()
        .environment(\.sheetClose, SheetCloseAction { animated, then in close(animated: animated, then: then) })
        // содержимое (сетка, дошедшая до верха) тянет шторку так же, как ручка
        .environment(\.sheetPull, SheetPullAction { dy in drag = max(0, dy) } end: { settle(velocity: $0) })
        .environmentObject(cover)
        .environmentObject(header)
        // сначала шторка встаёт за нижним краем, со следующего кадра выезжает (вместе с содержимым)
        .onAppear { DispatchQueue.main.async { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) { shown = true } } }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = max(0, $0.translation.height) }
            .onEnded { settle(velocity: $0.velocity.height) }
    }

    /// Палец отпущен: смахнули вниз — закрыть; иначе от шторки видно меньше четверти экрана — уехать
    /// вниз самой, больше — вернуться на место.
    private func settle(velocity: CGFloat) {
        let screen = UIScreen.main.bounds.height
        if velocity > 600 || height - drag < screen / 4 {
            close(animated: true) {}
        } else {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) { drag = 0 }
        }
    }

    private func close(animated: Bool, then: @escaping () -> Void) {
        guard !closing else { return }
        closing = true
        let remove = { if layered { model.popups.dismissOver(animated: false) } else { model.popups.dismiss(animated: false) } }
        guard animated else {
            remove()
            then()
            return
        }
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) { shown = false } completion: {
            remove()
            then()
        }
    }
}

/// Отступы окна (строка состояния, жестовая полоса) — там, где сам экран их игнорирует.
@MainActor
var windowSafeArea: UIEdgeInsets {
    UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets ?? .zero
}

struct PopupOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var host: PopupHost
    @State private var menuSize: CGSize = .zero

    var body: some View {
        ZStack {
            if let dialog = host.dialog {
                if host.dialogDims {
                    Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { host.dismiss() }.transition(.opacity)
                    dialog.frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else {
                    dialog.ignoresSafeArea()
                }
            }
            ForEach(Array(host.overlays.enumerated()), id: \.offset) { _, layer in layer.ignoresSafeArea() }
            if let menu = host.menu {
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).onTapGesture { host.dismiss() }
                        VStack(alignment: .leading, spacing: 0) { menu.content }
                            .padding(.vertical, 8)
                            .fixedSize()
                            .background(model.theme.surface, in: RoundedRectangle(cornerRadius: cardRadius))
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { menuSize = $0 }
                            .offset(menuOrigin(menu, in: g))
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: menu.trailing ? .topTrailing : .topLeading)))
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
                .ignoresSafeArea()
            }
        }
        .animation(.easeOut(duration: 0.14), value: host.dialog != nil)
        .animation(.easeOut(duration: 0.12), value: host.menu?.anchor)
    }

    /// Под элементом; не помещается снизу — над ним; не вылезает за края экрана.
    private func menuOrigin(_ m: PopupHost.Menu, in g: GeometryProxy) -> CGSize {
        let w = g.size.width, h = g.size.height
        var x = m.trailing ? m.anchor.maxX - menuSize.width - m.offsetX : m.anchor.minX + m.offsetX
        x = min(max(8, x), w - menuSize.width - 8)
        var y = m.anchor.maxY
        if y + menuSize.height > h - 8 { y = max(8, m.anchor.minY - menuSize.height) }
        return CGSize(width: x, height: y)
    }
}

extension View {
    /// Рамка элемента в координатах окна — для привязки меню.
    func globalFrame(_ frame: Binding<CGRect>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.wrappedValue = $0 }
    }
}

/// Toast Android: тёмная плашка снизу на ~2 с.
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var text: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        self.text = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.text = nil }
        }
    }
}

struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack {
            Spacer()
            if let text = center.text {
                Text(verbatim: text).font(.roboto(14)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(hex: 0x323232).opacity(0.95), in: Capsule())
                    .padding(.horizontal, 32)
                    .padding(.bottom, 64)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.text)
        .allowsHitTesting(false)
    }
}
