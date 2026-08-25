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
    final client = dio.Dio();
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

  /// GET /account/avatar/{account_id} — null, если у аккаунта нет фото
  /// профиля (404) или запрос не удался — вызывающая сторона в этом
  /// случае показывает заглушку, а не бросает исключение выше.
  Future<Uint8List?> getAvatar(String token, String accountId) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/account/avatar/$accountId'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint(
          'getAvatar failed: accountId=$accountId status=${response.statusCode} body=${response.body}',
        );
        return null;
      }
      return response.bodyBytes;
    } catch (e) {
      debugPrint('getAvatar exception: accountId=$accountId error=$e');
      return null;
    }
  }

  /// GET /account/avatar — своё же фото, но БЕЗ account_id в запросе:
  /// сервер сам берёт его из токена сессии (см. NewGetMyAvatarHandler).
  /// Специально не переиспользует getAvatar(token, accountId) —
  /// закэшированный на клиенте account_id (см. Session.getAccountId) может
  /// устареть и разойтись с тем, что реально означает текущий токен
  /// (например, после пересоздания аккаунтов при чистке базы), тогда
  /// getAvatar получил бы честный, но бесполезный "аккаунт не найден".
  Future<Uint8List?> getMyAvatar(String token) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/account/avatar'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint(
          'getMyAvatar failed: status=${response.statusCode} body=${response.body}',
        );
        return null;
      }
      return response.bodyBytes;
    } catch (e) {
      debugPrint('getMyAvatar exception: $e');
      return null;
    }
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
  }) async {
    final client = dio.Dio();
    try {
      final response = await client.get<List<int>>(
        '${ApiConfig.baseUrl}/media/$mediaId',
        options: dio.Options(
          headers: {'Authorization': 'Bearer $token'},
          responseType: dio.ResponseType.bytes,
        ),
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
    } on dio.DioException {
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
