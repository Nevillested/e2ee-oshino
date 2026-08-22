import 'dart:async';
import '../storage/chat_store.dart';
import '../storage/send_queue_store.dart';
import 'debug_log.dart';
import 'send_ack_registry.dart';
import 'websocket_service.dart';

/// Единая надёжная очередь ВСЕГО исходящего трафика — см. план (текст,
/// медиа, звонки-как-сообщения, реакции, лёгкие события профиля). Два
/// разных механизма для двух разных требований:
///
/// - "Тяжёлые" операции (загрузка фото/видео/файла/голосового —
///   до того как конверт вообще готов к отправке) сериализуются через
///   [runHeavy] — следующая не начинает загрузку, пока не завершилась
///   (успехом ИЛИ неудачей) предыдущая. Вызывающий код (chat_screen.dart)
///   оборачивает в неё весь свой существующий путь "загрузить → собрать
///   InnerMessage → зашифровать" целиком, ничего в самой крипто-логике
///   не меняя.
/// - Готовый ЗАШИФРОВАННЫЙ конверт (и у лёгких, и у тяжёлых сообщений —
///   разницы для этой части уже нет) кладётся в [enqueue] — надёжная,
///   переживающая перезапуск процесса очередь на диске
///   (SendQueueStore), элемент удаляется из неё только по реальному ack
///   от сервера (см. SendAckRegistry/websocket.go:ackSender — раньше
///   такого подтверждения не было вообще, был только "send and forget").
class SendQueueProcessor {
  SendQueueProcessor._();
  static final instance = SendQueueProcessor._();

  bool _started = false;
  Future<void> _heavyChain = Future.value();

  void start() {
    if (_started) return;
    _started = true;
    WebSocketService.instance.statusUpdates.listen((status) {
      if (status == ConnectionStatus.connected) {
        DebugLog.log('SendQueueProcessor sweep triggered by reconnect');
        unawaited(_sweep());
      }
    });
    unawaited(_sweep());
  }

  Future<T> runHeavy<T>(Future<T> Function() op) {
    final result = _heavyChain.then((_) => op());
    // Следующий вызов должен ждать эту попытку целиком — и успех, и
    // неудачу — иначе одна упавшая загрузка навсегда заблокировала бы
    // весь дальнейший "тяжёлый" поток.
    _heavyChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// [onAcked] — вызывается ТОЛЬКО при реальном подтверждении сервером
  /// (см. websocket.go:ackSender), не раньше. Специально НЕ переживает
  /// перезапуск процесса (колбэк — не JSON, в SendQueueStore не пишется)
  /// — если приложение убьют между постановкой в очередь и ack, колбэк
  /// на этот конкретный заход потеряется; для всех текущих применений
  /// (например, read-receipt в chat_screen.dart) это безопасно —
  /// естественный следующий триггер (открытие чата/новое сообщение)
  /// просто попробует снова, идемпотентно.
  Future<void> enqueue({
    required String toDeviceId,
    required Map<String, dynamic> envelope,
    required String deliveryId,
    bool silent = false,
    String? messageId,
    String? peerLogin,
    Future<void> Function()? onAcked,
  }) async {
    await SendQueueStore.add(
      id: deliveryId,
      toDeviceId: toDeviceId,
      envelope: envelope,
      silent: silent,
      messageId: messageId,
      peerLogin: peerLogin,
    );
    unawaited(
      _attempt(
        deliveryId,
        toDeviceId,
        envelope,
        silent,
        messageId,
        peerLogin,
        onAcked,
      ),
    );
  }

  Future<void> _sweep() async {
    final items = await SendQueueStore.getAll();
    DebugLog.log('SendQueueProcessor sweep: ${items.length} item(s) pending');
    for (final item in items) {
      unawaited(
        _attempt(
          item['id'] as String,
          item['to_device_id'] as String,
          (item['envelope'] as Map).cast<String, dynamic>(),
          item['silent'] as bool? ?? false,
          item['message_id'] as String?,
          item['peer_login'] as String?,
        ),
      );
    }
  }

  Future<void> _attempt(
    String id,
    String toDeviceId,
    Map<String, dynamic> envelope,
    bool silent,
    String? messageId,
    String? peerLogin, [
    Future<void> Function()? onAcked,
  ]) async {
    final ackFuture = SendAckRegistry.wait(id);
    try {
      await WebSocketService.instance.sendEnvelope(
        toDeviceId,
        envelope,
        id,
        silent: silent,
      );
    } catch (e) {
      // Не подключены прямо сейчас — не ошибка в смысле "не удалось
      // навсегда", просто ждём следующего sweep() по реконнекту. Элемент
      // остаётся в SendQueueStore как есть.
      SendAckRegistry.cancel(id);
      DebugLog.log('SendQueueProcessor id=$id not sent (offline): $e');
      return;
    }
    try {
      await ackFuture.timeout(const Duration(seconds: 8));
    } catch (e) {
      SendAckRegistry.cancel(id);
      DebugLog.log('SendQueueProcessor id=$id no ack within timeout: $e');
      return;
    }
    await SendQueueStore.remove(id);
    DebugLog.log('SendQueueProcessor id=$id acked, removed from queue');
    if (messageId != null && peerLogin != null) {
      await ChatStore.updateMessageStatus(peerLogin, messageId, 'sent');
    }
    await onAcked?.call();
  }
}
