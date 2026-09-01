import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Состояние докачки большого файла по кусочкам (см. media_upload.dart),
/// пережившее сбой сети или закрытие приложения — единственное, что нужно
/// помнить у СЕБЯ, чтобы при повторной попытке не заливать файл заново с
/// нуля: сам сервер своего состояния не хранит (см. upload_media_chunked.go
/// на сервере — единственный источник правды там MinIO/ListObjectParts).
///
/// Ключ записи — messageId, тот же самый id, с которым PendingSendRetrier
/// вызывает uploadAndDescribeMedia повторно (job['id']), поэтому найти
/// "свою" незавершённую сессию при ретрае — просто чтение по messageId, без
/// какой-либо дополнительной проводки через PendingSendStore/StoredMessage.
class ChunkedUploadSessionStore {
  static const _storage = FlutterSecureStorage();
  static String _key(String messageId) => 'chunked_upload_session_$messageId';

  static Future<
    ({String mediaId, String uploadId, int partSize, String keyBase64})?
  >
  get(String messageId) async {
    final raw = await _storage.read(key: _key(messageId));
    if (raw == null) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return (
      mediaId: j['media_id'] as String,
      uploadId: j['upload_id'] as String,
      partSize: j['part_size'] as int,
      keyBase64: j['key_base64'] as String,
    );
  }

  static Future<void> save(
    String messageId, {
    required String mediaId,
    required String uploadId,
    required int partSize,
    required String keyBase64,
  }) {
    return _storage.write(
      key: _key(messageId),
      value: jsonEncode({
        'media_id': mediaId,
        'upload_id': uploadId,
        'part_size': partSize,
        'key_base64': keyBase64,
      }),
    );
  }

  static Future<void> clear(String messageId) {
    return _storage.delete(key: _key(messageId));
  }
}
