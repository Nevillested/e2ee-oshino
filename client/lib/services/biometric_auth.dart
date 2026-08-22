import 'package:local_auth/local_auth.dart';

/// Что реально доступно на этом телефоне — Android/iOS не позволяют
/// приложению выбрать "только отпечаток, не лицо" (системный BiometricPrompt
/// сам решает, что показать пользователю, исходя из того, что у него
/// заведено в настройках ОС) — здесь только определяем, КАК назвать пункт
/// меню, сама проверка всегда идёт одним и тем же системным диалогом.
enum BiometricCapability { fingerprint, face, generic }

class BiometricAuth {
  BiometricAuth._();

  static final _auth = LocalAuthentication();

  /// null — биометрии на устройстве нет вообще (ни разрешение, ни хотя бы
  /// одна заведённая в ОС запись) — в этом случае соответствующий пункт
  /// меню в "Вход в приложение" не должен показываться совсем (см. ТЗ
  /// пользователя).
  static Future<BiometricCapability?> detectCapability() async {
    try {
      // canCheckBiometrics — true только если есть хотя бы одна ЗАВЕДЁННАЯ
      // запись (отпечаток/лицо) прямо сейчас, не просто наличие сканера —
      // предлагать включить биометрию, которую нечем будет пройти,
      // бессмысленно.
      final canCheck = await _auth.canCheckBiometrics;
      if (!canCheck) return null;
      final types = await _auth.getAvailableBiometrics();
      final hasFace = types.contains(BiometricType.face);
      final hasFingerprint = types.contains(BiometricType.fingerprint);
      if (hasFace && !hasFingerprint) return BiometricCapability.face;
      if (hasFingerprint && !hasFace) return BiometricCapability.fingerprint;
      // И то, и другое, или Android вернул только обобщённый
      // strong/weak без разбивки по типу (частый случай) — единственный
      // системный диалог всё равно один на оба, показываем общую подпись.
      return BiometricCapability.generic;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
