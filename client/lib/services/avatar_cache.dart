import 'dart:typed_data';
import '../api/api_client.dart';
import '../session.dart';

/// Фото профиля НЕ зашифровано (см. комментарий в account_avatar.go на
/// сервере) — просто обычный HTTP GET по account_id, поэтому его можно
/// свободно кэшировать в памяти на время сессии приложения: одно и то же
/// фото не нужно перекачивать на каждой перерисовке списка чатов.
class AvatarCache {
  static final Map<String, Uint8List?> _cache = {};
  static final Map<String, DateTime> _cachedAt = {};
  static final Map<String, Future<Uint8List?>> _inFlight = {};
  // Счётчик поколений на accountId — растёт при каждом invalidate(). Нужен,
  // чтобы поймать гонку: запрос, отправленный ДО загрузки нового фото (и
  // потому вернувший старое значение/null), может резолвиться ПОСЛЕ того,
  // как invalidate() уже очистил кэш — без этой проверки он бы затирал
  // кэш обратно устаревшим результатом. Классический пример: список чатов
  // запрашивает аватар для "Заметок" (тот же account_id, что и свой
  // профиль) ещё до того, как пользователь успел загрузить новое фото в
  // настройках — тот запрос долетает до сервера и обратно уже ПОСЛЕ
  // invalidate(), и без generation-проверки молча возвращал бы отображение
  // к старому/пустому фото при следующем открытии экрана.
  static final Map<String, int> _generation = {};

  // Сервер не умеет уведомлять нас о том, что ЧУЖОЙ аватар поменялся (для
  // этого нужно было бы отслеживать "кто чей контакт", как presence-
  // подписки, а сервер это принципиально не хранит) — без TTL кэш чужого
  // аватара, once закэшированный (даже как "фото нет"), оставался бы таким
  // навсегда до перезапуска приложения, даже если человек только что
  // загрузил новое фото. TTL — простой, без нового серверного сигнала,
  // способ рано или поздно (в течение нескольких минут) это заметить.
  static const _ttl = Duration(minutes: 3);

  /// null — либо у аккаунта нет фото, либо запрос не удался; вызывающая
  /// сторона в обоих случаях показывает заглушку, различать не нужно.
  static Future<Uint8List?> get(String accountId) async {
    final cachedAt = _cachedAt[accountId];
    final isFresh =
        cachedAt != null && DateTime.now().difference(cachedAt) < _ttl;
    if (isFresh && _cache.containsKey(accountId)) return _cache[accountId];
    final inFlight = _inFlight[accountId];
    if (inFlight != null) return inFlight;

    final myGeneration = _generation[accountId] ?? 0;
    final future = _fetch(accountId);
    _inFlight[accountId] = future;
    final result = await future;
    _inFlight.remove(accountId);
    // Пока этот запрос летал туда-обратно, кэш успели инвалидировать
    // (см. комментарий у _generation выше) — результат уже устарел, в
    // общий кэш его не кладём (только возвращаем вызвавшему, разово).
    if ((_generation[accountId] ?? 0) != myGeneration) {
      return result;
    }
    _cache[accountId] = result;
    _cachedAt[accountId] = DateTime.now();
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
    _cachedAt.remove(accountId);
    _generation[accountId] = (_generation[accountId] ?? 0) + 1;
  }
}
