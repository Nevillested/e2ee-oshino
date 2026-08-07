import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Кэш уже расшифрованных медиафайлов на диске. Без него каждое открытие
/// экрана чата заново скачивало бы файл с сервера и расшифровывало его —
/// дорого по трафику и по времени. Хранится в расшифрованном виде — это
/// касается только локального дискового кэша, не передачи по сети, и
/// согласуется с тем, что история сообщений тоже хранится расшифрованной.
class MediaCache {
  static Future<File> _fileFor(String mediaId) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/media_cache_$mediaId');
  }

  static Future<Uint8List?> read(String mediaId) async {
    final file = await _fileFor(mediaId);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  }

  static Future<void> write(String mediaId, Uint8List bytes) async {
    final file = await _fileFor(mediaId);
    await file.writeAsBytes(bytes);
  }
}