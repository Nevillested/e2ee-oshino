import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';
import '../crypto/media_cipher.dart';
import '../crypto/streaming_file_cipher.dart';
import '../l10n/app_strings.dart';
import '../models/picked_media.dart';
import '../storage/chat_store.dart';
import '../storage/media_cache.dart';

/// Порог, с которого файл льётся потоково (шифрование в отдельном изоляте,
/// загрузка целиком уже зашифрованным файлом) — тот же порог, что и раньше
/// жил только в ChatScreen; вынесен сюда, чтобы автоматический повтор после
/// сетевого сбоя (см. PendingSendRetrier) грузил файл ТЕМ ЖЕ путём, что и
/// обычная отправка, без дублирования этой логики в двух местах.
const streamingThresholdBytes = 20 * 1024 * 1024; // 20 МБ

/// Шифрует и грузит один файл на сервер — общая логика для обычной отправки
/// (ChatScreen._uploadAndDescribeMedia — теперь тонкая обёртка над этим) и
/// автоматического повтора после сбоя сети (PendingSendRetrier), вынесена
/// сюда, чтобы не дублировать шифрование/чанкинг в двух местах.
Future<Map<String, dynamic>> uploadAndDescribeMedia({
  required String peerLogin,
  required PickedMedia item,
  required String messageId,
  required int size,
  required String fileName,
  required String token,
  required String peerAccountIdForUpload,
  void Function(double percent)? onProgress,
}) async {
  final apiClient = ApiClient();
  final chunked = size > streamingThresholdBytes;
  String mediaId;
  String keyBase64;
  String? nonceBase64;
  String? macBase64;

  await ChatStore.updateProcessingStep(
    peerLogin,
    messageId,
    tr('chat.encrypting'),
  );

  if (chunked) {
    final tempDir = await getTemporaryDirectory();
    final encTempFile = File('${tempDir.path}/enc_$messageId.bin');
    final inputPath = item.file.path;
    final outputPath = encTempFile.path;
    final keyPath = '${tempDir.path}/key_$messageId.bin';
    await compute(encryptFileIsolateEntry, {
      'input': inputPath,
      'output': outputPath,
      'key': keyPath,
    });
    final keyBytes = await File(keyPath).readAsBytes();
    try {
      await File(keyPath).delete();
    } catch (_) {}

    await ChatStore.updateProcessingStep(
      peerLogin,
      messageId,
      tr('chat.uploading'),
    );
    mediaId = await apiClient.uploadEncryptedMediaFileWithProgress(
      token,
      encTempFile.path,
      peerAccountIdForUpload,
      onProgress: (p) => onProgress?.call(p),
    );
    try {
      await encTempFile.delete();
    } catch (_) {}
    await MediaCache.writeFromFile(mediaId, item.file);
    keyBase64 = base64Encode(keyBytes);
  } else {
    final bytes = await item.file.readAsBytes();
    final encrypted = await encryptFileBytes(bytes);
    await ChatStore.updateProcessingStep(
      peerLogin,
      messageId,
      tr('chat.uploading'),
    );
    // uploadEncryptedMediaWithProgress (байты целиком через
    // MultipartFile.fromBytes) отдаёт dio ОДНИМ куском — прогресс из-за
    // этого не дробится на промежуточные тики, только 0% и сразу 100%
    // (жалоба пользователя: "должно быть постепенное изменение"). Пишем
    // шифротекст во временный файл и грузим тем же файловым методом, что
    // и "тяжёлый" путь ниже — MultipartFile.fromFile читает файл потоком
    // и репортит прогресс по-настоящему постепенно.
    final tempDir = await getTemporaryDirectory();
    final encTempFile = File('${tempDir.path}/enc_$messageId.bin');
    await encTempFile.writeAsBytes(encrypted.ciphertext);
    try {
      mediaId = await apiClient.uploadEncryptedMediaFileWithProgress(
        token,
        encTempFile.path,
        peerAccountIdForUpload,
        onProgress: (p) => onProgress?.call(p),
      );
    } finally {
      try {
        await encTempFile.delete();
      } catch (_) {}
    }
    await MediaCache.write(mediaId, bytes);
    keyBase64 = base64Encode(encrypted.key);
    nonceBase64 = base64Encode(encrypted.nonce);
    macBase64 = base64Encode(encrypted.mac);
  }

  await ChatStore.updateMediaInfo(
    peerLogin,
    messageId,
    mediaId: mediaId,
    keyBase64: keyBase64,
    nonceBase64: nonceBase64,
    macBase64: macBase64,
  );

  return {
    'message_id': messageId,
    'media_id': mediaId,
    'key': keyBase64,
    'nonce': nonceBase64,
    'mac': macBase64,
    'file_name': fileName,
    'is_file': item.isFile,
    'is_video': item.isVideo,
    'file_size': size,
    'chunked': chunked,
    'spoiler': item.isSpoiler,
  };
}
