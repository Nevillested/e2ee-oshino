import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'double_ratchet.dart';

/// Хранит состояние Double Ratchet отдельно для каждого устройства
/// собеседника — раньше здесь лежал один статичный ключ, теперь целое
/// состояние, которое меняется с каждым сообщением.
class SessionStore {
  static const _storage = FlutterSecureStorage();
  static String _key(String remoteDeviceId) => 'ratchet:$remoteDeviceId';

  static Future<void> saveState(
    String remoteDeviceId,
    RatchetState state,
  ) async {
    final json = await state.toJson();
    await _storage.write(key: _key(remoteDeviceId), value: jsonEncode(json));
  }

  static Future<RatchetState?> getState(String remoteDeviceId) async {
    final stored = await _storage.read(key: _key(remoteDeviceId));
    if (stored == null) return null;
    return RatchetState.fromJson(jsonDecode(stored) as Map<String, dynamic>);
  }
}
