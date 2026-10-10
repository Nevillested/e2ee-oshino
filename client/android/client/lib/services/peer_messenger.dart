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
import 'debug_log.dart';
import 'send_queue_processor.dart';

/// Отправка одного зашифрованного сообщения конкретному устройству вне
/// контекста экрана чата (используется, например, для уведомления о
/// пропущенном звонке). Устанавливает Double Ratchet сессию так же, как
/// это делает сам ChatScreen, если сессии с этим устройством ещё нет —
/// prekey-бандл собеседника лежит на сервере заранее, поэтому сессию
/// можно установить, даже если собеседник сейчас офлайн.
///
/// Вызывающий код должен сам обернуть вызов в
/// `SendLock.run(peerDeviceId, () => sendPeerMessage(...))`, используя тот
/// же ключ блокировки (device_id собеседника — НЕ login: раньше здесь по
/// ошибке стоял login, из-за чего блокировка не серилизовалась ни с одним
/// другим путём отправки в приложении, все они ключуются по device_id, см.
/// ChatScreen/MessageRouter/control_message_sender.dart/message_resend.dart),
/// что и остальные пути отправки — иначе параллельные операции с
/// состоянием Double Ratchet одного и того же собеседника могут затереть
/// друг друга.
Future<void> sendPeerMessage(String peerDeviceId, InnerMessage inner) async {
  final token = await Session.getToken();
  final myDeviceId = await KeyStore.getStoredDeviceId();

  var state = await SessionStore.getState(peerDeviceId);
  Map<String, dynamic>? initHeader;

  if (state == null) {
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
    DebugLog.log('PeerMessenger: fresh X3DH session to=$peerDeviceId');
  }

  final next = await state.nextSendingKey();
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
  );
}
