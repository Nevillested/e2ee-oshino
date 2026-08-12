import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Единственный на весь (живой, foreground-движок) экземпляр
/// flutter_local_notifications и единственная точка его initialize().
///
/// Важно: плагин под капотом общается с нативной стороной через один и тот
/// же канал независимо от того, сколько раз создать
/// FlutterLocalNotificationsPlugin() в Dart — но initialize() рассчитан на
/// однократный вызов. Если вызвать его из нескольких мест по отдельности,
/// обработчик нажатий на кнопки действий (onDidReceiveNotificationResponse)
/// из более раннего вызова тихо перестаёт работать. Поэтому и сам плагин, и
/// его инициализация — здесь, в одном месте.
///
/// Используется сейчас только для простых уведомлений о новых сообщениях
/// (см. push_service.dart) — у них нет ни действий, ни payload, поэтому
/// _handleResponse ничего не делает. Уведомление "Идёт разговор" (с кнопкой
/// "Завершить звонок") через этот плагин НЕ строится: у
/// flutter_local_notifications действия без открытия UI
/// (showsUserInterface: false) всегда обрабатываются через отдельный,
/// изолированный от живого приложения FlutterEngine — там свой пустой
/// CallService, никак не связанный с реальным идущим звонком. Поэтому то
/// уведомление собрано полностью нативно, см. OngoingCallNotifier.kt
/// (пакет call_ring_plugin) + PipService/CallRingPlugin на Dart-стороне.
final FlutterLocalNotificationsPlugin localNotifications = FlutterLocalNotificationsPlugin();

bool _initialized = false;

void _handleResponse(NotificationResponse response) {}

@pragma('vm:entry-point')
void onBackgroundNotificationResponse(NotificationResponse response) {
  _handleResponse(response);
}

Future<void> ensureLocalNotificationsInitialized() async {
  if (_initialized) return;
  _initialized = true;
  await localNotifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: _handleResponse,
    onDidReceiveBackgroundNotificationResponse: onBackgroundNotificationResponse,
  );
}
