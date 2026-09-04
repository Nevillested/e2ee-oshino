import 'dart:async';
import 'dart:io';
import '../crypto/message_envelope.dart';
import '../l10n/app_strings.dart';
import '../models/picked_media.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/chunked_upload_session_store.dart';
import '../storage/peer_account_store.dart';
import '../storage/pending_send_store.dart';
import 'debug_log.dart';
import 'media_download_manager.dart';
import 'media_upload.dart';
import 'message_cleanup.dart';
import 'message_resend.dart';
import 'upload_cancel_registry.dart';
import 'upload_progress_bus.dart';

/// Одна строка очереди «файлы» в панели передач. [id] — id задания (цель
/// ✕); [rowKey] — уникальный ключ строки (у группы = messageId файла).
class UploadRow {
  final String id;
  final String rowKey;
  final String peerLogin;
  final String label;
  final double percent;
  final bool active;
  const UploadRow({
    required this.id,
    required this.rowKey,
    required this.peerLogin,
    required this.label,
    required this.percent,
    required this.active,
  });
}

/// Отличает "файла больше нет, повторять бессмысленно" (задание убираем
/// насовсем) от обычного сетевого сбоя (задание остаётся, повторится само
/// на следующем реконнекте) — раньше оба случая тихо схлопывались в один
/// и тот же "успех" в _attempt (см. разбор пользовательских логов: кнопка
/// "Повторить отправку" выглядела нерабочей именно поэтому — задание уже
/// было удалено первым же фоновым sweep'ом).
class _PermanentRetryFailure implements Exception {
  final String message;
  _PermanentRetryFailure(this.message);
  @override
  String toString() => message;
}

/// Итог одной попытки — нужен вызывающей стороне (см. ChatScreen._retrySend),
/// чтобы дать пользователю честную обратную связь вместо тишины.
enum RetryOutcome { sent, permanentlyFailed, willRetryLater, notFound }

/// Досылает сообщения, которые не удалось даже поставить в
/// SendQueueProcessor — сбой сети ДО готового конверта (загрузка медиа/
/// голосового на сервер, либо получение prekey-бандла для самой первой
/// сессии с собеседником).
///
/// ВАЖНО (ТЗ пользователя): раньше здесь ещё был автоматический фоновый
/// повтор — по реконнекту WebSocket и раз в 20с (см. историю правок,
/// start()/_sweep() ниже) — молча досылал зависшие задания сам, без
/// участия пользователя. Пользователь явно попросил это убрать: заново
/// отправлять — ТОЛЬКО по его собственному нажатию "Повторить отправку"
/// на упавшем сообщении (см. retryNow ниже, единственная оставшаяся точка
/// входа). Задание из PendingSendStore теперь просто лежит и ждёт —
/// сколько угодно, хоть до следующего холодного старта приложения — пока
/// пользователь сам не решит повторить.
///
/// Группы файлов (см. ChatScreen._sendGroupNetwork) тоже покрыты — если
/// ЛЮБОЙ файл группы не пережил сбой сети, вся группа сдаётся окончательно
/// (см. _retryMediaGroup): частичная отправка группы хуже её отсутствия.
class PendingSendRetrier {
  PendingSendRetrier._();
  static final instance = PendingSendRetrier._();
  final Set<String> _inFlight = {};

  bool _started = false;
  bool _workerBusy = false;
  String? _activeId;
  final Map<String, double> _progress = {}; // id/messageId -> %

  /// messageId файлов группы, снятых пользователем через ✕ в панели передач
  /// (по одному, не вся группа). Живёт в памяти на всю сессию — покрывает и
  /// «файл ещё в очереди» и «файл грузится прямо сейчас»; на холодном старте
  /// множество пустое, и правит уже обновлённый в cancelGroupItem
  /// PendingSendStore (файла нет в job['items']).
  final Set<String> _cancelledGroupItems = {};
  final _snapshotCtl = StreamController<void>.broadcast();

  /// Панель передач слушает это (+ UploadProgressBus для процентов).
  Stream<void> get snapshotChanges => _snapshotCtl.stream;

  /// Воркер очереди «файлы» (ТЗ: отдельный поток на любое сообщение с
  /// файлом). Запускается один раз при подключении (см.
  /// home_placeholder._connect). На старте подхватывает задания,
  /// оставшиеся с прошлой сессии / прерванные убийством приложения на
  /// середине загрузки — они докачиваются с места обрыва (ChunkedUpload
  /// Session). Задания с state='failed' (упали по сети) НЕ трогаются — их
  /// перезапускает только "Повторить отправку".
  void start() {
    if (_started) return;
    _started = true;
    UploadProgressBus.stream.listen((e) => _progress[e.$1] = e.$2);
    unawaited(_sweepOrphans());
    _kick();
  }

  /// Свежий процесс — загрузок не идёт: застрявшие в 'sending' медиа без
  /// задания помечаем 'failed' (см. ChatStore.failOrphanedSendingMedia).
  Future<void> _sweepOrphans() async {
    try {
      final jobs = await PendingSendStore.getAll();
      final ids = jobs.map((j) => j['id'] as String).toSet();
      await ChatStore.failOrphanedSendingMedia(ids);
    } catch (e) {
      DebugLog.log('PendingSendRetrier _sweepOrphans failed: $e');
    }
  }

  /// Поставить новое задание в очередь файлов и запустить воркер.
  Future<void> enqueue(Map<String, dynamic> job) async {
    await PendingSendStore.add(job);
    _snapshotCtl.add(null);
    _kick();
  }

  void _kick() {
    if (_workerBusy) return;
    _workerBusy = true;
    unawaited(_worker());
  }

  Future<void> _worker() async {
    try {
      while (true) {
        final jobs = await PendingSendStore.getAll();
        Map<String, dynamic>? next;
        for (final j in jobs) {
          if (j['state'] == 'failed') continue;
          if (_inFlight.contains(j['id'] as String)) continue;
          next = j;
          break;
        }
        if (next == null) break;
        MediaDownloadManager.instance.setFileUploadActive(true);
        _activeId = next['id'] as String;
        _snapshotCtl.add(null);
        await _attempt(next);
        _activeId = null;
        _snapshotCtl.add(null);
      }
    } finally {
      _workerBusy = false;
      _activeId = null;
      MediaDownloadManager.instance.setFileUploadActive(false);
      _snapshotCtl.add(null);
    }
  }

  /// "Повторить отправку" из контекстного меню сообщения. id — messageId
  /// одиночного сообщения или groupId группы. notFound — задания уже нет.
  Future<RetryOutcome> retryNow(String id) async {
    final jobs = await PendingSendStore.getAll();
    Map<String, dynamic>? job;
    for (final j in jobs) {
      if (j['id'] == id) {
        job = j;
        break;
      }
    }
    if (job == null) return RetryOutcome.notFound;
    job['state'] = 'queued';
    await PendingSendStore.add(Map<String, dynamic>.from(job));
    // Часики вместо «!» сразу (ТЗ), а сама отправка — уже в воркере.
    final peerLogin = job['peer_login'] as String?;
    if (peerLogin != null) {
      for (final mid in _messageIdsFor(job)) {
        await ChatStore.markRetrying(peerLogin, mid, tr('chat.queued'));
      }
    }
    _snapshotCtl.add(null);
    _kick();
    return RetryOutcome.sent;
  }

  /// ✕ на строке очереди файлов в панели передач — то же, что «Отменить
  /// отправку» на пузыре в чате: прервать активную загрузку, удалить
  /// сообщение(я) и все следы, убрать задание.
  Future<void> cancelJob(String id) async {
    final jobs = await PendingSendStore.getAll();
    Map<String, dynamic>? job;
    for (final j in jobs) {
      if (j['id'] == id) {
        job = j;
        break;
      }
    }
    if (job == null) return;
    final peerLogin = job['peer_login'] as String?;
    for (final mid in _messageIdsFor(job)) {
      UploadCancelRegistry.cancel(mid);
    }
    if (peerLogin != null) {
      await cancelOutgoingMessages(peerLogin, _messageIdsFor(job));
    }
    await PendingSendStore.remove(id);
    _snapshotCtl.add(null);
  }

  /// ✕ на ОДНОМ файле группы в панели передач (ТЗ пользователя): убрать
  /// именно этот файл из группы и продолжить грузить остальные. Если это
  /// был последний файл группы — не отправляется вообще ничего, включая
  /// подпись (текст-сообщение группы).
  Future<void> cancelGroupItem(String jobId, String messageId) async {
    _cancelledGroupItems.add(messageId);
    // Оборвать загрузку этого файла, если он грузится прямо сейчас.
    UploadCancelRegistry.cancel(messageId);

    final jobs = await PendingSendStore.getAll();
    Map<String, dynamic>? job;
    for (final j in jobs) {
      if (j['id'] == jobId) {
        job = j;
        break;
      }
    }
    if (job == null || job['kind'] != 'media_group') {
      // Не группа (или задания уже нет) — трактуем как отмену целиком.
      return cancelJob(jobId);
    }
    final peerLogin = job['peer_login'] as String?;
    final items = (job['items'] as List).cast<Map<String, dynamic>>();
    final remaining = items
        .where((it) => it['message_id'] != messageId)
        .toList();
    final textId = job['text_message_id'] as String?;

    // cancelOutgoingMessages -> purgeMessageArtifacts снесёт задание целиком
    // по groupId — поэтому сначала полная зачистка удаляемого файла, потом
    // (если что-то осталось) заново кладём урезанное задание.
    if (peerLogin != null) {
      await cancelOutgoingMessages(peerLogin, [messageId]);
    }

    if (remaining.isEmpty) {
      // Отменили все файлы группы → не отправляем ничего, включая подпись.
      if (peerLogin != null && textId != null) {
        await cancelOutgoingMessages(peerLogin, [textId]);
      }
      await PendingSendStore.remove(jobId);
    } else {
      job['items'] = remaining;
      await PendingSendStore.add(Map<String, dynamic>.from(job));
    }
    _snapshotCtl.add(null);
    _kick();
  }

  /// Снапшот очереди файлов для панели передач — активное сверху, дальше в
  /// порядке очереди. Группа разворачивается в ОТДЕЛЬНУЮ строку на каждый
  /// файл (ТЗ пользователя — не «группа как один файл»); ✕ на строке файла
  /// группы убирает только этот файл (см. cancelGroupItem), ✕ на одиночном
  /// файле — всё задание. Упавшие (state='failed') не показываем.
  List<UploadRow> snapshot(List<Map<String, dynamic>> jobs) {
    final rows = <UploadRow>[];
    for (final j in jobs) {
      if (j['state'] == 'failed') continue;
      final jobId = j['id'] as String;
      // Заметки — показываем «Заметки» вместо служебного логина __notes__.
      final peer = j['notes'] == true
          ? tr('home.notes')
          : (j['peer_login'] as String? ?? '');
      final active = jobId == _activeId;
      if (j['kind'] == 'media_group') {
        final items = (j['items'] as List).cast<Map<String, dynamic>>();
        for (final it in items) {
          final mid = it['message_id'] as String;
          rows.add(
            UploadRow(
              id: jobId,
              rowKey: mid,
              peerLogin: peer,
              label: it['file_name'] as String? ?? tr('media.file'),
              percent: _progress[mid] ?? 0,
              active: active,
            ),
          );
        }
      } else {
        rows.add(
          UploadRow(
            id: jobId,
            rowKey: jobId,
            peerLogin: peer,
            label: _jobLabel(j),
            percent: _progress[jobId] ?? 0,
            active: active,
          ),
        );
      }
    }
    rows.sort((a, b) {
      if (a.active != b.active) return a.active ? -1 : 1;
      return 0;
    });
    return rows;
  }

  static String _jobLabel(Map<String, dynamic> j) {
    switch (j['kind'] as String?) {
      case 'voice':
        return tr('media.voiceNote');
      case 'video_note':
        return tr('media.videoNote');
      default:
        return j['file_name'] as String? ?? tr('media.file');
    }
  }

  Future<RetryOutcome> _attempt(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    // Тот же приём, что и в SendQueueProcessor._inFlight — не даём двум
    // конкурентным sweep'ам запустить вторую параллельную попытку поверх
    // уже идущей для одного и того же id.
    if (_inFlight.contains(id)) return RetryOutcome.willRetryLater;
    _inFlight.add(id);
    final peerLogin = job['peer_login'] as String?;
    // ТЗ пользователя: "восклицательный знак сменяется на часики, и
    // отправка повторяется ещё раз" — отмечаем ВСЕ затрагиваемые этим
    // заданием сообщения как "отправляется снова" ДО начала самой попытки
    // (а не только по её итогу), и возвращаем обратно в 'failed', если
    // попытка не удалась — единая точка для всех видов заданий (см.
    // _messageIdsFor), вместо дублирования в каждом _retryXxx.
    final messageIds = _messageIdsFor(job);
    if (peerLogin != null) {
      for (final mid in messageIds) {
        await ChatStore.markRetrying(peerLogin, mid, tr('chat.queued'));
      }
    }
    try {
      final kind = job['kind'] as String;
      switch (kind) {
        case 'text':
          await _retryText(job);
          break;
        case 'voice':
        case 'video_note':
          await _retryMediaLike(job, isVoiceOrVideoNote: true);
          break;
        case 'media':
          await _retryMediaLike(job, isVoiceOrVideoNote: false);
          break;
        case 'media_group':
          await _retryMediaGroup(job);
          break;
        default:
          DebugLog.log(
            'PendingSendRetrier id=$id unknown job kind=$kind — dropping',
          );
          await PendingSendStore.remove(id);
          return RetryOutcome.permanentlyFailed;
      }
      await PendingSendStore.remove(id);
      return RetryOutcome.sent;
    } on _PermanentRetryFailure catch (e) {
      if (peerLogin != null) {
        for (final mid in messageIds) {
          await ChatStore.updateMessageStatus(peerLogin, mid, 'failed');
        }
      }
      await PendingSendStore.remove(id);
      DebugLog.log('PendingSendRetrier id=$id permanently abandoned: $e');
      return RetryOutcome.permanentlyFailed;
    } catch (e) {
      if (peerLogin != null) {
        for (final mid in messageIds) {
          await ChatStore.updateMessageStatus(peerLogin, mid, 'failed');
        }
      }
      // ТЗ: упавшее по сети → "!" в чате, дальше ТОЛЬКО по "Повторить".
      // Помечаем задание failed и оставляем в PendingSendStore — воркер
      // его больше не берёт, а частичный прогресс (ChunkedUploadSession +
      // enc-файл) сохраняется для докачки при "Повторить".
      job['state'] = 'failed';
      await PendingSendStore.add(Map<String, dynamic>.from(job));
      _snapshotCtl.add(null);
      DebugLog.log('PendingSendRetrier id=$id send-FAILED error=$e — marked failed');
      return RetryOutcome.willRetryLater;
    } finally {
      _inFlight.remove(id);
    }
  }

  /// Все messageId, которые затрагивает это задание — одиночное сообщение
  /// (text/voice/video_note/media, id самого задания и есть его messageId)
  /// либо группа (media_group — свой messageId у каждого файла плюс,
  /// отдельно, у текста-подписи, если она была).
  List<String> _messageIdsFor(Map<String, dynamic> job) {
    if (job['kind'] == 'media_group') {
      final items = (job['items'] as List).cast<Map<String, dynamic>>();
      final ids = items.map((i) => i['message_id'] as String).toList();
      final textId = job['text_message_id'] as String?;
      if (textId != null) ids.add(textId);
      return ids;
    }
    return [job['id'] as String];
  }

  Future<void> _retryText(Map<String, dynamic> job) async {
    final peerLogin = job['peer_login'] as String;
    final peerDeviceId = await MessageResend.resolvePeerDeviceId(
      peerLogin,
      job['peer_device_id'] as String,
    );
    final inner = InnerMessage(
      messageId: job['id'] as String,
      type: 'text',
      sentAt: job['sent_at'] as int,
      body: job['text'] as String,
      replyToMessageId: job['reply_to_id'] as String?,
      replyToPreview: job['reply_to_preview'] as String?,
    );
    await MessageResend.sendEnvelope(
      peerDeviceId: peerDeviceId,
      peerLogin: peerLogin,
      inner: inner,
    );
  }

  /// Общий путь для voice/video_note/media — во всех трёх сначала заново
  /// грузится локальный файл (см. uploadAndDescribeMedia), затем строится
  /// InnerMessage нужного типа и отправляется тем же MessageResend.
  Future<void> _retryMediaLike(
    Map<String, dynamic> job, {
    required bool isVoiceOrVideoNote,
  }) async {
    final id = job['id'] as String;
    final file = File(job['file_path'] as String);
    if (!await file.exists()) {
      // Оригинал пропал (очистка кэша приложения — путь пикера обычно
      // именно там). Если чанковая загрузка уже началась, её
      // зашифрованный enc-файл + сессия лежат в applicationSupport и
      // чистку кэша переживают — дозаливаем из них, оригинал не нужен.
      final resumable = await ChunkedUploadSessionStore.get(id) != null;
      if (!resumable) {
        DebugLog.log(
          'PendingSendRetrier id=$id source gone and not resumable — permanent',
        );
        throw _PermanentRetryFailure('local file missing');
      }
      DebugLog.log(
        'PendingSendRetrier id=$id source gone but chunked session exists — resuming',
      );
    }
    // Заметки (чат с самим собой) — конверта Double Ratchet нет: файл
    // грузится ровно так же, а по завершении сообщение просто помечается
    // 'sent'. peerDeviceId не нужен, «получатель» загрузки — свой аккаунт.
    final notes = job['notes'] == true;
    final peerLogin = job['peer_login'] as String;
    final token = await Session.getToken();
    if (token == null) {
      throw Exception('not logged in, cannot retry media upload');
    }
    final String peerDeviceId;
    final String peerAccountId;
    if (notes) {
      peerDeviceId = '';
      peerAccountId =
          await Session.getAccountId() ??
          job['peer_account_id'] as String? ??
          '';
    } else {
      peerDeviceId = await MessageResend.resolvePeerDeviceId(
        peerLogin,
        job['peer_device_id'] as String,
      );
      peerAccountId =
          await PeerAccountStore.get(peerDeviceId) ??
          job['peer_account_id'] as String;
    }
    final size = job['size'] as int;

    final bool isVideo;
    final String fileName;
    final bool isFile;
    final bool isSpoiler;
    if (isVoiceOrVideoNote) {
      isVideo = job['kind'] == 'video_note';
      fileName = isVideo ? 'video_note.mp4' : 'voice.m4a';
      isFile = false;
      isSpoiler = false;
    } else {
      isVideo = job['is_video'] as bool? ?? false;
      fileName = job['file_name'] as String;
      isFile = job['is_file'] as bool? ?? false;
      isSpoiler = job['is_spoiler'] as bool? ?? false;
    }

    final desc = await uploadAndDescribeMedia(
      peerLogin: peerLogin,
      item: PickedMedia(
        file: file,
        isVideo: isVideo,
        isFile: isFile,
        isSpoiler: isSpoiler,
      ),
      messageId: id,
      size: size,
      fileName: fileName,
      token: token,
      peerAccountIdForUpload: peerAccountId,
      onProgress: (percent) => UploadProgressBus.emit(id, percent),
    );

    if (notes) {
      // uploadAndDescribeMedia уже записал mediaId/key/nonce в StoredMessage
      // (ChatStore.updateMediaInfo) — осталось только пометить отправленным.
      await ChatStore.updateMessageStatus(peerLogin, id, 'sent');
      if (isVoiceOrVideoNote || job['persisted'] == true) {
        await PendingSendStore.deletePersistedFile(file.path);
      }
      return;
    }

    final InnerMessage inner;
    if (isVoiceOrVideoNote) {
      final durationMs = job['duration_ms'] as int;
      inner = isVideo
          ? InnerMessage.videoNote(
              messageId: id,
              mediaId: desc['media_id'] as String,
              keyBase64: desc['key'] as String,
              nonceBase64: desc['nonce'] as String?,
              macBase64: desc['mac'] as String?,
              fileSize: size,
              chunked: desc['chunked'] as bool,
              durationMs: durationMs,
            )
          : InnerMessage.voice(
              messageId: id,
              mediaId: desc['media_id'] as String,
              keyBase64: desc['key'] as String,
              nonceBase64: desc['nonce'] as String?,
              macBase64: desc['mac'] as String?,
              fileSize: size,
              chunked: desc['chunked'] as bool,
              durationMs: durationMs,
            );
    } else {
      inner = InnerMessage.media(
        messageId: id,
        mediaId: desc['media_id'] as String,
        keyBase64: desc['key'] as String,
        nonceBase64: desc['nonce'] as String?,
        macBase64: desc['mac'] as String?,
        fileName: fileName,
        isFile: isFile,
        isVideo: isVideo,
        fileSize: size,
        chunked: desc['chunked'] as bool,
        spoiler: isSpoiler,
        replyToMessageId: job['reply_to_id'] as String?,
        replyToPreview: job['reply_to_preview'] as String?,
      );
    }

    await MessageResend.sendEnvelope(
      peerDeviceId: peerDeviceId,
      peerLogin: peerLogin,
      inner: inner,
    );
    // Удаляем file, только если это НАША копия (голосовое/видео-кружок
    // всегда; мелкое 'media' < 20 МБ — job['persisted']==true). Оригинал
    // пикера у больших 'media' не трогаем.
    if (isVoiceOrVideoNote || job['persisted'] == true) {
      await PendingSendStore.deletePersistedFile(file.path);
    }
  }

  /// Группа файлов (см. ChatScreen._sendGroupNetwork). Файл, снятый
  /// пользователем через ✕ в панели передач (см. cancelGroupItem /
  /// _cancelledGroupItems), молча выкидывается и грузятся остальные; если
  /// не осталось ни одного файла — не отправляется ничего, включая подпись.
  /// А вот сетевой сбой на любом ОСТАВШЕМСЯ файле по-прежнему роняет всю
  /// группу окончательно: частичная отправка группы хуже её отсутствия.
  Future<void> _retryMediaGroup(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    final rawItems = (job['items'] as List).cast<Map<String, dynamic>>();

    final notes = job['notes'] == true;
    final peerLogin = job['peer_login'] as String;
    final token = await Session.getToken();
    if (token == null) {
      throw Exception('not logged in, cannot retry media group upload');
    }
    final String peerDeviceId;
    final String peerAccountId;
    if (notes) {
      peerDeviceId = '';
      peerAccountId =
          await Session.getAccountId() ??
          job['peer_account_id'] as String? ??
          '';
    } else {
      peerDeviceId = await MessageResend.resolvePeerDeviceId(
        peerLogin,
        job['peer_device_id'] as String,
      );
      peerAccountId =
          await PeerAccountStore.get(peerDeviceId) ??
          job['peer_account_id'] as String;
    }

    final uploaded = <Map<String, dynamic>>[];
    final ackItems = <Map<String, dynamic>>[];
    final textMessageId = job['text_message_id'] as String?;

    for (var i = 0; i < rawItems.length; i++) {
      final item = rawItems[i];
      final mid = item['message_id'] as String;
      // ✕ по одному файлу группы в панели передач — файла больше нет в
      // задании: пропускаем и грузим остальные (ТЗ пользователя).
      if (_cancelledGroupItems.contains(mid) ||
          !await _groupStillHasItem(id, mid)) {
        continue;
      }

      final file = File(item['file_path'] as String);
      if (!await file.exists()) {
        // Оригинал пропал (чистка кэша). Если чанковая загрузка этого
        // файла уже началась — её enc-файл в applicationSupport цел,
        // дозаливаем из него. Иначе вся группа окончательно провалена.
        final resumable = await ChunkedUploadSessionStore.get(mid) != null;
        if (!resumable) {
          DebugLog.log(
            'PendingSendRetrier id=$id media_group file gone & not resumable — '
            'giving up on the whole group permanently (${file.path})',
          );
          throw _PermanentRetryFailure('local file missing in group');
        }
      }

      try {
        final desc = await uploadAndDescribeMedia(
          peerLogin: peerLogin,
          item: PickedMedia(
            file: file,
            isVideo: item['is_video'] as bool? ?? false,
            isFile: item['is_file'] as bool? ?? false,
            isSpoiler: item['is_spoiler'] as bool? ?? false,
          ),
          messageId: mid,
          size: item['size'] as int,
          fileName: item['file_name'] as String,
          token: token,
          peerAccountIdForUpload: peerAccountId,
          onProgress: (percent) {
            UploadProgressBus.emit(mid, percent);
            // Прогресс всей группы — для строки в панели передач (ключ = id
            // группы): доля уже залитых файлов + доля текущего.
            UploadProgressBus.emit(
              id,
              (i + percent / 100) / rawItems.length * 100,
            );
          },
        );
        uploaded.add(desc);
        ackItems.add(item);
      } catch (e) {
        // Файл отменён пользователем прямо во время загрузки (dio бросает
        // отмену) — группу не роняем, идём дальше. Любой другой сбой —
        // это настоящая ошибка сети, вся группа окончательно падает.
        if (_cancelledGroupItems.contains(mid) ||
            !await _groupStillHasItem(id, mid)) {
          DebugLog.log(
            'PendingSendRetrier id=$id group item $mid cancelled mid-upload: $e',
          );
          continue;
        }
        rethrow;
      }
    }

    if (uploaded.isEmpty) {
      // Все файлы группы отменены → не отправляем НИЧЕГО, даже подпись (ТЗ).
      if (textMessageId != null) {
        await cancelOutgoingMessages(peerLogin, [textMessageId]);
      }
      DebugLog.log(
        'PendingSendRetrier id=$id all group items cancelled — nothing sent',
      );
      return;
    }

    if (notes) {
      // Заметки — конверта нет: файлы залиты (mediaId/key уже в StoredMessage),
      // просто помечаем всю группу и подпись отправленными.
      if (textMessageId != null) {
        await ChatStore.updateMessageStatus(peerLogin, textMessageId, 'sent');
      }
      for (final item in ackItems) {
        await ChatStore.updateMessageStatus(
          peerLogin,
          item['message_id'] as String,
          'sent',
        );
        if (item['persisted'] == true) {
          await PendingSendStore.deletePersistedFile(
            item['file_path'] as String,
          );
        }
      }
      return;
    }

    final inner = InnerMessage.mediaGroup(
      groupId: id,
      messageId: id,
      caption: job['caption'] as String?,
      textMessageId: textMessageId,
      files: uploaded,
    );

    await MessageResend.sendEnvelope(
      peerDeviceId: peerDeviceId,
      peerLogin: peerLogin,
      inner: inner,
      onAcked: () async {
        if (textMessageId != null) {
          await ChatStore.updateMessageStatus(peerLogin, textMessageId, 'sent');
        }
        for (final item in ackItems) {
          await ChatStore.updateMessageStatus(
            peerLogin,
            item['message_id'] as String,
            'sent',
          );
        }
      },
    );
    // Удаляем только НАШИ копии (мелкие файлы, persisted==true); большие —
    // это оригиналы пикера, не трогаем.
    for (final item in ackItems) {
      if (item['persisted'] == true) {
        await PendingSendStore.deletePersistedFile(item['file_path'] as String);
      }
    }
  }

  /// Файл ещё числится в группе [jobId] в PendingSendStore? false — либо
  /// пользователь снял его через ✕ (cancelGroupItem), либо задания уже нет.
  Future<bool> _groupStillHasItem(String jobId, String messageId) async {
    final jobs = await PendingSendStore.getAll();
    for (final j in jobs) {
      if (j['id'] != jobId) continue;
      final items =
          (j['items'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      return items.any((it) => it['message_id'] == messageId);
    }
    return false;
  }
}
