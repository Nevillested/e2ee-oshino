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
  // deliveryId'ы, для которых прямо сейчас уже идёт отправка+ожидание ack —
  // без этого набора _sweep(), вызванный дважды почти одновременно (что
  // регулярно случается: WS.connect() уже видит частично собранную
  // локальную очередь ДО того, как соединение реально готово, а следом
  // статус переключается в connected и слушатель триггерит ещё один sweep
  // на ту же самую, ещё не опустевшую очередь — см. debug_log с
  // пользователя, где оба sweep идут буквально в одном и том же цикле
  // реконнекта), запускал бы ВТОРОЙ параллельный _attempt на тот же id.
  // SendAckRegistry.wait(id) во втором вызове тогда просто затирал бы
  // Completer первого — тот навсегда терял способ узнать про реальный ack
  // (который сервер, получив дублирующее сообщение дважды, тоже пришлёт
  // дважды, но fulfill() при повторном вызове для уже разрешённого id —
  // молчаливый no-op) и стабильно "таймаутил" через 8с, даже когда
  // сообщение было реально доставлено. Итог именно то, на что жаловался
  // пользователь: сообщение "висит" — its onAcked/markMessageStatus('sent')
  // никогда не срабатывали для проигравшей попытки, а read-receipt'ы
  // из-за этого же самого бага так и не помечались отправленными и заново
  // накапливались на каждом следующем реконнекте (см. лавинообразный рост
  // очереди в логе — 27, 30, 32 "зависших" элемента подряд).
  final Set<String> _inFlight = {};

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
    // См. комментарий у _inFlight — не даём двум конкурентным sweep'ам (или
    // sweep'у, наложившемуся на enqueue() того же id) запустить вторую
    // параллельную попытку поверх уже идущей: она бы просто затёрла ack-
    // ожидание первой, и та навсегда "зависла" бы, даже реально получив ack.
    if (_inFlight.contains(id)) {
      DebugLog.log(
        'SendQueueProcessor id=$id already in flight, skipping duplicate attempt',
      );
      return;
    }
    _inFlight.add(id);
    try {
      final ackFuture = SendAckRegistry.wait(id);
      // Предохранитель от "unhandled exception": до этой точки и до того,
      // как ниже (после sendEnvelope) появится настоящий слушатель через
      // ackFuture.timeout(...), сообщение может быть отменено параллельно
      // (см. message_cleanup.dart:purgeMessageArtifacts -> SendAckRegistry.
      // cancel — например, пользователь нажал "Отменить" на ещё
      // отправляющемся сообщении) — тогда completer завершается ошибкой, а у
      // ackFuture в этот момент ещё нет ни одного слушателя: Dart считает
      // это настоящим необработанным исключением. Без дебаггера это просто
      // шум в логе, но под VM-дебаггером с дефолтным "pause on uncaught
      // exceptions" (например, запуск через VSCode) это останавливает ВЕСЬ
      // изолят навсегда — реальный кейс с устройства: приложение зависало
      // намертво (ANR) ровно в моменты реконнекта, когда очередь пыталась
      // отправить, пока канал ещё не был готов. Этот catchError — просто
      // постоянный слушатель "по умолчанию", он не мешает реальному await
      // ниже (у Future может быть несколько независимых слушателей).
      unawaited(ackFuture.catchError((_) {}));
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
        // НЕ вызываем SendAckRegistry.cancel(id) здесь — раньше именно это
        // теряло честно доставленный ack, если сервер отвечал дольше 8с:
        // реальный кейс с устройства — конверт видео-заметки отправлен в
        // 20:45:31, локальный таймаут сработал в 20:45:39 (через 8с), а
        // настоящий ack от сервера пришёл только в 20:46:08 — на 29с позже.
        // cancel() уже успевал стереть ожидание из реестра, и fulfill()
        // для этого id находил уже пустое место — сообщение навсегда
        // зависало на "Saving on server", хотя реально дошло и лежало на
        // сервере. Таймаут здесь означает только "хватит ждать В ЭТОЙ
        // попытке": освобождаем _inFlight, чтобы следующий sweep (по
        // реконнекту) мог попробовать снова — повторная отправка с тем же
        // id безопасна, — но продолжаем слушать тот же ackFuture в фоне на
        // случай, если ack всё же придёт сам, просто с опозданием.
        DebugLog.log(
          'SendQueueProcessor id=$id no ack within timeout: $e — '
          'still listening in background for a late ack',
        );
        unawaited(
          _finalizeOnLateAck(id, ackFuture, messageId, peerLogin, onAcked),
        );
        return;
      }
      await _finalizeAcked(id, messageId, peerLogin, onAcked);
    } finally {
      _inFlight.remove(id);
    }
  }

  /// Довершает попытку, чей ack пришёл ПОСЛЕ того, как _attempt уже сдалась
  /// по локальному 8-секундному таймауту (см. комментарий выше) — слушает
  /// тот же ackFuture без ограничения по времени, поскольку сообщение уже
  /// физически отправлено и единственное, чего не хватает — подтверждения.
  Future<void> _finalizeOnLateAck(
    String id,
    Future<void> ackFuture,
    String? messageId,
    String? peerLogin,
    Future<void> Function()? onAcked,
  ) async {
    try {
      await ackFuture;
    } catch (_) {
      // Отменено по какой-то другой причине (не таймаутом — этот путь его
      // больше не вызывает) — сдаёмся молча.
      return;
    }
    DebugLog.log(
      'SendQueueProcessor id=$id: late ack arrived after local timeout gave up',
    );
    await _finalizeAcked(id, messageId, peerLogin, onAcked);
  }

  Future<void> _finalizeAcked(
    String id,
    String? messageId,
    String? peerLogin,
    Future<void> Function()? onAcked,
  ) async {
    await SendQueueStore.remove(id);
    DebugLog.log('SendQueueProcessor id=$id acked, removed from queue');
    if (messageId != null && peerLogin != null) {
      await ChatStore.updateMessageStatus(peerLogin, messageId, 'sent');
    }
    await onAcked?.call();
  }
}
