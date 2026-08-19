import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../session.dart';

/// Почта для восстановления — тем же принципом, что и MyAvatarStore:
/// известна ОДИН раз при старте приложения (init), а не перезапрашивается
/// каждый раз при открытии настроек. Меняется РОВНО в момент, когда мы
/// сами её добавили/удалили (setEmail/clear) — сервер запрашивать
/// незачем, это гарантированно то же самое, что мы туда только что
/// отправили. showEmailDialog (email_dialog.dart) просто читает notifier.
class MyEmailStore {
  MyEmailStore._();

  static final ValueNotifier<String?> notifier = ValueNotifier<String?>(null);
  static bool _initStarted = false;

  /// Вызывается один раз при старте приложения (см. _connect() в
  /// home_placeholder_screen.dart) — идемпотентна, повторные вызовы в
  /// рамках одной сессии приложения игнорируются.
  static Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    final token = await Session.getToken();
    if (token == null) return;
    final info = await ApiClient().getMyAccountInfo(token);
    notifier.value = info?.email;
  }

  /// Сразу после успешного добавления/подтверждения — без похода на
  /// сервер за тем, что мы туда только что сами и отправили.
  static void setEmail(String email) {
    notifier.value = email;
  }

  /// Сразу после успешного удаления.
  static void clear() {
    notifier.value = null;
  }

  /// Вызывается при выходе из аккаунта/удалении аккаунта — без этого при
  /// логине в ДРУГОЙ аккаунт (без полного перезапуска процесса
  /// приложения) init() видел бы _initStarted=true и молча оставлял
  /// висеть почту ПРЕЖНЕГО аккаунта.
  static void reset() {
    _initStarted = false;
    notifier.value = null;
  }
}
