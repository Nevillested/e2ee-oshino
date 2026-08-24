import 'dart:async';
import 'dart:io';
import '../crypto/message_envelope.dart';
import '../models/picked_media.dart';
import '../session.dart';
import '../storage/peer_account_store.dart';
import '../storage/pending_send_store.dart';
import 'debug_log.dart';
import 'media_upload.dart';
import 'message_resend.dart';
import 'websocket_service.dart';

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
/// Группы файлов (см. ChatScreen._sendGroupNetwork) сюда сознательно не
/// входят — самый частый и болезненный случай (проверено логами) это
/// одиночный текст/голосовое/фото, а автоматический повтор частичной
/// загрузки группы (когда упал файл N из M) заметно сложнее и рискованнее
/// без возможности прогнать это через реальное устройство — оставлено на
/// отдельную доработку.
class PendingSendRetrier {
  PendingSendRetrier._();
  static final instance = PendingSendRetrier._();

  bool _started = false;
  final Set<String> _inFlight = {};

  void start() {
    if (_started) return;
    _started = true;
    WebSocketService.instance.statusUpdates.listen((status) {
      if (status == ConnectionStatus.connected) {
        DebugLog.log('PendingSendRetrier sweep triggered by reconnect');
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

  Future<void> _attempt(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    // Тот же приём, что и в SendQueueProcessor._inFlight — не даём двум
    // конкурентным sweep'ам запустить вторую параллельную попытку поверх
    // уже идущей для одного и того же id.
    if (_inFlight.contains(id)) return;
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
        default:
          DebugLog.log(
            'PendingSendRetrier id=$id unknown job kind=$kind — dropping',
          );
          await PendingSendStore.remove(id);
          return;
      }
      await PendingSendStore.remove(id);
      DebugLog.log('PendingSendRetrier id=$id handed off to SendQueueProcessor');
    } catch (e) {
      DebugLog.log(
        'PendingSendRetrier id=$id retry-FAILED error=$e — will retry on next reconnect',
      );
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
      // Файл не пережил сбой (например, систему выгрузила приложение из
      // памяти между попытками и подчистила temp) — переотправить нечем,
      // это уже окончательная неудача, а не повод ретраить бесконечно.
      DebugLog.log(
        'PendingSendRetrier id=$id local file missing, giving up permanently',
      );
      return;
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
    try {
      await file.delete();
    } catch (_) {}
  }
}
