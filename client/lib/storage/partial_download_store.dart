import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Недокачанные "хвосты" скачиваемых медиа — зашифрованные байты, которые
/// уже успели долететь до обрыва/переключения на другой файл/выхода из
/// приложения. Хранятся в устойчивой папке (НЕ getTemporaryDirectory —
/// ОС вправе стереть её в любой момент, особенно пока процесс не запущен;
/// тот же вывод, что и у PendingSendStore.persistFile / ChunkedUploadSession),
/// чтобы `MediaDownloadManager` при возврате продолжил закачку с места
/// обрыва через HTTP Range, а не тянул весь файл из Японии заново.
///
/// Ключ — mediaId. Сам файл-хвост и есть всё состояние: его длина = сколько
/// байт уже есть. Полный размер зашифрованного файла менеджер, если не
/// помнит с этой сессии, спрашивает у сервера дешёвым HEAD-запросом.
class PartialDownloadStore {
  static Directory? _dirCache;

  static Future<Directory> _dir() async {
    if (_dirCache != null) return _dirCache!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/partial_downloads');
    await d.create(recursive: true);
    return _dirCache = d;
  }

  static Future<File> fileFor(String mediaId) async {
    final d = await _dir();
    return File('${d.path}/$mediaId.part');
  }

  static Future<int> existingBytes(String mediaId) async {
    final f = await fileFor(mediaId);
    return await f.exists() ? await f.length() : 0;
  }

  /// Насовсем выбросить хвост — после успешной сборки файла ИЛИ когда
  /// пользователь явно нажал ✕ (отказался; см. ТЗ — ✕ = удалить частичное,
  /// в отличие от переключения/выхода, где хвост сохраняется).
  static Future<void> discard(String mediaId) async {
    try {
      final f = await fileFor(mediaId);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Разовая уборка при старте приложения (см. main.dart) — хвосты, к
  /// которым не возвращались дольше [maxAge], пользователю уже вряд ли
  /// нужны, а место занимают.
  static Future<void> pruneStale({
    Duration maxAge = const Duration(days: 7),
  }) async {
    try {
      final d = await _dir();
      final cutoff = DateTime.now().subtract(maxAge);
      await for (final entity in d.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
