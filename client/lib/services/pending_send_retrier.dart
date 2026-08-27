import 'dart:async';
import 'dart:io';
import '../crypto/message_envelope.dart';
import '../models/picked_media.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/peer_account_store.dart';
import '../storage/pending_send_store.dart';
import 'debug_log.dart';
import 'media_upload.dart';
import 'message_resend.dart';
import 'upload_progress_bus.dart';
import 'websocket_service.dart';

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
/// сессии с собеседником). Раньше такой сбой был окончательным: пузырь
/// навсегда оставался 'failed', даже когда сеть возвращалась (см. разбор
/// пользовательских логов voice-сообщения — ТЗ пользователя). Запускается
/// тем же сигналом, что и сам SendQueueProcessor — реконнект WebSocket —
/// плюс один раз при старте, на случай холодного старта с уже накопленной
/// с прошлого раза очередью (SharedPreferences/secure storage переживают
/// перезапуск процесса).
///
/// Группы файлов (см. ChatScreen._sendGroupNetwork) тоже покрыты — если
/// ЛЮБОЙ файл группы не пережил сбой сети, вся группа сдаётся окончательно
/// (см. _retryMediaGroup): частичная отправка группы хуже её отсутствия.
class PendingSendRetrier {
  PendingSendRetrier._();
  static final instance = PendingSendRetrier._();

  bool _started = false;
  final Set<String> _inFlight = {};

  // Реальный кейс с устройства: группа из 3 фото не смогла уйти офлайн —
  // загрузка ПЕРВОГО файла зависла на плохой сети (ещё живой TCP, но без
  // ответа) дольше, чем шёл реконнект WebSocket. Задание попадает в
  // PendingSendStore только когда ЭТА конкретная попытка внутри
  // ChatScreen._sendGroupNetwork наконец провалится и долетит до catch —
  // а к этому моменту момент для авто-повтора "по реконнекту" уже упущен:
  // WS давно снова connected, второго такого события ждать неоткуда, пока
  // либо не разорвётся СЛЕДУЮЩИЙ раз, либо пользователь не перезапустит
  // приложение (holodный старт тоже делает sweep). Тот же класс проблемы
  // уже чинили на сервере (см. server/internal/api/websocket.go —
  // startPendingMessageSweeper): полагаться ТОЛЬКО на события реконнекта
  // недостаточно, нужна периодическая подстраховка. 20с — тот же интервал,
  // что и у серверного sweeper'а, для единообразия.
  static const _periodicSweepInterval = Duration(seconds: 20);

  // Не сохраняем Timer в поле для последующей отмены — start() вызывается
  // ровно один раз за всё время жизни процесса (см. _started выше, и его
  // единственный вызов в home_placeholder_screen.dart), отдельного stop()
  // у этого синглтона как и у SendQueueProcessor нет и не предполагается.
  void start() {
    if (_started) return;
    _started = true;
    WebSocketService.instance.statusUpdates.listen((status) {
      if (status == ConnectionStatus.connected) {
        DebugLog.log('PendingSendRetrier sweep triggered by reconnect');
        unawaited(_sweep());
      }
    });
    Timer.periodic(_periodicSweepInterval, (_) {
      // Не дёргаем сеть впустую, пока соединения всё равно нет — попытка
      // заведомо провалится тем же способом, каким и попало в очередь.
      if (WebSocketService.instance.isConnected) {
        unawaited(_sweep());
      }
    });
    unawaited(_sweep());
  }

  Future<void> _sweep() async {
    final jobs = await PendingSendStore.getAll();
    if (jobs.isEmpty) return;
    DebugLog.log('PendingSendRetrier sweep: ${jobs.length} job(s) pending');
    for (final job in jobs) {
      unawaited(_attempt(job));
    }
  }

  /// Ручной повтор ОДНОГО конкретного задания прямо сейчас — по нажатию
  /// "Повторить отправку" в контекстном меню сообщения (см. ТЗ
  /// пользователя), а не по ожиданию следующего реконнекта. id — messageId
  /// одиночного сообщения или groupId группы (см. PendingSendStore.add в
  /// ChatScreen — job['id'] всегда один из этих двух). Тихий no-op, если
  /// задания уже нет (например, фоновый sweep успел забрать его первым).
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
    return await _attempt(job);
  }

  Future<RetryOutcome> _attempt(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    // Тот же приём, что и в SendQueueProcessor._inFlight — не даём двум
    // конкурентным sweep'ам запустить вторую параллельную попытку поверх
    // уже идущей для одного и того же id.
    if (_inFlight.contains(id)) return RetryOutcome.willRetryLater;
    _inFlight.add(id);
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
      DebugLog.log('PendingSendRetrier id=$id sent successfully');
      return RetryOutcome.sent;
    } on _PermanentRetryFailure catch (e) {
      await PendingSendStore.remove(id);
      DebugLog.log('PendingSendRetrier id=$id permanently abandoned: $e');
      return RetryOutcome.permanentlyFailed;
    } catch (e) {
      DebugLog.log(
        'PendingSendRetrier id=$id retry-FAILED error=$e — will retry on next reconnect',
      );
      return RetryOutcome.willRetryLater;
    } finally {
      _inFlight.remove(id);
    }
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
      // Файл не пережил сбой (например, устойчивая копия была снята до
      // введения PendingSendStore.persistFile, или её стёр сам пользователь
      // очисткой хранилища приложения) — переотправить нечем, это уже
      // окончательная неудача, а не повод ретраить бесконечно.
      DebugLog.log(
        'PendingSendRetrier id=$id local file missing, giving up permanently',
      );
      throw _PermanentRetryFailure('local file missing');
    }
    final peerLogin = job['peer_login'] as String;
    final peerDeviceId = await MessageResend.resolvePeerDeviceId(
      peerLogin,
      job['peer_device_id'] as String,
    );
    final token = await Session.getToken();
    if (token == null) {
      throw Exception('not logged in, cannot retry media upload');
    }
    final peerAccountId =
        await PeerAccountStore.get(peerDeviceId) ??
        job['peer_account_id'] as String;
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
    // file здесь всегда наша собственная устойчивая копия (см.
    // PendingSendStore.persistFile в ChatScreen), не оригинал пользователя
    // — удалять безопасно и для 'media' тоже, в отличие от прежней логики,
    // где 'media' нарочно не трогали.
    await PendingSendStore.deletePersistedFile(file.path);
  }

  /// Группа файлов (см. ChatScreen._sendGroupNetwork) — если ЛЮБОЙ из
  /// файлов группы не пережил сбой, вся группа сдаётся окончательно
  /// (частичная отправка группы хуже, чем её отсутствие: получатель
  /// ожидает увидеть все файлы вместе, а не половину без предупреждения).
  Future<void> _retryMediaGroup(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    final rawItems = (job['items'] as List).cast<Map<String, dynamic>>();
    final files = <File>[];
    for (final item in rawItems) {
      final file = File(item['file_path'] as String);
      if (!await file.exists()) {
        DebugLog.log(
          'PendingSendRetrier id=$id media_group missing file=${file.path}, '
          'giving up on the whole group permanently',
        );
        throw _PermanentRetryFailure('local file missing in group');
      }
      files.add(file);
    }

    final peerLogin = job['peer_login'] as String;
    final peerDeviceId = await MessageResend.resolvePeerDeviceId(
      peerLogin,
      job['peer_device_id'] as String,
    );
    final token = await Session.getToken();
    if (token == null) {
      throw Exception('not logged in, cannot retry media group upload');
    }
    final peerAccountId =
        await PeerAccountStore.get(peerDeviceId) ??
        job['peer_account_id'] as String;

    final uploaded = <Map<String, dynamic>>[];
    for (var i = 0; i < rawItems.length; i++) {
      final item = rawItems[i];
      final desc = await uploadAndDescribeMedia(
        peerLogin: peerLogin,
        item: PickedMedia(
          file: files[i],
          isVideo: item['is_video'] as bool? ?? false,
          isFile: item['is_file'] as bool? ?? false,
          isSpoiler: item['is_spoiler'] as bool? ?? false,
        ),
        messageId: item['message_id'] as String,
        size: item['size'] as int,
        fileName: item['file_name'] as String,
        token: token,
        peerAccountIdForUpload: peerAccountId,
        onProgress: (percent) =>
            UploadProgressBus.emit(item['message_id'] as String, percent),
      );
      uploaded.add(desc);
    }

    final inner = InnerMessage.mediaGroup(
      groupId: id,
      messageId: id,
      caption: job['caption'] as String?,
      textMessageId: job['text_message_id'] as String?,
      files: uploaded,
    );

    final textMessageId = job['text_message_id'] as String?;
    await MessageResend.sendEnvelope(
      peerDeviceId: peerDeviceId,
      peerLogin: peerLogin,
      inner: inner,
      onAcked: () async {
        if (textMessageId != null) {
          await ChatStore.updateMessageStatus(peerLogin, textMessageId, 'sent');
        }
        for (final item in rawItems) {
          await ChatStore.updateMessageStatus(
            peerLogin,
            item['message_id'] as String,
            'sent',
          );
        }
      },
    );
    // Все files здесь — наши собственные устойчивые копии (см.
    // PendingSendStore.persistFile в ChatScreen), не оригиналы пользователя.
    for (final file in files) {
      await PendingSendStore.deletePersistedFile(file.path);
    }
  }
}
