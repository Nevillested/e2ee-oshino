import 'dart:convert';
import 'package:cryptography/cryptography.dart';

final _aesGcm = AesGcm.with256bits();

/// Поля конверта, которые управляют состоянием Double Ratchet и
/// маршрутизацией (какой ключ использовать, чей это шаг ратчета, какое
/// сообщение по счёту, чья это X3DH-инициализация) — лежат РЯДОМ с
/// зашифрованным телом открытым текстом (они и не секрет — ratchet_pubkey
/// это публичный DH-ключ), но раньше вообще НЕ были защищены целостностью:
/// GCM auth tag покрывал только сам ciphertext, так что сервер (или кто
/// угодно, кто может подменить конверт на лету) мог незаметно подменить
/// message_number/ratchet_pubkey/sender_device_id, не трогая ciphertext —
/// расшифровка бы прошла успешно с "чужими" метаданными, что могло тихо
/// рассинхронизировать ratchet-состояние или исказить атрибуцию сообщения.
/// Теперь эти поля дополнительно связываются с шифротекстом через
/// associated data GCM — подмена любого из них после шифрования ломает MAC,
/// и расшифровка честно падает, вместо того чтобы принять искажённые
/// метаданные вместе с настоящим содержимым.
const _aadFieldNames = [
  'sender_device_id',
  'ratchet_pubkey',
  'message_number',
  'ephemeral_pubkey',
  'sender_identity_dh_pubkey',
  'used_one_time_prekey',
];

List<int> _buildAad(Map<String, dynamic> fields) {
  final parts = _aadFieldNames.map((k) => '$k=${fields[k]}').join('|');
  return utf8.encode(parts);
}

/// [aad] — заголовочные поля конверта (см. _aadFieldNames), которые уйдут
/// РЯДОМ с результатом этой функции в том же самом envelope — вызывающий
/// код должен собрать их ДО вызова (next.header + sender_device_id +
/// initHeader, если есть) и передать сюда же, а не только заспредить в
/// envelope постфактум: иначе они останутся незащищёнными.
Future<Map<String, String>> encryptMessage(
  List<int> sessionKey,
  String plaintext, {
  Map<String, dynamic> aad = const {},
}) async {
  final secretBox = await _aesGcm.encrypt(
    utf8.encode(plaintext),
    secretKey: SecretKey(sessionKey),
    aad: _buildAad(aad),
  );
  return {
    'nonce': base64Encode(secretBox.nonce),
    'ciphertext': base64Encode(secretBox.cipherText),
    'mac': base64Encode(secretBox.mac.bytes),
  };
}

/// [envelope] — те же имена полей, что и в [aad] у encryptMessage,
/// читаются отсюда напрямую (envelope и есть уже полученный конверт целиком
/// — лишние поля вроде nonce/ciphertext/mac просто игнорируются построением
/// AAD, оно смотрит только на именованные заголовочные поля).
Future<String> decryptMessage(
  List<int> sessionKey,
  Map<String, dynamic> envelope,
) async {
  final secretBox = SecretBox(
    base64Decode(envelope['ciphertext'] as String),
    nonce: base64Decode(envelope['nonce'] as String),
    mac: Mac(base64Decode(envelope['mac'] as String)),
  );
  final plainBytes = await _aesGcm.decrypt(
    secretBox,
    secretKey: SecretKey(sessionKey),
    aad: _buildAad(envelope),
  );
  return utf8.decode(plainBytes);
}
