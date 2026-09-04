import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../config.dart';
import '../l10n/app_strings.dart';
import 'dart:typed_data';
import 'package:dio/dio.dart' as dio;
import 'package:dio/io.dart' show IOHttpClientAdapter;
import 'package:native_dio_adapter/native_dio_adapter.dart';
import 'package:cronet_http/cronet_http.dart' show CronetEngine;
import 'dart:io';
import '../services/debug_log.dart';

/// Отдельный тип ошибки для сетевых/серверных проблем — так их удобно
/// ловить в UI через try/catch и показывать пользователю e.toString().
class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}

class ApiClient {
  /// Таймауты для загрузки/скачивания медиа (см. uploadEncryptedMediaFileWithProgress/
  /// downloadEncryptedMediaToFile) — без них у dio.Dio() таймаутов НЕТ
  /// ВООБЩЕ: на "мёртвой" сети без явной ошибки (не офлайн — тот падает
  /// быстро и чисто, а именно тишина: соединение вроде установилось, но
  /// дальше ни ответа, ни ошибки — слабый мобильный сигнал, обрывающий
  /// зависшие соединения NAT/прокси и т.п.) await мог виснуть сколь угодно
  /// долго, ни разу не попадая в catch — сообщение навсегда застревало на
  /// "Шифрование…"/"Загрузка на сервер…", без единой строки в логе.
  ///
  /// Значения намеренно щедрые, не под конкретный размер файла — connect
  /// короткий (устанавливаться соединение обязано быстро, если сеть
  /// вообще способна отвечать), send/receive куда длиннее (реальный кейс
  /// с устройства: 8 МБ видео честно грузились 24с на плохой сети — резкий
  /// таймаут убил бы рабочую, просто медленную передачу). Это страховка от
  /// бесконечного зависания, а не тонкая настройка — если по свежим логам
  /// окажется, что эти значения сами обрубают что-то живое, поправим по
  /// факту.
  static const _mediaConnectTimeout = Duration(seconds: 15);
  static const _mediaTransferTimeout = Duration(minutes: 5);

  // ОДИН общий Dio на все медиа-запросы (presigned PUT/GET файлов) за всё
  // время жизни приложения — раньше _mediaDioClient() создавал новый на
  // КАЖДЫЙ вызов, то есть каждая часть чанковой загрузки заново поднимала
  // TCP+TLS (на RTT ~150–200 мс это ~0.3–0.5 c впустую на часть). Теперь
  // соединения переиспользуются между частями и повторами.
  //
  // Транспорт — NativeAdapter: на Android это Cronet (из Google Play
  // Services, вес APK ~0), даёт HTTP/2, а когда на токийском nginx включат
  // http3 — ещё и QUIC/BBR (одиночный TCP на международном плече упирается
  // в окно, у QUIC этой проблемы нет). На iOS — URLSession. Если Cronet-
  // провайдер на устройстве выключен (AOSP-эмулятор, девайс без GMS) —
  // createFallbackAdapter возвращает обычный dart:io-транспорт.
  static dio.Dio? _sharedMediaDio;

  dio.Dio _mediaDioClient() {
    return _sharedMediaDio ??= dio.Dio(
      dio.BaseOptions(
        connectTimeout: _mediaConnectTimeout,
        sendTimeout: _mediaTransferTimeout,
        receiveTimeout: _mediaTransferTimeout,
      ),
    )..httpClientAdapter = NativeAdapter(
      createCronetEngine: () => CronetEngine.build(
        enableHttp2: true,
        enableQuic: true,
        enableBrotli: false, // медиа зашифрованы — сжимать нечего
      ),
      createFallbackAdapter: (error, stackTrace) {
        DebugLog.log(
          'media transport: Cronet недоступен ($error) — dart:io fallback',
        );
        return IOHttpClientAdapter();
      },
    );
  }

  /// POST /register — регистрация нового аккаунта.
  /// Возвращает otpauth:// ссылку для приложения-аутентификатора.
  Future<String> register(
    String login,
    String password,
    String inviteCode,
  ) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'login': login,
        'password': password,
        'invite_code': inviteCode,
      }),
    );

    if (response.statusCode == 409) {
      throw ApiException(tr('error.loginTaken'));
    }
    if (response.statusCode == 403) {
      throw ApiException(tr('error.loginReserved'));
    }
    if (response.statusCode == 422) {
      throw ApiException(tr('error.inviteCodeInvalid'));
    }
    if (response.statusCode != 200) {
      throw ApiException(
        '${tr('error.registerFailed')} (${response.statusCode})',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['totp_url'] as String;
  }

  /// POST /account/recover/request — запросить код восстановления пароля.
  /// Сервер различает три исхода отдельными статусами: 404 — такого логина
  /// нет, 422 — логин есть, но почта не указана, 200 — код отправлен.
  Future<void> requestPasswordRecovery(String login) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/account/recover/request'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'login': login}),
    );
    if (response.statusCode == 404) {
      throw ApiException(tr('error.recoveryUserNotFound'));
    }
    if (response.statusCode == 422) {
      throw ApiException(tr('error.recoveryNoEmailOnFile'));
    }
    if (response.statusCode != 200) {
      throw ApiException(tr('error.recoveryRequestFailed'));
    }
  }

  /// POST /account/recover/verify — проверить код восстановления, не
  /// расходуя его (реальная смена пароля — отдельный вызов ниже).
  Future<void> verifyRecoveryCode(String login, String token) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/account/recover/verify'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'login': login, 'token': token}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.recoveryWrongCode'));
    }
  }

  /// POST /account/recover/reset — задать новый пароль по коду
  /// восстановления. Код на сервере одноразовый — расходуется этим вызовом.
  Future<void> resetPasswordWithRecoveryCode(
    String login,
    String token,
    String newPassword,
  ) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/account/recover/reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'login': login,
        'token': token,
        'new_password': newPassword,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.recoveryWrongCode'));
    }
  }

  /// POST /account/recover/reset-totp — как resetPasswordWithRecoveryCode
  /// выше, но для восстановления доступа к аутентификатору: вводить
  /// нечего (новый секрет сервер генерирует сам, случайный), в ответ —
  /// та же форма, что при регистрации (otpauth-ссылка), дальше подходит
  /// тот же экран подтверждения (VerifyTotpScreen).
  Future<String> resetTotpWithRecoveryCode(String login, String token) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/account/recover/reset-totp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'login': login, 'token': token}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.recoveryWrongCode'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['totp_url'] as String;
  }

  /// POST /verify-totp — подтверждение первого TOTP-кода после регистрации.
  Future<void> verifyTotp(String login, String code) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/verify-totp'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'login': login, 'code': code}),
    );

    if (response.statusCode != 200) {
      throw ApiException(tr('error.wrongTotpCode'));
    }
  }

  Future<String> uploadEncryptedMediaFileWithProgress(
    String token,
    String filePath,
    String recipientAccountId, {
    required void Function(double percent) onProgress,
    dio.CancelToken? cancelToken,
  }) async {
    final client = _mediaDioClient();
    final length = await File(filePath).length();
    final formData = dio.FormData.fromMap({
      'recipient_account_id': recipientAccountId,
      'file': await dio.MultipartFile.fromFile(
        filePath,
        filename: 'encrypted.bin',
      ),
    });

    try {
      final response = await client.post<String>(
        '${ApiConfig.baseUrl}/upload-media',
        data: formData,
        options: dio.Options(
          headers: {'Authorization': 'Bearer $token'},
          responseType: dio.ResponseType.plain,
        ),
        cancelToken: cancelToken,
        onSendProgress: (sent, total) {
          final effectiveTotal = total > 0 ? total : length;
          if (effectiveTotal > 0) onProgress(sent / effectiveTotal * 100);
        },
      );

      if (response.statusCode != 200 || response.data == null) {
        throw ApiException(tr('error.uploadFailed'));
      }
      return response.data!;
    } on dio.DioException catch (e) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw ApiException(tr('error.cancelledByUser'));
      }
      throw ApiException(tr('error.uploadFailed'));
    }
  }

  /// POST /upload-media/init — начать докачку большого файла по кусочкам
  /// (см. media_upload.dart). Сервер сам выбирает media_id и фиксированный
  /// размер части — возвращает их вместе с upload_id, который дальше нужен
  /// каждому следующему вызову части/списка частей/завершения.
  Future<({String mediaId, String uploadId, int partSize})> initChunkedUpload(
    String token,
    int sizeBytes,
  ) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/upload-media/init'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'size_bytes': sizeBytes}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.uploadFailed'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (
      mediaId: data['media_id'] as String,
      uploadId: data['upload_id'] as String,
      partSize: data['part_size'] as int,
    );
  }

  /// PUT /upload-media/{mediaId}/part/{partNumber} — залить одну часть файла
  /// (part_number начинается с 1, как того требует сам S3/MinIO).
  Future<void> uploadChunkedPart(
    String token,
    String mediaId,
    String uploadId,
    int partNumber,
    Uint8List data, {
    dio.CancelToken? cancelToken,
    void Function(double percent)? onProgress,
  }) async {
    final client = _mediaDioClient();
    try {
      final response = await client.put(
        '${ApiConfig.baseUrl}/upload-media/$mediaId/part/$partNumber',
        data: data,
        options: dio.Options(
          headers: {
            'Authorization': 'Bearer $token',
            dio.Headers.contentLengthHeader: data.length,
          },
          responseType: dio.ResponseType.plain,
        ),
        queryParameters: {'upload_id': uploadId},
        cancelToken: cancelToken,
        onSendProgress: (sent, total) {
          final effectiveTotal = total > 0 ? total : data.length;
          if (effectiveTotal > 0 && onProgress != null) {
            onProgress(sent / effectiveTotal * 100);
          }
        },
      );
      if (response.statusCode != 200) {
        throw ApiException(tr('error.uploadFailed'));
      }
    } on dio.DioException catch (e) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw ApiException(tr('error.cancelledByUser'));
      }
      throw ApiException(tr('error.uploadFailed'));
    }
  }

  /// GET /upload-media/{mediaId}/parts — какие части уже долетели раньше
  /// (используется при возврате к прерванной докачке — см. media_upload.dart).
  /// Источник правды — сам MinIO, сервер здесь ничего своего не хранит.
  Future<Set<int>> listChunkedParts(
    String token,
    String mediaId,
    String uploadId,
  ) async {
    final response = await http.get(
      Uri.parse(
        '${ApiConfig.baseUrl}/upload-media/$mediaId/parts?upload_id=$uploadId',
      ),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.uploadFailed'));
    }
    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .map((e) => (e as Map<String, dynamic>)['part_number'] as int)
        .toSet();
  }

  /// POST /upload-media/{mediaId}/complete — собрать все залитые части в
  /// готовый объект в MinIO и создать запись о файле в БД. Именно этот шаг
  /// делает файл видимым/скачиваемым для получателя.
  Future<void> completeChunkedUpload(
    String token,
    String mediaId,
    String uploadId,
    String recipientAccountId,
  ) async {
    final response = await http.post(
      Uri.parse(
        '${ApiConfig.baseUrl}/upload-media/$mediaId/complete?upload_id=$uploadId',
      ),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'recipient_account_id': recipientAccountId}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.uploadFailed'));
    }
  }

  /// POST /upload-media/{mediaId}/abort — отменить незавершённую докачку
  /// (например, пользователь удалил ещё не отправленное сообщение). Не
  /// критично, если вызов не удался — брошенные multipart-загрузки убирает
  /// lifecycle-политика бакета на стороне инфраструктуры.
  Future<void> abortChunkedUpload(
    String token,
    String mediaId,
    String uploadId,
  ) async {
    try {
      await http.post(
        Uri.parse(
          '${ApiConfig.baseUrl}/upload-media/$mediaId/abort?upload_id=$uploadId',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
    } catch (_) {
      // намеренно проглатываем — см. комментарий выше
    }
  }

  // ===== presigned-URL: байты файлов идут напрямую в MinIO мимо сервера =====
  // (см. server/internal/api/media_presign.go). Москва только подписывает
  // URL + ведёт строку в media_files; сами байты — на files.oshino.space
  // (VPS в Токио → FRP-туннель до NAS, всё в одном регионе).

  /// POST /upload-media/presign — presigned PUT для НЕчанкового файла
  /// целиком. Возвращает media_id + url; строку в БД сервер создаст только
  /// после finalizeMediaUpload (когда байты реально долетели).
  Future<({String mediaId, String url})> presignMediaPut(String token) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/upload-media/presign'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) throw ApiException(tr('error.uploadFailed'));
    final d = jsonDecode(response.body) as Map<String, dynamic>;
    return (mediaId: d['media_id'] as String, url: d['url'] as String);
  }

  /// POST /upload-media/{mediaId}/finalize — после успешного PUT: сервер
  /// проверяет, что объект нужного размера реально лежит в MinIO, и создаёт
  /// запись в media_files. [sizeBytes] — размер ШИФРОТЕКСТА.
  Future<void> finalizeMediaUpload(
    String token,
    String mediaId,
    String recipientAccountId,
    int sizeBytes,
    String fileName,
  ) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/upload-media/$mediaId/finalize'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'recipient_account_id': recipientAccountId,
        'size_bytes': sizeBytes,
        'file_name': fileName,
      }),
    );
    if (response.statusCode != 200) throw ApiException(tr('error.uploadFailed'));
  }

  /// POST /upload-media/{mediaId}/part-urls — presigned PUT-URL на каждую
  /// запрошенную часть чанковой загрузки.
  Future<Map<int, String>> presignMediaPartUrls(
    String token,
    String mediaId,
    String uploadId,
    List<int> partNumbers,
  ) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/upload-media/$mediaId/part-urls'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'upload_id': uploadId, 'part_numbers': partNumbers}),
    );
    if (response.statusCode != 200) throw ApiException(tr('error.uploadFailed'));
    final d = jsonDecode(response.body) as Map<String, dynamic>;
    final urls = (d['urls'] as Map<String, dynamic>);
    return urls.map((k, v) => MapEntry(int.parse(k), v as String));
  }

  /// GET /media/{id}/url — presigned GET-URL для скачивания напрямую из
  /// MinIO + полный размер шифротекста (чтобы не делать отдельный HEAD).
  Future<({String url, int sizeBytes})> presignMediaGet(
    String token,
    String mediaId,
  ) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/media/$mediaId/url'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.downloadFailed'));
    }
    final d = jsonDecode(response.body) as Map<String, dynamic>;
    return (
      url: d['url'] as String,
      sizeBytes: (d['size_bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// PUT зашифрованных байт напрямую на presigned-URL MinIO. Наш
  /// Bearer-токен сюда НЕ шлём — авторизует сам подписанный URL.
  /// [body] — File (стримится с диска) или Uint8List.
  Future<void> putToPresignedUrl(
    String url,
    Object body, {
    required int contentLength,
    void Function(double percent)? onProgress,
    dio.CancelToken? cancelToken,
  }) async {
    final client = _mediaDioClient();
    final Object data = body is File ? body.openRead() : body;
    try {
      final response = await client.putUri<void>(
        Uri.parse(url),
        data: data,
        options: dio.Options(
          headers: {dio.Headers.contentLengthHeader: contentLength},
          responseType: dio.ResponseType.plain,
          followRedirects: false,
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
        onSendProgress: (sent, total) {
          final t = total > 0 ? total : contentLength;
          if (t > 0 && onProgress != null) onProgress(sent / t * 100);
        },
        cancelToken: cancelToken,
      );
      if (response.statusCode == null ||
          response.statusCode! < 200 ||
          response.statusCode! >= 300) {
        throw ApiException(tr('error.uploadFailed'));
      }
    } on dio.DioException catch (e) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw ApiException(tr('error.cancelledByUser'));
      }
      throw ApiException(tr('error.uploadFailed'));
    }
  }

  /// dio.download сам пишет ответ сервера прямо в файл по мере получения,
  /// не накапливая его целиком в памяти — критично для файлов до 500 МБ.
  Future<void> downloadEncryptedMediaToFile(
    String token,
    String mediaId,
    File destFile, {
    void Function(double percent)? onProgress,
    dio.CancelToken? cancelToken,
  }) async {
    final client = _mediaDioClient();
    try {
      await client.download(
        '${ApiConfig.baseUrl}/media/$mediaId',
        destFile.path,
        options: dio.Options(headers: {'Authorization': 'Bearer $token'}),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null)
            onProgress(received / total * 100);
        },
      );
    } on dio.DioException catch (e) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw ApiException(tr('error.cancelledByUser'));
      }
      throw ApiException(tr('error.downloadFailed'));
    }
  }

  /// HEAD /media/{id} — только полный размер зашифрованного файла в байтах,
  /// без самой закачки (сервер отвечает заголовками, тело не тянет из
  /// MinIO — см. download_media.go). Нужен MediaDownloadManager, когда на
  /// диске уже есть частичный хвост, а сколько всего байт в файле —
  /// с прошлой сессии не сохранилось. 0 при любой ошибке.
  Future<int> probeEncryptedMediaSize(String token, String mediaId) async {
    try {
      final client = _mediaDioClient();
      final resp = await client.head<void>(
        '${ApiConfig.baseUrl}/media/$mediaId',
        options: dio.Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return int.tryParse(resp.headers.value('content-length') ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Скачивает зашифрованный медиафайл в [destFile] С ДОКАЧКОЙ: если файл
  /// уже частично заполнен (см. PartialDownloadStore), дописывает только
  /// недостающий хвост через заголовок `Range: bytes=<есть>-` (сервер
  /// отвечает 206 + Content-Range). [onProgress] получает АБСОЛЮТНЫЙ
  /// процент по всему файлу (не по остатку). Возвращает полный размер
  /// зашифрованного файла в байтах — по нему вызывающая сторона понимает,
  /// целиком ли хвост уже собран и можно ли расшифровывать.
  Future<int> downloadEncryptedMediaResumable(
    String token,
    String mediaId,
    File destFile, {
    int? knownTotalBytes,
    void Function(double percent)? onProgress,
    dio.CancelToken? cancelToken,
    // Если задан — качаем байты по этому presigned-URL напрямую из MinIO
    // (files.oshino.space), мимо московского сервера. Наш Bearer-токен на
    // такой URL не шлём — авторизует сам URL.
    String? directUrl,
  }) async {
    final client = _mediaDioClient();
    final url = directUrl ?? '${ApiConfig.baseUrl}/media/$mediaId';

    var existing = await destFile.exists() ? await destFile.length() : 0;
    var total = knownTotalBytes ?? 0;

    if (existing > 0 && total <= 0) {
      total = await probeEncryptedMediaSize(token, mediaId);
      if (total > 0 && existing >= total) {
        // Всё уже скачано на прошлой сессии — осталось только расшифровать.
        onProgress?.call(100);
        return total;
      }
      if (total > 0 && existing > total) {
        // Локальный хвост длиннее реального файла (порча) — начисто.
        await destFile.delete();
        existing = 0;
      }
    }

    final headers = <String, dynamic>{
      if (directUrl == null) 'Authorization': 'Bearer $token',
    };
    if (existing > 0) headers['Range'] = 'bytes=$existing-';

    try {
      final response = await client.download(
        url,
        destFile.path,
        options: dio.Options(
          headers: headers,
          validateStatus: (s) => s == 200 || s == 206,
        ),
        // КРИТИЧНО: по умолчанию dio при ошибке/отмене СНОСИТ файл — а нам
        // нужно, чтобы недокачанный хвост остался на диске для докачки с
        // места обрыва (см. PartialDownloadStore / MediaDownloadManager).
        deleteOnError: false,
        fileAccessMode: existing > 0
            ? dio.FileAccessMode.append
            : dio.FileAccessMode.write,
        cancelToken: cancelToken,
        onReceiveProgress: (received, chunkTotal) {
          if (onProgress == null) return;
          final overall = existing + received;
          final grand = total > 0
              ? total
              : (chunkTotal > 0 ? existing + chunkTotal : 0);
          if (grand > 0) {
            onProgress((overall / grand * 100).clamp(0, 100).toDouble());
          }
        },
      );

      final contentRange = response.headers.value('content-range');
      if (contentRange != null) {
        final slash = contentRange.lastIndexOf('/');
        if (slash != -1) {
          total = int.tryParse(contentRange.substring(slash + 1)) ?? total;
        }
      }
      if (total <= 0) total = await destFile.length();
      return total;
    } on dio.DioException catch (e) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw ApiException(tr('error.cancelledByUser'));
      }
      // 416 при докачке = наш локальный хвост не бьётся с файлом на
      // сервере (порча/протухший .part) — сносим и качаем начисто один раз.
      if (e.response?.statusCode == 416 && existing > 0) {
        try {
          if (await destFile.exists()) await destFile.delete();
        } catch (_) {}
        return downloadEncryptedMediaResumable(
          token,
          mediaId,
          destFile,
          knownTotalBytes: null,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      }
      throw ApiException(tr('error.downloadFailed'));
    }
  }

  /// POST /login — вход. Возвращает токен сессии и текущий язык, сохранённый
  /// на сервере (см. LocaleStore — вызывающая сторона применяет его сразу).
  Future<({String token, String language})> login(
    String login,
    String password,
    String totpCode,
  ) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'login': login,
        'password': password,
        'totp_code': totpCode,
      }),
    );

    if (response.statusCode == 429) {
      throw ApiException(tr('error.tooManyLoginAttempts'));
    }
    if (response.statusCode != 200) {
      throw ApiException(tr('error.wrongCredentials'));
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return (
      token: data['token'] as String,
      language: data['language'] as String? ?? 'en',
    );
  }

  /// PUT /account/language — язык теперь хранится на сервере, а не только
  /// локально (задел под будущий вход с нескольких устройств).
  Future<void> updateLanguage(String token, String language) async {
    final response = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/account/language'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'language': language}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.languageSaveFailed'));
    }
  }

  /// PUT /account/password — смена пароля внутри уже открытого аккаунта
  /// (настройки). Старый пароль не нужен — токен сессии уже подтверждает
  /// личность.
  Future<void> changePassword(String token, String newPassword) async {
    final response = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/account/password'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'new_password': newPassword}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.changePasswordFailed'));
    }
  }

  /// PUT /account/email — почта для восстановления доступа (опционально).
  /// Пустая строка снимает почту с аккаунта.
  Future<void> updateEmail(String token, String email) async {
    final response = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/account/email'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'email': email}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.emailSaveFailed'));
    }
  }

  /// POST /account/email/request — первый шаг привязки НОВОЙ почты: сервер
  /// проверяет, что она не занята другим аккаунтом, и шлёт код на неё.
  /// Сама почта пока не сохраняется — только после requestEmailConfirm.
  Future<void> requestEmailVerification(String token, String email) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/account/email/request'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'email': email}),
    );
    if (response.statusCode == 409) {
      throw ApiException(tr('error.emailTaken'));
    }
    if (response.statusCode != 200) {
      throw ApiException(tr('error.emailVerifyRequestFailed'));
    }
  }

  /// POST /account/email/confirm — второй шаг: код верный → сервер реально
  /// записывает почту в accounts.email.
  Future<void> confirmEmailVerification(String token, String code) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/account/email/confirm'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'code': code}),
    );
    if (response.statusCode == 409) {
      throw ApiException(tr('error.emailTaken'));
    }
    if (response.statusCode != 200) {
      throw ApiException(tr('error.recoveryWrongCode'));
    }
  }

  /// POST /account/avatar — фото профиля НЕ шифруется (см. комментарий в
  /// account_avatar.go на сервере) — видно всем контактам как есть.
  Future<void> uploadAvatar(String token, Uint8List jpegBytes) async {
    final client = _mediaDioClient();
    final formData = dio.FormData.fromMap({
      'file': dio.MultipartFile.fromBytes(jpegBytes, filename: 'avatar.jpg'),
    });
    try {
      final response = await client.post(
        '${ApiConfig.baseUrl}/account/avatar',
        data: formData,
        options: dio.Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (response.statusCode != 200) {
        debugPrint(
          'uploadAvatar failed: status=${response.statusCode} body=${response.data}',
        );
        throw ApiException(tr('error.uploadFailed'));
      }
    } on dio.DioException catch (e) {
      debugPrint('uploadAvatar exception: $e');
      throw ApiException(tr('error.uploadFailed'));
    }
  }

  /// DELETE /account/avatar — убирает своё фото профиля (и в MinIO, и в
  /// БД, см. NewDeleteAvatarHandler на сервере).
  Future<void> deleteAvatar(String token) async {
    final response = await http.delete(
      Uri.parse('${ApiConfig.baseUrl}/account/avatar'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      debugPrint(
        'deleteAvatar failed: status=${response.statusCode} body=${response.body}',
      );
      throw ApiException(tr('error.uploadFailed'));
    }
  }

  /// GET /account/avatar/{account_id} — null ТОЛЬКО если сервер честно
  /// подтвердил, что у аккаунта нет фото/оно скрыто приватностью (404 —
  /// см. account_avatar.go на сервере, там всегда именно этот статус для
  /// обоих случаев). Любая другая неудача (сеть недоступна, таймаут,
  /// неожиданный статус) — бросает исключение, а НЕ возвращает null.
  ///
  /// Раньше сетевая ошибка тоже тихо превращалась в null — неотличимо от
  /// "фото правда нет" для вызывающей стороны (см. AvatarCache.get/
  /// _refreshInBackground): реальный кейс с устройства — выключил/включил
  /// вайфай, запрос на обновление чужого аватара улетел в момент разрыва,
  /// поймал сетевое исключение, вернул null, и AvatarCache честно
  /// перезаписала УЖЕ ЗАГРУЖЕННОЕ фото на "фото нет", заодно удалив его и
  /// с диска (см. _writeToDisk) — фото пропадало из списка чатов на
  /// ровном месте. Теперь AvatarCache сама решает, что делать с ошибкой
  /// (оставить старое значение как есть), а не получает от этого метода
  /// ложное "фото нет".
  Future<Uint8List?> getAvatar(String token, String accountId) async {
    final response = await http
        .get(
          Uri.parse('${ApiConfig.baseUrl}/account/avatar/$accountId'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw ApiException(
        'getAvatar failed: accountId=$accountId status=${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  /// GET /account/avatar — своё же фото, но БЕЗ account_id в запросе:
  /// сервер сам берёт его из токена сессии (см. NewGetMyAvatarHandler).
  /// Специально не переиспользует getAvatar(token, accountId) —
  /// закэшированный на клиенте account_id (см. Session.getAccountId) может
  /// устареть и разойтись с тем, что реально означает текущий токен
  /// (например, после пересоздания аккаунтов при чистке базы), тогда
  /// getAvatar получил бы честный, но бесполезный "аккаунт не найден".
  /// null ТОЛЬКО на честное подтверждение от сервера (404 — своего фото
  /// нет); любая другая неудача бросает исключение — см. подробный
  /// комментарий у getAvatar выше про ту же самую причину (сетевая ошибка
  /// не должна маскироваться под "фото нет").
  Future<Uint8List?> getMyAvatar(String token) async {
    final response = await http
        .get(
          Uri.parse('${ApiConfig.baseUrl}/account/avatar'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw ApiException('getMyAvatar failed: status=${response.statusCode}');
    }
    return response.bodyBytes;
  }

  /// POST /chats/mute — полный мьют, включая push при закрытом приложении
  /// (решение сервера, кому будить, зависит от этой отметки).
  Future<void> muteChat(String token, String peerAccountId) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/chats/mute'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'peer_account_id': peerAccountId}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.muteFailed'));
    }
  }

  Future<void> unmuteChat(String token, String peerAccountId) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/chats/unmute'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'peer_account_id': peerAccountId}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.muteFailed'));
    }
  }

  /// GET /chats/muted — список account_id замьюченных собеседников, чтобы
  /// восстановить локальное отображение (иконка в списке чатов) при
  /// старте приложения.
  Future<List<String>> getMutedChats(String token) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/chats/muted'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['peer_account_ids'] as List<dynamic>).cast<String>();
    } catch (_) {
      return [];
    }
  }

  /// POST /contacts/block — запрещает отправку сообщений и звонков между
  /// этой парой в ОБЕ стороны (см. проверку в websocket.go), а не только
  /// со стороны блокирующего.
  Future<void> blockContact(String token, String peerAccountId) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/contacts/block'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'peer_account_id': peerAccountId}),
    );
    if (response.statusCode != 200) {
      debugPrint(
        'blockContact failed: status=${response.statusCode} body=${response.body}',
      );
      throw ApiException(tr('error.blockFailed'));
    }
  }

  Future<void> unblockContact(String token, String peerAccountId) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/contacts/unblock'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'peer_account_id': peerAccountId}),
    );
    if (response.statusCode != 200) {
      debugPrint(
        'unblockContact failed: status=${response.statusCode} body=${response.body}',
      );
      throw ApiException(tr('error.blockFailed'));
    }
  }

  /// GET /contacts/blocked — обе стороны сразу (кого заблокировал я, кто
  /// заблокировал меня), чтобы на старте приложения одним запросом
  /// восстановить, в каких чатах должна быть заглушка вместо панели
  /// сообщений и какая именно (приоритет 1 или 2 — см. chat_screen.dart).
  ///
  /// Возвращает null при сбое (сеть/таймаут/не-200) — ЭТО ОТЛИЧАЕТСЯ от
  /// пустых списков: пустой список означает "сервер точно сказал — блоков
  /// нет", а null — "не удалось узнать". Раньше оба случая возвращали
  /// одинаковые пустые списки, из-за чего временный сбой запроса выглядел
  /// как "блоков нет" и затирал корректный локальный кэш обратно на
  /// "не заблокирован" — вызывающий код обязан не трогать локальное
  /// состояние при null, а не считать его равносильным пустому ответу.
  Future<({List<String> blockedByMe, List<String> blockingMe})?>
  getBlockedContacts(String token) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/contacts/blocked'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint(
          'getBlockedContacts failed: status=${response.statusCode} body=${response.body}',
        );
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (
        blockedByMe: (data['blocked_by_me'] as List<dynamic>).cast<String>(),
        blockingMe: (data['blocking_me'] as List<dynamic>).cast<String>(),
      );
    } catch (e) {
      debugPrint('getBlockedContacts exception: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> getPrekeyBundle(
    String token,
    String deviceId,
  ) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/devices/$deviceId/prekey-bundle'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 409) {
      throw ApiException(tr('error.peerOutOfKeys'));
    }
    if (response.statusCode != 200) {
      throw ApiException(tr('error.peerKeysFailed'));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Сколько ещё не израсходованных one-time-prekeys лежит на сервере для
  /// СВОЕГО устройства — см. services/prekey_replenisher.dart. null при
  /// любой сетевой/серверной ошибке — вызывающий код просто пропускает
  /// пополнение до следующей попытки, а не считает это чем-то, что нужно
  /// показывать пользователю.
  Future<int?> getPrekeyCount(String token, String deviceId) async {
    try {
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/devices/$deviceId/prekey-count'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['remaining'] as int;
    } catch (_) {
      return null;
    }
  }

  Future<String> registerDevice(
    String token,
    String identityPubkeyBase64, {
    required String identityDhPubkeyBase64,
    required String identityDhSignatureBase64,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/register-device'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'identity_pubkey': identityPubkeyBase64,
        'identity_dh_pubkey': identityDhPubkeyBase64,
        'identity_dh_signature': identityDhSignatureBase64,
      }),
    );

    if (response.statusCode != 200) {
      throw ApiException(tr('error.deviceRegisterFailed'));
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['device_id'] as String;
  }

  Future<void> uploadPrekeys(
    String token, {
    required String deviceId,
    required String signedPrekeyBase64,
    required String signedPrekeySignatureBase64,
    required List<String> oneTimePrekeysBase64,
  }) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/prekeys/upload'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'device_id': deviceId,
        'signed_prekey': signedPrekeyBase64,
        'signed_prekey_signature': signedPrekeySignatureBase64,
        'one_time_prekeys': oneTimePrekeysBase64,
      }),
    );

    if (response.statusCode != 200) {
      throw ApiException(tr('error.prekeysFailed'));
    }
  }

  Future<({List<Map<String, dynamic>> devices, String accountId})>
  getDevicesByLogin(String token, String login) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/accounts/$login/devices'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 404) {
      throw ApiException(tr('error.userNotFound'));
    }
    if (response.statusCode != 200) {
      throw ApiException(tr('error.userLookupFailed'));
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    // 1. Безопасно извлекаем account_id (преобразуем любая значение -> String, либо пустая строка)
    final rawAccountId = data['account_id'] ?? data['accountId'] ?? data['id'];
    if (rawAccountId == null) {
      throw ApiException(tr('error.noAccountId'));
    }
    final String accountId = rawAccountId.toString();

    // 2. Безопасно обрабатываем список устройств (если nil/null — вернем пустой список)
    final rawDevices = data['devices'];
    List<Map<String, dynamic>> devices = [];

    if (rawDevices is List) {
      devices = rawDevices
          .map((d) => Map<String, dynamic>.from(d as Map))
          .toList();
    }

    return (devices: devices, accountId: accountId);
  }

  Future<String> uploadEncryptedMedia(
    String token,
    Uint8List ciphertext,
    String recipientAccountId,
  ) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiConfig.baseUrl}/upload-media'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.fields['recipient_account_id'] = recipientAccountId;
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        ciphertext,
        filename: 'encrypted.bin',
      ),
    );

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode != 200) {
      throw ApiException(tr('error.uploadFailed'));
    }
    return response.body;
  }

  /// dio вместо обычного http — только он даёт onReceiveProgress, нужный
  /// для процента скачивания в реальном времени (см. ТЗ пользователя:
  /// чат должен показывать "сколько уже скачано", а не декоративный
  /// спиннер). Тот же приём, что уже используется в
  /// downloadEncryptedMediaToFile ниже.
  Future<Uint8List> downloadEncryptedMedia(
    String token,
    String mediaId, {
    void Function(double percent)? onProgress,
    dio.CancelToken? cancelToken,
  }) async {
    final client = _mediaDioClient();
    try {
      final response = await client.get<List<int>>(
        '${ApiConfig.baseUrl}/media/$mediaId',
        options: dio.Options(
          headers: {'Authorization': 'Bearer $token'},
          responseType: dio.ResponseType.bytes,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total * 100);
          }
        },
      );
      if (response.statusCode != 200 || response.data == null) {
        throw ApiException(tr('error.downloadFailed'));
      }
      return Uint8List.fromList(response.data!);
    } on dio.DioException catch (e) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw ApiException(tr('error.cancelledByUser'));
      }
      throw ApiException(tr('error.downloadFailed'));
    }
  }

  Future<({String accountId, String login, String displayName})?>
  getDeviceOwnerInfo(String token, String deviceId) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/devices/$deviceId/owner'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final login = data['login'] as String;
      return (
        accountId: data['account_id'] as String,
        login: login,
        displayName: data['display_name'] as String? ?? login,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool?> checkSession(String token) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/session/check'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      return response.statusCode == 200;
    } catch (_) {
      // null означает "не удалось узнать" — например, нет интернета.
      // Это принципиально отличается от false ("сервер явно сказал: невалиден").
      return null;
    }
  }

  Future<Map<String, dynamic>?> getTurnCredentials(String token) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/turn-credentials'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// POST /push/register — привязывает FCM-токен к устройству, чтобы
  /// сервер мог разбудить его push-ом, когда WebSocket не подключён.
  Future<bool> registerPushToken(
    String token,
    String deviceId,
    String fcmToken,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/push/register'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'device_id': deviceId, 'fcm_token': fcmToken}),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint(
          'registerPushToken: HTTP ${response.statusCode}: ${response.body}',
        );
      }
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('registerPushToken: exception: $e');
      return false;
    }
  }

  /// DELETE /push/register — отвязывает FCM-токен от устройства (см.
  /// account_actions.dart) — без этого при выходе из аккаунта push-токен
  /// физического телефона оставался в базе на СТАРОМ device_id, и если на
  /// этом же телефоне логинились в ДРУГОЙ аккаунт, сообщения прежнему
  /// аккаунту всё ещё будили этот телефон пушем.
  Future<bool> unregisterPushToken(String token, String deviceId) async {
    try {
      final response = await http
          .delete(
            Uri.parse('${ApiConfig.baseUrl}/push/register'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'device_id': deviceId}),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint(
          'unregisterPushToken: HTTP ${response.statusCode}: ${response.body}',
        );
      }
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('unregisterPushToken: exception: $e');
      return false;
    }
  }

  Future<bool> deleteAccount(String token) async {
    final response = await http
        .delete(
          Uri.parse('${ApiConfig.baseUrl}/account'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 8));
    return response.statusCode == 200;
  }

  Future<
    ({
      String accountId,
      String login,
      // Сырое значение (может быть пустым) — см. AccountMeResponse.DisplayName
      // на сервере: тут это "что редактировать в настройках", а не "что
      // показать собеседникам" (для этого — displayName в getAccountProfile/
      // getDeviceOwnerInfo, уже с фолбэком на login).
      String? displayName,
      String language,
      String? email,
      bool hasAvatar,
      String? status,
      String? birthday,
      int findByLoginVisibility,
      int avatarVisibility,
      int birthdayVisibility,
      int statusVisibility,
    })?
  >
  getMyAccountInfo(String token) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/account/me'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (
        accountId: data['account_id'] as String,
        login: data['login'] as String,
        displayName: data['display_name'] as String?,
        language: data['language'] as String? ?? 'en',
        email: data['email'] as String?,
        hasAvatar: data['has_avatar'] as bool? ?? false,
        status: data['status'] as String?,
        birthday: data['birthday'] as String?,
        findByLoginVisibility: data['find_by_login_visibility'] as int? ?? 1,
        avatarVisibility: data['avatar_visibility'] as int? ?? 1,
        birthdayVisibility: data['birthday_visibility'] as int? ?? 1,
        statusVisibility: data['status_visibility'] as int? ?? 1,
      );
    } catch (_) {
      return null;
    }
  }

  /// PUT /account/display-name — пустая строка снимает отображаемое имя
  /// целиком (клиент откатывается на login).
  Future<void> updateDisplayName(String token, String displayName) async {
    final response = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/account/display-name'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'display_name': displayName}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.displayNameSaveFailed'));
    }
  }

  /// PUT /account/status — статус профиля, пустая строка валидна (снимает
  /// статус целиком).
  Future<void> updateStatus(String token, String status) async {
    final response = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/account/status'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'status': status}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.statusSaveFailed'));
    }
  }

  /// PUT /account/birthday — birthday: null снимает дату целиком.
  Future<void> updateBirthday(String token, String? birthday) async {
    final response = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/account/birthday'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'birthday': birthday}),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.birthdaySaveFailed'));
    }
  }

  /// PUT /account/privacy — все 4 настройки видимости профиля разом.
  Future<void> updatePrivacy(
    String token, {
    required int findByLogin,
    required int avatar,
    required int birthday,
    required int status,
  }) async {
    final response = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/account/privacy'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'find_by_login': findByLogin,
        'avatar': avatar,
        'birthday': birthday,
        'status': status,
      }),
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.privacySaveFailed'));
    }
  }

  /// GET /account/profile/{login} — профиль ЧУЖОГО пользователя, уже
  /// отфильтрованный сервером по его настройкам приватности (см.
  /// account_profile.go). 404, если у пользователя find_by_login=0 (его
  /// "не существует" для поиска) — тот же случай, что и логин не найден.
  Future<
    ({
      String accountId,
      String login,
      String displayName,
      List<Map<String, dynamic>> devices,
      String? status,
      String? birthday,
      bool hasAvatar,
    })?
  >
  getAccountProfile(String token, String login) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/account/profile/$login'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw ApiException(tr('error.userLookupFailed'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final rawDevices = data['devices'];
    final devices = rawDevices is List
        ? rawDevices.map((d) => Map<String, dynamic>.from(d as Map)).toList()
        : <Map<String, dynamic>>[];
    final resolvedLogin = data['login'] as String;
    return (
      accountId: data['account_id'] as String,
      login: resolvedLogin,
      displayName: data['display_name'] as String? ?? resolvedLogin,
      devices: devices,
      status: data['status'] as String?,
      birthday: data['birthday'] as String?,
      hasAvatar: data['has_avatar'] as bool? ?? false,
    );
  }

  /// POST /reports — жалоба на сообщение. Переписка E2E-зашифрована,
  /// сервер физически не может увидеть текст сам — поэтому messageText
  /// шлём открытым текстом добровольно, тем же, что уже видно в своём
  /// пузыре сообщения (см. _reportMessage в chat_screen.dart).
  Future<void> reportMessage(
    String token,
    String reportedDeviceId,
    String messageText,
    String reason,
  ) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/reports'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'reported_device_id': reportedDeviceId,
            'message_text': messageText,
            'reason': reason,
          }),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw ApiException(
        '${tr('error.reportFailed')} (${response.statusCode})',
      );
    }
  }

  /// POST /feedback — произвольный отзыв из экрана "О приложении".
  Future<void> sendFeedback(String token, String message) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/feedback'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'message': message}),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw ApiException(
        '${tr('error.feedbackFailed')} (${response.statusCode})',
      );
    }
  }
}
