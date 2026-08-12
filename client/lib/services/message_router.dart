import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/x3dh.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/peer_identity_store.dart';
import 'active_chat_tracker.dart';
import 'send_lock.dart';
import 'sound_service.dart';
import 'websocket_service.dart';

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

    await SendLock.run(senderDeviceId, () => _processIncoming(senderDeviceId, envelope));
  }

  static Future<void> _processIncoming(
    String senderDeviceId,
    Map<String, dynamic> envelope,
  ) async {
    try {
      var state = await SessionStore.getState(senderDeviceId);

      if (state == null) {
        final rootKey = await establishIncomingSessionRaw(envelope);
        if (rootKey == null) return;
        await PeerIdentityStore.save(
          senderDeviceId,
          envelope['sender_identity_dh_pubkey'] as String,
        );
        state = await RatchetState.initAsReceiver(
          rootKey: rootKey,
          remoteEphemeralPubkey:
              base64DecodeSafe(envelope['ephemeral_pubkey'] as String),
        );
      }

      final messageKey = await state.nextReceivingKey(envelope);

      final rawInner = await decryptMessage(messageKey, envelope);
      await SessionStore.saveState(senderDeviceId, state);

      final inner = InnerMessage.decode(rawInner);
      final ownerInfo = await _resolveOwner(senderDeviceId);
      if (ownerInfo == null) return;

      final chatIsOpen = ActiveChatTracker.currentPeerLogin == ownerInfo.login;

      if (inner.type == 'text') {
        await ChatStore.addMessage(
          ownerInfo.login,
          StoredMessage(inner.messageId, inner.body, false, inner.sentAt, groupId: inner.groupId),
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
    ),
    accountId: ownerInfo.accountId,
    incrementUnread: !chatIsOpen,
  );
} else if (inner.type == 'media_group') {
  final groupInfo = jsonDecode(inner.body) as Map<String, dynamic>;
  final caption = groupInfo['caption'] as String?;
  final textMessageId = groupInfo['text_message_id'] as String?;
  final filesRaw = (groupInfo['files'] as List<dynamic>).cast<Map<String, dynamic>>();

  final newMessages = <StoredMessage>[];
  if (caption != null && caption.isNotEmpty && textMessageId != null) {
    newMessages.add(StoredMessage(textMessageId, caption, false, inner.sentAt, groupId: inner.groupId));
  }
  for (final f in filesRaw) {
    final isFile = f['is_file'] as bool? ?? false;
    final fileName = f['file_name'] as String;
    newMessages.add(StoredMessage(
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
    ));
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
}

      if (!chatIsOpen) {
        SoundService.playMessageSound();
      }
    } catch (e, stackTrace) {
      debugPrint('MessageRouter: ошибка обработки сообщения: $e\n$stackTrace');
    }
  }

  static Future<({String accountId, String login})?> _resolveOwner(String deviceId) async {
    final token = await Session.getToken();
    if (token == null) return null;
    return ApiClient().getDeviceOwnerInfo(token, deviceId);
  }
}