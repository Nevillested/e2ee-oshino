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
import 'websocket_service.dart';

/// Отправка одного зашифрованного сообщения конкретному устройству вне
/// контекста экрана чата (используется, например, для уведомления о
/// пропущенном звонке). Устанавливает Double Ratchet сессию так же, как
/// это делает сам ChatScreen, если сессии с этим устройством ещё нет —
/// prekey-бандл собеседника лежит на сервере заранее, поэтому сессию
/// можно установить, даже если собеседник сейчас офлайн.
///
/// Вызывающий код должен сам обернуть вызов в
/// `SendLock.run(peerLogin, () => sendPeerMessage(...))`, используя тот
/// же ключ блокировки (логин собеседника), что и ChatScreen — иначе
/// параллельные операции с состоянием Double Ratchet одного и того же
/// собеседника могут затереть друг друга.
Future<void> sendPeerMessage(String peerDeviceId, InnerMessage inner) async {
  final token = await Session.getToken();
  final myDeviceId = await KeyStore.getStoredDeviceId();

  var state = await SessionStore.getState(peerDeviceId);
  Map<String, dynamic>? initHeader;

  if (state == null) {
    final bundle = await ApiClient().getPrekeyBundle(token!, peerDeviceId);
    await PeerAccountStore.save(peerDeviceId, bundle['account_id'] as String);
    await PeerIdentityStore.save(peerDeviceId, bundle['identity_dh_pubkey'] as String);

    final outgoing = await establishOutgoingRoot(bundle: bundle, myDeviceId: myDeviceId!);
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

  await WebSocketService.instance.sendEnvelope(peerDeviceId, envelope, inner.messageId);
}
