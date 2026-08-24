import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Задачи "не удалось даже поставить в SendQueueProcessor" — сбой сети ДО
/// того, как готов зашифрованный конверт (загрузка медиа/голосового на
/// сервер, либо получение prekey-бандла для самой первой сессии с
/// собеседником, см. PendingSendRetrier). В отличие от SendQueueStore, здесь
/// лежит ещё НЕ зашифрованное сообщение (текст) или ссылка на локальный
/// файл — именно этот, самый первый шаг раньше не переживал офлайн вообще:
/// сообщение сразу и навсегда помечалось 'failed', даже когда сеть
/// возвращалась (см. разбор пользовательских логов voice-сообщения).
class PendingSendStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'pending_send_queue';

  static Future<List<Map<String, dynamic>>> getAll() async {
    final stored = await _storage.read(key: _key);
    if (stored == null) return [];
    final list = jsonDecode(stored) as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  static Future<void> _writeAll(List<Map<String, dynamic>> items) async {
    await _storage.write(key: _key, value: jsonEncode(items));
  }

  /// job['id'] — messageId, служит и ключом дедупликации: повторный add с
  /// тем же id просто заменяет старую запись, а не дублирует её.
  static Future<void> add(Map<String, dynamic> job) async {
    final items = await getAll();
    items.removeWhere((item) => item['id'] == job['id']);
    items.add(job);
    await _writeAll(items);
  }

  static Future<void> remove(String id) async {
    final items = await getAll();
    items.removeWhere((item) => item['id'] == id);
    await _writeAll(items);
  }
}
