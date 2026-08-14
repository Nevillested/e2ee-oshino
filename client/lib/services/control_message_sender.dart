import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/x3dh.dart';
import '../session.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import 'send_lock.dart';
import 'websocket_service.dart';

/// Отправка служебного control-сообщения (реакция/пин/правка/удаление) вне
/// открытого ChatScreen — нужно для действий из списка чатов (например,
/// "очистить историю"/"удалить диалог" с галочкой "у собеседника тоже", см.
/// showChatListContextMenu в home_placeholder_screen.dart), где своего
/// состояния Double Ratchet сессии ещё нет и заводить его приходится с нуля,
/// как это делает ChatScreen._ensureSessionForSending при первой отправке.
class ControlMessageSender {
  static Future<void> send({
    required String peerLogin,
    required String peerDeviceId,
    required InnerMessage inner,
  }) async {
    if (peerDeviceId.isEmpty) return;
    try {
      await SendLock.run(peerLogin, () async {
        final myDeviceId = await KeyStore.getStoredDeviceId();
        var state = await SessionStore.getState(peerDeviceId);
        Map<String, dynamic>? initHeader;

        if (state == null) {
          final token = await Session.getToken();
          final bundle = await ApiClient().getPrekeyBundle(
            token!,
            peerDeviceId,
          );
          await PeerAccountStore.save(
            peerDeviceId,
            bundle['account_id'] as String,
          );
          await PeerIdentityStore.save(
            peerDeviceId,
            bundle['identity_dh_pubkey'] as String,
          );
          final outgoing = await establishOutgoingRoot(
            bundle: bundle,
            myDeviceId: myDeviceId!,
          );
          state = await RatchetState.initAsSender(
            rootKey: outgoing.rootKey,
            ephemeralKeyPair: outgoing.ephemeralKeyPair,
          );
          initHeader = outgoing.initHeader;
        }

        final next = await state.nextSendingKey();
        await SessionStore.saveState(peerDeviceId, state);

        final encrypted = await encryptMessage(next.messageKey, inner.encode());
        final envelope = <String, dynamic>{
          ...encrypted,
          ...next.header,
          'sender_device_id': myDeviceId,
          if (initHeader != null) ...initHeader,
        };

        await WebSocketService.instance.sendEnvelope(
          peerDeviceId,
          envelope,
          inner.messageId,
          silent: true,
        );
      });
    } catch (e) {
      debugPrint('Ошибка отправки служебного сообщения (вне чата): $e');
    }
  }
}
