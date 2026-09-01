import 'dart:async';
import 'dart:io';
import '../crypto/message_envelope.dart';
import '../l10n/app_strings.dart';
import '../models/picked_media.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/peer_account_store.dart';
import '../storage/pending_send_store.dart';
import 'debug_log.dart';
import 'media_upload.dart';
import 'message_resend.dart';
import 'upload_progress_bus.dart';

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

  /// Единственный способ повторить упавшее задание — по нажатию "Повторить
  /// отправку" в контекстном меню сообщения (ТЗ пользователя: никакого
  /// фонового автоповтора, только явное действие пользователя). id —
  /// messageId одиночного сообщения или groupId группы (см.
  /// PendingSendStore.add в ChatScreen — job['id'] всегда один из этих
  /// двух). notFound — задания уже нет (например, сообщение удалено).
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
      DebugLog.log('PendingSendRetrier id=$id sent successfully');
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
      DebugLog.log(
        'PendingSendRetrier id=$id retry-FAILED error=$e — will retry on next reconnect',
      );
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
