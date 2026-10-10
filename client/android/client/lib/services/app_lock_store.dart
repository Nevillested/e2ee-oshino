import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Настройки блокировки приложения ("Вход в приложение" в настройках) —
/// целиком локальные, на сервер ничего не уходит (см. ТЗ пользователя).
/// PIN-код НИКОГДА не хранится сам по себе — только его хэш (SHA-256) с
/// случайной солью, тем же способом, каким это принято делать для любого
/// пароля: даже полный доступ к хранилищу устройства не даёт восстановить
/// сам PIN.
class AppLockSettings {
  final bool enabled;
  final int timeoutSeconds;
  final bool biometricEnabled;
  final bool hasPin;
  final int pinLength;

  const AppLockSettings({
    this.enabled = false,
    this.timeoutSeconds = 60,
    this.biometricEnabled = false,
    this.hasPin = false,
    this.pinLength = 4,
  });

  AppLockSettings copyWith({
    bool? enabled,
    int? timeoutSeconds,
    bool? biometricEnabled,
    bool? hasPin,
    int? pinLength,
  }) => AppLockSettings(
    enabled: enabled ?? this.enabled,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    biometricEnabled: biometricEnabled ?? this.biometricEnabled,
    hasPin: hasPin ?? this.hasPin,
    pinLength: pinLength ?? this.pinLength,
  );
}

class AppLockStore {
  AppLockStore._();

  static const _storage = FlutterSecureStorage();
  static const _keyEnabled = 'app_lock_enabled';
  static const _keyTimeout = 'app_lock_timeout_seconds';
  static const _keyBiometric = 'app_lock_biometric_enabled';
  static const _keyPinHash = 'app_lock_pin_hash';
  static const _keyPinSalt = 'app_lock_pin_salt';
  static const _keyPinLength = 'app_lock_pin_length';

  static final ValueNotifier<AppLockSettings> notifier = ValueNotifier(
    const AppLockSettings(),
  );

  static Future<void> init() async {
    final enabled = (await _storage.read(key: _keyEnabled)) == 'true';
    final timeoutStr = await _storage.read(key: _keyTimeout);
    final biometric = (await _storage.read(key: _keyBiometric)) == 'true';
    final pinHash = await _storage.read(key: _keyPinHash);
    final pinLengthStr = await _storage.read(key: _keyPinLength);
    notifier.value = AppLockSettings(
      enabled: enabled,
      timeoutSeconds: int.tryParse(timeoutStr ?? '') ?? 60,
      biometricEnabled: biometric,
      hasPin: pinHash != null,
      pinLength: int.tryParse(pinLengthStr ?? '') ?? 4,
    );
  }

  /// [pin] — 4..8 цифр, проверка диапазона на стороне UI (см.
  /// app_lock_settings_screen.dart). Длину храним отдельно (это не секрет
  /// сам по себе, только чтобы экран блокировки знал, сколько точек
  /// рисовать и когда автоматически проверять введённое).
  static Future<void> setPin(String pin) async {
    final salt = _generateSaltHex();
    final hash = await _hashPin(pin, salt);
    await _storage.write(key: _keyPinSalt, value: salt);
    await _storage.write(key: _keyPinHash, value: hash);
    await _storage.write(key: _keyPinLength, value: pin.length.toString());
    notifier.value = notifier.value.copyWith(hasPin: true, pinLength: pin.length);
  }

  static Future<bool> verifyPin(String pin) async {
    final salt = await _storage.read(key: _keyPinSalt);
    final hash = await _storage.read(key: _keyPinHash);
    if (salt == null || hash == null) return false;
    final candidate = await _hashPin(pin, salt);
    return candidate == hash;
  }

  /// Удаляет PIN — а вместе с ним, обязательно, и биометрию, и саму
  /// блокировку целиком: PIN — единственный запасной способ входа, без
  /// него оставлять включённой биометрию (или тем более саму блокировку
  /// без ЛЮБОГО способа её пройти) нельзя (см. ТЗ: "числовой — обязательный,
  /// без него нельзя добавить отпечаток/распознавание лица").
  static Future<void> removePin() async {
    await _storage.delete(key: _keyPinHash);
    await _storage.delete(key: _keyPinSalt);
    await _storage.delete(key: _keyPinLength);
    await _storage.write(key: _keyBiometric, value: 'false');
    await _storage.write(key: _keyEnabled, value: 'false');
    notifier.value = const AppLockSettings();
  }

  static Future<void> setEnabled(bool v) async {
    if (v && !notifier.value.hasPin) return;
    await _storage.write(key: _keyEnabled, value: v.toString());
    notifier.value = notifier.value.copyWith(enabled: v);
  }

  static Future<void> setTimeoutSeconds(int seconds) async {
    await _storage.write(key: _keyTimeout, value: seconds.toString());
    notifier.value = notifier.value.copyWith(timeoutSeconds: seconds);
  }

  static Future<void> setBiometricEnabled(bool v) async {
    if (v && !notifier.value.hasPin) return;
    await _storage.write(key: _keyBiometric, value: v.toString());
    notifier.value = notifier.value.copyWith(biometricEnabled: v);
  }

  static Future<String> _hashPin(String pin, String saltHex) async {
    final saltBytes = _hexToBytes(saltHex);
    final input = <int>[...utf8.encode(pin), ...saltBytes];
    final hash = await Sha256().hash(input);
    return _bytesToHex(hash.bytes);
  }

  static String _generateSaltHex() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return _bytesToHex(bytes);
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _hexToBytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}
