import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' as dio;

import '../api/api_client.dart';
import '../crypto/media_cipher.dart';
import '../crypto/streaming_file_cipher.dart';
import '../session.dart';
import '../storage/media_cache.dart';
import '../storage/partial_download_store.dart';
import 'debug_log.dart';
import 'media_download_foreground.dart';

/// Всё, что движку нужно знать про один файл, чтобы скачать и расшифровать
/// его без участия экрана чата — строится из StoredMessage вызывающей
/// стороной (см. chat_screen.dart).
class DownloadSpec {
  final String mediaId;
  final String keyBase64;
  final bool chunked;

  /// nonce/mac — только для НЕчанкованных файлов (один GCM-блок целиком,
  /// см. media_cipher.dart). У чанкованных (streaming_file_cipher.dart)
  /// каждый блок несёт свой тег внутри, тут null.
  final String? nonceBase64;
  final String? macBase64;

  /// Размер ОТКРЫТОГО файла (StoredMessage.fileSize) — по нему решается,
  /// брать ли файл в автоочередь: авто только < 3 МБ, крупнее — лишь по
  /// явному запросу пользователя (ТЗ).
  final int plaintextSize;

  const DownloadSpec({
    required this.mediaId,
    required this.keyBase64,
    required this.chunked,
    required this.plaintextSize,
    this.nonceBase64,
    this.macBase64,
  });
}

enum _Tier { user, auto }

enum _Outcome { completed, failed, cancelled, preempted }

class _PreemptedException implements Exception {
  const _PreemptedException();
}

/// Единый, независимый от жизненного цикла экрана чата движок скачивания
/// медиа. Две очереди (ТЗ пользователя):
///
///  * **пользовательская** — файлы, по иконке скачивания которых человек
///    нажал сам. Всегда приоритетнее авто; новый тап встаёт в НАЧАЛО и
///    вытесняет текущую загрузку (её хвост сохраняется на диске).
///  * **автоматическая** — только файлы < 3 МБ, которые появлялись на
///    экране. Порядок — «кого видели позже, того раньше»: повторно
///    показавшийся на экране файл прыгает в начало. Не чистится при
///    прокрутке (раз попал — рано или поздно скачается), но работает
///    только когда пользовательская очередь пуста.
///
/// Строго ПО ОДНОМУ файлу за раз — у проекта один сервер в Москве и
/// хранилище в Японии, параллелить сеть смысла нет.
///
/// Докачка: недокачанный зашифрованный хвост лежит в PartialDownloadStore,
/// возобновление — через HTTP Range (см. ApiClient.downloadEncryptedMediaResumable).
/// Переживает переключение на другой файл, выход из чата и — Stage 2 —
/// сворачивание приложения (движок переедет в фоновый изолят).
class MediaDownloadManager {
  MediaDownloadManager._();
  static final MediaDownloadManager instance = MediaDownloadManager._();

  static const int autoDownloadLimitBytes = 3 * 1024 * 1024; // 3 МБ

  final ApiClient _api = ApiClient();

  final Map<String, DownloadSpec> _specs = {};
  final List<String> _userQueue = []; // [0] = самый свежий тап
  final List<String> _autoQueue = []; // [0] = кого видели позже всех
  final Set<String> _visible = {}; // сейчас на экране (только < 3 МБ)
  final Set<String> _userCancelled = {};
  final Set<String> _forgotten = {}; // сообщение удалено во время загрузки

  // Недавно упавшие авто-загрузки: чтобы плитка, висящая на экране, не
  // молотила по серверу заново каждые 350 мс (см. setVisible). Явный тап
  // пользователя этот кулдаун игнорирует.
  final Map<String, DateTime> _failedAt = {};
  static const Duration _failCooldown = Duration(seconds: 20);

  bool _inCooldown(String mediaId) {
    final t = _failedAt[mediaId];
    return t != null && DateTime.now().difference(t) < _failCooldown;
  }

  String? _activeId;
  _Tier? _activeTier;
  dio.CancelToken? _activeCancel;
  bool _preemptRequested = false;
  bool _busy = false;

  final Map<String, double> _progress = {};
  final Map<String, List<Completer<File>>> _waiters = {};

  final StreamController<String> _progressCtl = StreamController.broadcast();
  final StreamController<String> _doneCtl = StreamController.broadcast();
  final StreamController<String> _failedCtl = StreamController.broadcast();

  /// mediaId, у которого только что поменялся процент.
  Stream<String> get progressChanges => _progressCtl.stream;

  /// mediaId, чей расшифрованный файл только что лёг в MediaCache.
  Stream<String> get done => _doneCtl.stream;

  /// mediaId, чья загрузка сорвалась (хвост сохранён, повторный тап
  /// продолжит с места обрыва).
  Stream<String> get failed => _failedCtl.stream;

  double? progressOf(String mediaId) => _progress[mediaId];
  String? get activeId => _activeId;
  bool isActive(String mediaId) => _activeId == mediaId;
  bool isQueued(String mediaId) =>
      _userQueue.contains(mediaId) || _autoQueue.contains(mediaId);
  bool isWorking(String mediaId) => isActive(mediaId) || isQueued(mediaId);

  // ---- вход от экрана чата ----

  /// Пользователь нажал на иконку скачивания. Вытесняет всё, встаёт в
  /// начало пользовательской очереди.
  void requestUserDownload(DownloadSpec spec) {
    _specs[spec.mediaId] = spec;
    _userCancelled.remove(spec.mediaId);
    _failedAt.remove(spec.mediaId); // явный тап игнорирует кулдаун
    _autoQueue.remove(spec.mediaId);
    _userQueue.remove(spec.mediaId);
    _userQueue.insert(0, spec.mediaId);
    _reconcile();
  }

  /// Экран чата сообщает актуальный набор медиа на экране (уже
  /// отдебаунсенный вызывающей стороной). Только файлы < 3 МБ реально
  /// попадают в автоочередь.
  void setVisible(Iterable<DownloadSpec> specs) {
    final ids = <String>{};
    for (final s in specs) {
      _specs[s.mediaId] = s;
      if (s.plaintextSize >= autoDownloadLimitBytes) continue;
      ids.add(s.mediaId);
      if (_userQueue.contains(s.mediaId)) continue;
      if (_userCancelled.contains(s.mediaId)) continue;
      if (_inCooldown(s.mediaId)) continue;
      _autoQueue.remove(s.mediaId);
      _autoQueue.insert(0, s.mediaId);
    }
    _visible
      ..clear()
      ..addAll(ids);
    _reconcile();
  }

  /// Пользователь нажал ✕ — отказался от файла. Хвост УДАЛЯЕМ (в отличие
  /// от переключения/выхода — там сохраняется).
  void cancelUserDownload(String mediaId) {
    _userQueue.remove(mediaId);
    _autoQueue.remove(mediaId);
    _userCancelled.add(mediaId);
    _progress.remove(mediaId);
    if (_activeId == mediaId) {
      _activeCancel?.cancel('user cancelled');
    } else {
      unawaited(PartialDownloadStore.discard(mediaId));
      _failWaiters(mediaId, ApiException('cancelled'));
    }
    _progressCtl.add(mediaId);
    _syncForegroundService();
  }

  /// Сообщение удалено — забыть про его файл целиком: снять с очередей,
  /// прервать активную загрузку, снести недокачанный хвост. В отличие от
  /// cancelUserDownload НЕ помечает mediaId «отменённым пользователем»
  /// (файла больше не существует, помечать нечего).
  void forget(String mediaId) {
    _userQueue.remove(mediaId);
    _autoQueue.remove(mediaId);
    _visible.remove(mediaId);
    _userCancelled.remove(mediaId);
    _specs.remove(mediaId);
    _progress.remove(mediaId);
    if (_activeId == mediaId) {
      _forgotten.add(mediaId);
      _activeCancel?.cancel('forgotten');
    } else {
      unawaited(PartialDownloadStore.discard(mediaId));
      _failWaiters(mediaId, ApiException('message deleted'));
    }
    _syncForegroundService();
  }

  /// Императивный путь для «открыть файл / сохранить / проиграть /
  /// просмотрщик / кадр-превью»: гарантирует, что расшифрованный файл
  /// лежит в MediaCache, скачивая при необходимости. [userInitiated]
  /// true — как явный тап (высший приоритет, вытесняет), false — тихо, в
  /// начало автоочереди (используется для превью того, что и так на
  /// экране).
  Future<File> ensureDownloaded(
    DownloadSpec spec, {
    bool userInitiated = true,
  }) async {
    final cache = await MediaCache.fileFor(spec.mediaId);
    if (await cache.exists()) return cache;

    // Не свой запрос + файл недавно не скачался -> не дёргаем сервер ещё
    // раз прямо сейчас; вызывающая сторона (FutureBuilder плитки) получит
    // ошибку и покажет "повторить", а следующий showVisible после кулдауна
    // подхватит сам.
    if (!userInitiated &&
        _inCooldown(spec.mediaId) &&
        !_userQueue.contains(spec.mediaId) &&
        _activeId != spec.mediaId) {
      throw ApiException('download on cooldown');
    }

    _specs[spec.mediaId] = spec;
    _userCancelled.remove(spec.mediaId);
    final completer = Completer<File>();
    _waiters.putIfAbsent(spec.mediaId, () => []).add(completer);

    if (userInitiated) {
      _failedAt.remove(spec.mediaId);
      _userQueue.remove(spec.mediaId);
      _autoQueue.remove(spec.mediaId);
      _userQueue.insert(0, spec.mediaId);
    } else if (!_userQueue.contains(spec.mediaId)) {
      _autoQueue.remove(spec.mediaId);
      _autoQueue.insert(0, spec.mediaId);
    }
    _reconcile();
    return completer.future;
  }

  // ---- планировщик ----

  String? _desiredNext() {
    if (_userQueue.isNotEmpty) return _userQueue.first;
    if (_autoQueue.isNotEmpty) return _autoQueue.first;
    return null;
  }

  void _reconcile() {
    _syncForegroundService();
    if (_activeId != null) {
      if (_shouldPreemptActive()) {
        _preemptRequested = true;
        _activeCancel?.cancel('preempted');
      }
      return;
    }
    _pump();
  }

  bool _fgsOn = false;

  /// Тонкий Android foreground-сервис нужен ТОЛЬКО пока крутится (или ждёт
  /// очереди) загрузка, которую пользователь запросил сам — чтобы её не
  /// прибило вместе с процессом при сворачивании приложения. Фоновую
  /// авто-закачку мелочи (< 3 МБ) им не прикрываем: она короткая и не
  /// критична, а лишнее уведомление ни к чему. Стартуем всегда из
  /// состояния, куда попадаем по действию пользователя (обычно приложение
  /// при этом на переднем плане — Android не ругается на старт из фона).
  void _syncForegroundService() {
    final want =
        _userQueue.isNotEmpty ||
        (_activeId != null && _activeTier == _Tier.user);
    if (want == _fgsOn) return;
    _fgsOn = want;
    if (want) {
      unawaited(MediaDownloadForeground.start('Загрузка файлов'));
    } else {
      unawaited(MediaDownloadForeground.stop());
    }
  }

  bool _shouldPreemptActive() {
    final active = _activeId!;
    final want = _desiredNext();
    if (want == null || want == active) return false;
    if (_activeTier == _Tier.user) {
      // Пользовательскую загрузку вытесняет только более свежий тап.
      return _userQueue.isNotEmpty && _userQueue.first != active;
    }
    // Активна авто-загрузка.
    if (_userQueue.isNotEmpty) return true; // любой запрос пользователя
    // Другой авто-файл лезет вперёд — вытесняем ТОЛЬКО если активный уже
    // ушёл с экрана (иначе пинг-понг, пока человек на него смотрит).
    return _autoQueue.isNotEmpty &&
        _autoQueue.first != active &&
        !_visible.contains(active);
  }

  void _pump() {
    if (_busy || _activeId != null) return;
    final next = _desiredNext();
    if (next == null) return;
    final spec = _specs[next];
    if (spec == null) {
      _userQueue.remove(next);
      _autoQueue.remove(next);
      _pump();
      return;
    }

    _busy = true;
    _activeId = next;
    _activeTier = _userQueue.contains(next) ? _Tier.user : _Tier.auto;
    _activeCancel = dio.CancelToken();
    _preemptRequested = false;

    unawaited(_drive(spec));
  }

  Future<void> _drive(DownloadSpec spec) async {
    final id = spec.mediaId;
    _Outcome outcome;
    Object? error;
    try {
      await _runOne(spec, _activeCancel!);
      outcome = _Outcome.completed;
    } on _PreemptedException {
      outcome = _Outcome.preempted;
    } catch (e) {
      error = e;
      outcome = _userCancelled.contains(id)
          ? _Outcome.cancelled
          : _Outcome.failed;
    }

    _activeId = null;
    _activeTier = null;
    _activeCancel = null;
    _busy = false;

    if (_forgotten.remove(id)) {
      // Сообщение удалили, пока файл качался — тихо сносим всё, без
      // failed-события (показывать нечему).
      _userQueue.remove(id);
      _autoQueue.remove(id);
      _progress.remove(id);
      await PartialDownloadStore.discard(id);
      _failWaiters(id, error ?? ApiException('message deleted'));
      _syncForegroundService();
      _pump();
      return;
    }

    switch (outcome) {
      case _Outcome.completed:
        _userQueue.remove(id);
        _autoQueue.remove(id);
        _failedAt.remove(id);
        _progress[id] = 100;
        await PartialDownloadStore.discard(id);
        _doneCtl.add(id);
        _progressCtl.add(id);
        final cache = await MediaCache.fileFor(id);
        _resolveWaiters(id, cache);
      case _Outcome.cancelled:
        _userQueue.remove(id);
        _autoQueue.remove(id);
        await PartialDownloadStore.discard(id);
        _progress.remove(id);
        _failWaiters(id, error ?? ApiException('cancelled'));
        _progressCtl.add(id);
      case _Outcome.failed:
        _userQueue.remove(id);
        _autoQueue.remove(id);
        _progress.remove(id);
        _failedAt[id] = DateTime.now();
        // Хвост НЕ трогаем — повторный тап продолжит с места обрыва.
        DebugLog.log('MediaDownloadManager id=$id download failed: $error');
        _failedCtl.add(id);
        _failWaiters(id, error ?? ApiException('download failed'));
        _progressCtl.add(id);
      case _Outcome.preempted:
        // Остаётся в своей очереди (мы её не трогали) — _pump ниже
        // подхватит новый приоритетный файл, а этот докачается позже.
        DebugLog.log('MediaDownloadManager id=$id preempted, tail kept');
    }

    _syncForegroundService();
    _pump();
  }

  Future<void> _runOne(DownloadSpec spec, dio.CancelToken cancel) async {
    final id = spec.mediaId;
    final cache = await MediaCache.fileFor(id);
    if (await cache.exists()) return;

    final token = await Session.getToken();
    if (token == null) throw ApiException('not logged in');

    final partial = await PartialDownloadStore.fileFor(id);

    int encTotal;
    try {
      encTotal = await _api.downloadEncryptedMediaResumable(
        token,
        id,
        partial,
        onProgress: (p) {
          _progress[id] = p;
          _progressCtl.add(id);
        },
        cancelToken: cancel,
      );
    } on ApiException {
      if (cancel.isCancelled &&
          _preemptRequested &&
          !_userCancelled.contains(id)) {
        throw const _PreemptedException();
      }
      rethrow;
    }

    final have = await partial.exists() ? await partial.length() : 0;
    if (encTotal > 0 && have < encTotal) {
      // Соединение оборвалось посреди потока, но dio не бросил (редко) —
      // считаем неполным, хвост сохраняем, повтор продолжит.
      throw ApiException('incomplete ($have/$encTotal)');
    }

    // Расшифровка собранного хвоста прямо в MediaCache.
    try {
      if (spec.chunked) {
        await StreamingFileCipher.decryptFileToFile(
          inputFile: partial,
          outputFile: cache,
          keyBytes: base64Decode(spec.keyBase64),
        );
      } else {
        final ct = await partial.readAsBytes();
        final plain = await decryptFileBytes(
          key: base64Decode(spec.keyBase64),
          nonce: base64Decode(spec.nonceBase64!),
          mac: base64Decode(spec.macBase64!),
          ciphertext: ct,
        );
        await cache.writeAsBytes(plain);
      }
    } catch (e) {
      // Порча шифротекста / не тот ключ — хвост бесполезен, сносим оба.
      try {
        if (await cache.exists()) await cache.delete();
      } catch (_) {}
      await PartialDownloadStore.discard(id);
      rethrow;
    }
  }

  // ---- ожидающие ensureDownloaded ----

  void _resolveWaiters(String mediaId, File file) {
    final list = _waiters.remove(mediaId);
    if (list == null) return;
    for (final c in list) {
      if (!c.isCompleted) c.complete(file);
    }
  }

  void _failWaiters(String mediaId, Object error) {
    final list = _waiters.remove(mediaId);
    if (list == null) return;
    for (final c in list) {
      if (!c.isCompleted) c.completeError(error);
    }
  }
}
