import 'dart:convert';
import 'package:cryptography/cryptography.dart';

final _x25519 = X25519();
final _hmac = Hmac.sha256();

const _maxSkippedKeys = 100; // защита от чрезмерного расхода памяти/диска

Future<List<int>> _hkdf(List<int> ikm, String info, int length) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: const [],
    info: utf8.encode(info),
  );
  return derived.extractBytes();
}

Future<List<int>> _hmacBytes(List<int> key, int marker) async {
  final mac = await _hmac.calculateMac([marker], secretKey: SecretKey(key));
  return mac.bytes;
}

/// Хранит всё состояние сессии Double Ratchet с одним конкретным
/// устройством собеседника. Сериализуется в JSON для сохранения на диск.
///
/// ВАЖНОЕ ПРАВИЛО ПРИ ИСПОЛЬЗОВАНИИ: сохранять состояние на диск можно
/// ТОЛЬКО после того, как расшифровка сообщения этим ключом прошла
/// успешно. Если сохранить раньше и расшифровка провалится — состояние
/// окажется "убежавшим вперёд" навсегда, и все следующие сообщения от
/// этого собеседника перестанут расшифровываться без возможности
/// восстановления.
class RatchetState {
  List<int> rootKey;
  List<int>? sendingChainKey;
  List<int>? receivingChainKey;
  SimpleKeyPair sendingRatchetKeyPair;
  List<int>? receivingRatchetPublicKey;
  int sendMessageNumber;
  int receiveMessageNumber;
  bool needsSendingRatchet;

  /// Ключи сообщений, которые "перескочили" (пришло сообщение с большим
  /// номером, чем ожидалось) — сохраняются на случай, если пропущенное
  /// сообщение всё же придёт позже, с опозданием.
  Map<int, List<int>> skippedReceivingKeys;

  RatchetState({
    required this.rootKey,
    required this.sendingRatchetKeyPair,
    this.sendingChainKey,
    this.receivingChainKey,
    this.receivingRatchetPublicKey,
    this.sendMessageNumber = 0,
    this.receiveMessageNumber = 0,
    this.needsSendingRatchet = false,
    Map<int, List<int>>? skippedReceivingKeys,
  }) : skippedReceivingKeys = skippedReceivingKeys ?? {};

  static Future<RatchetState> initAsSender({
    required List<int> rootKey,
    required SimpleKeyPair ephemeralKeyPair,
  }) async {
    final chainKey = await _hkdf(rootKey, 'oshinobu-init', 32);
    return RatchetState(
      rootKey: rootKey,
      sendingRatchetKeyPair: ephemeralKeyPair,
      sendingChainKey: chainKey,
    );
  }

  static Future<RatchetState> initAsReceiver({
    required List<int> rootKey,
    required List<int> remoteEphemeralPubkey,
  }) async {
    final chainKey = await _hkdf(rootKey, 'oshinobu-init', 32);
    final freshKeyPair = await _x25519.newKeyPair();
    return RatchetState(
      rootKey: rootKey,
      sendingRatchetKeyPair: freshKeyPair,
      receivingChainKey: chainKey,
      receivingRatchetPublicKey: remoteEphemeralPubkey,
      needsSendingRatchet: true,
    );
  }

  Future<void> _dhRatchetStepForSending() async {
    final newKeyPair = await _x25519.newKeyPair();
    final shared = await _x25519.sharedSecretKey(
      keyPair: newKeyPair,
      remotePublicKey: SimplePublicKey(receivingRatchetPublicKey!, type: KeyPairType.x25519),
    );
    final combined = [...rootKey, ...await shared.extractBytes()];
    final derived = await _hkdf(combined, 'oshinobu-ratchet', 64);
    rootKey = derived.sublist(0, 32);
    sendingChainKey = derived.sublist(32, 64);
    sendingRatchetKeyPair = newKeyPair;
    sendMessageNumber = 0;
    needsSendingRatchet = false;
  }

  Future<void> _dhRatchetStepForReceiving(List<int> newRemotePubkey) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: sendingRatchetKeyPair,
      remotePublicKey: SimplePublicKey(newRemotePubkey, type: KeyPairType.x25519),
    );
    final combined = [...rootKey, ...await shared.extractBytes()];
    final derived = await _hkdf(combined, 'oshinobu-ratchet', 64);
    rootKey = derived.sublist(0, 32);
    receivingChainKey = derived.sublist(32, 64);
    receivingRatchetPublicKey = newRemotePubkey;
    receiveMessageNumber = 0;
    needsSendingRatchet = true;
    // Новая цепочка — старые "пропущенные" ключи из предыдущей эпохи
    // больше не актуальны, они относились к другому receivingChainKey.
    skippedReceivingKeys = {};
  }

  Future<({Map<String, dynamic> header, List<int> messageKey})> nextSendingKey() async {
    if (needsSendingRatchet) {
      await _dhRatchetStepForSending();
    }
    final messageKey = await _hmacBytes(sendingChainKey!, 1);
    sendingChainKey = await _hmacBytes(sendingChainKey!, 2);
    final myPublic = await sendingRatchetKeyPair.extractPublicKey();
    final header = {
      'ratchet_pubkey': base64Encode(myPublic.bytes),
      'message_number': sendMessageNumber,
    };
    sendMessageNumber++;
    return (header: header, messageKey: messageKey);
  }

  /// Возвращает ключ для расшифровки конкретного входящего сообщения.
  /// НЕ мутирует ничего непредсказуемо — если сообщение с этим номером
  /// уже был пропущен ранее (пришло не по порядку), просто отдаёт
  /// заранее сохранённый ключ, без продвижения цепочки.
  Future<List<int>> nextReceivingKey(Map<String, dynamic> header) async {
    final incomingPubkey = base64Decode(header['ratchet_pubkey'] as String);
    final messageNumber = header['message_number'] as int;

    final isNewRatchetKey = receivingRatchetPublicKey == null ||
        !_bytesEqual(receivingRatchetPublicKey!, incomingPubkey);

    if (isNewRatchetKey) {
      await _dhRatchetStepForReceiving(incomingPubkey);
    }

    // Сообщение, которое мы уже когда-то пропустили и запомнили ключ для
    // него — просто отдаём сохранённый ключ, ничего больше не трогаем.
    if (skippedReceivingKeys.containsKey(messageNumber)) {
      return skippedReceivingKeys.remove(messageNumber)!;
    }

    if (messageNumber < receiveMessageNumber) {
      // Номер меньше уже обработанного и не найден среди пропущенных —
      // это повтор или испорченные данные, ключ восстановить невозможно.
      throw Exception('Сообщение с номером $messageNumber уже было обработано ранее');
    }

    if (messageNumber - receiveMessageNumber > _maxSkippedKeys) {
      throw Exception('Слишком большой разрыв в номерах сообщений — отказ от обработки');
    }

    // Догоняем цепочку до нужного номера, попутно запоминая ключи для
    // всех "перепрыгнутых" позиций — вдруг те сообщения придут позже.
    while (receiveMessageNumber < messageNumber) {
      final skippedKey = await _hmacBytes(receivingChainKey!, 1);
      receivingChainKey = await _hmacBytes(receivingChainKey!, 2);
      skippedReceivingKeys[receiveMessageNumber] = skippedKey;
      receiveMessageNumber++;
    }

    final messageKey = await _hmacBytes(receivingChainKey!, 1);
    receivingChainKey = await _hmacBytes(receivingChainKey!, 2);
    receiveMessageNumber++;
    return messageKey;
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<Map<String, dynamic>> toJson() async {
    final privateBytes = await sendingRatchetKeyPair.extractPrivateKeyBytes();
    final publicKey = await sendingRatchetKeyPair.extractPublicKey();
    return {
      'root_key': base64Encode(rootKey),
      'sending_chain_key': sendingChainKey != null ? base64Encode(sendingChainKey!) : null,
      'receiving_chain_key': receivingChainKey != null ? base64Encode(receivingChainKey!) : null,
      'sending_ratchet_private': base64Encode(privateBytes),
      'sending_ratchet_public': base64Encode(publicKey.bytes),
      'receiving_ratchet_public': receivingRatchetPublicKey != null
          ? base64Encode(receivingRatchetPublicKey!)
          : null,
      'send_message_number': sendMessageNumber,
      'receive_message_number': receiveMessageNumber,
      'needs_sending_ratchet': needsSendingRatchet,
      'skipped_receiving_keys': skippedReceivingKeys.map(
        (key, value) => MapEntry(key.toString(), base64Encode(value)),
      ),
    };
  }

  static RatchetState fromJson(Map<String, dynamic> json) {
    final keyPair = SimpleKeyPairData(
      base64Decode(json['sending_ratchet_private'] as String),
      publicKey: SimplePublicKey(
        base64Decode(json['sending_ratchet_public'] as String),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );

    final skippedRaw = json['skipped_receiving_keys'] as Map<String, dynamic>? ?? {};
    final skipped = skippedRaw.map(
      (key, value) => MapEntry(int.parse(key), base64Decode(value as String)),
    );

    return RatchetState(
      rootKey: base64Decode(json['root_key'] as String),
      sendingRatchetKeyPair: keyPair,
      sendingChainKey: json['sending_chain_key'] != null
          ? base64Decode(json['sending_chain_key'] as String)
          : null,
      receivingChainKey: json['receiving_chain_key'] != null
          ? base64Decode(json['receiving_chain_key'] as String)
          : null,
      receivingRatchetPublicKey: json['receiving_ratchet_public'] != null
          ? base64Decode(json['receiving_ratchet_public'] as String)
          : null,
      sendMessageNumber: json['send_message_number'] as int,
      receiveMessageNumber: json['receive_message_number'] as int,
      needsSendingRatchet: json['needs_sending_ratchet'] as bool,
      skippedReceivingKeys: skipped,
    );
  }
}