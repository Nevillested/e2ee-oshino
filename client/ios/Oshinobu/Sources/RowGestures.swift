import SwiftUI
import UIKit

// Жесты строки сообщения — одним автоматом, как у Android (ChatScreen.kt MessageRow / classify):
// тап, двойной тап, долгий тап с протяжкой и свайп влево не спорят друг с другом и со скроллом ленты.
// Касание классифицируется так: отпустили до 400 мс — тап; сдвиг по горизонтали дальше 8 pt
// (и в полтора раза больше вертикального) влево — свайп-ответ, вправо — не наш (свайп назад);
// по вертикали дальше 8 pt — скролл ленты, не наш; держат 400 мс — долгий тап, и дальше — протяжка.
// Двойной тап ждём до 220 мс от первого касания (как Telegram), а не системные 300 мс после отпускания.

/// Касание строки (касание пальцем; меньше 8 pt — ещё не движение).
private let touchSlop: CGFloat = 8
/// longPressTimeout Compose.
private let longPressSeconds: TimeInterval = 0.4
/// Окно двойного тапа — от первого касания.
private let doubleTapWindow: TimeInterval = 0.22

/// Распознаватель: .ended из .possible — тап; .began/.changed/.ended — долгий тап или свайп.
final class RowGestureRecognizer: UIGestureRecognizer {
    enum Kind { case none, tap, long, swipe }
    private(set) var kind = Kind.none
    private(set) var downLocation: CGPoint = .zero
    private(set) var downTime: TimeInterval = 0
    /// Палец коснулся строки (до классификации) — для двойного тапа.
    var onDown: (() -> Bool)?
    /// Свайп-ответ: без него любой сдвиг до долгого нажатия — не наш (листание, пейджер).
    var swipeEnabled = true
    /// Принимать ли касание в этой точке окна: лента уходит под шапку и поле ввода, а UIKit отдаёт
    /// касание по ним строке под ними — такие касания не наши.
    var accepts: ((CGPoint) -> Bool)?
    private var timer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, numberOfTouches <= 1, let t = touches.first else {
            state = .failed
            return
        }
        if let accepts, !accepts(t.location(in: view?.window)) {
            state = .failed
            return
        }
        downLocation = t.location(in: view)
        downTime = t.timestamp
        findScrollViews(t)
        // второй тап двойного — дальше это касание никому не нужно
        if onDown?() == true {
            kind = .tap
            state = .failed
            return
        }
        let timer = Timer(timeInterval: longPressSeconds, repeats: false) { [weak self] _ in
            guard let self, self.state == .possible else { return }
            self.kind = .long
            self.state = .began
        }
        // таймер идёт и пока UIScrollView держит режим отслеживания касаний
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        let p = t.location(in: view)
        switch state {
        case .possible:
            let dx = p.x - downLocation.x, dy = p.y - downLocation.y
            if abs(dx) > touchSlop && abs(dx) > abs(dy) * 1.5 {
                if dx > 0 || !swipeEnabled {
                    state = .failed
                } else {
                    timer?.invalidate()
                    kind = .swipe
                    state = .began
                }
            } else if abs(dy) > touchSlop {
                state = .failed
            }
        case .began, .changed:
            state = .changed
        default: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        switch state {
        case .possible:
            kind = .tap
            state = .ended
        case .began, .changed:
            state = .ended
        default: break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        timer?.invalidate()
        timer = nil
        kind = .none
    }

    /// Прокрутки под пальцем, от ближней к дальней (сетка, пейджер паков, лента): SwiftUI вешает
    /// распознаватель на вью экрана, поэтому их ищем по точке касания, а не среди родителей.
    private(set) var scrollViewsUnderTouch: [UIScrollView] = []

    /// Лента, в которой лежит строка.
    var enclosingScrollView: UIScrollView? { scrollViewsUnderTouch.first }

    /// Касание целиком наше: всё, что листается под пальцем, отпускает его.
    func freezeScrolling() {
        for sv in scrollViewsUnderTouch {
            sv.panGestureRecognizer.isEnabled = false
            sv.panGestureRecognizer.isEnabled = true
        }
    }

    private func findScrollViews(_ t: UITouch) {
        scrollViewsUnderTouch = []
        guard let window = view?.window else { return }
        var v = window.hitTest(t.location(in: window), with: nil)
        while let current = v {
            if let sv = current as? UIScrollView { scrollViewsUnderTouch.append(sv) }
            v = current.superview
        }
    }
}

/// Колбэки жестов строки; точки — в координатах окна.
struct RowGestureHandlers {
    var selectionMode: Bool
    /// Видимая часть ленты (между шапкой и полем ввода) в координатах окна.
    var feedArea: CGRect = .infinite
    /// Нажимаемое внутри пузыря — тап по нему не наш.
    var zones: TapZones? = nil
    var swipeReplyEnabled: Bool
    var onTap: (CGPoint) -> Void
    var onDoubleTap: () -> Void
    /// Долгий тап: где палец и лента (её автопрокрутку ведёт экран чата).
    var onLongPress: (CGPoint, UIScrollView?) -> Void
    /// Протяжка после долгого тапа; nil — отпустили.
    var onDragSelect: (CGPoint?) -> Void
    /// Свайп влево: сдвиг строки (≤ 0); nil — отпустили.
    var onSwipe: (CGFloat?) -> Void
}

struct RowGestures: UIGestureRecognizerRepresentable {
    var handlers: RowGestureHandlers

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var handlers: RowGestureHandlers
        /// Одиночный тап ждёт: вдруг второй.
        var pendingTap: DispatchWorkItem?
        var fired = false

        init(_ handlers: RowGestureHandlers) { self.handlers = handlers }

        // лента и свайп назад распознаются вместе с нами: кто чей — решает классификация
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(handlers) }

    func makeUIGestureRecognizer(context: Context) -> RowGestureRecognizer {
        let g = RowGestureRecognizer()
        g.delegate = context.coordinator
        g.cancelsTouchesInView = false
        let coordinator = context.coordinator
        g.accepts = { [weak coordinator] p in coordinator?.handlers.feedArea.contains(p) ?? true }
        g.onDown = { [weak coordinator] in
            guard let c = coordinator, let pending = c.pendingTap, !c.handlers.selectionMode else { return false }
            pending.cancel()
            c.pendingTap = nil
            c.handlers.onDoubleTap()
            return true
        }
        return g
    }

    func updateUIGestureRecognizer(_ recognizer: RowGestureRecognizer, context: Context) {
        context.coordinator.handlers = handlers
    }

    func handleUIGestureRecognizerAction(_ g: RowGestureRecognizer, context: Context) {
        let c = context.coordinator
        let h = c.handlers
        let point = context.converter.location(in: .global)
        switch g.kind {
        case .tap where g.state == .ended:
            if !h.selectionMode, h.zones?.contains(point) == true { return }
            if h.selectionMode {
                h.onTap(point)
                return
            }
            let wait = doubleTapWindow - (ProcessInfo.processInfo.systemUptime - g.downTime)
            guard wait > 0 else {
                h.onTap(point)
                return
            }
            let item = DispatchWorkItem { [weak c] in
                c?.pendingTap = nil
                h.onTap(point)
            }
            c.pendingTap = item
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
        case .long:
            switch g.state {
            case .began:
                // лента больше не листается пальцем — касание целиком наше
                g.freezeScrolling()
                h.onLongPress(point, g.enclosingScrollView)
            case .changed: h.onDragSelect(point)
            default: h.onDragSelect(nil)
            }
        case .swipe:
            switch g.state {
            case .began:
                g.freezeScrolling()
                c.fired = false
            case .changed:
                guard h.swipeReplyEnabled else { return }
                let local = g.location(in: g.view)
                let dx = local.x - g.downLocation.x
                h.onSwipe(min(0, dx))
            default:
                h.onSwipe(nil)
            }
        default: break
        }
    }
}

// MARK: - касание целиком (кнопка записи)

/// Касание от нажатия до отпускания: .began сразу при нажатии, .changed при движении, .ended / .cancelled.
/// Ничем не перехватывается (awaitFirstDown + цикл событий на Android).
final class TouchTrackRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, touches.count == 1 else { return }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .cancelled }
    }

    /// Касание не уступаем никому (свайп назад, лента).
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { false }
}

enum TouchPhase { case down, move, up }

/// Касание с точкой в координатах окна.
struct TouchTrack: UIGestureRecognizerRepresentable {
    let onTouch: (TouchPhase, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> TouchTrackRecognizer {
        let g = TouchTrackRecognizer()
        g.cancelsTouchesInView = true
        return g
    }

    func handleUIGestureRecognizerAction(_ g: TouchTrackRecognizer, context: Context) {
        let point = context.converter.location(in: .global)
        switch g.state {
        case .began: onTouch(.down, point)
        case .changed: onTouch(.move, point)
        case .ended, .cancelled, .failed: onTouch(.up, point)
        default: break
        }
    }
}

// MARK: - нажимаемое внутри пузыря

/// Рамки нажимаемых элементов внутри пузырей (фото, файл, плеер, цитата, стикер) в координатах окна:
/// тап по ним забирает сам элемент, меню строки не открывается (на Android — касание, уже съеденное
/// вложенным clickable, классифицируется как отмена).
final class TapZones {
    fileprivate var frames: [UUID: CGRect] = [:]

    func contains(_ point: CGPoint) -> Bool { frames.values.contains { $0.contains(point) } }
}

private struct TapZonesKey: EnvironmentKey {
    static let defaultValue: TapZones? = nil
}

extension EnvironmentValues {
    var tapZones: TapZones? {
        get { self[TapZonesKey.self] }
        set { self[TapZonesKey.self] = newValue }
    }
}

private struct TapZoneModifier: ViewModifier {
    @Environment(\.tapZones) private var zones
    let enabled: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { zones?.frames[id] = enabled ? $0 : nil }
            .onChange(of: enabled) { _, on in if !on { zones?.frames[id] = nil } }
            .onDisappear { zones?.frames[id] = nil }
    }
}

extension View {
    /// Элемент внутри пузыря, который сам обрабатывает нажатие (enabled: false — сейчас не нажимается).
    func tapZone(_ enabled: Bool = true) -> some View { modifier(TapZoneModifier(enabled: enabled)) }
}

// MARK: - нажатие и долгое нажатие (сетка стикеров)

/// Тап и долгое нажатие с протяжкой (StickerGrid на Android: detectTapGestures + долгое с переключением):
/// тап — сразу при отпускании; держат 400 мс — превью, палец ведёт по соседним, отпустили — превью уходит.
/// Сдвиг до 400 мс — листание сетки или паков, не наше.
struct PressGestures: UIGestureRecognizerRepresentable {
    var onTap: () -> Void
    /// Долгое нажатие и протяжка: где палец (окно); nil — отпустили.
    var onLong: (CGPoint?) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PressGestures
        init(_ parent: PressGestures) { self.parent = parent }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(self) }

    func makeUIGestureRecognizer(context: Context) -> RowGestureRecognizer {
        let g = RowGestureRecognizer()
        g.swipeEnabled = false
        g.delegate = context.coordinator
        g.cancelsTouchesInView = false
        return g
    }

    func updateUIGestureRecognizer(_ recognizer: RowGestureRecognizer, context: Context) { context.coordinator.parent = self }

    func handleUIGestureRecognizerAction(_ g: RowGestureRecognizer, context: Context) {
        let p = context.coordinator.parent
        switch (g.kind, g.state) {
        case (.tap, .ended): p.onTap()
        case (.long, .began):
            // ни сетка, ни паки, ни лента больше не листаются пальцем — касание целиком наше
            g.freezeScrolling()
            p.onLong(context.converter.location(in: .global))
        case (.long, .changed): p.onLong(context.converter.location(in: .global))
        case (.long, _): p.onLong(nil)
        default: break
        }
    }
}

// MARK: - нажатие рядом с системным полем ввода

/// Прозрачная UIKit-цель нажатия поверх кнопки. Нужна там, где рядом системное поле ввода: его
/// UIKit-вью ловит касания шире, чем видно, и забирает их у нарисованной SwiftUI кнопки; настоящий
/// UIControl слоем выше получает касание первым.
struct UIKitTapTarget: UIViewRepresentable {
    let action: () -> Void

    final class Target: UIControl {
        var action: (() -> Void)?
        @objc func fire() { action?() }
    }

    func makeUIView(context: Context) -> Target {
        let v = Target()
        v.backgroundColor = .clear
        v.addTarget(v, action: #selector(Target.fire), for: .touchUpInside)
        return v
    }

    func updateUIView(_ v: Target, context: Context) { v.action = action }
}

// MARK: - наблюдатель сдвига (кнопки)

/// Только смотрит, сдвинулся ли палец дальше 10 pt (touch slop): ничего не распознаёт и никому не мешает —
/// ни прокрутке, ни самой кнопке. Кнопка по нему отличает нажатие от свайпа.
final class MoveWatcherRecognizer: UIGestureRecognizer {
    var onMoved: ((Bool) -> Void)?
    private var start: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        start = t.location(in: view?.window)
        onMoved?(false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        let p = t.location(in: view?.window)
        if hypot(p.x - start.x, p.y - start.y) > 10 { onMoved?(true) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
}

struct MoveWatcher: UIGestureRecognizerRepresentable {
    let onMoved: (Bool) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onMoved: (Bool) -> Void
        init(_ onMoved: @escaping (Bool) -> Void) { self.onMoved = onMoved }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(onMoved) }

    func makeUIGestureRecognizer(context: Context) -> MoveWatcherRecognizer {
        let g = MoveWatcherRecognizer()
        g.delegate = context.coordinator
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        let c = context.coordinator
        g.onMoved = { [weak c] in c?.onMoved($0) }
        return g
    }

    func updateUIGestureRecognizer(_ recognizer: MoveWatcherRecognizer, context: Context) { context.coordinator.onMoved = onMoved }

    func handleUIGestureRecognizerAction(_ g: MoveWatcherRecognizer, context: Context) {}
}

// MARK: - потянуть шторку за прокрутку

/// Прокрутка внутри шторки, дошедшая до верха, тянет шторку вниз (вложенная прокрутка
/// ModalBottomSheet на Android): палец вниз у верхнего края — двигается вся шторка, а не содержимое.
/// Ставится фоном содержимого прокрутки; свой распознаватель вешает на сам UIScrollView.
struct ScrollPullsSheet: UIViewRepresentable {
    let pull: SheetPullAction?

    final class Anchor: UIView, UIGestureRecognizerDelegate {
        var pull: SheetPullAction?
        private weak var scroll: UIScrollView?
        private let pan = UIPanGestureRecognizer()
        private var engagedAt: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, scroll == nil else { return }
            var v = superview
            while let current = v, !(current is UIScrollView) { v = current.superview }
            guard let sv = v as? UIScrollView else { return }
            scroll = sv
            pan.addTarget(self, action: #selector(handle(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            sv.addGestureRecognizer(pan)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        private var atTop: Bool {
            guard let sv = scroll else { return false }
            return sv.contentOffset.y <= -sv.adjustedContentInset.top + 0.5
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            guard let sv = scroll, let pull else { return }
            let t = g.translation(in: sv.superview).y
            switch g.state {
            case .began, .changed:
                if engagedAt == nil, t > 0, atTop { engagedAt = t }
                guard let start = engagedAt else { return }
                // содержимое стоит у верха, едет шторка
                sv.contentOffset.y = -sv.adjustedContentInset.top
                pull.changed(max(0, t - start))
            default:
                if engagedAt != nil { pull.end(g.velocity(in: sv.superview).y) }
                engagedAt = nil
            }
        }
    }

    func makeUIView(context: Context) -> Anchor {
        let v = Anchor()
        v.isUserInteractionEnabled = false
        v.pull = pull
        return v
    }

    func updateUIView(_ v: Anchor, context: Context) { v.pull = pull }
}
