import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Хранит identity DH-ключ собеседника — нужен для отображения кода
/// сверки на экране "Проверка ключей".
class PeerIdentityStore {
  static const _storage = FlutterSecureStorage();
  static String _key(String deviceId) => 'peer_identity:$deviceId';

  static Future<void> save(String deviceId, String identityDhPubkeyBase64) {
    return _storage.write(key: _key(deviceId), value: identityDhPubkeyBase64);
  }

  static Future<Map<String, String>?> get(String deviceId) async {
    final stored = await _storage.read(key: _key(deviceId));
    if (stored == null) return null;
    return {'identity_dh': stored};
  }
}
