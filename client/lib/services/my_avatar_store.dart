import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../session.dart';

/// Собственное фото профиля — намеренно ОТДЕЛЬНО от AvatarCache (которая
/// продолжает обслуживать фото ЧУЖИХ аккаунтов и остаётся честным
/// "запросил → закешировал" механизмом на много разных id). Своё же фото
/// не нужно ни перезапрашивать при каждом открытии настроек/списка чатов,
/// ни бояться гонки "устаревший ответ прилетел после инвалидации" — оно
/// известно ОДИН раз при старте приложения (init) и меняется РОВНО в
/// момент, когда мы сами его загрузили (setUploaded, байты уже есть на
/// руках, сервер запрашивать незачем — это гарантированно то же самое,
/// что мы туда только что отправили). AvatarSettingsTile и "Заметки" в
/// списке чатов оба просто слушают notifier — единый источник истины,
/// без повторных сетевых походов и без FutureBuilder-гонок.
class MyAvatarStore {
  MyAvatarStore._();

  static final ValueNotifier<Uint8List?> notifier = ValueNotifier<Uint8List?>(
    null,
  );
  static bool _initStarted = false;

  /// Вызывается один раз при старте приложения (см. _connect() в
  /// home_placeholder_screen.dart) — идемпотентна, повторные вызовы в
  /// рамках одной сессии приложения игнорируются.
  ///
  /// Специально getMyAvatar (без account_id в запросе), а не
  /// getAvatar(token, Session.getAccountId()) — закэшированный на
  /// клиенте account_id (SharedPreferences) может устареть и разойтись с
  /// тем, что реально означает текущий токен (например, после
  /// пересоздания аккаунтов при чистке базы на сервере) — тогда сервер
  /// честно отвечал "аккаунт не найден" на чужой/несуществующий id, хотя
  /// сама сессия рабочая. getMyAvatar просит сервер взять account_id
  /// из токена самому, тем же способом, что уже используют загрузка и
  /// удаление — там эта проблема никогда не проявлялась именно поэтому.
  static Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    final token = await Session.getToken();
    if (token == null) return;
    notifier.value = await ApiClient().getMyAvatar(token);
  }

  /// Сразу после успешной загрузки нового фото — без похода на сервер за
  /// тем, что мы туда только что сами и отправили.
  static void setUploaded(Uint8List bytes) {
    debugPrint('MyAvatarStore.setUploaded: ${bytes.length} байт');
    notifier.value = bytes;
  }

  /// Сразу после успешного удаления — тем же принципом: сами знаем
  /// результат, повторно спрашивать сервер незачем.
  static void setRemoved() {
    debugPrint('MyAvatarStore.setRemoved');
    notifier.value = null;
  }
}
