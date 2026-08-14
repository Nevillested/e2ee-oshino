import 'dart:typed_data';
import '../api/api_client.dart';
import '../session.dart';

/// Фото профиля НЕ зашифровано (см. комментарий в account_avatar.go на
/// сервере) — просто обычный HTTP GET по account_id, поэтому его можно
/// свободно кэшировать в памяти на время сессии приложения: одно и то же
/// фото не нужно перекачивать на каждой перерисовке списка чатов.
class AvatarCache {
  static final Map<String, Uint8List?> _cache = {};
  static final Map<String, Future<Uint8List?>> _inFlight = {};

  /// null — либо у аккаунта нет фото, либо запрос не удался; вызывающая
  /// сторона в обоих случаях показывает заглушку, различать не нужно.
  static Future<Uint8List?> get(String accountId) async {
    if (_cache.containsKey(accountId)) return _cache[accountId];
    final inFlight = _inFlight[accountId];
    if (inFlight != null) return inFlight;

    final future = _fetch(accountId);
    _inFlight[accountId] = future;
    final result = await future;
    _cache[accountId] = result;
    _inFlight.remove(accountId);
    return result;
  }

  static Future<Uint8List?> _fetch(String accountId) async {
    final token = await Session.getToken();
    if (token == null) return null;
    return ApiClient().getAvatar(token, accountId);
  }

  /// Вызывается после успешной загрузки нового фото — иначе кэш ещё долго
  /// отдавал бы старое (или "нет фото") даже для собственного аккаунта.
  static void invalidate(String accountId) {
    _cache.remove(accountId);
  }
}
