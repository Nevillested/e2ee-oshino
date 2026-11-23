import SwiftUI

// Стек экранов с переходами Android-клиента (ui/AppNavigation.kt, SwipeBack.kt, SharedElements.kt).
// Новый экран выезжает справа поверх неподвижного (450 мс, EaseInOut) и при возврате уезжает вправо
// (340 мс); профиль собеседника проявляется с увеличением от 0,8 (350 мс), а экран под ним гаснет,
// увеличиваясь до 1,1, — закрытие наоборот (300 мс); просмотр медиа — проявление (220 мс).
// Каждый переход — прогресс 0…1, на который кривая накладывается при отрисовке. Свайп вправо с любого
// места экрана ведёт прогресс закрытия пальцем, как предиктивный «назад» Compose (переход
// перематывается): отпустили дальше середины или броском вправо (≥ ширины экрана в секунду) —
// закрытие доигрывается, иначе — возврат. Рисуются только два верхних экрана, остальные
// живут невидимыми: под уходящим экраном не просвечивает весь стек.
// Аватар собеседника перелетает из шапки чата на место большого фото профиля и обратно.

/// Как экран появляется и уходит.
enum ScreenTransition {
    case slide, scaleFade, fade

    /// Длительность открытия и закрытия.
    var durations: (open: Double, close: Double) {
        switch self {
        case .slide: (0.45, 0.34)
        case .scaleFade: (0.35, 0.3)
        case .fade: (0.22, 0.22)
        }
    }

    /// Кривая Compose: EaseInOut для выезда, FastOutSlowIn (tween по умолчанию) для остальных.
    func ease(_ x: CGFloat) -> CGFloat {
        switch self {
        case .slide: cubicBezier(x, 0.42, 0, 0.58, 1)
        case .scaleFade, .fade: cubicBezier(x, 0.4, 0, 0.2, 1)
        }
    }
}

/// Значение кубической Безье (p1, p2) с концами (0,0)–(1,1) в точке x: t ищется бисекцией.
func cubicBezier(_ x: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGFloat {
    let x = min(1, max(0, x))
    func bez(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat { 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t }
    var lo: CGFloat = 0, hi: CGFloat = 1
    for _ in 0..<22 {
        let mid = (lo + hi) / 2
        if bez(mid, x1, x2) < x { lo = mid } else { hi = mid }
    }
    return bez((lo + hi) / 2, y1, y2)
}

struct NavEntry<Route: Hashable>: Identifiable {
    let id = UUID()
    let route: Route
}

/// Перелёт аватара для экрана: ключ собеседника и прогресс 0 (в шапке чата) … 1 (в профиле).
private struct AvatarFlight {
    let accountId: String
    var t: CGFloat
}

@MainActor
final class StackNav<Route: Hashable>: ObservableObject {
    @Published private(set) var entries: [NavEntry<Route>] = []
    /// Прогресс перехода экрана: 0 — его нет, 1 — открыт полностью.
    @Published fileprivate var progress: [UUID: CGFloat] = [:]
    /// Экран уходит (закрытие или свайп назад) — кривая закрытия, а не открытия.
    @Published fileprivate var exiting: Set<UUID> = []
    @Published fileprivate var flights: [UUID: AvatarFlight] = [:]
    /// Экран сейчас не отдаёт свайп назад (панель эмодзи, меню, выбор).
    @Published var swipeBlocked = false
    let transition: (Route) -> ScreenTransition
    let sharedAvatar: (Route) -> String?
    /// Экран закрывается свайпом назад (у просмотра медиа горизонталь — листание).
    let swipeBack: (Route) -> Bool

    init(transition: @escaping (Route) -> ScreenTransition = { _ in .slide }, sharedAvatar: @escaping (Route) -> String? = { _ in nil },
         swipeBack: @escaping (Route) -> Bool = { _ in true }) {
        self.transition = transition
        self.sharedAvatar = sharedAvatar
        self.swipeBack = swipeBack
    }

    /// Заменить верхний экран другим: верхний убирается сразу, новый въезжает (popUpTo … inclusive).
    func replaceTop(with route: Route) {
        if let last = entries.last {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                entries.removeLast()
                progress[last.id] = nil
                exiting.remove(last.id)
                flights[last.id] = nil
            }
        }
        push(route)
    }

    /// Верхний экран, который не уходит.
    var top: Route? { entries.last(where: { !exiting.contains($0.id) })?.route }

    func push(_ route: Route) {
        let entry = NavEntry(route: route)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            entries.append(entry)
            progress[entry.id] = 0
            if let acc = sharedAvatar(route) { flights[entry.id] = AvatarFlight(accountId: acc, t: 0) }
        }
        // первый кадр — в начале перехода, дальше — анимация
        DispatchQueue.main.async { [self] in animate(entry.id, to: 1, duration: transition(route).durations.open) }
    }

    func pop() {
        guard let entry = entries.last(where: { !exiting.contains($0.id) }) else { return }
        exiting.insert(entry.id)
        guard flights[entry.id] == nil, let acc = sharedAvatar(entry.route) else {
            animate(entry.id, to: 0, duration: transition(entry.route).durations.close)
            return
        }
        // аватар снова в полёте: сначала встаёт на место фото профиля, со следующего кадра летит назад
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { flights[entry.id] = AvatarFlight(accountId: acc, t: progress[entry.id] ?? 1) }
        DispatchQueue.main.async { [self] in animate(entry.id, to: 0, duration: transition(entry.route).durations.close) }
    }

    func reset(_ routes: [Route]) {
        entries = routes.map { NavEntry(route: $0) }
        progress = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, 1) })
        exiting = []
        flights = [:]
    }

    /// Довести переход экрана до target: 0 — экран убирается из стека, 1 — открыт (уход отменён).
    fileprivate func animate(_ id: UUID, to target: CGFloat, duration: Double) {
        let from = progress[id] ?? 0
        let seconds = max(0.05, duration * abs(target - from))
        var pending = flights[id] == nil ? 1 : 2
        let done = { [self] in
            pending -= 1
            guard pending == 0, progress[id] == target else { return }
            if target == 0 {
                entries.removeAll { $0.id == id }
                progress[id] = nil
                exiting.remove(id)
            } else {
                exiting.remove(id)
            }
            // аватар долетел — на место встают настоящие
            flights[id] = nil
        }
        withAnimation(.linear(duration: seconds)) { progress[id] = target } completion: { done() }
        if flights[id] != nil {
            // общий элемент Compose — пружина StiffnessMediumLow без отскока
            withAnimation(.interpolatingSpring(stiffness: 400, damping: 40)) { flights[id]?.t = target } completion: { done() }
        }
    }

    /// Свайп назад: экран следует за пальцем (fraction — доля ширины), переход перематывается.
    fileprivate func seekBack(_ id: UUID, fraction: CGFloat) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let p = 1 - min(1, max(0, fraction))
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            exiting.insert(id)
            progress[id] = p
            if let acc = sharedAvatar(entry.route) { flights[id] = AvatarFlight(accountId: acc, t: p) }
        }
    }

    /// Палец отпущен: закрытие доигрывается или экран возвращается — по кривой закрытия.
    fileprivate func finishSwipe(_ id: UUID, close: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        animate(id, to: close ? 0 : 1, duration: transition(entry.route).durations.close)
    }
}

private struct NavBackKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// «Назад» для экрана в стеке (стрелка в шапке).
    var navBack: @MainActor () -> Void {
        get { self[NavBackKey.self] }
        set { self[NavBackKey.self] = newValue }
    }
}

/// Аватары, которые перелетают между экранами: где лежит каждый (в координатах экрана, без
/// анимаций перехода) и чем нарисован.
@MainActor
final class SharedAvatars: ObservableObject {
    enum Role { case source, target }
    @Published fileprivate(set) var frames: [String: CGRect] = [:]
    @Published fileprivate(set) var flying: Set<String> = []
    fileprivate(set) var data: [String: Data] = [:]

    fileprivate func key(_ accountId: String, _ role: Role) -> String { "\(role == .source ? "s" : "t"):\(accountId)" }

    fileprivate func report(_ accountId: String, _ role: Role, _ frame: CGRect) {
        let k = key(accountId, role)
        if frames[k] != frame { frames[k] = frame }
    }
}

/// Пространство координат экрана в стеке (до сдвигов и масштабов перехода).
let navScreenSpace = "navScreen"

/// Аватар собеседника, который перелетает между шапкой чата (source) и профилем (target).
struct SharedPeerAvatar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var shared: SharedAvatars
    let accountId: String?
    let size: CGFloat
    let role: SharedAvatars.Role
    @State private var data: Data?

    var body: some View {
        AvatarImage(data: data, size: size)
            .opacity(accountId.map { shared.flying.contains($0) } == true ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(navScreenSpace)) } action: { frame in
                if let accountId, !accountId.isEmpty { shared.report(accountId, role, frame) }
            }
            .task(id: accountId) {
                guard let accountId, !accountId.isEmpty else { return }
                data = await model.core.avatars.get(accountId)
                shared.data[accountId] = data
                for await changed in model.core.avatars.changes.stream() where changed == accountId {
                    data = await model.core.avatars.get(accountId)
                    shared.data[accountId] = data
                }
            }
    }
}

struct NavHost<Route: Hashable, Root: View, Screen: View>: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var nav: StackNav<Route>
    @ViewBuilder var root: () -> Root
    @ViewBuilder var screen: (Route) -> Screen
    @StateObject private var shared = SharedAvatars()
    @State private var exclusions = SwipeBackExclusions()
    @State private var swipeId: UUID?
    @State private var swipeDecided = false

    var body: some View {
        GeometryReader { g in
            let entries = nav.entries
            let count = entries.count
            ZStack {
                model.theme.background.ignoresSafeArea()
                root()
                    .safeAreaPadding(windowInsets)
                    .coordinateSpace(name: navScreenSpace)
                    .modifier(motion(index: -1, entries: entries, width: g.size.width))
                    .allowsHitTesting(nav.top == nil)
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    let isTop = i == count - 1
                    screen(entry.route)
                        .safeAreaPadding(windowInsets)
                        .coordinateSpace(name: navScreenSpace)
                        .environment(\.navBack) { nav.pop() }
                        .modifier(motion(index: i, entries: entries, width: g.size.width))
                        // свайп назад тоже помечает экран уходящим — его собственный жест не отключаем
                        .allowsHitTesting(isTop && (!nav.exiting.contains(entry.id) || swipeId == entry.id))
                        .zIndex(Double(i + 1))
                        .simultaneousGesture(isTop && nav.swipeBack(entry.route) ? swipeBack(entry.id, width: g.size.width) : nil)
                }
                ForEach(entries.filter { nav.flights[$0.id] != nil }, id: \.id) { entry in
                    if let f = nav.flights[entry.id] { flyingAvatar(f) }
                }
                .zIndex(Double(count + 1))
            }
            .onChange(of: nav.flights.values.map(\.accountId)) { _, ids in shared.flying = Set(ids) }
        }
        // экраны — во весь экран, а отступы окна (строка состояния, жестовая полоса) им возвращаются
        // как безопасная зона: каждый сам решает, заходить ли под них (поле ввода чата — до самого низа).
        // Под клавиатуру система экраны не ужимает: место под ней раскладывают сами экраны
        // (чат — панелью высотой с клавиатуру, формы — отступом прокрутки), как adjustNothing + insets.
        .ignoresSafeArea()
        .environmentObject(shared)
        .environment(\.swipeBackExclusions, exclusions)
    }

    private var windowInsets: EdgeInsets {
        let i = windowSafeArea
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    /// Движение экрана index (-1 — корень): верхний — по своему переходу, под ним — по переходу
    /// верхнего (гаснет под профилем), ниже — не рисуется.
    private func motion(index: Int, entries: [NavEntry<Route>], width: CGFloat) -> ScreenMotion {
        let count = entries.count
        // стек пуст — корень просто виден
        if count == 0 { return ScreenMotion(p: 1, exiting: false, kind: .slide, role: .under, width: width) }
        if index == count - 1 {
            let e = entries[index]
            return ScreenMotion(p: nav.progress[e.id] ?? 0, exiting: nav.exiting.contains(e.id), kind: nav.transition(e.route), role: .moving, width: width)
        }
        if index == count - 2 {
            let above = entries[count - 1]
            return ScreenMotion(p: nav.progress[above.id] ?? 0, exiting: nav.exiting.contains(above.id), kind: nav.transition(above.route), role: .under, width: width)
        }
        return ScreenMotion(p: 1, exiting: false, kind: .fade, role: .hidden, width: width)
    }

    @ViewBuilder private func flyingAvatar(_ f: AvatarFlight) -> some View {
        if let from = shared.frames[shared.key(f.accountId, .source)], let to = shared.frames[shared.key(f.accountId, .target)] {
            FlyingAvatar(t: f.t, from: from, to: to, data: shared.data[f.accountId])
        }
    }

    /// Свайп вправо, начатый горизонтально, — назад; вертикальный жест и свайп влево (ответ) — не наш.
    private func swipeBack(_ id: UUID, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                // свайп по горизонтальному ряду (темы, паки, панель эмодзи) — его листание, не «назад»
                if !swipeDecided, exclusions.contains(v.startLocation) {
                    swipeDecided = true
                    return
                }
                // экран занял палец (превью стикера, протяжка выбора) — свайп назад не наш; начатый — отменяем
                if nav.swipeBlocked {
                    if swipeId == id {
                        swipeId = nil
                        nav.finishSwipe(id, close: false)
                    }
                    swipeDecided = true
                    return
                }
                if !swipeDecided {
                    swipeDecided = true
                    let dx = v.translation.width, dy = v.translation.height
                    if dx > 0 && dx > abs(dy) {
                        swipeId = id
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                if swipeId == id { nav.seekBack(id, fraction: max(0, v.translation.width) / max(1, width)) }
            }
            .onEnded { v in
                swipeDecided = false
                guard swipeId == id else { return }
                swipeId = nil
                let fraction = max(0, v.translation.width) / max(1, width)
                let velocity = v.velocity.width / max(1, width)
                let close = abs(velocity) >= 1 ? velocity > 0 : fraction > 0.5
                nav.finishSwipe(id, close: close)
            }
    }
}

/// Сдвиг, прозрачность и масштаб экрана по прогрессу перехода (кривая — при отрисовке, как при
/// перемотке перехода в Compose).
private struct ScreenMotion: ViewModifier, Animatable {
    enum Role { case moving, under, hidden }
    var p: CGFloat
    let exiting: Bool
    let kind: ScreenTransition
    let role: Role
    let width: CGFloat

    var animatableData: CGFloat {
        get { p }
        set { p = newValue }
    }

    func body(content: Content) -> some View {
        // k — насколько экран (верхний) открыт по кривой: при уходе кривая идёт от начала закрытия
        let k = exiting ? 1 - kind.ease(1 - p) : kind.ease(p)
        var opacity: CGFloat = 1, scale: CGFloat = 1, dx: CGFloat = 0
        switch role {
        case .hidden: opacity = 0
        case .moving:
            switch kind {
            case .slide: dx = (1 - k) * width
            case .scaleFade: opacity = k; scale = 0.8 + 0.2 * k
            case .fade: opacity = k
            }
        case .under:
            if kind == .scaleFade { opacity = 1 - k; scale = 1 + 0.1 * k }
        }
        return content
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(x: dx)
    }
}

/// Аватар в полёте между шапкой чата и профилем.
private struct FlyingAvatar: View, Animatable {
    var t: CGFloat
    let from: CGRect
    let to: CGRect
    let data: Data?

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    var body: some View {
        let x = from.midX + (to.midX - from.midX) * t
        let y = from.midY + (to.midY - from.midY) * t
        let side = from.width + (to.width - from.width) * t
        AvatarImage(data: data, size: max(1, side))
            .position(x: x, y: y)
            .allowsHitTesting(false)
    }
}

/// Раскрытие кругом из центра (главный экран после заставки, 600 мс): fraction 0…1 — до полного покрытия.
struct CircleReveal: Shape {
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // раскрылось — ничего не режем: маска остаётся на экране, а его рамка меняется (клавиатура),
        // и круг по новой рамке срезал бы углы
        if fraction >= 1 { return Path(rect.insetBy(dx: -10_000, dy: -10_000)) }
        let r = hypot(rect.width, rect.height) / 2 * fraction
        return Path(ellipseIn: CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2))
    }
}

/// Где свайп назад не начинается: горизонтальные ряды, которые листаются сами (на Android они
/// забирают свой свайп раньше общего «назад»).
final class SwipeBackExclusions {
    fileprivate var frames: [UUID: CGRect] = [:]
    func contains(_ p: CGPoint) -> Bool { frames.values.contains { $0.contains(p) } }
}

private struct SwipeBackExclusionsKey: EnvironmentKey {
    static let defaultValue: SwipeBackExclusions? = nil
}

extension EnvironmentValues {
    var swipeBackExclusions: SwipeBackExclusions? {
        get { self[SwipeBackExclusionsKey.self] }
        set { self[SwipeBackExclusionsKey.self] = newValue }
    }
}

private struct NoSwipeBack: ViewModifier {
    @Environment(\.swipeBackExclusions) private var exclusions
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { exclusions?.frames[id] = $0 }
            .onDisappear { exclusions?.frames[id] = nil }
    }
}

extension View {
    /// Горизонтальный ряд, свайп по которому — его листание, а не «назад».
    func noSwipeBack() -> some View { modifier(NoSwipeBack()) }
}
