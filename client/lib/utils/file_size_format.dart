import '../l10n/app_strings.dart';

/// Общий формат размера файла — раньше жил приватным методом в
/// chat_screen.dart, вынесен сюда, чтобы им же мог пользоваться экран
/// настроек (см. "Очистить кэш медиа" — нужно показать, сколько места
/// освободится).
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes ${tr('unit.bytes')}';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} ${tr('unit.kb')}';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} ${tr('unit.mb')}';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} ${tr('unit.gb')}';
}
