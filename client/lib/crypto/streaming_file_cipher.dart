// ignore_for_file: unintended_html_in_doc_comment

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Потоковое (chunked) шифрование файлов — используется для больших
/// файлов вместо media_cipher.dart, чтобы не держать весь файл целиком
/// в оперативной памяти (именно это раньше вызывало OutOfMemoryError на
/// файлах ~100МБ). Файл режется на блоки по [chunkSize] байт открытого
/// текста; каждый блок шифруется отдельно AES-256-GCM с детерминированным
/// nonce (безопасно — ключ файла случайный и уникальный для каждой
/// отправки, поэтому nonce на основе номера блока никогда не повторяется
/// для одного и того же ключа) и AAD, содержащим номер блока и флаг
/// "это последний блок" — если файл обрежут (случайно или специально),
/// расшифровка обнаружит отсутствие блока с флагом isLast=true.
class StreamingFileCipher {
  static const int chunkSize = 4 * 1024 * 1024; // 4 МБ на блок
  static final _aesGcm = AesGcm.with256bits();

  static List<int> _nonceForChunk(int index) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, index, Endian.big);
    return nonce;
  }

  static List<int> _aadForChunk(int index, bool isLast) {
    return utf8.encode('$index:${isLast ? 1 : 0}');
  }

  /// Шифрует [inputFile] блоками в [outputFile]. Возвращает случайный
  /// ключ файла (32 байта) — его нужно передать собеседнику отдельно,
  /// зашифрованным через Double Ratchet, как и обычный файловый ключ.
  static Future<List<int>> encryptFileToFile({
    required File inputFile,
    required File outputFile,
    void Function(double percent)? onProgress,
  }) async {
    final secretKey = await _aesGcm.newSecretKey();
    final keyBytes = await secretKey.extractBytes();

    final totalSize = await inputFile.length();
    final sink = outputFile.openWrite();

    var index = 0;
    var processed = 0;
    var buffer = <int>[];

    await for (final part in inputFile.openRead()) {
      buffer.addAll(part);
      while (buffer.length >= chunkSize) {
        final chunk = buffer.sublist(0, chunkSize);
        buffer = buffer.sublist(chunkSize);
        await _encryptAndWriteChunk(sink, secretKey, chunk, index, isLast: false);
        index++;
        processed += chunk.length;
        onProgress?.call(totalSize == 0 ? 100 : processed / totalSize * 100);
      }
    }

    // Последний блок (может быть неполным или даже пустым для файла,
    // размер которого кратен chunkSize) — обязательно с флагом isLast.
    await _encryptAndWriteChunk(sink, secretKey, buffer, index, isLast: true);

    await sink.close();
    onProgress?.call(100);
    return keyBytes;
  }


  static Future<void> _encryptAndWriteChunk(
    IOSink sink,
    SecretKey key,
    List<int> plainChunk,
    int index, {
    required bool isLast,
  }) async {
    final secretBox = await _aesGcm.encrypt(
      plainChunk,
      secretKey: key,
      nonce: _nonceForChunk(index),
      aad: _aadForChunk(index, isLast),
    );

    final payload = <int>[...secretBox.cipherText, ...secretBox.mac.bytes];
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    sink.add(header.buffer.asUint8List());
    sink.add(payload);
  }

  /// Расшифровывает файл, зашифрованный [encryptFileToFile], блоками, в
  /// [outputFile]. Бросает исключение, если последний физически
  /// присутствующий блок не помечен isLast=true — значит файл обрезан.
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

    try {
      while (offset < totalSize) {
        final headerBytes = await raf.read(4);
        if (headerBytes.length < 4) {
          throw Exception('Повреждённый файл: неполный заголовок блока');
        }
        final len = ByteData.sublistView(Uint8List.fromList(headerBytes)).getUint32(0, Endian.big);
        offset += 4;

        final payload = await raf.read(len);
        if (payload.length < len) {
          throw Exception('Повреждённый файл: блок обрезан');
        }
        offset += len;

        final cipherText = payload.sublist(0, payload.length - 16);
        final mac = payload.sublist(payload.length - 16);

        List<int> plainChunk;
        bool isLastChunk;
        try {
          plainChunk = await _aesGcm.decrypt(
            SecretBox(cipherText, nonce: _nonceForChunk(index), mac: Mac(mac)),
            secretKey: secretKey,
            aad: _aadForChunk(index, false),
          );
          isLastChunk = false;
        } catch (_) {
          plainChunk = await _aesGcm.decrypt(
            SecretBox(cipherText, nonce: _nonceForChunk(index), mac: Mac(mac)),
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
      throw Exception('Файл повреждён или обрезан — отсутствует завершающий блок');
    }
  }
}

/// Точка входа для изолята через compute() — top-level функция строго
/// одного простого аргумента (Map<String,String>) и одного простого
/// результата (String), это единственный по-настоящему надёжный способ
/// передать работу в отдельный поток здесь: Isolate.run() на практике
/// падал с "object is unsendable", ссылаясь на внутренние _Future из
/// dart:io/cryptography, даже когда мы передавали только строки —
/// видимо, что-то в цепочке шифрования тянет за собой непередаваемое
/// состояние при упаковке самого замыкания. compute() избегает этого,
/// потому что использует обычную top-level функцию как точку входа
/// нового изолята, а не сериализует произвольное замыкание целиком.
Future<String> encryptFileIsolateEntry(Map<String, String> args) async {
  final inputPath = args['input']!;
  final outputPath = args['output']!;
  final keyPath = args['key']!;

  final keyBytes = await StreamingFileCipher.encryptFileToFile(
    inputFile: File(inputPath),
    outputFile: File(outputPath),
  );
  await File(keyPath).writeAsBytes(keyBytes);
  return keyPath;
}