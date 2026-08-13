import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

class MediaCache {
  static Future<File> fileFor(String mediaId) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/media_cache_$mediaId');
  }

  static Future<bool> exists(String mediaId) async {
    final file = await fileFor(mediaId);
    return file.exists();
  }

  static Future<Uint8List?> read(String mediaId) async {
    final file = await fileFor(mediaId);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  }

  static Future<void> write(String mediaId, Uint8List bytes) async {
    final file = await fileFor(mediaId);
    await file.writeAsBytes(bytes);
  }

  /// Копирует уже существующий файл с диска (например, оригинал,
  /// который мы сами только что отправили) в кэш без прохода через
  /// оперативную память — обычная файловая операция копирования.
  static Future<void> writeFromFile(String mediaId, File source) async {
    final dest = await fileFor(mediaId);
    await source.copy(dest.path);
  }
}
