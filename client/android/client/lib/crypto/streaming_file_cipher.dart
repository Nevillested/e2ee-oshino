// ignore_for_file: unintended_html_in_doc_comment

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute;
import '../services/debug_log.dart';
import 'native_file_cipher.dart';

/// Потоковое (chunked) шифрование файлов — для больших файлов вместо
/// media_cipher.dart, чтобы не держать весь файл в оперативке. Файл режется
/// на блоки [chunkSize] байт открытого текста; каждый блок — отдельный
/// AES-256-GCM с детерминированным nonce (безопасно: ключ файла случайный
/// и уникальный на отправку) и AAD с номером блока + флагом "последний" —
/// если файл обрежут, расшифровка не увидит блок с isLast=true и упадёт.
///
/// Работает на `Uint8List` + `RandomAccessFile` (раньше был `List<int>` —
/// 8-кратный оверхед по памяти на боксинг + горы GC-мусора от `sublist`/
/// spread на каждом блоке; это и был главный источник нагрева на больших
/// файлах). Сама AES-GCM — чистый Dart из `cryptography`; шифрование и
/// расшифровка целиком выносятся в фоновый изолят (`compute`, см.
/// encryptFileIsolateEntry / decryptFileIsolateEntry), чтобы не грузить
/// UI-поток. Формат блоков самоописательный (длина-префикс), смена
/// [chunkSize] взаимно совместима между клиентами.
class StreamingFileCipher {
  static const int chunkSize = 4 * 1024 * 1024; // 4 МБ на блок
  static final AesGcm _aesGcm = AesGcm.with256bits();

  static Uint8List _nonceForChunk(int index) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, index, Endian.big);
    return nonce;
  }

  static Uint8List _aadForChunk(int index, bool isLast) {
    return Uint8List.fromList(utf8.encode('$index:${isLast ? 1 : 0}'));
  }

  /// Дочитывает [buf] до конца ЛИБО до EOF — `readInto` для файла может
  /// вернуть меньше запрошенного и не на EOF, поэтому крутим до заполнения.
  /// Возвращает сколько всего байт положено в [buf] (< buf.length ⇒ EOF).
  static Future<int> _fill(RandomAccessFile raf, Uint8List buf) async {
    var total = 0;
    while (total < buf.length) {
      final n = await raf.readInto(buf, total);
      if (n == 0) break;
      total += n;
    }
    return total;
  }

  /// Шифрует [inputFile] блоками в [outputFile]. Возвращает случайный
  /// 32-байтный ключ файла — его передают собеседнику отдельно,
  /// зашифрованным через Double Ratchet.
  static Future<Uint8List> encryptFileToFile({
    required File inputFile,
    required File outputFile,
    void Function(double percent)? onProgress,
  }) async {
    final secretKey = await _aesGcm.newSecretKey();
    final keyBytes = Uint8List.fromList(await secretKey.extractBytes());

    final totalSize = await inputFile.length();
    final input = await inputFile.open();
    final sink = outputFile.openWrite();
    final buf = Uint8List(chunkSize);

    try {
      var index = 0;
      var processed = 0;
      while (true) {
        final n = await _fill(input, buf);
        final isLast = n < chunkSize;
        final plain = n == chunkSize
            ? buf
            : Uint8List.sublistView(buf, 0, n);
        await _encryptAndWriteChunk(sink, secretKey, plain, index, isLast: isLast);
        index++;
        processed += n;
        onProgress?.call(totalSize == 0 ? 100 : processed / totalSize * 100);
        if (isLast) break;
      }
    } finally {
      await input.close();
      await sink.close();
    }
    onProgress?.call(100);
    return keyBytes;
  }

  static Future<void> _encryptAndWriteChunk(
    IOSink sink,
    SecretKey key,
    Uint8List plainChunk,
    int index, {
    required bool isLast,
  }) async {
    final secretBox = await _aesGcm.encrypt(
      plainChunk,
      secretKey: key,
      nonce: _nonceForChunk(index),
      aad: _aadForChunk(index, isLast),
    );
    final ct = secretBox.cipherText;
    final mac = secretBox.mac.bytes;
    final header = Uint8List(4);
    ByteData.sublistView(header).setUint32(0, ct.length + mac.length, Endian.big);
    sink.add(header);
    sink.add(ct);
    sink.add(mac);
  }

  /// Расшифровывает файл, зашифрованный [encryptFileToFile], блоками, в
  /// [outputFile]. Бросает, если последний физически присутствующий блок
  /// не помечен isLast=true — значит файл обрезан.
  static Future<void> decryptFileToFile({
    required File inputFile,
    required File outputFile,
    required List<int> keyBytes,
    void Function(double percent)? onProgress,
  }) async {
    final secretKey = SecretKey(keyBytes);
    final totalSize = await inputFile.length();
    final raf = await inputFile.open();
    final sink = outputFile.openWrite();

    var index = 0;
    var offset = 0;
    var sawLast = false;
    final header = Uint8List(4);

    try {
      while (offset < totalSize) {
        if (await _fill(raf, header) < 4) {
          throw Exception('Повреждённый файл: неполный заголовок блока');
        }
        offset += 4;
        final len = ByteData.sublistView(header).getUint32(0, Endian.big);

        final payload = Uint8List(len);
        if (await _fill(raf, payload) < len) {
          throw Exception('Повреждённый файл: блок обрезан');
        }
        offset += len;

        final ct = Uint8List.sublistView(payload, 0, len - 16);
        final mac = Mac(Uint8List.sublistView(payload, len - 16));

        List<int> plainChunk;
        bool isLastChunk;
        try {
          plainChunk = await _aesGcm.decrypt(
            SecretBox(ct, nonce: _nonceForChunk(index), mac: mac),
            secretKey: secretKey,
            aad: _aadForChunk(index, false),
          );
          isLastChunk = false;
        } catch (_) {
          plainChunk = await _aesGcm.decrypt(
            SecretBox(ct, nonce: _nonceForChunk(index), mac: mac),
            secretKey: secretKey,
            aad: _aadForChunk(index, true),
          );
          isLastChunk = true;
        }

        sink.add(plainChunk);
        sawLast = isLastChunk;
        index++;
        onProgress?.call(totalSize == 0 ? 100 : offset / totalSize * 100);
      }
    } finally {
      await raf.close();
      await sink.close();
    }

    if (!sawLast) {
      throw Exception(
        'Файл повреждён или обрезан — отсутствует завершающий блок',
      );
    }
  }

  /// Шифрует файл, НЕ грузя UI-поток: на Android — аппаратный AES через
  /// нативный канал (см. NativeFileCipher, ~4 МБ/с чистого Dart → сотни
  /// МБ/с); везде ещё — чистый Dart в фоновом изоляте (encryptFileIsolateEntry).
  /// Формат байт на диске одинаковый в обоих случаях.
  static Future<Uint8List> encryptFileInIsolate({
    required File inputFile,
    required File outputFile,
  }) async {
    if (NativeFileCipher.isSupported) {
      try {
        return await NativeFileCipher.encryptFileToFile(
          input: inputFile,
          output: outputFile,
        );
      } catch (e) {
        DebugLog.error('NativeFileCipher encrypt failed ($e) — Dart-isolate fallback');
      }
    }
    final keyB64 = await compute(encryptFileIsolateEntry, {
      'input': inputFile.path,
      'output': outputFile.path,
    });
    return base64Decode(keyB64);
  }

  /// См. [encryptFileInIsolate] — то же для расшифровки.
  static Future<void> decryptFileInIsolate({
    required File inputFile,
    required File outputFile,
    required List<int> keyBytes,
  }) async {
    if (NativeFileCipher.isSupported) {
      try {
        await NativeFileCipher.decryptFileToFile(
          input: inputFile,
          output: outputFile,
          keyBytes: keyBytes,
        );
        return;
      } catch (e) {
        DebugLog.error('NativeFileCipher decrypt failed ($e) — Dart-isolate fallback');
      }
    }
    await compute(decryptFileIsolateEntry, {
      'input': inputFile.path,
      'output': outputFile.path,
      'key': base64Encode(keyBytes),
    });
  }
}

/// Точка входа изолята для шифрования (compute). Только простые
/// аргументы/результат — Isolate.run() на этом коде падал "object is
/// unsendable" из-за внутренних _Future в dart:io/cryptography, а compute()
/// с обычной top-level функцией этого избегает.
Future<String> encryptFileIsolateEntry(Map<String, String> args) async {
  final key = await StreamingFileCipher.encryptFileToFile(
    inputFile: File(args['input']!),
    outputFile: File(args['output']!),
  );
  return base64Encode(key);
}

/// Точка входа изолята для расшифровки (compute).
Future<void> decryptFileIsolateEntry(Map<String, String> args) async {
  await StreamingFileCipher.decryptFileToFile(
    inputFile: File(args['input']!),
    outputFile: File(args['output']!),
    keyBytes: base64Decode(args['key']!),
  );
}
