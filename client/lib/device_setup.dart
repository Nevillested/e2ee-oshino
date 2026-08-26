import 'dart:convert';
import 'api/api_client.dart';
import 'crypto/key_store.dart';
import 'services/debug_log.dart';

/// Убеждается, что текущее устройство зарегистрировано на сервере и у
/// него есть свежие prekeys. Вызывается один раз, сразу после успешного
/// логина. Если устройство уже было зарегистрировано раньше (device_id
/// сохранён локально) — просто выходит, ничего не делая повторно.
Future<void> ensureDeviceRegistered(ApiClient apiClient, String token) async {
  DebugLog.log('DeviceSetup ensureDeviceRegistered: start');
  final existingDeviceId = await KeyStore.getStoredDeviceId();
  if (existingDeviceId != null) {
    DebugLog.log(
      'DeviceSetup ensureDeviceRegistered: device already registered deviceId=$existingDeviceId, skipping',
    );
    return;
  }

  DebugLog.log('DeviceSetup: no local device_id — first run on this device, registering fresh');

  final identityKeyPair = await KeyStore.getOrCreateIdentityKeyPair();
  final identityPublicKey = await identityKeyPair.extractPublicKey();

  final dhResult = await KeyStore.getOrCreateIdentityDhKeyPair(identityKeyPair);
  final dhPublicKey = await dhResult.keyPair.extractPublicKey();

  DebugLog.log('DeviceSetup: calling registerDevice on server');
  final deviceId = await apiClient.registerDevice(
    token,
    base64Encode(identityPublicKey.bytes),
    identityDhPubkeyBase64: base64Encode(dhPublicKey.bytes),
    identityDhSignatureBase64: base64Encode(dhResult.signature),
  );
  DebugLog.log('DeviceSetup: registerDevice OK, server assigned deviceId=$deviceId');

  final signedPrekey = await KeyStore.createSignedPrekey(identityKeyPair);
  final oneTimePrekeys = await KeyStore.createOneTimePrekeys(20);

  DebugLog.log(
    'DeviceSetup: uploading prekeys to server (1 signed + ${oneTimePrekeys.length} one-time)',
  );
  await apiClient.uploadPrekeys(
    token,
    deviceId: deviceId,
    signedPrekeyBase64: base64Encode(signedPrekey.publicKey),
    signedPrekeySignatureBase64: base64Encode(signedPrekey.signature),
    oneTimePrekeysBase64: oneTimePrekeys.map(base64Encode).toList(),
  );
  DebugLog.log('DeviceSetup: uploadPrekeys OK');

  await KeyStore.saveDeviceId(deviceId);
  DebugLog.log('DeviceSetup ensureDeviceRegistered: DONE, deviceId=$deviceId saved locally');
}
