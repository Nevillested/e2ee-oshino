import '../l10n/app_strings.dart';

/// Строка статуса собеседника — показывается по центру под его логином в
/// шапке чата (см. chat_screen.dart). Ровно 3 варианта, по приоритету:
/// печатает прямо сейчас > онлайн и не печатает > офлайн (тогда — когда был
/// последний раз, с разной степенью подробности в зависимости от давности).
String formatPresenceStatus({
  required bool typing,
  required bool? online,
  required int? lastSeenMs,
}) {
  if (typing) return tr('presence.typing');
  if (online == true) return tr('presence.online');
  if (lastSeenMs == null || lastSeenMs == 0) return '';
  return _formatLastSeen(lastSeenMs);
}

String _formatLastSeen(int timestampMs) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final now = DateTime.now();
  final isToday =
      date.year == now.year && date.month == now.month && date.day == now.day;
  final hh = date.hour.toString().padLeft(2, '0');
  final mm = date.minute.toString().padLeft(2, '0');

  if (isToday) {
    final diff = now.difference(date);
    if (diff.inHours < 1) {
      if (diff.inMinutes < 1) return tr('presence.justNow');
      return '${diff.inMinutes} ${tr('presence.minutesAgoSuffix')}';
    }
    return '$hh:$mm';
  }

  final dd = date.day.toString().padLeft(2, '0');
  // ignore: non_constant_identifier_names
  final MM = date.month.toString().padLeft(2, '0');
  return '$dd.$MM.${date.year} $hh:$mm';
}
