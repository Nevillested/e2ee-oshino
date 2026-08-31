import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';
import '../session.dart';
import 'debug_log.dart';

/// Фото профиля НЕ зашифровано (см. комментарий в account_avatar.go на
/// сервере) — просто обычный HTTP GET по account_id, поэтому его можно
/// свободно кэшировать в памяти на время сессии приложения: одно и то же
/// фото не нужно перекачивать на каждой перерисовке списка чатов.
class AvatarCache {
  static final Map<String, Uint8List?> _cache = {};
  static final Map<String, DateTime> _cachedAt = {};
  static final Map<String, Future<({bool ok, Uint8List? bytes})>> _inFlight =
      {};
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

  // Живой сигнал (см. WebSocketService.avatarChangedEvents/home_placeholder_
  // screen.dart) вызывает invalidate() сразу же — TTL выше остаётся только
  // подстраховкой на случай, если этот сигнал по какой-то причине не
  // дошёл (например, оба устройства были офлайн в момент отправки).
  // Виджеты, показывающие ЧУЖОЙ аватар (см. _OtherAvatarLeading в
  // home_placeholder_screen.dart, шапка чата в chat_screen.dart),
  // слушают этот стрим и перезапрашивают немедленно, а не ждут, пока их
  // FutureBuilder сам когда-нибудь перестроится.
  static final _changesController = StreamController<String>.broadcast();
  static Stream<String> get changes => _changesController.stream;

  static Future<File> _diskFileFor(String accountId) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/avatar_cache_$accountId');
  }

  /// Синхронный доступ к тому, что УЖЕ лежит в памяти прямо сейчас (без
  /// похода в диск/сеть) — null, если ещё ничего не запрашивали. Нужен
  /// местам, которым критично не ждать даже одного лишнего кадра (см.
  /// CachedAvatarImage) — FutureBuilder(future: get(...)) всегда рисует
  /// "нет данных" на первом кадре, ДАЖЕ если результат на самом деле уже
  /// готов синхронно, просто потому что колбэк Future всегда срабатывает
  /// асинхронно. При каждом пересоздании виджета (а Hero-полёт пересоздаёт
  /// его несколько раз) это давало заметное мелькание плейсхолдера поверх
  /// уже загруженного фото.
  static Uint8List? peek(String accountId) => _cache[accountId];

  /// null — либо у аккаунта нет фото, либо запрос не удался; вызывающая
  /// сторона в обоих случаях показывает заглушку, различать не нужно.
  static Future<Uint8List?> get(String accountId) async {
    final cachedAt = _cachedAt[accountId];
    final isFresh =
        cachedAt != null && DateTime.now().difference(cachedAt) < _ttl;
    if (isFresh && _cache.containsKey(accountId)) return _cache[accountId];
    final inFlight = _inFlight[accountId];
    if (inFlight != null) {
      final result = await inFlight;
      return result.ok ? result.bytes : _cache[accountId];
    }

    // Диск (в отличие от карт выше) переживает перезапуск процесса — на
    // холодном старте приложения показываем то, что было закэшировано в
    // ПРОШЛЫЙ раз, сразу же, вместо пустой заглушки на секунду-другую,
    // пока летит сетевой запрос (это и была причина "аватарки подтягиваются
    // с задержкой при каждом входе" — карты выше при каждом новом запуске
    // процесса всегда пустые). Свежесть диска при этом не гарантирована —
    // ниже всё равно запускаем обычный сетевой рефреш в фоне, который
    // молча обновит и диск, и память, и пришлёт сигнал через `changes`,
    // если фото на сервере успело смениться, пока приложение было закрыто.
    if (!_cache.containsKey(accountId)) {
      final diskFile = await _diskFileFor(accountId);
      if (await diskFile.exists()) {
        try {
          final diskBytes = await diskFile.readAsBytes();
          DebugLog.log(
            'AvatarCache.get($accountId): читаю с диска, ${diskBytes.length} байт',
          );
          _cache[accountId] = diskBytes;
          _cachedAt[accountId] = DateTime.now();
          unawaited(_refreshInBackground(accountId));
          return diskBytes;
        } catch (e) {
          // Повреждённый/недочитанный файл — просто идём обычным путём ниже.
          // См. жалобу "иногда при перезапуске приложения пропадают фото
          // собеседников" — если это снова повторится, тут будет видно,
          // что причиной был именно нечитаемый файл кэша, а не что-то ещё.
          DebugLog.log(
            'AvatarCache.get($accountId): файл на диске есть, но НЕ ЧИТАЕТСЯ: $e',
          );
        }
      }
    }

    final myGeneration = _generation[accountId] ?? 0;
    final future = _fetch(accountId);
    _inFlight[accountId] = future;
    final result = await future;
    _inFlight.remove(accountId);
    // Сеть подвела (см. _fetch: ok=false на любую сетевую ошибку, а не
    // только на честное "фото нет" от сервера) — реальный кейс с
    // устройства: выключил/включил вайфай, запрос улетел в момент
    // разрыва, поймал исключение — раньше это молча превращалось в null и
    // затирало уже загруженное фото (и в памяти, и на диске) на "фото
    // нет". Теперь просто НЕ трогаем кэш вообще и отдаём то, что уже там
    // было (может оказаться null, если раньше ничего не грузили — тогда
    // честно показываем заглушку, это не регрессия).
    if (!result.ok) return _cache[accountId];
    // Пока этот запрос летал туда-обратно, кэш успели инвалидировать
    // (см. комментарий у _generation выше) — результат уже устарел, в
    // общий кэш его не кладём (только возвращаем вызвавшему, разово).
    if ((_generation[accountId] ?? 0) != myGeneration) {
      return result.bytes;
    }
    _cache[accountId] = result.bytes;
    _cachedAt[accountId] = DateTime.now();
    unawaited(_writeToDisk(accountId, result.bytes));
    return result.bytes;
  }

  /// Тихий фоновый рефреш вслед за мгновенным ответом с диска — сам ничего
  /// никому не возвращает напрямую, только докатывает то, что реально
  /// сейчас на сервере, и будит подписчиков `changes`, если оказалось, что
  /// фото поменялось, пока приложение было закрыто.
  static Future<void> _refreshInBackground(String accountId) async {
    final myGeneration = _generation[accountId] ?? 0;
    final result = await _fetch(accountId);
    // Сеть подвела — оставляем и память, и диск как есть (см. комментарий
    // в get() выше про ту же самую причину), ничего не сигналим подписчикам.
    if (!result.ok) return;
    if ((_generation[accountId] ?? 0) != myGeneration) return;
    final old = _cache[accountId];
    _cache[accountId] = result.bytes;
    _cachedAt[accountId] = DateTime.now();
    unawaited(_writeToDisk(accountId, result.bytes));
    if (!_bytesEqual(old, result.bytes)) {
      _changesController.add(accountId);
    }
  }

  static Future<void> _writeToDisk(String accountId, Uint8List? bytes) async {
    try {
      final file = await _diskFileFor(accountId);
      if (bytes == null || bytes.isEmpty) {
        // Фото легитимно пропало (скрыли приватностью/удалили) — если тут
        // молча ничего не делать, старый файл на диске переживёт даже
        // перезапуск процесса: следующий холодный старт get() прочтёт ЕГО
        // раньше, чем успеет долететь фоновый рефреш, и на секунду покажет
        // то самое фото, которое как раз скрыли.
        if (await file.exists()) await file.delete();
        return;
      }
      // Пишем во временный файл и переименовываем — не напрямую в файл
      // кэша: rename() на одной и той же файловой системе атомарен, а
      // прямая writeAsBytes() — нет. Если процесс убьют посреди записи
      // (реальный кейс с устройства: "иногда при перезапуске приложения
      // пропадают фото собеседников"), на диске либо останется старый
      // валидный файл, либо ничего — но никогда не частично записанный,
      // непригодный для декодирования.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      DebugLog.log(
        'AvatarCache._writeToDisk($accountId): записал ${bytes.length} байт',
      );
    } catch (e) {
      // Диск переполнен/недоступен на запись — не критично, просто в
      // следующий раз холодный старт снова пойдёт в сеть. Логируем — та же
      // диагностика "пропавших фото собеседников", что и выше в get().
      DebugLog.log('AvatarCache._writeToDisk($accountId): ОШИБКА записи: $e');
    }
  }

  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// ok=false — сеть подвела (или нет токена сессии), кэш ЗАТРАГИВАТЬ
  /// НЕЛЬЗЯ, старое значение (если было) остаётся в силе. ok=true —
  /// честный ответ сервера, bytes==null тогда означает подтверждённое
  /// "фото нет" (404 — см. ApiClient.getAvatar/getMyAvatar).
  static Future<({bool ok, Uint8List? bytes})> _fetch(String accountId) async {
    final token = await Session.getToken();
    if (token == null) return (ok: false, bytes: null);
    try {
      final bytes = await ApiClient().getAvatar(token, accountId);
      DebugLog.log(
        'AvatarCache._fetch($accountId): сервер ответил, ${bytes?.length ?? 0} байт '
        '(null=${bytes == null})',
      );
      return (ok: true, bytes: bytes);
    } catch (e) {
      DebugLog.log('AvatarCache._fetch($accountId): сетевая ошибка: $e');
      return (ok: false, bytes: null);
    }
  }

  /// Вызывается после успешной загрузки нового фото — иначе кэш ещё долго
  /// отдавал бы старое (или "нет фото") даже для собственного аккаунта.
  static void invalidate(String accountId) {
    _cache.remove(accountId);
    _cachedAt.remove(accountId);
    _generation[accountId] = (_generation[accountId] ?? 0) + 1;
    _changesController.add(accountId);
  }
}
