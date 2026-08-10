String formatChatTime(int timestampMs) {
  if (timestampMs == 0) return '';

  final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final now = DateTime.now();
  final isToday = date.year == now.year && date.month == now.month && date.day == now.day;

  if (isToday) {
    final hh = date.hour.toString().padLeft(2, '0');
    final mm = date.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  final dd = date.day.toString().padLeft(2, '0');
  // ignore: non_constant_identifier_names
  final MM = date.month.toString().padLeft(2, '0');
  return '$dd.$MM';
}