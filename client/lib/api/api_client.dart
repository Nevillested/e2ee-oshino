import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'dart:typed_data';

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
        'Не удалось зарегистрироваться (код ${response.statusCode})',
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
      throw ApiException('Неверный код подтверждения');
    }
  }

  /// POST /login — вход. Возвращает сырой токен сессии.
  Future<String> login(
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

    if (response.statusCode != 200) {
      throw ApiException('Неверный логин, пароль или код');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return data['token'] as String;
  }

Future<Map<String, dynamic>> getPrekeyBundle(String token, String deviceId) async {
  final response = await http.get(
    Uri.parse('${ApiConfig.baseUrl}/devices/$deviceId/prekey-bundle'),
    headers: {'Authorization': 'Bearer $token'},
  );

  if (response.statusCode == 409) {
    throw ApiException('У собеседника закончились ключи, попробуйте позже');
  }
  if (response.statusCode != 200) {
    throw ApiException('Не удалось получить ключи собеседника');
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
    throw ApiException('Не удалось зарегистрировать устройство');
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
      throw ApiException('Не удалось загрузить prekeys');
    }
  }

Future<({List<Map<String, dynamic>> devices, String accountId})> getDevicesByLogin(
  String token,
  String login,
) async {
  final response = await http.get(
    Uri.parse('${ApiConfig.baseUrl}/accounts/$login/devices'),
    headers: {'Authorization': 'Bearer $token'},
  );

  if (response.statusCode == 404) {
    throw ApiException('Такого пользователя нет');
  }
  if (response.statusCode != 200) {
    throw ApiException('Не удалось найти пользователя');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;

  // 1. Безопасно извлекаем account_id (преобразуем любая значение -> String, либо пустая строка)
  final rawAccountId = data['account_id'] ?? data['accountId'] ?? data['id'];
  if (rawAccountId == null) {
    throw ApiException('Сервер не вернул account_id пользователя');
  }
  final String accountId = rawAccountId.toString();

  // 2. Безопасно обрабатываем список устройств (если nil/null — вернем пустой список)
  final rawDevices = data['devices'];
  List<Map<String, dynamic>> devices = [];

  if (rawDevices is List) {
    devices = rawDevices.map((d) => Map<String, dynamic>.from(d as Map)).toList();
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
    http.MultipartFile.fromBytes('file', ciphertext, filename: 'encrypted.bin'),
  );

  final streamed = await request.send();
  final response = await http.Response.fromStream(streamed);

  if (response.statusCode != 200) {
    throw ApiException('Не удалось загрузить файл');
  }
  return response.body;
}

Future<Uint8List> downloadEncryptedMedia(String token, String mediaId) async {
  final response = await http.get(
    Uri.parse('${ApiConfig.baseUrl}/media/$mediaId'),
    headers: {'Authorization': 'Bearer $token'},
  );
  if (response.statusCode != 200) {
    throw ApiException('Не удалось скачать файл');
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
    return (accountId: data['account_id'] as String, login: data['login'] as String);
  } catch (_) {
    return null;
  }
}

}
