import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

class MediaCache {
  // Путь к временной директории не меняется за время жизни процесса —
  // резолвим его (единственный асинхронный шаг, платформенный вызов) один
  // раз и переиспользуем, вместо того чтобы каждый раз заново идти в
  // async getTemporaryDirectory(). Именно это и открывает дорогу к
  // existsSync() ниже — синхронной проверке "файл уже здесь", без которой
  // ЛЮБАЯ проверка неизбежно проходит через FutureBuilder и минимум один
  // кадр "не готово" — даже для файла, который на самом деле уже лежит на
  // диске (реальная жалоба пользователя: у уже скачанных фото на долю
  // секунды мелькает текст "Скачивание/В очереди", потому что сам факт
  // асинхронности проверки, а не факт отсутствия файла, и создавал вспышку).
  static Directory? _dirCache;

  static Future<Directory> _dir() async {
    return _dirCache ??= await getTemporaryDirectory();
  }

  /// Вызывать один раз при старте приложения (см. main.dart), до первого
  /// открытия чата — прогревает _dirCache, чтобы existsSync() ниже уже
  /// работал к моменту первой отрисовки списка сообщений.
  static Future<void> warmUp() async {
    await _dir();
  }

  static Future<File> fileFor(String mediaId) async {
    final dir = await _dir();
    return File('${dir.path}/media_cache_$mediaId');
  }

  static Future<bool> exists(String mediaId) async {
    final file = await fileFor(mediaId);
    return file.exists();
  }

  /// Синхронный аналог exists() — единственный способ узнать "файл уже на
  /// устройстве" ДО первой отрисовки виджета, без прохода через
  /// FutureBuilder (см. комментарий у _dirCache выше). Если _dirCache ещё
  /// не прогрет (warmUp() почему-то не был вызван/не успел) — безопасный
  /// дефолт false: в худшем случае лишний раз покажется текст закачки,
  /// вместо того чтобы соврать "файла нет" и не показать существующий.
  static bool existsSync(String mediaId) {
    final dir = _dirCache;
    if (dir == null) return false;
    return File('${dir.path}/media_cache_$mediaId').existsSync();
  }

  static Future<Uint8List?> read(String mediaId) async {
    final file = await fileFor(mediaId);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  }

  /// Синхронный аналог read() — для уже подтверждённо существующего файла
  /// (см. existsSync) позволяет прочитать готовые байты превью прямо в
  /// build(), без единого кадра ожидания/спиннера (ТЗ пользователя: "почему
  /// нельзя сразу отображать превью фото?"). Годится только для маленьких
  /// файлов уровня фото-превью — намеренно НЕ используется для полноразмерных
  /// видео/голосовых (там синхронное чтение на UI-потоке заметно подвесило
  /// бы кадр, да и превью для них всё равно не читается напрямую отсюда, а
  /// генерируется отдельно, см. generateVideoThumbnail).
  static Uint8List? readSync(String mediaId) {
    final dir = _dirCache;
    if (dir == null) return null;
    final file = File('${dir.path}/media_cache_$mediaId');
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
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

  /// Стирает расшифрованный кэш одного файла — часть полной зачистки
  /// удалённого сообщения (см. purgeMessageArtifacts, ТЗ пользователя:
  /// удаление должно быть полным сбросом, а не просто исчезновением из
  /// списка). Тихий no-op, если файла и так уже нет.
  static Future<void> delete(String mediaId) async {
    final file = await fileFor(mediaId);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// "Очистить кэш медиа" в настройках (ТЗ пользователя) — стирает ВСЕ
  /// расшифрованные файлы разом, только по префиксу media_cache_ (во
  /// временной папке лежат и другие, не относящиеся к этому кэшу файлы —
  /// временные файлы шифрования при отправке, кадры-превью и т.п., их
  /// трогать нельзя). Сама переписка (ChatStore — mediaId/ключи/nonce/mac)
  /// не трогается вообще, поэтому любой файл после этого просто скачается
  /// и расшифруется заново по обычному пути (см. _resolvePhotoBytes/
  /// _resolveRecordedMediaFile в chat_screen.dart — они уже сами проверяют
  /// MediaCache.exists и докачивают, если файла нет).
  static Future<int> clearAll() async {
    final dir = await getTemporaryDirectory();
    var count = 0;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('media_cache_')) continue;
        try {
          await entity.delete();
          count++;
        } catch (_) {}
      }
    } catch (_) {}
    return count;
  }

  /// Суммарный размер кэша в байтах — для подтверждения перед очисткой
  /// (ТЗ пользователя: "нужно выводить, сколько места будет освобождено").
  /// Тот же префиксный фильтр, что и в clearAll — считаем ровно то, что
  /// потом реально удалится, не больше.
  static Future<int> totalSize() async {
    final dir = await getTemporaryDirectory();
    var total = 0;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('media_cache_')) continue;
        try {
          total += await entity.length();
        } catch (_) {}
      }
    } catch (_) {}
    return total;
  }
}
