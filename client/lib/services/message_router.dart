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
import 'websocket_service.dart';
import 'send_lock.dart';

class MessageRouter {
  static bool _started = false;
  static final _updatesController = StreamController<String>.broadcast();

  /// Испускает peer_account_id (не device_id!) собеседника, чью историю
  /// нужно перечитать — экраны должны подписываться на это.
  static Stream<String> get updates => _updatesController.stream;

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

      if (inner.type == 'text') {
        await ChatStore.addMessage(
          ownerInfo.accountId,
          StoredMessage(inner.messageId, inner.body, false, inner.sentAt),
          peerLogin: ownerInfo.login,
        );
      } else if (inner.type == 'media') {
        final mediaInfo = jsonDecode(inner.body) as Map<String, dynamic>;
        await ChatStore.addMessage(
          ownerInfo.accountId,
          StoredMessage(
            inner.messageId,
            '📷 Фото',
            false,
            inner.sentAt,
            isMedia: true,
            mediaId: mediaInfo['media_id'] as String,
            mediaKeyBase64: mediaInfo['key'] as String,
            mediaNonceBase64: mediaInfo['nonce'] as String,
            mediaMacBase64: mediaInfo['mac'] as String,
            fileName: mediaInfo['file_name'] as String,
          ),
          peerLogin: ownerInfo.login,
        );
      }

      _updatesController.add(ownerInfo.accountId);
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