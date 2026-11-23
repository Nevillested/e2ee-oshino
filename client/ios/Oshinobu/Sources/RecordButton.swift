import OshinobuCore
import SwiftUI

// Запись голосового и видеосообщения — как у Android (ui/chat/Recording.kt).
// Удержание кнопки — запись; вверх — фиксация (можно отпустить); влево — отмена.
// Нажатие — переключить голос/видео (в зафиксированной записи — отправить).

enum RecKind { case voice, video }
enum RecPhase { case idle, dragging, locked }

/// Видео-кружок длиннее не пишется — отправляется сам.
private let maxVideoNoteSeconds: TimeInterval = 5 * 60
/// Вверх на столько — фиксация.
private let lockDistance: CGFloat = 70

@MainActor
final class ChatRecorder: ObservableObject {
    /// Что пишет кнопка в покое: голос или видео (нажатие переключает).
    @Published var cameraSelected = false
    @Published private(set) var phase = RecPhase.idle
    @Published private(set) var kind: RecKind?
    @Published private(set) var elapsed: TimeInterval = 0
    /// Сдвиг пальца от точки нажатия.
    @Published private(set) var drag: CGSize = .zero

    let voice = VoiceRecorder()
    let video = VideoNoteRecorder()
    private var ticker: Task<Void, Never>?
    private var pointerDown = false
    private var dir: URL?
    var onRecorded: ((URL, Int64, Bool) -> Void)?

    var recording: Bool { phase != .idle }

    func onPointer(_ down: Bool) { pointerDown = down }

    /// Начать запись (палец удерживает кнопку).
    func begin(dir: URL) {
        guard phase == .idle else { return }
        self.dir = dir
        let isVideo = cameraSelected
        Task { [weak self] in
            guard let self else { return }
            let ok: Bool
            if isVideo {
                ok = await video.prepare()
                if ok { video.start(dir: dir) }
            } else {
                ok = await voice.start(dir: dir)
            }
            guard ok else { return }
            if !pointerDown {
                // отпустили раньше, чем запись успела начаться
                discard(isVideo ? .video : .voice)
                return
            }
            kind = isVideo ? .video : .voice
            phase = .dragging
            drag = .zero
            elapsed = 0
            let started = Date()
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self else { return }
                    self.elapsed = Date().timeIntervalSince(started)
                    if self.kind == .video && self.elapsed >= maxVideoNoteSeconds {
                        self.finish(send: true)
                        return
                    }
                }
            }
        }
    }

    /// Палец сдвинулся: влево за половину экрана — отмена, вверх на 70 — фиксация. Возвращает, что произошло.
    func onDrag(_ offset: CGSize) -> RecPhase? {
        guard phase == .dragging else { return nil }
        drag = offset
        if offset.width < -UIScreen.main.bounds.width * 0.5 {
            finish(send: false)
            return .idle
        }
        if offset.height < -lockDistance {
            phase = .locked
            return .locked
        }
        return nil
    }

    /// Палец отпущен: без фиксации — отправить.
    func onRelease() {
        if phase == .dragging { finish(send: true) }
    }

    func finish(send: Bool) {
        guard phase != .idle, let k = kind else { return }
        ticker?.cancel()
        phase = .idle
        kind = nil
        elapsed = 0
        drag = .zero
        if !send {
            discard(k)
            return
        }
        switch k {
        case .voice:
            if case let (url, ms)? = voice.stop(cancel: false) { onRecorded?(url, ms, false) }
        case .video:
            video.stop(cancel: false) { [weak self] url, ms in
                self?.video.shutdown()
                if let url { self?.onRecorded?(url, ms, true) }
            }
        }
    }

    /// Смена камеры прямо во время записи (запись не прерывается).
    func flipCamera() { video.flipCamera() }

    func release() {
        if let k = kind { discard(k) }
        ticker?.cancel()
        phase = .idle
        kind = nil
    }

    private func discard(_ k: RecKind) {
        switch k {
        case .voice: _ = voice.stop(cancel: true)
        case .video: video.stop(cancel: true) { [weak self] _, _ in self?.video.shutdown() }
        }
    }
}

/// Кнопка записи 40×40: нажатие — переключить голос/видео (в фиксации — отправить), удержание — запись.
/// Касание ведёт UIKit-распознаватель: нажатие видно сразу, жест не перехватывает ни лента, ни свайп назад.
struct RecordButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: ChatRecorder
    @State private var holdTask: Task<Void, Never>?
    @State private var holding = false
    @State private var start: CGPoint = .zero

    var body: some View {
        ZStack {
            icon
            // касание — на неизменном слое: смена иконки (серый микрофон → красный) пересоздавала бы
            // распознаватель, и он посреди удержания сообщал «отпустили»
            Color.clear
                .contentShape(Circle())
                .accessibilityIdentifier("recordButton")
                .gesture(TouchTrack { phase, point in
                switch phase {
                case .down:
                    start = point
                    pressed()
                case .move:
                    guard holding else { return }
                    switch recorder.onDrag(CGSize(width: point.x - start.x, height: point.y - start.y)) {
                    case .idle, .locked: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    default: break
                    }
                case .up: released()
                }
            })
        }
        .frame(width: 40, height: 40)
    }
    @ViewBuilder private var icon: some View {
        switch recorder.phase {
        case .locked: MIcon(.send, tint: model.theme.primary)
        case .dragging: MIcon(recorder.kind == .video ? .videocam : .mic, tint: Color(hex: 0xFF5252))
        case .idle:
            MIcon(recorder.cameraSelected ? .cameraAlt : .mic, tint: model.theme.textMuted)
                .id(recorder.cameraSelected)
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
        }
    }

    private func pressed() {
        recorder.onPointer(true)
        holding = false
        holdTask = Task {
            // долгое нажатие (как longPressTimeout на Android); раньше отпустили — это нажатие
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, recorder.phase == .idle else { return }
            let camera = recorder.cameraSelected
            guard RecordPermissions.granted(camera: camera) else {
                // системный запрос — и всё: запись не начинается, жест заканчивается
                recorder.onPointer(false)
                await RecordPermissions.request(camera: camera)
                return
            }
            holding = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            recorder.begin(dir: model.core.dirs.documents.appendingPathComponent("outgoing"))
        }
    }

    private func released() {
        let wasHolding = holding
        holdTask?.cancel()
        holdTask = nil
        holding = false
        recorder.onPointer(false)
        if wasHolding {
            recorder.onRelease()
            return
        }
        switch recorder.phase {
        case .locked: recorder.finish(send: true)
        case .idle:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.2)) { recorder.cameraSelected.toggle() }
        case .dragging: break
        }
    }
}

/// Поле ввода во время записи: мигающая точка, таймер, подсказка отмены (или «отмена» при фиксации).
/// Кнопка записи — та же, что в поле ввода: строка ложится левее неё, и жест удержания не обрывается
/// (SwiftUI обрывает жест, если поверх касания вырастает другая кнопка).
struct RecordingRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: ChatRecorder
    @State private var dim = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: 0xFF5252)).frame(width: 10, height: 10).opacity(dim ? 0.2 : 1)
                    .animation(.linear(duration: 0.6).repeatForever(autoreverses: true), value: dim)
                Text(verbatim: timer).font(.system(size: 16, design: .monospaced)).foregroundStyle(model.theme.textPrimary)
            }
            .padding(.horizontal, 10)
            ZStack {
                if recorder.phase == .locked {
                    Text("chat_cancelRecording").font(.roboto(13)).foregroundStyle(Color(hex: 0xFF5252)).padding(8)
                        .accessibilityIdentifier("cancelRecording")
                        .onTapGesture { recorder.finish(send: false) }
                } else {
                    let progress = min(1, max(0, -recorder.drag.width / (UIScreen.main.bounds.width * 0.5)))
                    let tint = blend(model.theme.textMuted, Color(hex: 0xFF5252), progress)
                    HStack(spacing: 0) {
                        MIcon(.chevronLeft, size: 16, tint: tint)
                        Text("chat_swipeLeftToCancel").font(.roboto(12)).foregroundStyle(tint).lineLimit(1)
                    }
                    .offset(x: -18 * progress)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.theme.surface)
        // касания не доходят до скрытого поля под строкой
        .contentShape(Rectangle())
        .onTapGesture {}
        .onAppear { dim = true }
    }

    private var timer: String {
        let s = Int(recorder.elapsed)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Смешать два цвета (lerp на Android).
func blend(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
    let ca = UIColor(a), cb = UIColor(b)
    var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
    ca.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    cb.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, opacity: a1 + (a2 - a1) * t)
}

/// Замочек над кнопкой записи: тянется и светлеет по мере движения пальца вверх.
struct RecordingLockIndicator: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: ChatRecorder

    var body: some View {
        let progress = min(1, max(0, -recorder.drag.height / lockDistance))
        let tint = blend(model.theme.textMuted, model.theme.primary, progress)
        VStack {
            MIcon(.keyboardArrowUp, size: 18, tint: tint)
            Spacer(minLength: 0)
            MIcon(.oLock, size: 20, tint: tint)
        }
        .padding(.vertical, 8)
        .frame(width: 38, height: 64)
        .background(model.theme.surface, in: RoundedRectangle(cornerRadius: 20))
        .scaleEffect(1 + 0.18 * progress)
        .offset(y: -10 * progress)
    }
}

/// Живое превью камеры во время записи кружка — квадрат во всю ширину над полем ввода, плюс смена камеры.
struct VideoNoteLivePreview: View {
    @ObservedObject var recorder: ChatRecorder

    var body: some View {
        CameraPreview(session: recorder.video.session)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .bottomLeading) {
                if recorder.video.canFlip {
                    MIcon(.cameraswitch, size: 22, tint: .white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.45), in: Circle())
                        .padding(12)
                        .accessibilityIdentifier("flipCamera")
                        .onTapGesture { recorder.flipCamera() }
                }
            }
    }
}
