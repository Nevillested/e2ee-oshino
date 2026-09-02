import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Персистентные очереди скачивания медиа (ручная + авто) — содержат ключи
/// расшифровки файлов, поэтому FlutterSecureStorage, как и
/// ChunkedUploadSessionStore. Сами недокачанные байты лежат отдельно
/// (PartialDownloadStore, `.part`-файлы); здесь — метаданные заданий, по
/// которым движок на старте приложения знает, ЧТО докачивать и как это
/// расшифровать. Очереди строго FIFO; воркеры берут с начала списка.
class DownloadQueueStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'media_download_queues_v1';

  // Авто-очередь может копиться долго (каждый мелкий файл, что пролистали) —
  // не даём ей разрастаться в secure storage без предела. Отсекаем с конца
  // (эти скачаются позже всех — при необходимости просто попадут заново,
  // когда пользователь снова их пролистает).
  static const _autoCap = 300;

  static Future<
    ({List<Map<String, dynamic>> manual, List<Map<String, dynamic>> auto})
  >
  load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) {
        return (
          manual: <Map<String, dynamic>>[],
          auto: <Map<String, dynamic>>[],
        );
      }
      final j = jsonDecode(raw) as Map<String, dynamic>;
      List<Map<String, dynamic>> list(String k) => ((j[k] as List?) ?? [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      return (manual: list('manual'), auto: list('auto'));
    } catch (_) {
      return (
        manual: <Map<String, dynamic>>[],
        auto: <Map<String, dynamic>>[],
      );
    }
  }

  static Future<void> save(
    List<Map<String, dynamic>> manual,
    List<Map<String, dynamic>> auto,
  ) async {
    try {
      final cappedAuto = auto.length > _autoCap
          ? auto.sublist(0, _autoCap)
          : auto;
      await _storage.write(
        key: _key,
        value: jsonEncode({'manual': manual, 'auto': cappedAuto}),
      );
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}
