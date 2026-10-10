import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Запоминает, какому account_id принадлежит конкретный device_id
/// собеседника — узнаём это один раз, когда впервые запрашиваем его
/// prekey-bundle, и используем позже (например, при загрузке медиафайлов,
/// которым сервер требует именно account_id получателя).
class PeerAccountStore {
  static const _storage = FlutterSecureStorage();
  static String _key(String deviceId) => 'peer_account:$deviceId';

  static Future<void> save(String deviceId, String accountId) {
    return _storage.write(key: _key(deviceId), value: accountId);
  }

  static Future<String?> get(String deviceId) {
    return _storage.read(key: _key(deviceId));
  }
}
