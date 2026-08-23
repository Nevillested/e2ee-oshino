import 'dart:async';

/// Зеркало серверного AckRegistry (server/internal/api/ack_registry.go) —
/// только теперь для ПОДТВЕРЖДЕНИЯ НАШИХ исходящих сообщений сервером
/// (см. websocket.go: ackSender), а не наоборот. Раньше такого пути не
/// было вообще — клиент отправлял и сразу забывал, полагаясь только на
/// "канал не выдал ошибку". Теперь SendQueueProcessor реально ждёт этот
/// ack, прежде чем считать элемент очереди доставленным.
class SendAckRegistry {
  static final Map<String, Completer<void>> _waiters = {};

  /// Второй вызов wait() для ТОГО ЖЕ deliveryId (в норме не должно
  /// случаться — см. _inFlight в SendQueueProcessor — но это дешёвая
  /// подстраховка) отдаёт ТУ ЖЕ future, а не заводит новый Completer поверх
  /// старого: раньше именно эта перезапись оставляла первого ожидающего
  /// без единственного способа узнать о реальном fulfill() — тот срабатывал
  /// уже для нового (второго) Completer'а, а первый вызывающий просто
  /// молча "висел" до собственного локального таймаута.
  static Future<void> wait(String deliveryId) {
    final existing = _waiters[deliveryId];
    if (existing != null) return existing.future;
    final completer = Completer<void>();
    _waiters[deliveryId] = completer;
    return completer.future;
  }

  static void fulfill(String deliveryId) {
    final completer = _waiters.remove(deliveryId);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  static void cancel(String deliveryId) {
    final completer = _waiters.remove(deliveryId);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('cancelled'));
    }
  }
}
