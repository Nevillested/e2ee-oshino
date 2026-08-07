import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

final _aesGcm = AesGcm.with256bits();

/// Шифрование файлов — отдельный, случайный ключ на каждый файл, не
/// связанный с Double Ratchet (файлы могут быть большими и переотправляться
/// повторно, поэтому не тратим на них ключи из цепочки сообщений).
class EncryptedFile {
  final List<int> key;
  final List<int> nonce;
  final List<int> mac;
  final Uint8List ciphertext;
  EncryptedFile(this.key, this.nonce, this.mac, this.ciphertext);
}

Future<EncryptedFile> encryptFileBytes(Uint8List plainBytes) async {
  final secretKey = await _aesGcm.newSecretKey();
  final secretBox = await _aesGcm.encrypt(plainBytes, secretKey: secretKey);
  return EncryptedFile(
    await secretKey.extractBytes(),
    secretBox.nonce,
    secretBox.mac.bytes,
    Uint8List.fromList(secretBox.cipherText),
  );
}

Future<Uint8List> decryptFileBytes({
  required List<int> key,
  required List<int> nonce,
  required List<int> mac,
  required Uint8List ciphertext,
}) async {
  final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
  final plainBytes = await _aesGcm.decrypt(secretBox, secretKey: SecretKey(key));
  return Uint8List.fromList(plainBytes);
}