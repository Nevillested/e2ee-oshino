import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:uuid/uuid.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/x3dh.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/peer_identity_store.dart';
import 'active_chat_tracker.dart';
import 'debug_log.dart';
import 'send_lock.dart';
import 'sound_service.dart';
import 'websocket_service.dart';

const _uuid = Uuid();

/// Служебные типы control-сообщений — синхронизируются как обычно, но не
/// считаются "сообщением" для звукового уведомления (см. _processIncoming).
const _silentTypes = {
  'reaction',
  'pin',
  'edit',
  'delete',
  'delete_chat',
  'read_receipt',
};

class MessageRouter {
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    WebSocketService.instance.messages.listen(_handleIncoming);
  }

  static Future<void> _handleIncoming(Map<String, dynamic> envelope) async {
    final senderDeviceId = envelope['sender_device_id'] as String?;
    if (senderDeviceId == null) return;
    // Транспортный довесок от WebSocketService (см. комментарий там) —
    // не часть самого конверта, вынимаем до передачи дальше.
    final deliveryId = envelope.remove('_deliveryId') as String?;
    DebugLog.log(
      'Router incoming from=$senderDeviceId deliveryId=${deliveryId ?? '-'}',
    );

    await SendLock.run(
      senderDeviceId,
      () => _processIncoming(senderDeviceId, envelope, deliveryId),
    );
  }

  /// Служебный конверт (см. _onDecryptFailure) — не шифруется Double
  /// Ratchet (сессия и есть то, что сломано), просто просит собеседника
  /// стереть локальную сессию с нами, чтобы следующая же его отправка
  /// сама подняла свежий X3DH-хендшейк.
  static const _sessionResetType = 'session_reset';

  static const _resetFailureThreshold = 3;
  static const _resetCooldown = Duration(seconds: 30);
  static final Map<String, int> _failureCounts = {};
  static final Map<String, DateTime> _lastResetRequestAt = {};

  static Future<void> _processIncoming(
    String senderDeviceId,
    Map<String, dynamic> envelope,
    String? deliveryId,
  ) async {
    try {
      if (envelope['type'] == _sessionResetType) {
        // Собеседник обнаружил у себя рассинхрон при чтении НАШИХ
        // сообщений и просит начать с чистого листа — стираем сессию,
        // наша следующая отправка ему сама поднимет новый X3DH.
        DebugLog.log(
          'Router session_reset received from=$senderDeviceId — clearing local session state',
        );
        await SessionStore.clearState(senderDeviceId);
        _failureCounts.remove(senderDeviceId);
        if (deliveryId != null) {
          WebSocketService.instance.ackDelivery(deliveryId);
        }
        return;
      }

      var state = await SessionStore.getState(senderDeviceId);
      var isFreshSession = false;

      if (state == null) {
        final fresh = await _establishFreshIncoming(senderDeviceId, envelope);
        if (fresh == null) {
          debugPrint(
            'MessageRouter: нет локальной сессии для senderDeviceId='
            '$senderDeviceId, а конверт не содержит данных для нового '
            'X3DH-хендшейка — сообщение отброшено, расшифровать нечем',
          );
          DebugLog.log(
            'Router DROP from=$senderDeviceId reason=no-session-and-no-handshake',
          );
          return;
        }
        state = fresh;
        isFreshSession = true;
      }

      String rawInner;
      try {
        final messageKey = await state.nextReceivingKey(envelope);
        rawInner = await decryptMessage(messageKey, envelope);
      } catch (e) {
        // Расшифровка с текущим состоянием не удалась — если конверт
        // всё же несёт валидные X3DH-поля (собеседник уже сам поднял
        // свежую сессию, а мы этого не заметили, потому что у нас
        // формально "было" старое состояние), пробуем принять её как
        // новую и повторить один раз, прежде чем считать это неудачей.
        final fresh = isFreshSession
            ? null
            : await _establishFreshIncoming(senderDeviceId, envelope);
        if (fresh == null) {
          await _onDecryptFailure(senderDeviceId);
          rethrow;
        }
        DebugLog.log(
          'Router recovered via fresh X3DH init from=$senderDeviceId after decrypt failure',
        );
        final messageKey = await fresh.nextReceivingKey(envelope);
        rawInner = await decryptMessage(messageKey, envelope);
        state = fresh;
      }

      _failureCounts.remove(senderDeviceId);
      await SessionStore.saveState(senderDeviceId, state);

      final inner = InnerMessage.decode(rawInner);
      DebugLog.log(
        'Router decrypted from=$senderDeviceId type=${inner.type} messageId=${inner.messageId}',
      );
      final ownerInfo = await _resolveOwner(senderDeviceId);
      if (ownerInfo == null) {
        DebugLog.log(
          'Router DROP from=$senderDeviceId reason=resolve-owner-failed',
        );
        return;
      }

      final chatIsOpen = ActiveChatTracker.currentPeerLogin == ownerInfo.login;

      if (inner.type == 'text') {
        await ChatStore.addMessage(
          ownerInfo.login,
          StoredMessage(
            inner.messageId,
            inner.body,
            false,
            inner.sentAt,
            groupId: inner.groupId,
            replyToMessageId: inner.replyToMessageId,
            replyToPreview: inner.replyToPreview,
          ),
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'media') {
        final mediaInfo = jsonDecode(inner.body) as Map<String, dynamic>;
        final isFile = mediaInfo['is_file'] as bool? ?? false;
        final fileName = mediaInfo['file_name'] as String;
        final fileSize = mediaInfo['file_size'] as int? ?? 0;
        final chunked = mediaInfo['chunked'] as bool? ?? false;

        await ChatStore.addMessage(
          ownerInfo.login,
          StoredMessage(
            inner.messageId,
            isFile ? fileName : '📷 Фото',
            false,
            inner.sentAt,
            isMedia: true,
            isFile: isFile,
            fileSize: fileSize,
            chunked: chunked,
            mediaId: mediaInfo['media_id'] as String,
            mediaKeyBase64: mediaInfo['key'] as String,
            mediaNonceBase64: mediaInfo['nonce'] as String?,
            mediaMacBase64: mediaInfo['mac'] as String?,
            fileName: fileName,
            groupId: inner.groupId,
            replyToMessageId: inner.replyToMessageId,
            replyToPreview: inner.replyToPreview,
          ),
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'voice' || inner.type == 'video_note') {
        final info = jsonDecode(inner.body) as Map<String, dynamic>;
        final isVideoNote = inner.type == 'video_note';
        await ChatStore.addMessage(
          ownerInfo.login,
          StoredMessage(
            inner.messageId,
            isVideoNote ? '🎥 Видеосообщение' : '🎤 Голосовое сообщение',
            false,
            inner.sentAt,
            isMedia: true,
            isVoice: !isVideoNote,
            isVideoNote: isVideoNote,
            fileSize: info['file_size'] as int? ?? 0,
            chunked: info['chunked'] as bool? ?? false,
            durationMs: info['duration_ms'] as int?,
            mediaId: info['media_id'] as String,
            mediaKeyBase64: info['key'] as String,
            mediaNonceBase64: info['nonce'] as String?,
            mediaMacBase64: info['mac'] as String?,
            groupId: inner.groupId,
            replyToMessageId: inner.replyToMessageId,
            replyToPreview: inner.replyToPreview,
          ),
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'media_group') {
        final groupInfo = jsonDecode(inner.body) as Map<String, dynamic>;
        final caption = groupInfo['caption'] as String?;
        final textMessageId = groupInfo['text_message_id'] as String?;
        final filesRaw = (groupInfo['files'] as List<dynamic>)
            .cast<Map<String, dynamic>>();

        final newMessages = <StoredMessage>[];
        if (caption != null && caption.isNotEmpty && textMessageId != null) {
          newMessages.add(
            StoredMessage(
              textMessageId,
              caption,
              false,
              inner.sentAt,
              groupId: inner.groupId,
            ),
          );
        }
        for (final f in filesRaw) {
          final isFile = f['is_file'] as bool? ?? false;
          final fileName = f['file_name'] as String;
          newMessages.add(
            StoredMessage(
              f['message_id'] as String,
              isFile ? fileName : '📷 Фото',
              false,
              inner.sentAt,
              isMedia: true,
              isFile: isFile,
              fileSize: f['file_size'] as int? ?? 0,
              chunked: f['chunked'] as bool? ?? false,
              mediaId: f['media_id'] as String,
              mediaKeyBase64: f['key'] as String,
              mediaNonceBase64: f['nonce'] as String?,
              mediaMacBase64: f['mac'] as String?,
              fileName: fileName,
              groupId: inner.groupId,
            ),
          );
        }

        await ChatStore.addMessages(
          ownerInfo.login,
          newMessages,
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'call_missed') {
        // Собеседник звонил, пока мы были офлайн, и call_offer до нас в
        // реальном времени не дошёл — это подстраховочное уведомление, дошедшее
        // через обычную очередь offline-доставки, а не через сигналы звонка.
        final callInfo = jsonDecode(inner.body) as Map<String, dynamic>;
        final calledAt = callInfo['called_at'] as int? ?? inner.sentAt;
        await ChatStore.addCallLog(
          ownerInfo.login,
          direction: 'incoming',
          outcome: 'missed',
          timestamp: calledAt,
          accountId: ownerInfo.accountId,
          incrementUnread: !chatIsOpen,
        );
      } else if (inner.type == 'reaction') {
        // Реакция от собеседника — с НАШЕЙ стороны это всегда "peer"-реакция,
        // независимо от того, кто автор самого сообщения, на которое она стоит.
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetId = data['target_id'] as String?;
        if (targetId != null) {
          await ChatStore.setReaction(
            ownerInfo.login,
            targetId,
            isMine: false,
            emoji: data['emoji'] as String?,
          );
          // Виброотклик на чужую реакцию — только если мы прямо сейчас
          // смотрим именно в этот чат (иначе непонятно, по какому поводу
          // телефон дёрнулся, если мы вообще не видим этот пузырь).
          if (chatIsOpen) HapticFeedback.vibrate();
        }
      } else if (inner.type == 'pin') {
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetId = data['target_id'] as String?;
        final pinned = data['pinned'] as bool? ?? false;
        await ChatStore.setPinned(ownerInfo.login, pinned ? targetId : null);
      } else if (inner.type == 'edit') {
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetId = data['target_id'] as String?;
        final newText = data['text'] as String?;
        if (targetId != null && newText != null) {
          await ChatStore.editMessageText(ownerInfo.login, targetId, newText);
        }
      } else if (inner.type == 'delete') {
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetIds =
            (data['target_ids'] as List<dynamic>?)?.cast<String>() ?? const [];
        await ChatStore.deleteMessages(ownerInfo.login, targetIds);
      } else if (inner.type == 'delete_chat') {
        // Собеседник удалил у себя весь диалог с галочкой "у обоих" — у нас
        // тоже убираем сам чат из списка (см. InnerMessage.deleteChat), а не
        // просто оставляем его пустым, как после обычной очистки истории.
        await ChatStore.removeChat(ownerInfo.login);
      } else if (inner.type == 'read_receipt') {
        // Собеседник подтверждает, что реально увидел перечисленные — это
        // НАШИ сообщения (targetIds всегда ссылаются на сообщения автора
        // квитанции, т.е. на нас), поэтому статус меняем без разбора
        // isMine, как и в остальных ветках выше.
        final data = jsonDecode(inner.body) as Map<String, dynamic>;
        final targetIds =
            (data['target_ids'] as List<dynamic>?)?.cast<String>() ?? const [];
        await ChatStore.markMessagesRead(ownerInfo.login, targetIds);
      }

      // Подтверждаем серверу доставку ТОЛЬКО теперь — конверт уже реально
      // расшифрован и сохранён (или осознанно ни во что не превратился,
      // как read_receipt/пустая реакция — тоже "обработано", ack честен).
      // Раньше ack уходил сразу по получении кадра, до этого места — любой
      // сбой ниже по цепочке (расшифровка, запись) означал, что сервер уже
      // считал сообщение доставленным и стирал его, а оно фактически терялось.
      if (deliveryId != null) {
        WebSocketService.instance.ackDelivery(deliveryId);
      }
      DebugLog.log(
        'Router OK from=$senderDeviceId type=${inner.type} messageId=${inner.messageId}',
      );

      // Реакция/пин/правка/удаление — служебные события, не самостоятельные
      // сообщения: не заслуживают звука, даже если чат закрыт (собеседник
      // увидит их, когда сам откроет чат — специально идти проверять их не
      // нужно). Замьюченный чат тоже не должен звучать — раньше эта
      // проверка тут отсутствовала: мьют реально гасил только push (когда
      // приложение закрыто/свёрнуто), а живое сообщение по уже открытому
      // WebSocket-соединению всё равно проигрывало звук.
      if (!chatIsOpen && !_silentTypes.contains(inner.type)) {
        final muted = await ChatStore.isChatMuted(ownerInfo.login);
        if (!muted) SoundService.playMessageSound();
      }
    } catch (e, stackTrace) {
      debugPrint('MessageRouter: ошибка обработки сообщения: $e\n$stackTrace');
      DebugLog.log(
        'Router FAILED from=$senderDeviceId deliveryId=${deliveryId ?? '-'} error=$e',
      );
    }
  }

  /// Пытается поднять входящую сессию с нуля из X3DH-полей конверта (если
  /// они там есть) — используется и когда локальной сессии вообще нет, и
  /// как fallback, когда расшифровка с уже имеющимся (рассинхронизированным)
  /// состоянием не удалась, но собеседник прислал свежий хендшейк.
  static Future<RatchetState?> _establishFreshIncoming(
    String senderDeviceId,
    Map<String, dynamic> envelope,
  ) async {
    final rootKey = await establishIncomingSessionRaw(envelope);
    if (rootKey == null) return null;
    await PeerIdentityStore.save(
      senderDeviceId,
      envelope['sender_identity_dh_pubkey'] as String,
    );
    return RatchetState.initAsReceiver(
      rootKey: rootKey,
      remoteEphemeralPubkey: base64DecodeSafe(
        envelope['ephemeral_pubkey'] as String,
      ),
    );
  }

  /// Считает подряд идущие неудачные попытки расшифровки от одного
  /// отправителя — после нескольких подряд решаем, что наша сессия с ним
  /// рассинхронизирована навсегда (см. docstring в double_ratchet.dart:
  /// такое состояние само себя не чинит), сбрасываем её у себя и просим
  /// собеседника сделать то же самое, чтобы его следующая отправка сама
  /// подняла свежий X3DH.
  static Future<void> _onDecryptFailure(String senderDeviceId) async {
    final count = (_failureCounts[senderDeviceId] ?? 0) + 1;
    _failureCounts[senderDeviceId] = count;
    DebugLog.log(
      'Router decrypt-failure-count from=$senderDeviceId count=$count',
    );
    if (count < _resetFailureThreshold) return;

    final lastRequest = _lastResetRequestAt[senderDeviceId];
    if (lastRequest != null &&
        DateTime.now().difference(lastRequest) < _resetCooldown) {
      return;
    }
    _lastResetRequestAt[senderDeviceId] = DateTime.now();

    DebugLog.log(
      'Router auto session-reset triggered for=$senderDeviceId after $count consecutive decrypt failures',
    );
    await SessionStore.clearState(senderDeviceId);
    await _sendSessionReset(senderDeviceId);
  }

  static Future<void> _sendSessionReset(String toDeviceId) async {
    final myDeviceId = await KeyStore.getStoredDeviceId();
    if (myDeviceId == null) return;
    final envelope = <String, dynamic>{
      'type': _sessionResetType,
      'sender_device_id': myDeviceId,
    };
    await WebSocketService.instance.sendEnvelope(
      toDeviceId,
      envelope,
      _uuid.v4(),
      silent: true,
    );
  }

  static Future<({String accountId, String login})?> _resolveOwner(
    String deviceId,
  ) async {
    final token = await Session.getToken();
    if (token == null) return null;
    return ApiClient().getDeviceOwnerInfo(token, deviceId);
  }
}
