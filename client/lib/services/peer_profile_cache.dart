import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';
import '../session.dart';

class PeerProfile {
  final String login;
  // Уже готовое к показу значение (display_name, если задан, иначе login
  // — см. ApiClient.getAccountProfile/сервер) — именно его и нужно
  // показывать везде, где раньше показывался login напрямую.
  final String displayName;
  final List<Map<String, dynamic>> devices;
  final String? status;
  final String? birthday;
  final bool hasAvatar;

  const PeerProfile({
    required this.login,
    required this.displayName,
    required this.devices,
    this.status,
    this.birthday,
    required this.hasAvatar,
  });

  Map<String, dynamic> toJson() => {
    'login': login,
    'display_name': displayName,
    'devices': devices,
    'status': status,
    'birthday': birthday,
    'has_avatar': hasAvatar,
  };

  static PeerProfile fromJson(Map<String, dynamic> j) => PeerProfile(
    login: j['login'] as String,
    displayName: j['display_name'] as String? ?? j['login'] as String,
    devices: (j['devices'] as List).cast<Map<String, dynamic>>(),
    status: j['status'] as String?,
    birthday: j['birthday'] as String?,
    hasAvatar: j['has_avatar'] as bool? ?? false,
  );
}

/// Кэш чужого профиля (статус/дата рождения/устройства) — тот же паттерн,
/// что и AvatarCache (генерация-счётчик против гонок, TTL, диск во
/// временной директории, живой `changes`-стрим), только для полей
/// профиля, а не для байтов фото (те по-прежнему через AvatarCache — он
/// уже был, здесь его не дублируем).
///
/// Поля, к которым у смотрящего нет доступа, сервер просто не присылает
/// (см. account_profile.go) — здесь это уже финальные, отфильтрованные
/// значения, отдельно перепроверять приватность на клиенте не нужно.
class PeerProfileCache {
  static final Map<String, PeerProfile?> _cache = {};
  static final Map<String, DateTime> _cachedAt = {};
  static final Map<String, Future<({bool ok, PeerProfile? profile})>>
  _inFlight = {};
  static final Map<String, int> _generation = {};

  // Аналогично AvatarCache: живой сигнал (profile_updated) инвалидирует
  // сразу, TTL — подстраховка на случай, если сигнал не дошёл (оба были
  // офлайн в момент отправки).
  static const _ttl = Duration(minutes: 3);

  static final _changesController = StreamController<String>.broadcast();
  static Stream<String> get changes => _changesController.stream;

  static Future<File> _diskFileFor(String accountId) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/peer_profile_cache_$accountId');
  }

  /// null — либо профиль недоступен (приватность/удалён), либо запрос не
  /// удался; вызывающая сторона в обоих случаях просто не показывает эти
  /// поля, различать не нужно.
  static Future<PeerProfile?> get(String accountId, String login) async {
    final cachedAt = _cachedAt[accountId];
    final isFresh =
        cachedAt != null && DateTime.now().difference(cachedAt) < _ttl;
    if (isFresh && _cache.containsKey(accountId)) return _cache[accountId];
    final inFlight = _inFlight[accountId];
    if (inFlight != null) {
      final result = await inFlight;
      return result.ok ? result.profile : _cache[accountId];
    }

    if (!_cache.containsKey(accountId)) {
      final diskFile = await _diskFileFor(accountId);
      if (await diskFile.exists()) {
        try {
          final json =
              jsonDecode(await diskFile.readAsString()) as Map<String, dynamic>;
          final diskProfile = PeerProfile.fromJson(json);
          _cache[accountId] = diskProfile;
          _cachedAt[accountId] = DateTime.now();
          unawaited(_refreshInBackground(accountId, login));
          return diskProfile;
        } catch (_) {
          // Повреждённый/недочитанный файл — просто идём обычным путём ниже.
        }
      }
    }

    final myGeneration = _generation[accountId] ?? 0;
    final future = _fetch(accountId, login);
    _inFlight[accountId] = future;
    final result = await future;
    _inFlight.remove(accountId);
    // Сеть подвела — та же причина и тот же фикс, что и в AvatarCache (см.
    // подробный комментарий там): не трогаем кэш, отдаём что уже было.
    if (!result.ok) return _cache[accountId];
    if ((_generation[accountId] ?? 0) != myGeneration) {
      return result.profile;
    }
    _cache[accountId] = result.profile;
    _cachedAt[accountId] = DateTime.now();
    unawaited(_writeToDisk(accountId, result.profile));
    return result.profile;
  }

  static Future<void> _refreshInBackground(
    String accountId,
    String login,
  ) async {
    final myGeneration = _generation[accountId] ?? 0;
    final result = await _fetch(accountId, login);
    if (!result.ok) return;
    if ((_generation[accountId] ?? 0) != myGeneration) return;
    _cache[accountId] = result.profile;
    _cachedAt[accountId] = DateTime.now();
    unawaited(_writeToDisk(accountId, result.profile));
    _changesController.add(accountId);
  }

  static Future<void> _writeToDisk(
    String accountId,
    PeerProfile? profile,
  ) async {
    if (profile == null) return;
    try {
      final file = await _diskFileFor(accountId);
      await file.writeAsString(jsonEncode(profile.toJson()));
    } catch (_) {}
  }

  /// ok=false — сеть подвела (или нет токена сессии), кэш затрагивать
  /// нельзя. ok=true, profile==null — честное "профиля нет/скрыт" (404).
  static Future<({bool ok, PeerProfile? profile})> _fetch(
    String accountId,
    String login,
  ) async {
    final token = await Session.getToken();
    if (token == null) return (ok: false, profile: null);
    try {
      final data = await ApiClient().getAccountProfile(token, login);
      if (data == null) return (ok: true, profile: null);
      return (
        ok: true,
        profile: PeerProfile(
          login: data.login,
          displayName: data.displayName,
          devices: data.devices,
          status: data.status,
          birthday: data.birthday,
          hasAvatar: data.hasAvatar,
        ),
      );
    } catch (_) {
      return (ok: false, profile: null);
    }
  }

  /// Вызывается по profile_updated (status/birthday) — см.
  /// websocket_service.dart:profileChangedEvents. Для avatar используется
  /// уже существующий AvatarCache.invalidate, не этот метод.
  static void invalidate(String accountId) {
    _cache.remove(accountId);
    _cachedAt.remove(accountId);
    _generation[accountId] = (_generation[accountId] ?? 0) + 1;
    _changesController.add(accountId);
  }
}
