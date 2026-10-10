import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Мост к аппаратному AES-256-GCM для файлов (см.
/// android/.../FileCipher.kt). Формат байт на диске идентичен
/// [StreamingFileCipher] — тот же файл читается и нативным, и Dart-путём.
///
/// Только Android. На остальных платформах [isSupported] == false и
/// вызывающая сторона ([StreamingFileCipher.encryptFileInIsolate] /
/// [decryptFileInIsolate]) сама откатывается на чистый Dart в изоляте.
class NativeFileCipher {
  static const MethodChannel _channel = MethodChannel('oshinobu/file_cipher');

  static bool get isSupported => Platform.isAndroid;

  /// Шифрует [input] в [output], возвращает случайный 32-байтный ключ файла.
  static Future<Uint8List> encryptFileToFile({
    required File input,
    required File output,
  }) async {
    final keyB64 = await _channel.invokeMethod<String>('encryptFile', {
      'input': input.path,
      'output': output.path,
    });
    if (keyB64 == null) {
      throw StateError('native encryptFile вернул null');
    }
    return base64Decode(keyB64);
  }

  /// Расшифровывает [input] в [output]. Бросает при обрыве/подмене/неверном ключе.
  static Future<void> decryptFileToFile({
    required File input,
    required File output,
    required List<int> keyBytes,
  }) {
    return _channel.invokeMethod('decryptFile', {
      'input': input.path,
      'output': output.path,
      'key': base64Encode(keyBytes),
    });
  }
}
