import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Постоянный лог-файл на устройстве — в отличие от debugPrint (который
/// вообще не пишется в release-сборке, а даже в debug исчезает вместе с
/// закрытым логкатом), переживает и release, и закрытие приложения.
/// Нужен, чтобы ловить редкие/неуловимые баги (например "пуш пришёл, а
/// сообщение не появилось") постфактум — пользователь замечает баг не
/// сидя рядом с компьютером с adb, а этот файл всегда можно прислать
/// потом (см. кнопку "Поделиться логом" в about_screen.dart).
///
/// ВАЖНО: сюда пишутся только метаданные (тип события, ID, статусы) —
/// НИКОГДА содержимое сообщений. Это E2EE-мессенджер, лог, который может
/// однажды кто-то переслать нам на разбор, не должен быть местом, где
/// случайно осела расшифрованная переписка.
class DebugLog {
  // Подробное «трассирующее» логирование closed-тестирования снято (см.
  // обсуждение с пользователем): теперь сюда пишутся в основном ошибки и
  // их причины, штатный happy-path почти не шумит. 1 МБ с запасом хватает
  // на историю ошибок и остаётся достаточно компактным, чтобы пользователь
  // мог прислать файл целиком.
  static const _maxBytes = 1 * 1024 * 1024;
  static File? _file;
  // Простая последовательная очередь записи — несколько параллельных
  // log() из разных мест (WS, MessageRouter, пуши) иначе могли бы
  // гоняться за одним и тем же файлом и терять строки.
  static Future<void> _writeChain = Future.value();

  static Future<File> _getFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/debug_log.txt');
    return _file!;
  }

  static void log(String message) {
    _writeChain = _writeChain.then((_) => _append(message)).catchError((_) {});
  }

  static Future<void> _append(String message) async {
    try {
      final file = await _getFile();
      final line = '${DateTime.now().toIso8601String()} $message\n';
      await file.writeAsString(line, mode: FileMode.append, flush: true);
      final len = await file.length();
      if (len > _maxBytes) await _trim(file);
    } catch (_) {
      // Диск недоступен/переполнен — лог не критичен для работы
      // приложения, просто теряем эту строку.
    }
  }

  static Future<void> _trim(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final keep = bytes.sublist(bytes.length - _maxBytes ~/ 2);
      await file.writeAsBytes(keep, flush: true);
    } catch (_) {}
  }

  static Future<File> getFile() => _getFile();

  // Разовое обнуление у уже установленных пользователей — лог разросся за
  // время closed-тестирования (см. _maxBytes выше — поднимался несколько
  // раз), у части пользователей файл, который они шлют через "Поделиться
  // логом", стал неудобно большим. Флаг в SharedPreferences гарантирует,
  // что это сработает РОВНО один раз за всё время жизни установки — при
  // следующих запусках (и на новых установках, где флаг сразу true с
  // первого чтения — а не в этом случае, см. ниже) больше ничего не трогает.
  // Ключ версионируется: смена суффикса => разовая очистка срабатывает
  // заново у всех при следующем обновлении. Поднят до v2 в сборке, где
  // с трассирующего логирования closed-тестирования вернулись к
  // «только ошибки» — у пользователей за время теста накопились
  // многомегабайтные логи, которые больше не нужны.
  static const _resetOnceKey = 'debug_log_reset_once_v2';

  static Future<void> resetOnceIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_resetOnceKey) ?? false) return;
      await prefs.setBool(_resetOnceKey, true);
      final file = await _getFile();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Не критично — максимум лог останется прежнего размера ещё раз.
    }
  }

  /// Ручная очистка по кнопке в настройках (см. about_screen.dart, ТЗ
  /// пользователя — "если разросся, пользователь мог его сам сбросить"),
  /// в отличие от resetOnceIfNeeded выше — не разовая миграция, а
  /// действие, доступное в любой момент.
  static Future<void> clear() async {
    final file = await _getFile();
    if (await file.exists()) await file.delete();
  }
}
