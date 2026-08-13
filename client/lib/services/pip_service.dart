import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Причина выхода из системного PiP — см. подробный комментарий в
/// MainActivity.kt у pendingLauncherReopen: Android не различает "юзер
/// развернул PiP своей кнопкой" и "юзер заново открыл приложение через
/// лаунчер/недавние" на уровне API, поэтому родная сторона сама определяет
/// причину эвристикой и передаёт её сюда.
enum PipExitReason {
  /// Развёрнуто кнопкой внутри самого PiP-окошка — нужно показать
  /// полноэкранный CallScreen.
  expand,

  /// Приложение открыли заново (лаунчер/недавние) — PiP просто пропадает,
  /// пользователь видит обычное приложение, звонок продолжается в фоне.
  reopen,
}

class PipModeEvent {
  final bool isInPip;
  final PipExitReason? exitReason;
  PipModeEvent(this.isInPip, this.exitReason);
}

/// Мост к нативному Picture-in-Picture на Android (MainActivity.kt).
///
/// Flutter сообщает нативной стороне, идёт ли сейчас звонок
/// (`setCallActive`) — только тогда система разрешает автоматический вход
/// в PiP при сворачивании приложения (Android 12+) или мы сами вызываем
/// enterPictureInPictureMode() из onUserLeaveHint (Android 8–11). На более
/// старых версиях/не-Android платформах канал просто недоступен —
/// вызовы тихо игнорируются.
///
/// Нативная сторона уведомляет обратно о смене PiP-режима
/// (`pipModeChanged`), вместе с причиной выхода — см. PipExitReason.
class PipService {
  static const _channel = MethodChannel('oshinobu/pip');

  static final _pipModeController = StreamController<PipModeEvent>.broadcast();
  static Stream<PipModeEvent> get pipModeChanges => _pipModeController.stream;

  /// Сигнал от MainActivity.onNewIntent — пользователь нажал "Ответить" в
  /// уведомлении о звонке, ПОКА приложение уже было живо (не холодный
  /// старт). В этом случае HomePlaceholderScreen не пересоздаётся и не
  /// спросит consumeAutoAccept() заново сама, поэтому нативная сторона
  /// толкает событие явно — CallService слушает его напрямую.
  static final _autoAcceptController = StreamController<void>.broadcast();
  static Stream<void> get autoAcceptRequests => _autoAcceptController.stream;

  /// Сигнал от MainActivity.onNewIntent — тап по САМОМУ уведомлению "Идёт
  /// разговор" (не по кнопке "Завершить звонок"). Уведомление собрано
  /// нативно (см. OngoingCallNotifier в call_ring_plugin), поэтому и тап по
  /// его телу помечается так же, intent-экстрой, а не через
  /// flutter_local_notifications payload.
  static final _openCallScreenController = StreamController<void>.broadcast();
  static Stream<void> get openCallScreenRequests =>
      _openCallScreenController.stream;

  static bool _initialized = false;

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    debugPrint(
      'PipService: устанавливаю обработчик входящих вызовов на канале oshinobu/pip',
    );
    _channel.setMethodCallHandler((call) async {
      debugPrint(
        'PipService: пришёл вызов от нативной стороны: ${call.method}',
      );
      if (call.method == 'pipModeChanged') {
        final args = (call.arguments as Map).cast<String, dynamic>();
        final isInPip = args['isInPip'] as bool? ?? false;
        final reasonStr = args['reason'] as String?;
        final reason = switch (reasonStr) {
          'expand' => PipExitReason.expand,
          'reopen' => PipExitReason.reopen,
          _ => null,
        };
        debugPrint(
          'PipService: pipModeChanged isInPip=$isInPip reason=$reasonStr',
        );
        _pipModeController.add(PipModeEvent(isInPip, reason));
      } else if (call.method == 'autoAcceptRequested') {
        debugPrint(
          'PipService: autoAcceptRequested -> публикую в autoAcceptRequests',
        );
        _autoAcceptController.add(null);
      } else if (call.method == 'openCallScreenRequested') {
        debugPrint(
          'PipService: openCallScreenRequested -> публикую в openCallScreenRequests',
        );
        _openCallScreenController.add(null);
      }
    });
  }

  static Future<void> setCallActive(bool active) async {
    _ensureInitialized();
    try {
      await _channel.invokeMethod('setCallActive', {'active': active});
    } catch (_) {
      // PiP недоступен на этой платформе/версии ОС — не критично.
    }
  }

  /// Сообщает нативной стороне, передаёт ли СОБЕСЕДНИК видео прямо сейчас —
  /// автоматический вход в PiP при сворачивании разрешён только тогда
  /// (иначе в плавающем окошке просто нечего показывать); ручная кнопка
  /// enterPipNow() на это ограничение не смотрит.
  static Future<void> setRemoteVideoActive(bool active) async {
    _ensureInitialized();
    try {
      await _channel.invokeMethod('setRemoteVideoActive', {'active': active});
    } catch (_) {}
  }

  /// Вход в PiP по явному нажатию кнопки на CallScreen — работает всегда,
  /// независимо от того, транслирует ли собеседник видео.
  static Future<void> enterPipNow() async {
    _ensureInitialized();
    try {
      await _channel.invokeMethod('enterPipNow');
    } catch (_) {}
  }

  /// Принудительно закрывает PiP — нужно, когда звонок завершился, ПОКА
  /// приложение было в PiP: иначе плавающее окошко осталось бы висеть с
  /// замороженным последним кадром видео. См. подробности у MainActivity.kt.
  static Future<void> exitPip() async {
    _ensureInitialized();
    try {
      await _channel.invokeMethod('exitPip');
    } catch (_) {}
  }

  /// Снимает флаг "показывать поверх экрана блокировки", который
  /// MainActivity ставит себе при запуске по входящему звонку (см.
  /// CallRingService + MainActivity.applyLockScreenFlagsIfNeeded). Нужно
  /// вызывать явно, когда звонок ДЕЙСТВИТЕЛЬНО завершён — иначе обычное
  /// открытие приложения после звонка продолжило бы обходить блокировку
  /// экрана, что для приватного мессенджера недопустимо.
  static Future<void> clearShowWhenLocked() async {
    _ensureInitialized();
    try {
      await _channel.invokeMethod('clearShowWhenLocked');
    } catch (_) {}
  }

  /// true, если приложение сейчас запущено кнопкой "Ответить" из
  /// уведомления о звонке (см. CallRingService) — тогда ближайший входящий
  /// звонок нужно принять автоматически, не дожидаясь повторного тапа уже
  /// на экране входящего вызова. Однократный флаг — сразу стирается на
  /// нативной стороне, чтобы случайно не принять какой-то другой звонок.
  static Future<bool> consumeAutoAccept() async {
    _ensureInitialized();
    try {
      final result =
          await _channel.invokeMethod<bool>('consumeAutoAccept') ?? false;
      debugPrint('PipService: consumeAutoAccept() -> $result');
      return result;
    } catch (e) {
      debugPrint('PipService: consumeAutoAccept failed: $e');
      return false;
    }
  }
}
