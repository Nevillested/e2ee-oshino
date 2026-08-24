import '../api/api_client.dart';
import '../crypto/double_ratchet.dart';
import '../crypto/key_store.dart';
import '../crypto/message_cipher.dart';
import '../crypto/message_envelope.dart';
import '../crypto/session_store.dart';
import '../crypto/x3dh.dart';
import '../session.dart';
import '../storage/chat_store.dart';
import '../storage/peer_account_store.dart';
import '../storage/peer_identity_store.dart';
import 'debug_log.dart';
import 'send_lock.dart';
import 'send_queue_processor.dart';

/// Общая логика "поднять Double Ratchet сессию (если её ещё нет) →
/// зашифровать → поставить в SendQueueProcessor" — версия БЕЗ зависимости от
/// State/BuildContext конкретного ChatScreen, вызывается и когда экран чата
/// закрыт (см. PendingSendRetrier, который досылает сообщения, упавшие ДО
/// того, как готов конверт, уже после того, как пользователь мог уйти из
/// чата или полностью закрыть приложение).
class MessageResend {
  /// Тот же алгоритм, что и ChatScreen._refreshPeerDeviceId — на офлайне
  /// молча остаёмся при последнем известном device_id, как и обычная
  /// отправка в этом случае.
  static Future<String> resolvePeerDeviceId(
    String peerLogin,
    String fallbackDeviceId,
  ) async {
    try {
      final token = await Session.getToken();
      if (token == null) return fallbackDeviceId;
      final result = await ApiClient().getDevicesByLogin(token, peerLogin);
      if (result.devices.isNotEmpty) {
        final deviceId = result.devices.first['device_id'] as String;
        await ChatStore.setLastKnownDeviceId(peerLogin, deviceId);
        return deviceId;
      }
    } catch (_) {
      // Офлайн/сервер недоступен — работаем с тем, что уже знаем.
    }
    return fallbackDeviceId;
  }

  static Future<void> sendEnvelope({
    required String peerDeviceId,
    required String peerLogin,
    required InnerMessage inner,
    Future<void> Function()? onAcked,
  }) async {
    await SendLock.run(peerDeviceId, () async {
      final myDeviceId = await KeyStore.getStoredDeviceId();
      var state = await SessionStore.getState(peerDeviceId);
      Map<String, dynamic>? initHeader;

      if (state == null) {
        DebugLog.log(
          'MessageResend establishing fresh X3DH outgoing session to=$peerDeviceId '
          '(no local session found)',
        );
        final token = await Session.getToken();
        final bundle = await ApiClient().getPrekeyBundle(token!, peerDeviceId);
        await PeerAccountStore.save(peerDeviceId, bundle['account_id'] as String);
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
      DebugLog.log(
        'MessageResend sending key (retry type=${inner.type} messageId=${inner.messageId}) '
        'to=$peerDeviceId messageNumber=${next.header['message_number']} '
        'ratchetPubkey=${next.header['ratchet_pubkey']}',
      );
      await SessionStore.saveState(peerDeviceId, state);

      final headerFields = <String, dynamic>{
        ...next.header,
        'sender_device_id': myDeviceId,
        if (initHeader != null) ...initHeader,
      };
      final encrypted = await encryptMessage(
        next.messageKey,
        inner.encode(),
        aad: headerFields,
      );
      final envelope = <String, dynamic>{...encrypted, ...headerFields};

      await SendQueueProcessor.instance.enqueue(
        toDeviceId: peerDeviceId,
        envelope: envelope,
        deliveryId: inner.messageId,
        messageId: inner.messageId,
        peerLogin: peerLogin,
        onAcked: onAcked,
      );
    });
  }
}
