import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' as dio;

import '../api/api_client.dart';
import '../crypto/media_cipher.dart';
import '../crypto/streaming_file_cipher.dart';
import '../l10n/app_strings.dart';
import '../session.dart';
import '../storage/download_queue_store.dart';
import '../storage/media_cache.dart';
import '../storage/partial_download_store.dart';
import 'debug_log.dart';
import 'media_download_foreground.dart';

/// Всё, что движку нужно, чтобы скачать и расшифровать один файл без экрана
/// чата. Строится из StoredMessage вызывающей стороной и персистится в
/// DownloadQueueStore (переживает перезапуск приложения).
class DownloadSpec {
  final String mediaId;
  final String keyBase64;
  final bool chunked;

  /// nonce/mac — только для НЕчанкованных файлов; у чанкованных null.
  final String? nonceBase64;
  final String? macBase64;

  /// Размер ОТКРЫТОГО файла — по нему решается, годится ли файл в
  /// авто-очередь (< 3 МБ).
  final int plaintextSize;

  /// Для панели передач: с кем чат и что за файл.
  final String peerLogin;
  final String label;

  const DownloadSpec({
    required this.mediaId,
    required this.keyBase64,
    required this.chunked,
    required this.plaintextSize,
    required this.peerLogin,
    required this.label,
    this.nonceBase64,
    this.macBase64,
  });

  Map<String, dynamic> toMap() => {
    'mediaId': mediaId,
    'key': keyBase64,
    'chunked': chunked,
    'nonce': nonceBase64,
    'mac': macBase64,
    'size': plaintextSize,
    'peer': peerLogin,
    'label': label,
  };

  static DownloadSpec fromMap(Map<String, dynamic> m) => DownloadSpec(
    mediaId: m['mediaId'] as String,
    keyBase64: m['key'] as String,
    chunked: m['chunked'] as bool? ?? false,
    nonceBase64: m['nonce'] as String?,
    macBase64: m['mac'] as String?,
    plaintextSize: m['size'] as int? ?? 0,
    peerLogin: m['peer'] as String? ?? '',
    label: m['label'] as String? ?? '',
  );
}

/// Одна строка в панели передач.
class DownloadRow {
  final String mediaId;
  final String peerLogin;
  final String label;
  final double percent; // 0..100
  final bool active; // качается прямо сейчас
  const DownloadRow({
    required this.mediaId,
    required this.peerLogin,
    required this.label,
    required this.percent,
    required this.active,
  });
}

class DownloadSnapshot {
  final List<DownloadRow> manual;
  final List<DownloadRow> auto;
  const DownloadSnapshot(this.manual, this.auto);
}

/// Движок скачивания медиа. **Два независимых потока** (ТЗ пользователя):
///
///  * **ручной** — файлы, по иконке скачивания которых человек нажал сам.
///    Строгий FIFO: нажал файл1, файл2, файл3 → так и качаются. Без
///    ограничения по числу и размеру. ✕ = стоп + удалить скачанное + файл
///    выбывает из очереди.
///  * **авто** — файлы < 3 МБ, которые пользователь пролистал в чате.
///    Строгий FIFO в порядке появления снизу экрана. Не чистится при
///    прокрутке (раз попал — рано или поздно скачается).
///
/// Потоки работают ПАРАЛЛЕЛЬНО и не вытесняют друг друга. Внутри потока —
/// строго по очереди, без вытеснения. Обе очереди персистятся
/// (DownloadQueueStore) + недокачанные байты (PartialDownloadStore,
/// `.part`) — на старте приложения обе докачиваются с места обрыва.
///
/// Ратчета не касается вообще: файл шифруется отдельным AES-ключом, ключ
/// пришёл в уже расшифрованном конверте (message_router, там приём
/// сериализован). Никакого общего изменяемого крипто-состояния между
/// потоками нет.
class MediaDownloadManager {
  MediaDownloadManager._();
  static final MediaDownloadManager instance = MediaDownloadManager._();

  static const int autoDownloadLimitBytes = 3 * 1024 * 1024; // 3 МБ
  static const int _networkRetries = 3;
  static const Duration _failCooldown = Duration(seconds: 20);

  final ApiClient _api = ApiClient();

  final Map<String, DownloadSpec> _specs = {};
  final List<String> _manualQueue = []; // [0] = активный/следующий
  final List<String> _autoQueue = [];
  final Set<String> _userCancelled = {};
  final Map<String, DateTime> _failedAt = {}; // кулдаун авто-повторов
  final Set<String> _dropPartial = {}; // отменённые — снести хвост
  final Set<String> _forgotten = {}; // сообщение удалено во время загрузки

  String? _manualActive;
  String? _autoActive;
  dio.CancelToken? _manualCancel;
  dio.CancelToken? _autoCancel;
  bool _manualBusy = false;
  bool _autoBusy = false;

  final Map<String, double> _progress = {};
  final Map<String, List<Completer<File>>> _waiters = {};

  final _progressCtl = StreamController<String>.broadcast();
  final _doneCtl = StreamController<String>.broadcast();
  final _failedCtl = StreamController<String>.broadcast();
  final _snapshotCtl = StreamController<void>.broadcast();

  Stream<String> get progressChanges => _progressCtl.stream;
  Stream<String> get done => _doneCtl.stream;
  Stream<String> get failed => _failedCtl.stream;

  /// Панель передач слушает это + progressChanges.
  Stream<void> get snapshotChanges => _snapshotCtl.stream;

  Timer? _persistTimer;
  bool _initDone = false;

  /// upload-менеджер сообщает, идёт ли сейчас загрузка файла — нужно для
  /// решения, держать ли foreground-сервис (ТЗ: FGS живёт, пока непуста
  /// ручная очередь скачивания ИЛИ идёт загрузка файла).
  bool _fileUploadActive = false;
  void setFileUploadActive(bool active) {
    if (_fileUploadActive == active) return;
    _fileUploadActive = active;
    _syncForegroundService();
  }

  double? progressOf(String mediaId) => _progress[mediaId];
  bool isActive(String mediaId) =>
      _manualActive == mediaId || _autoActive == mediaId;
  bool isQueued(String mediaId) =>
      (_manualQueue.contains(mediaId) || _autoQueue.contains(mediaId)) &&
      !isActive(mediaId);
  bool isWorking(String mediaId) =>
      _manualQueue.contains(mediaId) || _autoQueue.contains(mediaId);

  // ---- запуск / персист ----

  Future<void> init() async {
    if (_initDone) return;
    _initDone = true;
    final saved = await DownloadQueueStore.load();
    for (final m in [...saved.manual, ...saved.auto]) {
      try {
        final spec = DownloadSpec.fromMap(m);
        _specs[spec.mediaId] = spec;
      } catch (_) {}
    }
    _manualQueue.addAll(
      saved.manual
          .map((m) => m['mediaId'] as String?)
          .whereType<String>()
          .where(_specs.containsKey),
    );
    _autoQueue.addAll(
      saved.auto
          .map((m) => m['mediaId'] as String?)
          .whereType<String>()
          .where(_specs.containsKey),
    );
    _kickManual();
    _kickAuto();
    _emitSnapshot();
    _syncForegroundService();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), _persistNow);
  }

  Future<void> _persistNow() async {
    List<Map<String, dynamic>> dump(List<String> q) => q
        .map((id) => _specs[id]?.toMap())
        .whereType<Map<String, dynamic>>()
        .toList();
    await DownloadQueueStore.save(dump(_manualQueue), dump(_autoQueue));
  }

  void _emitSnapshot() {
    if (!_snapshotCtl.isClosed) _snapshotCtl.add(null);
  }

  // ---- вход от экрана чата ----

  /// Пользователь нажал на иконку скачивания — в конец РУЧНОЙ очереди.
  void requestUserDownload(DownloadSpec spec) {
    _specs[spec.mediaId] = spec;
    _userCancelled.remove(spec.mediaId);
    _failedAt.remove(spec.mediaId);
    _autoQueue.remove(spec.mediaId);
    if (!_manualQueue.contains(spec.mediaId)) _manualQueue.add(spec.mediaId);
    _schedulePersist();
    _emitSnapshot();
    _kickManual();
    _syncForegroundService();
  }

  /// Экран чата сообщает медиа, которые СЕЙЧАС на экране, в порядке снизу
  /// вверх. Мелкие (< 3 МБ) не свои нескачанные добавляются в КОНЕЦ
  /// авто-очереди, если их там ещё нет (без переупорядочивания).
  void setVisible(Iterable<DownloadSpec> specs) {
    var changed = false;
    for (final s in specs) {
      _specs[s.mediaId] = s;
      if (s.plaintextSize >= autoDownloadLimitBytes) continue;
      if (_userCancelled.contains(s.mediaId)) continue;
      if (_inCooldown(s.mediaId)) continue;
      if (_manualQueue.contains(s.mediaId)) continue;
      if (_autoQueue.contains(s.mediaId)) continue;
      if (MediaCache.existsSync(s.mediaId)) continue;
      _autoQueue.add(s.mediaId);
      changed = true;
    }
    if (changed) {
      _schedulePersist();
      _emitSnapshot();
      _kickAuto();
    }
  }

  /// ✕ в панели / в чате: стоп + удалить скачанное + выбывает из очереди.
  void cancelUserDownload(String mediaId) {
    _userCancelled.add(mediaId);
    _dropPartial.add(mediaId);
    _progress.remove(mediaId);
    final wasManual = _manualQueue.remove(mediaId);
    final wasAuto = _autoQueue.remove(mediaId);
    if (_manualActive == mediaId) {
      _manualCancel?.cancel('user cancelled');
    } else if (_autoActive == mediaId) {
      _autoCancel?.cancel('user cancelled');
    } else if (wasManual || wasAuto) {
      unawaited(PartialDownloadStore.discard(mediaId));
      _dropPartial.remove(mediaId);
      _failWaiters(mediaId, ApiException('cancelled'));
    }
    _schedulePersist();
    _emitSnapshot();
    _syncForegroundService();
  }

  /// Сообщение удалено — забыть про файл целиком (в т.ч. снести хвост).
  void forget(String mediaId) {
    _forgotten.add(mediaId);
    _dropPartial.add(mediaId);
    _userCancelled.remove(mediaId);
    _progress.remove(mediaId);
    _manualQueue.remove(mediaId);
    _autoQueue.remove(mediaId);
    if (_manualActive == mediaId) {
      _manualCancel?.cancel('forgotten');
    } else if (_autoActive == mediaId) {
      _autoCancel?.cancel('forgotten');
    } else {
      _specs.remove(mediaId);
      unawaited(PartialDownloadStore.discard(mediaId));
      _dropPartial.remove(mediaId);
      _forgotten.remove(mediaId);
      _failWaiters(mediaId, ApiException('message deleted'));
    }
    _schedulePersist();
    _emitSnapshot();
    _syncForegroundService();
  }

  /// Императивный путь «открыть / проиграть / просмотрщик / кадр-превью».
  /// userInitiated true — как явный тап (ручная очередь); false — тихо в
  /// авто-очередь (для превью того, что и так на экране).
  Future<File> ensureDownloaded(
    DownloadSpec spec,
    {bool userInitiated = true}
  ) async {
    final cache = await MediaCache.fileFor(spec.mediaId);
    if (await cache.exists()) return cache;

    if (!userInitiated &&
        !_manualQueue.contains(spec.mediaId) &&
        !isActive(spec.mediaId) &&
        (_inCooldown(spec.mediaId) ||
            _userCancelled.contains(spec.mediaId))) {
      // Не дёргаем сервер прямо сейчас — вызывающий (FutureBuilder плитки)
      // получит ошибку и покажет «повторить», а setVisible после кулдауна
      // подхватит сам.
      throw ApiException('download on cooldown');
    }

    _specs[spec.mediaId] = spec;
    _userCancelled.remove(spec.mediaId);
    final completer = Completer<File>();
    _waiters.putIfAbsent(spec.mediaId, () => []).add(completer);

    if (userInitiated) {
      _failedAt.remove(spec.mediaId);
      _autoQueue.remove(spec.mediaId);
      if (!_manualQueue.contains(spec.mediaId)) {
        _manualQueue.add(spec.mediaId);
      }
      _kickManual();
    } else if (!_manualQueue.contains(spec.mediaId) &&
        !_autoQueue.contains(spec.mediaId)) {
      _autoQueue.add(spec.mediaId);
      _kickAuto();
    }
    _schedulePersist();
    _emitSnapshot();
    _syncForegroundService();
    return completer.future;
  }

  // ---- воркеры ----

  void _kickManual() {
    if (_manualBusy) return;
    _manualBusy = true;
    unawaited(_manualLoop());
  }

  void _kickAuto() {
    if (_autoBusy) return;
    _autoBusy = true;
    unawaited(_autoLoop());
  }

  Future<void> _manualLoop() async {
    try {
      while (_manualQueue.isNotEmpty) {
        final id = _manualQueue.first;
        final spec = _specs[id];
        if (spec == null) {
          _manualQueue.removeAt(0);
          continue;
        }
        _manualActive = id;
        _manualCancel = dio.CancelToken();
        _emitSnapshot();
        _syncForegroundService();
        final outcome = await _drive(spec, _manualCancel!);
        _manualActive = null;
        _manualCancel = null;
        await _handleOutcome(id, outcome, _manualQueue);
      }
    } finally {
      _manualBusy = false;
      _manualActive = null;
      _syncForegroundService();
      _emitSnapshot();
    }
  }

  Future<void> _autoLoop() async {
    try {
      while (_autoQueue.isNotEmpty) {
        final id = _autoQueue.first;
        final spec = _specs[id];
        if (spec == null) {
          _autoQueue.removeAt(0);
          continue;
        }
        _autoActive = id;
        _autoCancel = dio.CancelToken();
        _emitSnapshot();
        final outcome = await _drive(spec, _autoCancel!);
        _autoActive = null;
        _autoCancel = null;
        await _handleOutcome(id, outcome, _autoQueue);
      }
    } finally {
      _autoBusy = false;
      _autoActive = null;
      _emitSnapshot();
    }
  }

  Future<_Outcome> _drive(DownloadSpec spec, dio.CancelToken cancel) async {
    try {
      await _runOne(spec, cancel);
      return _Outcome.completed;
    } catch (e) {
      if (_forgotten.contains(spec.mediaId)) return _Outcome.forgotten;
      if (_userCancelled.contains(spec.mediaId)) return _Outcome.cancelled;
      DebugLog.log('MediaDownloadManager id=${spec.mediaId} failed: $e');
      return _Outcome.failed;
    }
  }

  Future<void> _handleOutcome(
    String id,
    _Outcome outcome,
    List<String> queue,
  ) async {
    queue.remove(id);
    switch (outcome) {
      case _Outcome.completed:
        _failedAt.remove(id);
        _progress[id] = 100;
        await PartialDownloadStore.discard(id);
        _doneCtl.add(id);
        _progressCtl.add(id);
        _resolveWaiters(id, await MediaCache.fileFor(id));
      case _Outcome.cancelled:
        _progress.remove(id);
        if (_dropPartial.remove(id)) {
          await PartialDownloadStore.discard(id);
        }
        _failWaiters(id, ApiException('cancelled'));
        _progressCtl.add(id);
      case _Outcome.forgotten:
        _forgotten.remove(id);
        _dropPartial.remove(id);
        _specs.remove(id);
        _progress.remove(id);
        await PartialDownloadStore.discard(id);
        _failWaiters(id, ApiException('message deleted'));
      case _Outcome.failed:
        // Хвост НЕ трогаем — «Повторить» в чате продолжит с места обрыва.
        _progress.remove(id);
        _failedAt[id] = DateTime.now();
        _failedCtl.add(id);
        _failWaiters(id, ApiException('download failed'));
        _progressCtl.add(id);
    }
    _schedulePersist();
    _emitSnapshot();
  }

  Future<void> _runOne(DownloadSpec spec, dio.CancelToken cancel) async {
    final id = spec.mediaId;
    final cache = await MediaCache.fileFor(id);
    if (await cache.exists()) return;

    final token = await Session.getToken();
    if (token == null) throw ApiException('not logged in');

    final partial = await PartialDownloadStore.fileFor(id);

    // Ограниченный повтор на блипах сети — докачка через Range продолжит с
    // уже лежащего хвоста, не с нуля.
    int encTotal = 0;
    var delay = const Duration(seconds: 2);
    void reportDl(double p) {
      _progress[id] = p;
      _progressCtl.add(id);
    }

    for (var attempt = 1; ; attempt++) {
      try {
        try {
          // presigned GET — байты качаются напрямую из MinIO
          // (files.oshino.space), мимо московского сервера. Свежий URL на
          // каждой попытке (истёкший за 2ч заменяется). Тут же полный
          // размер — отдельный HEAD не нужен.
          final presigned = await _api.presignMediaGet(token, id);
          encTotal = await _api.downloadEncryptedMediaResumable(
            token,
            id,
            partial,
            directUrl: presigned.url,
            knownTotalBytes: presigned.sizeBytes > 0
                ? presigned.sizeBytes
                : null,
            onProgress: reportDl,
            cancelToken: cancel,
          );
        } catch (e) {
          if (cancel.isCancelled) rethrow;
          // presigned/Токио недоступны — качаем через московский relay
          // (старый эндпоинт `GET /media/{id}`, тоже с Range-докачкой).
          DebugLog.log('MediaDownloadManager $id presigned GET failed ($e) — relay fallback');
          encTotal = await _api.downloadEncryptedMediaResumable(
            token,
            id,
            partial,
            onProgress: reportDl,
            cancelToken: cancel,
          );
        }
        break;
      } catch (e) {
        if (cancel.isCancelled || attempt >= _networkRetries) rethrow;
        await Future<void>.delayed(delay);
        final doubled = delay * 2;
        delay = doubled > const Duration(seconds: 20)
            ? const Duration(seconds: 20)
            : doubled;
      }
    }

    final have = await partial.exists() ? await partial.length() : 0;
    if (encTotal > 0 && have < encTotal) {
      throw ApiException('incomplete ($have/$encTotal)');
    }

    try {
      if (spec.chunked) {
        await StreamingFileCipher.decryptFileInIsolate(
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
      try {
        if (await cache.exists()) await cache.delete();
      } catch (_) {}
      // Хвост был ПОЛНЫМ по размеру, а расшифровка всё равно упала → байты
      // битые, качаем заново. Неполный хвост оставляем — при повторе
      // Range-докачка дозальёт недостающее, а не 300 МБ с нуля.
      if (encTotal > 0 && have >= encTotal) {
        await PartialDownloadStore.discard(id);
      }
      rethrow;
    }
  }

  // ---- прочее ----

  bool _inCooldown(String mediaId) {
    final t = _failedAt[mediaId];
    return t != null && DateTime.now().difference(t) < _failCooldown;
  }

  bool _fgsOn = false;
  String? _fgsText;
  void _syncForegroundService() {
    // «Скачивание» = непустая ручная очередь (авто-очередь FGS не держит).
    // «Выгрузка» = активная загрузка файла в воркере PendingSendRetrier.
    final downloading = _manualQueue.isNotEmpty;
    final uploading = _fileUploadActive;
    if (!downloading && !uploading) {
      if (_fgsOn) {
        _fgsOn = false;
        _fgsText = null;
        unawaited(MediaDownloadForeground.stop());
      }
      return;
    }
    final key = downloading && uploading
        ? 'notification.downloadingAndUploadingFiles'
        : uploading
        ? 'notification.uploadingFiles'
        : 'notification.downloadingFiles';
    final text = tr(key);
    if (_fgsOn && text == _fgsText) return;
    _fgsOn = true;
    _fgsText = text;
    unawaited(MediaDownloadForeground.start(text: text));
  }

  DownloadSnapshot snapshot() {
    List<DownloadRow> rows(List<String> q, String? active) => q
        .map((id) {
          final s = _specs[id];
          if (s == null) return null;
          return DownloadRow(
            mediaId: id,
            peerLogin: s.peerLogin,
            label: s.label,
            percent: _progress[id] ?? 0,
            active: id == active,
          );
        })
        .whereType<DownloadRow>()
        .toList();
    return DownloadSnapshot(
      rows(_manualQueue, _manualActive),
      rows(_autoQueue, _autoActive),
    );
  }

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

enum _Outcome { completed, failed, cancelled, forgotten }
