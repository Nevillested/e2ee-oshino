import 'dart:convert';
import 'package:cryptography/cryptography.dart';

final _aesGcm = AesGcm.with256bits();

Future<Map<String, String>> encryptMessage(List<int> sessionKey, String plaintext) async {
  final secretBox = await _aesGcm.encrypt(utf8.encode(plaintext), secretKey: SecretKey(sessionKey));
  return {
    'nonce': base64Encode(secretBox.nonce),
    'ciphertext': base64Encode(secretBox.cipherText),
    'mac': base64Encode(secretBox.mac.bytes),
  };
}

Future<String> decryptMessage(List<int> sessionKey, Map<String, dynamic> envelope) async {
  final secretBox = SecretBox(
    base64Decode(envelope['ciphertext'] as String),
    nonce: base64Decode(envelope['nonce'] as String),
    mac: Mac(base64Decode(envelope['mac'] as String)),
  );
  final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: SecretKey(sessionKey));
  return utf8.decode(plainBytes);
}