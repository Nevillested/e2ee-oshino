import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../api/api_client.dart';
import '../crypto/key_store.dart';
import 'debug_log.dart';

/// Пополняет пул одноразовых prekeys на сервере, пока не поздно.
///
/// Раньше их загружали РОВНО ОДИН РАЗ, при первой регистрации устройства
/// (см. device_setup.dart), и никогда больше — сервер молча раздавал их по
/// одному на каждый новый входящий X3DH-хендшейк (см. ClaimOneTimePrekey на
/// сервере), пока не кончались совсем, а клиент об этом никак не узнавал.
/// После этого prekey-bundle для нашего устройства начинает отдаваться БЕЗ
/// одноразового ключа — X3DH всё ещё проходит (3 DH вместо 4), но теряет
/// свойство forward secrecy для самого первого сообщения новой переписки.
///
/// Порог и размер пополнения совпадают с исходной выгрузкой в
/// device_setup.dart (20 ключей) — не было причин выбирать другие числа.
const _lowWatermark = 5;
const _targetPoolSize = 20;

/// Дёргается при каждом входе на главный экран (см.
/// home_placeholder_screen.dart _connect()) — не по таймеру: у нас и так
/// достаточно частая точка входа (открытие приложения/реконнект), заводить
/// отдельный планировщик ради этого незачем. Все ошибки (сеть, сервер)
/// проглатываются — это фоновая подстраховка, не должна мешать обычной
/// работе приложения ни диалогом, ни исключением.
Future<void> ensurePrekeysTopped(
  ApiClient apiClient,
  String token,
  String deviceId,
) async {
  try {
    final remaining = await apiClient.getPrekeyCount(token, deviceId);
    if (remaining == null || remaining > _lowWatermark) return;

    final needed = _targetPoolSize - remaining;
    if (needed <= 0) return;

    final identityKeyPair = await KeyStore.getOrCreateIdentityKeyPair();
    final signedPrekeyPair = await KeyStore.getStoredSignedPrekeyPair();
    if (signedPrekeyPair == null) return;
    final signedPrekeyPublic = await signedPrekeyPair.extractPublicKey();

    // Тот же signed prekey, что уже на сервере — пополняем только
    // one-time-prekeys, менять/ротировать signed prekey тут не нужно.
    // Подпись пересчитываем заново (Ed25519 — не требует хранить её
    // отдельно, достаточно identity-ключа и самого signed prekey).
    final signature = await Ed25519().sign(
      signedPrekeyPublic.bytes,
      keyPair: identityKeyPair,
    );

    final newOneTimePrekeys = await KeyStore.createOneTimePrekeys(needed);

    await apiClient.uploadPrekeys(
      token,
      deviceId: deviceId,
      signedPrekeyBase64: base64Encode(signedPrekeyPublic.bytes),
      signedPrekeySignatureBase64: base64Encode(signature.bytes),
      oneTimePrekeysBase64: newOneTimePrekeys.map(base64Encode).toList(),
    );

    DebugLog.log(
      'PrekeyReplenisher topped up $needed one-time prekeys (had $remaining)',
    );
  } catch (e) {
    DebugLog.log('PrekeyReplenisher failed: $e');
  }
}
