import Foundation

/**
 * Настройки интерфейса — те же, что на Android (UiSettings, PendingEmailVerification):
 * размер текста, реакция по умолчанию и частота реакций, адрес почты, ждущий кода.
 * Ключи — свои для iOS (формат хранения у платформ разный).
 */
public final class UiSettings: @unchecked Sendable {
    public static let textScaleSteps: [Double] = [0.85, 0.9, 1.0, 1.1, 1.2, 1.3]
    public static let defaultReaction = "👍"
    /// Код из письма можно ввести 25 минут, даже закрыв окно.
    private static let pendingEmailTTLms: Int64 = 25 * 60_000

    private let secure: SecureStore
    private let prefs: Prefs

    public init(secure: SecureStore, prefs: Prefs) {
        self.secure = secure
        self.prefs = prefs
    }

    public var textScale: Double {
        get { prefs.double("ui_text_scale").flatMap { Self.textScaleSteps.contains($0) ? $0 : nil } ?? 1.0 }
        set { prefs.set("ui_text_scale", newValue) }
    }

    public var defaultReaction: String {
        get { secure.read("default_reaction_emoji") ?? Self.defaultReaction }
        set { secure.write("default_reaction_emoji", newValue) }
    }

    /// Частота реакций — для сортировки панели реакций.
    public func reactionUsage() -> [String: Int] {
        guard let raw = secure.read("reaction_usage_counts"), let data = raw.data(using: .utf8),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return counts
    }

    public func recordReactionUse(_ emoji: String) {
        var counts = reactionUsage()
        counts[emoji, default: 0] += 1
        if let data = try? JSONEncoder().encode(counts), let s = String(data: data, encoding: .utf8) { secure.write("reaction_usage_counts", s) }
    }

    /// all в исходном порядке, отсортированные по частоте использования.
    public func sortedReactions(_ all: [String]) -> [String] {
        let counts = reactionUsage()
        return all.enumerated().sorted { a, b in
            let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
    }

    /// Почта, на которую отправлен код подтверждения (nil — нет или код устарел).
    public var pendingEmail: String? {
        guard let email = prefs.string("pending_email"), let at = prefs.long("pending_email_at") else { return nil }
        if Int64(Date().timeIntervalSince1970 * 1000) - at >= Self.pendingEmailTTLms {
            clearPendingEmail()
            return nil
        }
        return email
    }

    public func setPendingEmail(_ email: String) {
        prefs.set("pending_email", email)
        prefs.set("pending_email_at", Int64(Date().timeIntervalSince1970 * 1000))
    }

    public func clearPendingEmail() {
        prefs.remove("pending_email")
        prefs.remove("pending_email_at")
    }
}
