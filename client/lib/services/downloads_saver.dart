import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Мост к нативному "сохранить в Download/Oshinobu" на Android
/// (MainActivity.kt) — ТЗ пользователя: "Сохранить на устройство" должно
/// класть файл в предсказуемое фиксированное место, а не открывать
/// системный SAF-диалог "Сохранить как" (file_picker.saveFile) — тот на
/// части устройств/эмуляторов без нормального Files-провайдера просто
/// ничего не показывает (реальный кейс с эмулятора, разбор с пользователем).
///
/// Передаём путь к уже расшифрованному файлу на диске (не байты) — нативная
/// сторона сама копирует его потоково, без прохода через Dart-память и
/// сериализацию канала для потенциально огромного файла.
class DownloadsSaver {
  DownloadsSaver._();

  static const _channel = MethodChannel('oshinobu/save_to_downloads');

  /// Возвращает человекочитаемый путь ("Download/Oshinobu/файл.pdf") при
  /// успехе, null — если не на Android или сохранение не удалось.
  static Future<String?> save(String sourcePath, String fileName) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('save', {
        'sourcePath': sourcePath,
        'fileName': fileName,
      });
    } catch (e) {
      debugPrint('DownloadsSaver.save FAILED: $e');
      return null;
    }
  }
}
