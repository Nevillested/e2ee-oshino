import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Мост к нативному Android foreground-service, который "по-настоящему"
/// звонит (зацикленный рингтон + полноэкранный вызов поверх блокировки),
/// когда обычное системное уведомление на это физически не способно —
/// используется по push-у типа "call", пока приложение свёрнуто или
/// полностью закрыто.
///
/// Канал специально зарегистрирован как полноценный Flutter-плагин (не
/// ad-hoc MethodChannel в MainActivity), потому что именно так его
/// подхватывает GeneratedPluginRegistrant в фоновом движке
/// firebase_messaging — том самом, что поднимается при полностью закрытом
/// приложении.
class CallRingPlugin {
  static const _channel = MethodChannel('oshinobu/call_ring');

  /// Событие от нативного EndCallReceiver — пользователь нажал "Завершить
  /// звонок" прямо в уведомлении "Идёт разговор". Уведомление и кнопка
  /// собраны полностью нативно (не через flutter_local_notifications) —
  /// см. подробное объяснение в OngoingCallNotifier.kt/EndCallReceiver.kt:
  /// у flutter_local_notifications действия без открытия UI ВСЕГДА уходят
  /// в отдельный, изолированный от реального приложения движок, так что
  /// такая кнопка через него в принципе не могла управлять настоящим
  /// звонком.
  static final _endCallController = StreamController<void>.broadcast();
  static Stream<void> get endCallRequests => _endCallController.stream;

  /// Событие от нативного CallDeclineReceiver — пользователь нажал
  /// "Отклонить" прямо в уведомлении о входящем звонке, ПОКА приложение
  /// живо. Раньше в этом случае звонящий не получал отказ вообще: HTTP-путь
  /// на /calls/decline рассчитан только на звонок, доставленный офлайн
  /// (через push) и лежащий в серверном PendingCallRegistry — а если
  /// приложение уже было открыто, call_offer пришёл через живой WebSocket,
  /// никакой записи в реестре нет, и сервер молча отвечал "нечего
  /// отклонять". Раз движок жив — просим CallService самому отклонить
  /// звонок через уже установленное соединение (см. CallDeclineReceiver.kt).
  static final _declineCallController = StreamController<void>.broadcast();
  static Stream<void> get declineCallRequests => _declineCallController.stream;

  static bool _handlerInitialized = false;
  static void _ensureHandler() {
    if (_handlerInitialized) return;
    _handlerInitialized = true;
    debugPrint('CallRingPlugin: устанавливаю обработчик входящих вызовов на канале oshinobu/call_ring');
    _channel.setMethodCallHandler((call) async {
      debugPrint('CallRingPlugin: пришёл вызов от нативной стороны: ${call.method}');
      if (call.method == 'endCallRequested') {
        debugPrint('CallRingPlugin: endCallRequested -> публикую в endCallRequests');
        _endCallController.add(null);
      } else if (call.method == 'declineCallRequested') {
        debugPrint('CallRingPlugin: declineCallRequested -> публикую в declineCallRequests');
        _declineCallController.add(null);
      }
    });
  }

  /// callId нужен для кнопки "Отклонить" в уведомлении — с его помощью
  /// сервер понимает, какой именно отложенный звонок отклоняют, и может
  /// мгновенно сообщить об этом звонящему (см. CallDeclineReceiver).
  static Future<void> startRinging({String? callId}) async {
    _ensureHandler();
    try {
      await _channel.invokeMethod('startRinging', {'callId': callId});
    } catch (_) {
      // Не критично — в худшем случае просто не будет полноэкранного звонка.
    }
  }

  static Future<void> stopRinging() async {
    try {
      await _channel.invokeMethod('stopRinging');
    } catch (_) {}
  }

  /// На Android 14+ полноэкранные уведомления требуют отдельного,
  /// отзываемого системой разрешения — даже объявленное в манифесте, оно
  /// может быть выключено по умолчанию. Программно включить нельзя, только
  /// открыть системный экран настроек, где пользователь включает его сам.
  static Future<void> ensureFullScreenIntentPermission() async {
    try {
      await _channel.invokeMethod('ensureFullScreenIntentPermission');
    } catch (_) {}
  }

  /// Кэширует токен сессии/device_id/адрес сервера в обычных (не
  /// keystore-шифрованных) SharedPreferences на нативной стороне — нужно,
  /// чтобы кнопка "Отклонить" в уведомлении могла авторизованно уведомить
  /// сервер напрямую из BroadcastReceiver, без поднятия Flutter-движка (там
  /// обычное защищённое хранилище сессии недоступно). Вызывать при каждом
  /// подключении, чтобы кэш не протухал.
  static Future<void> cacheCredentials({
    required String token,
    required String deviceId,
    required String baseUrl,
  }) async {
    try {
      await _channel.invokeMethod('cacheCredentials', {
        'token': token,
        'deviceId': deviceId,
        'baseUrl': baseUrl,
      });
    } catch (_) {}
  }

  /// Стирает кэш из cacheCredentials — обязательно вызывать при выходе из
  /// аккаунта/удалении аккаунта, иначе кнопка "Отклонить" продолжила бы
  /// пользоваться токеном уже вышедшего пользователя.
  static Future<void> clearCredentials() async {
    try {
      await _channel.invokeMethod('clearCredentials');
    } catch (_) {}
  }

  /// Показывает нативное уведомление "Идёт разговор с <имя>" — см.
  /// OngoingCallNotifier.kt. Не через flutter_local_notifications, см.
  /// комментарий у endCallRequests выше.
  static Future<void> showOngoingCallNotification(String peerLogin) async {
    _ensureHandler();
    debugPrint('CallRingPlugin: showOngoingCallNotification(peerLogin=$peerLogin)');
    try {
      await _channel.invokeMethod('showOngoingCall', {'peerLogin': peerLogin});
    } catch (e) {
      debugPrint('CallRingPlugin: showOngoingCallNotification failed: $e');
    }
  }

  static Future<void> hideOngoingCallNotification() async {
    _ensureHandler();
    debugPrint('CallRingPlugin: hideOngoingCallNotification()');
    try {
      await _channel.invokeMethod('hideOngoingCall');
    } catch (e) {
      debugPrint('CallRingPlugin: hideOngoingCallNotification failed: $e');
    }
  }
}
