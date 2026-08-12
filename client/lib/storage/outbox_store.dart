import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Очередь сообщений, которые не удалось отправить сразу (WebSocket был
/// закрыт в момент отправки). Хранится на диске — если приложение
/// закроют до восстановления связи, очередь не потеряется.
class OutboxStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'outbox_queue';

  static Future<List<Map<String, dynamic>>> getAll() async {
    final stored = await _storage.read(key: _key);
    if (stored == null) return [];
    final list = jsonDecode(stored) as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

static Future<void> add(
  String toDeviceId,
  Map<String, dynamic> envelope,
  String messageId, {
  bool silent = false,
}) async {
  final items = await getAll();
  items.add({
    'to_device_id': toDeviceId,
    'envelope': envelope,
    'message_id': messageId,
    'silent': silent,
  });
  await _storage.write(key: _key, value: jsonEncode(items));
}

  static Future<void> clear() async {
    await _storage.write(key: _key, value: jsonEncode(<Map<String, dynamic>>[]));
  }
}