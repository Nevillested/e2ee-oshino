import 'dart:async';

/// Гарантирует, что операции "прочитать состояние Double Ratchet →
/// продвинуть → сохранить" для одного и того же собеседника выполняются
/// строго по одной, без параллелизма. Без этой блокировки несколько
/// одновременных вызовов (быстрые тапы "отправить", либо несколько
/// сообщений, пришедших почти одновременно при выходе в онлайн) могли
/// прочитать ОДНО И ТО ЖЕ состояние сессии независимо друг от друга,
/// продвинуть его порознь и сохранить — затирая работу друг друга.
/// Это была реальная причина потери и разупорядочивания сообщений.
class SendLock {
  static final Map<String, Future<void>> _tail = {};

  static Future<T> run<T>(String key, Future<T> Function() action) async {
    final previous = _tail[key] ?? Future<void>.value();
    final completer = Completer<void>();
    _tail[key] = previous.then((_) => completer.future);

    await previous;
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }
}