import 'dart:io';

import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import 'debug_log.dart';

/// Обёртка над нативным MediaDownloadForegroundService (Android): тонкий
/// foreground-сервис, который НИЧЕГО не качает сам, а лишь держит процесс
/// приложения живым, пока идёт запрошенная пользователем загрузка файла и
/// приложение свёрнуто. Сам движок скачивания (MediaDownloadManager)
/// живёт в основном изоляте — Android иначе вправе прибить процесс вместе
/// с ним, как только приложение уходит с переднего плана.
///
/// НЕ переживает смахивание приложения из «недавних» — там процесс
/// убивается целиком; докачка с места обрыва подхватит это при следующем
/// запуске (см. PartialDownloadStore).
class MediaDownloadForeground {
  MediaDownloadForeground._();

  static const MethodChannel _channel = MethodChannel(
    'oshinobu/media_download_fgs',
  );

  static bool _running = false;
  static String? _currentText;

  /// [text] — заголовок уведомления, зависит от того, что сейчас идёт
  /// (скачивание / выгрузка / и то и другое) — см.
  /// MediaDownloadManager._syncForegroundService. Повторный вызов с новым
  /// текстом обновляет уже показанное уведомление (нативный onStartCommand
  /// снова зовёт startForeground с новой строкой).
  static Future<void> start({required String text}) async {
    if (!Platform.isAndroid) return;
    if (_running && _currentText == text) return;
    _running = true;
    _currentText = text;
    try {
      // Все тексты уведомления передаём с Dart-стороны через tr() — движок
      // передач живёт в основном изоляте, где AppStrings.locale уже
      // соответствует выбранному в приложении языку (см. LocaleStore).
      await _channel.invokeMethod<void>('start', {
        'text': text,
        'channelName': tr('notification.transfersChannelName'),
        'channelDescription': tr('notification.transfersChannelDescription'),
      });
    } catch (e) {
      _running = false;
      _currentText = null;
      DebugLog.log('MediaDownloadForeground.start failed: $e');
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid || !_running) return;
    _running = false;
    _currentText = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      DebugLog.log('MediaDownloadForeground.stop failed: $e');
    }
  }
}
