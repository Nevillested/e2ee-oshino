import Lottie
import SwiftUI

// Эффекты переписки — как у Android (ui/chat/Effects.kt, ReactionBurst.kt): рассыпание удалённого
// сообщения, схлопывание его места, подсветка после перехода, пульсация совпадения поиска, «взрыв» реакции.

/// Анимация рассыпания — столько же, сколько у Android (DISSOLVE_MS).
let dissolveSeconds: Double = 0.7
/// За сколько схлопывается место удаляемой строки.
private let collapseSeconds: Double = 0.3

/// FastOutSlowInEasing Material.
let fastOutSlowIn = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)

private func fastOutSlowInValue(_ x: CGFloat) -> CGFloat {
    // кубическая Безье (0.4, 0, 0.2, 1): ищем t по x бисекцией
    func bez(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat { 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t }
    var lo: CGFloat = 0, hi: CGFloat = 1
    for _ in 0..<20 {
        let mid = (lo + hi) / 2
        if bez(mid, 0.4, 0.2) < x { lo = mid } else { hi = mid }
    }
    return bez((lo + hi) / 2, 0, 1)
}

/// Осколки пузыря: прямоугольник, когда стартует (0…1) и куда улетает.
private struct Shard {
    let rect: CGRect
    let start: CGFloat
    let dx: CGFloat
    let dy: CGFloat
}

private func shards(for size: CGSize) -> [Shard] {
    // мельче 4 pt не режем, больше 300 осколков — кадры не успевают
    let side = max(4, ceil(sqrt(size.width * size.height / 300)))
    let cols = max(1, Int(ceil(size.width / side))), rows = max(1, Int(ceil(size.height / side)))
    var rng = SeededRandom(seed: UInt64(cols * 7919 + rows))
    var list: [Shard] = []
    list.reserveCapacity(cols * rows)
    for r in 0..<rows {
        for c in 0..<cols {
            let rect = CGRect(x: CGFloat(c) * side, y: CGFloat(r) * side,
                              width: min(side, size.width - CGFloat(c) * side), height: min(side, size.height - CGFloat(r) * side))
            // волна слева направо: правые осколки стартуют позже
            let start = CGFloat(c) / CGFloat(cols) * 0.45 + rng.next() * 0.1
            list.append(Shard(rect: rect, start: start, dx: (rng.next() - 0.3) * 61, dy: -(15 + rng.next() * 53)))
        }
    }
    return list
}

private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

/// Пузырь, который при удалении рассыпается на осколки: содержимое режется на мелкие квадраты, они
/// разлетаются вверх, сжимаясь в точку, — волной слева направо.
struct Dissolvable<Content: View>: View {
    let dissolving: Bool
    @ViewBuilder var content: () -> Content
    @State private var startedAt: Date?
    @State private var size: CGSize = .zero

    var body: some View {
        Group {
            if let startedAt, size != .zero {
                let pieces = shards(for: size)
                TimelineView(.animation) { timeline in
                    let t = min(1, CGFloat(timeline.date.timeIntervalSince(startedAt) / (dissolveSeconds - 0.06)))
                    Canvas { ctx, canvas in
                        guard let symbol = ctx.resolveSymbol(id: 0) else { return }
                        for s in pieces {
                            let local = min(1, max(0, (t - s.start) / (1 - s.start)))
                            if local >= 1 { continue }
                            let eased = fastOutSlowInValue(local)
                            let dx = s.dx * eased, dy = s.dy * eased
                            // осколок сжимается к своему центру — вместо затухания
                            let keep = 1 - local
                            let cx = s.rect.midX + dx, cy = s.rect.midY + dy
                            var c = ctx
                            c.clip(to: Path(CGRect(x: cx - s.rect.width * keep / 2, y: cy - s.rect.height * keep / 2,
                                                   width: s.rect.width * keep, height: s.rect.height * keep)))
                            c.translateBy(x: dx, y: dy)
                            c.draw(symbol, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2))
                        }
                    } symbols: {
                        content().frame(width: size.width, height: size.height).tag(0)
                    }
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            } else {
                content().onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            }
        }
        .onChange(of: dissolving, initial: true) { _, now in if now && startedAt == nil { startedAt = Date() } }
    }
}

/// Место удаляемой строки схлопывается сразу, пока она ещё рассыпается: соседние сообщения съезжают
/// вместе с началом анимации. Нижний край строки неподвижен — осколки летят оттуда, где было сообщение.
struct CollapseLayout: Layout, Animatable {
    var k: CGFloat
    var animatableData: CGFloat {
        get { k }
        set { k = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first?.sizeThatFits(proposal) else { return .zero }
        return CGSize(width: s.width, height: s.height * (1 - k))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        v.place(at: CGPoint(x: bounds.minX, y: bounds.maxY - s.height), proposal: ProposedViewSize(width: bounds.width, height: s.height))
    }
}

extension View {
    /// Строка, место которой схлопывается при удалении.
    func collapseOnDissolve(_ dissolving: Bool) -> some View {
        CollapseLayout(k: dissolving ? 1 : 0) { self }
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: collapseSeconds), value: dissolving)
    }
}

/// Подсветка после перехода к сообщению: разгорается 0,4 с, держится 0,3 с и гаснет 1,5 с (пик 0,35).
struct JumpFlash: View {
    let startedAt: Date?
    let color: Color

    var body: some View {
        if let startedAt {
            TimelineView(.animation) { tl in
                let ms = tl.date.timeIntervalSince(startedAt) * 1000
                RoundedRectangle(cornerRadius: 14).fill(color.opacity(alpha(ms)))
            }
            .allowsHitTesting(false)
        }
    }

    private func alpha(_ t: Double) -> Double {
        let peak = 0.35
        if t < 0 || t >= 2200 { return 0 }
        if t < 400 { return peak * Double(fastOutSlowInValue(CGFloat(t / 400))) }
        if t < 700 { return peak }
        return peak * (1 - Double(fastOutSlowInValue(CGFloat((t - 700) / 1500))))
    }
}

/// Пульсация строки (во всю ширину) — совпадение поиска, на котором стоим: 0,15 ↔ 0,45 за 650 мс (FastOutSlowIn).
struct PulsingHighlight: View {
    let color: Color
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start) / 0.65
            let phase = t.truncatingRemainder(dividingBy: 2)
            let x = CGFloat(phase < 1 ? phase : 2 - phase)
            RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.15 + 0.3 * fastOutSlowInValue(x)))
        }
        .allowsHitTesting(false)
    }
}

/// Анимированные реакции — Noto Animated Emoji (Google, CC BY 4.0), лежат в приложении
/// (Resources/Reactions/<кодовые точки без FE0F>.json): брать их с серверов Google нельзя —
/// Google узнавал бы, кто какую реакцию поставил. Для эмодзи без анимации — только частицы.
private func reactionAnimationName(_ emoji: String) -> String? {
    let key = emoji.unicodeScalars.map(\.value).filter { $0 != 0xFE0F }.map { String($0, radix: 16) }.joined(separator: "_")
    return Bundle.main.url(forResource: key, withExtension: "json") != nil ? key : nil
}

/// Только что поставленная реакция: живое эмодзи поверх бейджа и разлёт его маленьких копий;
/// места в раскладке не занимает. onDone — всё доиграло.
struct ReactionBurst: View {
    let emoji: String
    let onDone: () -> Void
    @State private var particles: CGFloat = 0
    @State private var presence: CGFloat = 0
    @State private var name: String?

    var body: some View {
        ZStack {
            if let name {
                LottieView(animation: .named(name))
                    .playing(loopMode: .playOnce)
                    .animationDidFinish { _ in
                        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26)) { presence = 0 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: onDone)
                    }
                    .resizable()
                    .frame(width: 72, height: 72)
                    // от размера бейджа (~четверть) до полного и обратно
                    .scaleEffect(0.25 + 0.75 * presence)
                    .opacity(min(1, max(0, presence)))
            }
            ForEach(0..<8, id: \.self) { i in
                let angle = 2 * Double.pi * Double(i) / 8
                Text(verbatim: emoji).font(.system(size: 11))
                    .offset(x: cos(angle) * 34 * particles, y: sin(angle) * 34 * particles)
                    .scaleEffect(1 - 0.4 * particles)
                    .opacity(1 - particles)
            }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .onAppear {
            name = reactionAnimationName(emoji)
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.7)) { particles = 1 }
            if name != nil {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.5)) { presence = 1 }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: onDone)
            }
        }
    }
}
