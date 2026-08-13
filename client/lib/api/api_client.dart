import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../config.dart';
import '../l10n/app_strings.dart';
import 'dart:typed_data';
import 'package:dio/dio.dart' as dio;
import 'dart:io';

/// Отдельный тип ошибки для сетевых/серверных проблем — так их удобно
/// ловить в UI через try/catch и показывать пользователю e.toString().
class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}

class ApiClient {
  /// POST /register — регистрация нового аккаунта.
  /// Возвращает otpauth:// ссылку для приложения-аутентификатора.
  Future<String> register(String login, String password) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'login': login, 'password': password}),
    );

    if (response.statusCode != 200) {
      throw ApiException(
        '${tr('error.registerFailed')} (${response.statusCode})',
      );
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
    final client = dio.Dio();
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

  /// dio.download сам пишет ответ сервера прямо в файл по мере получения,
  /// не накапливая его целиком в памяти — критично для файлов до 500 МБ.
  Future<void> downloadEncryptedMediaToFile(
    String token,
    String mediaId,
    File destFile, {
    void Function(double percent)? onProgress,
    dio.CancelToken? cancelToken,
  }) async {
    final client = dio.Dio();
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

  /// То же самое, что uploadEncryptedMedia, но с колбэком прогресса —
  /// обычный http-клиент такого колбэка не даёт, поэтому здесь используется
  /// dio, только внутри этого одного метода.
  Future<String> uploadEncryptedMediaWithProgress(
    String token,
    Uint8List ciphertext,
    String recipientAccountId, {
    required void Function(double percent) onProgress,
    dio.CancelToken? cancelToken,
  }) async {
    final client = dio.Dio();
    final formData = dio.FormData.fromMap({
      'recipient_account_id': recipientAccountId,
      'file': dio.MultipartFile.fromBytes(
        ciphertext,
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
          if (total > 0) onProgress(sent / total * 100);
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

  /// POST /login — вход. Возвращает сырой токен сессии.
  Future<String> login(String login, String password, String totpCode) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'login': login,
        'password': password,
        'totp_code': totpCode,
      }),
    );

    if (response.statusCode != 200) {
      throw ApiException(tr('error.wrongCredentials'));
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['token'] as String;
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

  Future<Uint8List> downloadEncryptedMedia(String token, String mediaId) async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/media/$mediaId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw ApiException(tr('error.downloadFailed'));
    }
    return response.bodyBytes;
  }

  Future<({String accountId, String login})?> getDeviceOwnerInfo(
    String token,
    String deviceId,
  ) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/devices/$deviceId/owner'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (
        accountId: data['account_id'] as String,
        login: data['login'] as String,
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

  Future<bool> deleteAccount(String token) async {
    final response = await http
        .delete(
          Uri.parse('${ApiConfig.baseUrl}/account'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 8));
    return response.statusCode == 200;
  }

  Future<({String accountId, String login})?> getMyAccountInfo(
    String token,
  ) async {
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
      );
    } catch (_) {
      return null;
    }
  }
}
