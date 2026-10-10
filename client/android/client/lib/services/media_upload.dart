import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../api/api_client.dart';
import '../crypto/media_cipher.dart';
import '../crypto/streaming_file_cipher.dart';
import '../l10n/app_strings.dart';
import 'debug_log.dart';
import '../models/picked_media.dart';
import '../storage/chat_store.dart';
import '../storage/chunked_upload_session_store.dart';
import '../storage/media_cache.dart';
import 'upload_cancel_registry.dart';

/// Порог, с которого файл льётся потоково (шифрование в отдельном изоляте,
/// загрузка целиком уже зашифрованным файлом) — тот же порог, что и раньше
/// жил только в ChatScreen; вынесен сюда, чтобы автоматический повтор после
/// сетевого сбоя (см. PendingSendRetrier) грузил файл ТЕМ ЖЕ путём, что и
/// обычная отправка, без дублирования этой логики в двух местах.
const streamingThresholdBytes = 20 * 1024 * 1024; // 20 МБ

/// Один сетевой шаг чанковой докачки (init / одна часть / список частей /
/// complete) повторяется несколько раз с нарастающей паузой, прежде чем
/// сдаться. Реальный кейс из лога пользователя: постоянные "Failed host
/// lookup: ee2e.oshino.space" — один сетевой блип на одной из ~44 частей
/// ронял всю загрузку 350-МБ файла целиком (`error=Failed to upload file`),
/// хотя докачка для того и сделана, чтобы такое переживать. Отмена
/// пользователем (см. UploadCancelRegistry / cancelToken) НЕ повторяется —
/// сразу пробрасывается наверх.
/// [label] — только для диагностики (см. DebugLog.error ниже), ни на что
/// функционально не влияет. Раньше сбой здесь логировался только в момент
/// падения последней попытки одной строкой без деталей — реальный кейс:
/// части синхронно спотыкались и потом ~40с ничего не летело, а понять,
/// на каком именно шаге и почему (DNS? таймаут? какая именно ошибка?)
/// было нельзя. Теперь
/// каждая проваленная попытка пишет: сколько мс она реально длилась
/// (мгновенный провал = обрыв соединения, долгий = таймаут), точный тип и
/// текст исключения, и сколько ждём перед повтором — этого должно хватить,
/// чтобы в следующий раз понять причину по одному только автоприсланному
/// логу (см. CrashReporter), не выпрашивая телефон физически.
Future<T> _retryChunkedStep<T>(
  Future<T> Function() step, {
  required dio.CancelToken cancelToken,
  int attempts = 5,
  String label = 'chunked-step',
}) async {
  var delay = const Duration(seconds: 2);
  for (var attempt = 1; ; attempt++) {
    final startedAt = DateTime.now();
    try {
      return await step();
    } catch (e) {
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (cancelToken.isCancelled) rethrow;
      if (attempt >= attempts) {
        DebugLog.error(
          '_retryChunkedStep[$label] ОКОНЧАТЕЛЬНО провалено: '
          'attempt=$attempt/$attempts, ${elapsedMs}мс на последнюю попытку, '
          'error=$e (${e.runtimeType})',
        );
        rethrow;
      }
      DebugLog.error(
        '_retryChunkedStep[$label] attempt=$attempt/$attempts провалена за '
        '${elapsedMs}мс: error=$e (${e.runtimeType}) — повтор через '
        '${delay.inSeconds}с',
      );
      await Future<void>.delayed(delay);
      final doubled = delay * 2;
      delay = doubled > const Duration(seconds: 30)
          ? const Duration(seconds: 30)
          : doubled;
    }
  }
}

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

  // Регистрируем токен на всё время загрузки (включая шифрование ниже —
  // не только сам HTTP-запрос) — см. UploadCancelRegistry: единственный
  // способ по-настоящему прервать уже идущую передачу файла, если
  // пользователь нажмёт "Отменить" на сообщении, которое ещё грузится
  // (ТЗ пользователя — раньше отмена только убирала локальные следы, а
  // сама загрузка молча донашивала себя в фоне).
  final cancelToken = UploadCancelRegistry.register(messageId);
  try {
    if (chunked) {
      // Устойчивая (не temp-) папка — ретрай после сбоя сети может
      // случиться и через долгое время (пользователь вернулся в чат позже),
      // а системный temp вправе стереть файл в любой момент, особенно пока
      // приложение не запущено (тот же вывод, что и для PendingSendStore.
      // persistFile/видео-превью — см. chat_screen.dart). Без этого файл
      // на 26% докачки, как в жалобе пользователя, при возврате пришлось бы
      // шифровать и заливать заново с нуля.
      final appDir = await getApplicationSupportDirectory();
      final chunkedDir = Directory('${appDir.path}/chunked_uploads');
      await chunkedDir.create(recursive: true);
      final encTempFile = File('${chunkedDir.path}/enc_$messageId.bin');

      // Шифрует файл заново и открывает НОВУЮ сессию докачки на сервере —
      // общий путь и для самой первой попытки, и для случая, когда старая
      // сессия оказалась недействительной (см. catch ниже).
      Future<
        ({String mediaId, String uploadId, int partSize, Uint8List keyBytes})
      >
      startFreshSession() async {
        // Шифрование целиком в фоновом изоляте — главный изолят (UI) не
        // грузится. Внутри — Uint8List/RandomAccessFile (без List<int>-
        // боксинга и GC-шторма прошлой версии, из-за которого грелся телефон).
        final keyBytes = await StreamingFileCipher.encryptFileInIsolate(
          inputFile: item.file,
          outputFile: encTempFile,
        );

        final totalSize = await encTempFile.length();
        final init = await _retryChunkedStep(
          () => apiClient.initChunkedUpload(token, totalSize),
          cancelToken: cancelToken,
          label: 'init',
        );
        await ChunkedUploadSessionStore.save(
          messageId,
          mediaId: init.mediaId,
          uploadId: init.uploadId,
          partSize: init.partSize,
          keyBase64: base64Encode(keyBytes),
        );
        return (
          mediaId: init.mediaId,
          uploadId: init.uploadId,
          partSize: init.partSize,
          keyBytes: keyBytes,
        );
      }

      String sessionMediaId;
      String sessionUploadId;
      int partSize;
      Uint8List keyBytes;
      Set<int> confirmedParts;

      final existingSession = await ChunkedUploadSessionStore.get(messageId);
      if (existingSession != null && await encTempFile.exists()) {
        try {
          // Источник правды о том, что уже долетело, — сам сервер (см.
          // upload_media_chunked.go), не что-то посчитанное локально.
          // С повтором (см. _retryChunkedStep): на нестабильной сети без
          // этого один блип здесь отправлял нас в startFreshSession —
          // повторное шифрование и заливка ВСЕГО файла с нуля, ровно то,
          // ради чего докачка и делалась. Заново считаем сессию мёртвой
          // только если список частей не отдался и после всех повторов.
          confirmedParts = await _retryChunkedStep(
            () => apiClient.listChunkedParts(
              token,
              existingSession.mediaId,
              existingSession.uploadId,
            ),
            cancelToken: cancelToken,
            label: 'list-parts',
          );
          sessionMediaId = existingSession.mediaId;
          sessionUploadId = existingSession.uploadId;
          partSize = existingSession.partSize;
          keyBytes = base64Decode(existingSession.keyBase64);
        } catch (_) {
          // Пользователь отменил отправку прямо во время повторов — не
          // затевать вместо этого полное перешифрование с нуля.
          if (cancelToken.isCancelled) rethrow;
          // Старая сессия на сервере уже недействительна (например,
          // /complete из прошлой попытки успел выполниться, а локальную
          // запись стереть не успели) — считаем докачку заново.
          await ChunkedUploadSessionStore.clear(messageId);
          final fresh = await startFreshSession();
          sessionMediaId = fresh.mediaId;
          sessionUploadId = fresh.uploadId;
          partSize = fresh.partSize;
          keyBytes = fresh.keyBytes;
          confirmedParts = {};
        }
      } else {
        final fresh = await startFreshSession();
        sessionMediaId = fresh.mediaId;
        sessionUploadId = fresh.uploadId;
        partSize = fresh.partSize;
        keyBytes = fresh.keyBytes;
        confirmedParts = {};
      }

      await ChatStore.updateProcessingStep(
        peerLogin,
        messageId,
        tr('chat.uploading'),
      );

      final totalSize = await encTempFile.length();
      final totalParts = (totalSize / partSize).ceil();

      int partLen(int pn) {
        final offset = (pn - 1) * partSize;
        return (offset + partSize > totalSize) ? totalSize - offset : partSize;
      }

      // Ещё не залитые части (по возрастанию номера).
      final pending = <int>[
        for (var pn = 1; pn <= totalParts; pn++)
          if (!confirmedParts.contains(pn)) pn,
      ];

      // Прогресс считаем по ПОДТВЕРЖДЁННЫМ частям (не по «в полёте»): тело
      // каждой части уходит на сервер целиком, честного in-flight прогресса
      // на этом шаге нет. Части грузятся строго по очереди 1→2→3→…, поэтому
      // процент растёт ровными шагами (часть = 8 МБ; на 300 МБ ~37 шагов).
      var confirmedBytes = 0;
      for (final pn in confirmedParts) {
        if (pn >= 1 && pn <= totalParts) confirmedBytes += partLen(pn);
      }
      var lastReportedPct = -1.0;
      void reportProgress() {
        if (totalSize <= 0) return;
        final pct = (confirmedBytes / totalSize * 100).clamp(0.0, 100.0);
        if (pct - lastReportedPct >= 0.5 || pct >= 100) {
          lastReportedPct = pct;
          onProgress?.call(pct);
        }
      }

      reportProgress();

      Future<void> uploadOnePart(int pn) async {
        final len = partLen(pn);
        final offset = (pn - 1) * partSize;

        await _retryChunkedStep(
          () async {
            // Часть читаем с диска разово (8 МБ) и льём через московский
            // сервер (PUT /upload-media/{id}/part/{n}) — единственный путь.
            // Сервер сам кладёт часть в MinIO по FRP-туннелю.
            final raf = await encTempFile.open();
            final Uint8List chunk;
            try {
              await raf.setPosition(offset);
              chunk = await raf.read(len);
            } finally {
              await raf.close();
            }
            await apiClient.uploadChunkedPart(
              token,
              sessionMediaId,
              sessionUploadId,
              pn,
              chunk,
              cancelToken: cancelToken,
            );
          },
          cancelToken: cancelToken,
          label: 'part $pn',
        );
        confirmedBytes += len;
        reportProgress();
      }

      // Строго последовательно, одним потоком: части 1→2→3→… через
      // московский сервер. Отмена пользователя прилетает исключением
      // изнутри uploadOnePart и пробрасывается наверх.
      for (final pn in pending) {
        await uploadOnePart(pn);
      }

      await _retryChunkedStep(
        () => apiClient.completeChunkedUpload(
          token,
          sessionMediaId,
          sessionUploadId,
          peerAccountIdForUpload,
        ),
        cancelToken: cancelToken,
        label: 'complete',
      );
      await ChunkedUploadSessionStore.clear(messageId);
      try {
        await encTempFile.delete();
      } catch (_) {}
      // Не фатально: файл УЖЕ на сервере. Локальная копия в кэше — лишь
      // оптимизация (не качать свой же файл заново). Если оригинал пикера
      // к этому моменту исчез — просто нет копии, сообщение всё равно
      // 'sent'.
      try {
        await MediaCache.writeFromFile(sessionMediaId, item.file);
      } catch (_) {}
      mediaId = sessionMediaId;
      keyBase64 = base64Encode(keyBytes);
    } else {
      final bytes = await item.file.readAsBytes();
      final encrypted = await encryptFileBytes(bytes);
      await ChatStore.updateProcessingStep(
        peerLogin,
        messageId,
        tr('chat.uploading'),
      );
      // Шифротекст во временный файл — заливка стримит его с диска
      // (честный in-flight прогресс на dart:io-транспорте, не «0% → 100%»).
      final tempDir = await getTemporaryDirectory();
      final encTempFile = File('${tempDir.path}/enc_$messageId.bin');
      await encTempFile.writeAsBytes(encrypted.ciphertext);
      try {
        // Единственный путь: весь файл через московский сервер
        // (POST /upload-media). Сервер сам кладёт объект в MinIO по
        // FRP-туннелю.
        mediaId = await apiClient.uploadEncryptedMediaFileWithProgress(
          token,
          encTempFile.path,
          peerAccountIdForUpload,
          onProgress: (p) => onProgress?.call(p),
          cancelToken: cancelToken,
        );
      } finally {
        try {
          await encTempFile.delete();
        } catch (_) {}
      }
      // Не фатально — см. комментарий в чанковой ветке выше.
      try {
        await MediaCache.write(mediaId, bytes);
      } catch (_) {}
      keyBase64 = base64Encode(encrypted.key);
      nonceBase64 = base64Encode(encrypted.nonce);
      macBase64 = base64Encode(encrypted.mac);
    }
  } finally {
    UploadCancelRegistry.unregister(messageId);
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
