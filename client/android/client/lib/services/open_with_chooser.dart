import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Мост к нативному "открыть через..." на Android (MainActivity.kt) — ТЗ
/// пользователя: тап по файлу в чате должен ВСЕГДА показывать системный
/// диалог выбора приложения, а не молча открывать в том, что назначено
/// умолчанием. Плагин open_file (см. его использование раньше в
/// chat_screen.dart) внутри делает голый Intent.ACTION_VIEW +
/// startActivity() без Intent.createChooser() — если для типа файла есть
/// приложение "по умолчанию", открывает СРАЗУ в нём, без вопроса; диалог
/// выбора Android сам показывает только когда подходящих приложений
/// несколько И среди них ещё не выбрано "всегда". Обойти это можно только
/// нативно — здесь.
///
/// Не на Android (или если сам вызов почему-то не удался) — вызывающая
/// сторона сама решает, что делать (см. её fallback на OpenFile.open).
class OpenWithChooser {
  OpenWithChooser._();

  static const _channel = MethodChannel('oshinobu/open_with_chooser');

  /// true — чем-то удалось открыть (сам факт показа диалога выбора тоже
  /// считается успехом, дальше это уже не наша забота). false — на
  /// устройстве нет вообще ни одного приложения для этого типа файла, либо
  /// платформа не Android/канал недоступен.
  static Future<bool> open(String path, {String? mimeType}) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('open', {
        'path': path,
        'mimeType': mimeType,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('OpenWithChooser.open FAILED: $e');
      return false;
    }
  }
}
