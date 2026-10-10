/// Повторяет [action] до успеха, с экспоненциальной паузой (капнутой на
/// 30с) между попытками — для HTTP-действий вроде сохранения профиля/
/// приватности, где по требованию нужно "либо сервер подтвердил
/// сохранение, либо пробуем снова", а не тихо смириться с одной неудачей.
/// В отличие от SendQueueProcessor (тот — про WebSocket-доставку
/// зашифрованных конвертов с ack по DeliveryId) это отдельный, более
/// простой механизм для обычных REST-запросов.
Future<void> retryUntilSuccess(Future<void> Function() action) async {
  var delay = const Duration(seconds: 1);
  while (true) {
    try {
      await action();
      return;
    } catch (_) {
      await Future.delayed(delay);
      final doubled = delay * 2;
      delay = doubled > const Duration(seconds: 30)
          ? const Duration(seconds: 30)
          : doubled;
    }
  }
}
