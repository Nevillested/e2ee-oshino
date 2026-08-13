import 'package:call_ring_plugin/call_ring_plugin.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../api/api_client.dart';
import '../config.dart';
import '../crypto/key_store.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../storage/locale_store.dart';
import 'local_notifications.dart';

const _messagesChannelId = 'messages';

/// Push-уведомления через FCM — стадия 1: только обычные сообщения.
///
/// Принципиально: сам push НИЧЕГО не сообщает о содержимом переписки — ни
/// отправителя, ни текста. Это голый сигнал "у тебя что-то есть, подключись
/// к своему серверу" (data-only сообщение, без блока notification). Реальные
/// данные приложение получает уже по собственному зашифрованному каналу
/// (WebSocket) после того как проснулось — Google в этой схеме их не видит.
class PushService {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await Firebase.initializeApp();
    } catch (e) {
      // google-services.json не настроен/недоступен — приложение должно
      // продолжать работать и без push.
      debugPrint('PushService: Firebase.initializeApp() failed: $e');
      return;
    }

    await ensureLocalNotificationsInitialized();

    FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);

    final messaging = FirebaseMessaging.instance;
    final permission = await messaging.requestPermission();
    debugPrint(
      'PushService: notification permission = ${permission.authorizationStatus}',
    );

    // На Android 14+ отдельно проверяем разрешение на full-screen intent —
    // без него экран входящего звонка просто не будет всплывать поверх
    // блокировки, даже если сам push и рингтон работают нормально.
    await CallRingPlugin.ensureFullScreenIntentPermission();

    messaging.onTokenRefresh.listen((t) {
      debugPrint('PushService: onTokenRefresh: $t');
      _registerToken(t);
    });
    final token = await messaging.getToken();
    debugPrint('PushService: getToken() = $token');
    if (token != null) await _registerToken(token);

    FirebaseMessaging.onMessage.listen((message) {
      // Приложение и так на переднем плане с живым WebSocket — реальное
      // сообщение придёт своим путём через MessageRouter, дублировать
      // локальным уведомлением не нужно.
      //
      // Исключение — звонок: Android может доставить push именно сюда
      // (а не в pushBackgroundHandler) просто потому, что процесс приложения
      // ещё жив, даже если реально оно свёрнуто и WebSocket-соединение уже
      // "зомби" (сервер это тоже проверяет отдельно, но клиенту всё равно
      // нужно физически показать входящий вызов) — поэтому для 'call' здесь
      // делаем то же самое, что и в фоновом обработчике.
      final type = message.data['type'];
      if (type == 'call') {
        CallRingPlugin.startRinging(
          callId: message.data['call_id'],
          callerDeviceId: message.data['caller_device_id'],
        );
      } else if (type == 'call_cancel') {
        CallRingPlugin.stopRinging();
      }
    });
  }

  static Future<void> _registerToken(String token) async {
    try {
      final sessionToken = await Session.getToken();
      final deviceId = await KeyStore.getStoredDeviceId();
      if (sessionToken == null || deviceId == null) {
        debugPrint(
          'PushService: _registerToken: нет sessionToken/deviceId, пропуск',
        );
        return;
      }
      final ok = await ApiClient().registerPushToken(
        sessionToken,
        deviceId,
        token,
      );
      debugPrint(
        'PushService: registerPushToken() -> $ok (device_id=$deviceId)',
      );

      // Кнопке "Отклонить" в уведомлении о звонке нужен свой, независимый
      // от Dart-хранилища доступ к токену сессии — обновляем кэш на
      // нативной стороне при каждой (пере)регистрации push-токена.
      await CallRingPlugin.cacheCredentials(
        token: sessionToken,
        deviceId: deviceId,
        baseUrl: ApiConfig.baseUrl,
      );
    } catch (e) {
      // Не получилось сейчас — токен уйдёт при следующем запуске/обновлении.
      debugPrint('PushService: _registerToken failed: $e');
    }
  }
}

/// Обработчик фоновых/terminated push — ОБЯЗАН быть top-level функцией (не
/// методом класса), потому что при полностью закрытом приложении вызывается
/// в отдельном изоляте без доступа к состоянию остального приложения —
/// поэтому не полагается на PushService, а сам создаёт себе всё необходимое.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  // Отдельный изолят — AppStrings.locale тут ещё не читан, статическое
  // поле стартует со значением по умолчанию (см. LocaleStore). Без этого
  // push "У вас новое сообщение" всегда приходил бы по-русски, даже если
  // пользователь выбрал английский.
  await LocaleStore.init();

  final type = message.data['type'];
  if (type != 'message' && type != 'call' && type != 'call_cancel') return;

  if (type == 'call') {
    // Обычное уведомление тут не подходит — не умеет ни зациклить рингтон,
    // ни надёжно поднять полноэкранный вызов поверх блокировки. Вместо
    // этого поднимаем нативный foreground-service (CallRingService),
    // который делает это сам, как настоящая звонилка. Как только реальный
    // call_offer дойдёт по WebSocket (см. CallService), сервис остановится
    // и управление рингтоном/экраном звонка перейдёт уже к живому приложению.
    await CallRingPlugin.startRinging(
      callId: message.data['call_id'],
      callerDeviceId: message.data['caller_device_id'],
    );
    return;
  }

  if (type == 'call_cancel') {
    // Звонящий передумал ждать раньше, чем мы успели подключиться —
    // сервер прислал отдельный пуш специально, чтобы прекратить рингтон
    // сразу, не дожидаясь его собственного 45-секундного таймаута.
    await CallRingPlugin.stopRinging();
    return;
  }

  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  final details = NotificationDetails(
    android: AndroidNotificationDetails(
      _messagesChannelId,
      tr('push.messagesChannelName'),
      channelDescription: tr('push.messagesChannelDescription'),
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  // Без содержимого — на этой стадии мы намеренно не поднимаем WebSocket
  // в фоне ради экономии времени/риска, поэтому не знаем ни отправителя,
  // ни текста. Открыв приложение, пользователь увидит реальное сообщение
  // как обычно.
  await notifications.show(0, 'Oshinobu', tr('push.newMessageBody'), details);
}
