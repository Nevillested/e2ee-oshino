import Foundation

// Подписи времени, присутствия и размеров — те же правила, что на Android (core/format).
// Перевод — через tr (ключи локализации вида "presence.typing"), часы и пояс подменяемы для тестов.

private func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

private func calendar(_ zone: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = zone
    return c
}

private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

/// Время в списке чатов и в пузыре: сегодня — "HH:mm", иначе — "dd.MM".
public func formatChatTime(_ timestampMs: Int64, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000), zone: TimeZone = .current) -> String {
    if timestampMs == 0 { return "" }
    let cal = calendar(zone)
    let d = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date(timestampMs))
    if cal.isDate(date(timestampMs), inSameDayAs: date(nowMs)) {
        return "\(two(d.hour!)):\(two(d.minute!))"
    }
    return "\(two(d.day!)).\(two(d.month!))"
}

/// Строка под именем собеседника: "печатает…", "в сети", "был(а) …" или пусто.
public func formatPresence(typing: Bool, online: Bool?, lastSeenMs: Int64?, tr: (String) -> String,
                           nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000), zone: TimeZone = .current) -> String {
    if typing { return tr("presence.typing") }
    if online == true { return tr("presence.online") }
    guard let lastSeenMs, lastSeenMs != 0 else { return "" }
    let cal = calendar(zone)
    let seen = date(lastSeenMs)
    let now = date(nowMs)
    let d = cal.dateComponents([.year, .month, .day, .hour, .minute], from: seen)
    let time = "\(two(d.hour!)):\(two(d.minute!))"
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: seen), to: cal.startOfDay(for: now)).day ?? 0
    switch days {
    case 0:
        let ago = now.timeIntervalSince(seen)
        if ago < 60 { return tr("presence.justNow") }
        if ago < 3600 { return "\(Int(ago / 60)) \(tr("presence.minutesAgoSuffix"))" }
        return time
    case 1:
        return "\(tr("presence.yesterdayAt")) \(time)"
    default:
        return "\(two(d.day!)).\(two(d.month!)).\(d.year!) \(time)"
    }
}

/// Размер файла: байты, КБ/МБ с одним знаком, ГБ с двумя (разделитель — точка).
public func formatFileSize(_ bytes: Int64, tr: (String) -> String) -> String {
    func f(_ v: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), v) }
    if bytes < 1024 { return "\(bytes) \(tr("unit.bytes"))" }
    if bytes < 1024 * 1024 { return "\(f(Double(bytes) / 1024, 1)) \(tr("unit.kb"))" }
    if bytes < 1024 * 1024 * 1024 { return "\(f(Double(bytes) / (1024 * 1024), 1)) \(tr("unit.mb"))" }
    return "\(f(Double(bytes) / (1024 * 1024 * 1024), 2)) \(tr("unit.gb"))"
}

/// Размер папки со всеми вложенными файлами (байты).
func directorySize(_ url: URL) -> Int64 {
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in e {
        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
    }
    return total
}
