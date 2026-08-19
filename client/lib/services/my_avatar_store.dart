import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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

  static Future<File> _diskFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/my_avatar_cache.bin');
  }

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

    // Диск переживает перезапуск процесса (в отличие от notifier, который
    // при каждом холодном старте начинает с null) — показываем то, что
    // было закэшировано в прошлый раз, сразу же, вместо пустой заглушки
    // на секунду-другую у "Заметок", пока летит сетевой запрос.
    try {
      final file = await _diskFile();
      if (await file.exists()) {
        notifier.value = await file.readAsBytes();
      }
    } catch (_) {}

    final fresh = await ApiClient().getMyAvatar(token);
    notifier.value = fresh;
    unawaited(_writeToDisk(fresh));
  }

  static Future<void> _writeToDisk(Uint8List? bytes) async {
    try {
      final file = await _diskFile();
      if (bytes == null || bytes.isEmpty) {
        if (await file.exists()) await file.delete();
        return;
      }
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // Диск недоступен/переполнен — не критично, просто в следующий раз
      // холодный старт снова пойдёт в сеть без мгновенного превью.
    }
  }

  /// Сразу после успешной загрузки нового фото — без похода на сервер за
  /// тем, что мы туда только что сами и отправили.
  static void setUploaded(Uint8List bytes) {
    notifier.value = bytes;
    unawaited(_writeToDisk(bytes));
  }

  /// Сразу после успешного удаления — тем же принципом: сами знаем
  /// результат, повторно спрашивать сервер незачем.
  static void setRemoved() {
    notifier.value = null;
    unawaited(_writeToDisk(null));
  }

  /// Вызывается при выходе из аккаунта/удалении аккаунта (см.
  /// account_actions.dart) — без этого при логине в ДРУГОЙ аккаунт (без
  /// полного перезапуска процесса приложения) init() видел бы
  /// _initStarted=true и молча оставлял висеть фото ПРЕЖНЕГО аккаунта,
  /// пока кто-нибудь явно не загрузит/не удалит новое. Диск чистим по
  /// той же причине — иначе следующий init() (уже для ДРУГОГО аккаунта
  /// на этом же устройстве) на долю секунды показал бы фото ПРЕЖНЕГО
  /// аккаунта из диска, прежде чем сетевой запрос его поправит.
  static void reset() {
    _initStarted = false;
    notifier.value = null;
    unawaited(_writeToDisk(null));
  }
}
