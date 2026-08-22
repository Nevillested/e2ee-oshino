import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Единая надёжная очередь ВСЕГО исходящего трафика (текст/медиа/звонки-
/// как-сообщения/реакции/лёгкие события профиля) — замена OutboxStore,
/// который только копил недоставленное при разрыве связи и потом слал
/// одним махом без ожидания подтверждения ("send and forget"). Здесь
/// элемент считается отправленным ТОЛЬКО когда реально пришёл ack от
/// сервера (см. SendAckRegistry/SendQueueProcessor) — до этого момента
/// он остаётся в очереди и переживает перезапуск процесса.
///
/// Хранится уже ЗАШИФРОВАННЫЙ конверт (шифрование — до постановки в
/// очередь, синхронно, через существующий SendLock — здесь это не
/// трогается вообще, очередь отвечает только за надёжную ДОСТАВКУ уже
/// готового конверта).
class SendQueueStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'send_queue';

  static Future<List<Map<String, dynamic>>> getAll() async {
    final stored = await _storage.read(key: _key);
    if (stored == null) return [];
    final list = jsonDecode(stored) as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  static Future<void> _writeAll(List<Map<String, dynamic>> items) async {
    await _storage.write(key: _key, value: jsonEncode(items));
  }

  /// [id] — он же DeliveryId, используется и для ack-подтверждения, и для
  /// удаления элемента из очереди. Порядок "тяжёлые строго по одному,
  /// лёгкие сразу параллельно" обеспечивается РАНЬШЕ, на уровне
  /// SendQueueProcessor.runHeavy() (сериализует саму загрузку файла, до
  /// того как конверт вообще готов) — здесь, на уровне уже готового
  /// зашифрованного конверта, все элементы равноправны, разницы
  /// "лёгкий/тяжёлый" для самой доставки/ретраев уже нет.
  /// [messageId]/[peerLogin] — опционально, только чтобы после ack
  /// проставить статус 'sent' в ChatStore для реального пузыря сообщения
  /// (control-сообщения без своего пузыря их не передают).
  static Future<void> add({
    required String id,
    required String toDeviceId,
    required Map<String, dynamic> envelope,
    bool silent = false,
    String? messageId,
    String? peerLogin,
  }) async {
    final items = await getAll();
    items.add({
      'id': id,
      'to_device_id': toDeviceId,
      'envelope': envelope,
      'silent': silent,
      if (messageId != null) 'message_id': messageId,
      if (peerLogin != null) 'peer_login': peerLogin,
    });
    await _writeAll(items);
  }

  static Future<void> remove(String id) async {
    final items = await getAll();
    items.removeWhere((item) => item['id'] == id);
    await _writeAll(items);
  }
}
