package com.oshinobu.core.format

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.util.Locale

// Подписи времени, присутствия и размеров — как во Flutter-клиенте
// (utils/time_format.dart, presence_format.dart, file_size_format.dart).
// Перевод — через [tr] (ключи локализации), часы и пояс подменяемы для тестов.

private fun two(n: Int) = n.toString().padStart(2, '0')

private fun at(ms: Long, zone: ZoneId): ZonedDateTime = Instant.ofEpochMilli(ms).atZone(zone)

/** Время в списке чатов и в пузыре: сегодня — "HH:mm", иначе — "dd.MM". */
fun formatChatTime(timestampMs: Long, nowMs: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String {
    if (timestampMs == 0L) return ""
    val date = at(timestampMs, zone)
    return if (date.toLocalDate() == at(nowMs, zone).toLocalDate()) {
        "${two(date.hour)}:${two(date.minute)}"
    } else {
        "${two(date.dayOfMonth)}.${two(date.monthValue)}"
    }
}

/** Строка под именем собеседника: "печатает…", "в сети", "был(а) …" или пусто. */
fun formatPresence(
    typing: Boolean,
    online: Boolean?,
    lastSeenMs: Long?,
    tr: (String) -> String,
    nowMs: Long = System.currentTimeMillis(),
    zone: ZoneId = ZoneId.systemDefault(),
): String {
    if (typing) return tr("presence.typing")
    if (online == true) return tr("presence.online")
    if (lastSeenMs == null || lastSeenMs == 0L) return ""
    val date = at(lastSeenMs, zone)
    val now = at(nowMs, zone)
    val time = "${two(date.hour)}:${two(date.minute)}"
    return when (ChronoUnit.DAYS.between(date.toLocalDate(), now.toLocalDate())) {
        0L -> {
            val ago = Duration.between(date, now)
            when {
                ago.toMinutes() < 1 -> tr("presence.justNow")
                ago.toHours() < 1 -> "${ago.toMinutes()} ${tr("presence.minutesAgoSuffix")}"
                else -> time
            }
        }
        1L -> "${tr("presence.yesterdayAt")} $time"
        else -> "${two(date.dayOfMonth)}.${two(date.monthValue)}.${date.year} $time"
    }
}

/** Размер файла: байты, КБ/МБ с одним знаком, ГБ с двумя (разделитель — точка, как во Flutter). */
fun formatFileSize(bytes: Long, tr: (String) -> String): String = when {
    bytes < 1024 -> "$bytes ${tr("unit.bytes")}"
    bytes < 1024L * 1024 -> "${String.format(Locale.ROOT, "%.1f", bytes / 1024.0)} ${tr("unit.kb")}"
    bytes < 1024L * 1024 * 1024 -> "${String.format(Locale.ROOT, "%.1f", bytes / (1024.0 * 1024))} ${tr("unit.mb")}"
    else -> "${String.format(Locale.ROOT, "%.2f", bytes / (1024.0 * 1024 * 1024))} ${tr("unit.gb")}"
}
