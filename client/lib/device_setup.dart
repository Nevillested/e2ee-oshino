import 'dart:convert';
import 'api/api_client.dart';
import 'crypto/key_store.dart';

/// Убеждается, что текущее устройство зарегистрировано на сервере и у
/// него есть свежие prekeys. Вызывается один раз, сразу после успешного
/// логина. Если устройство уже было зарегистрировано раньше (device_id
/// сохранён локально) — просто выходит, ничего не делая повторно.
Future<void> ensureDeviceRegistered(ApiClient apiClient, String token) async {
  final existingDeviceId = await KeyStore.getStoredDeviceId();
  if (existingDeviceId != null) {
    return;
  }

  final identityKeyPair = await KeyStore.getOrCreateIdentityKeyPair();
  final identityPublicKey = await identityKeyPair.extractPublicKey();

  final dhResult = await KeyStore.getOrCreateIdentityDhKeyPair(identityKeyPair);
  final dhPublicKey = await dhResult.keyPair.extractPublicKey();

  final deviceId = await apiClient.registerDevice(
    token,
    base64Encode(identityPublicKey.bytes),
    identityDhPubkeyBase64: base64Encode(dhPublicKey.bytes),
    identityDhSignatureBase64: base64Encode(dhResult.signature),
  );

  final signedPrekey = await KeyStore.createSignedPrekey(identityKeyPair);
  final oneTimePrekeys = await KeyStore.createOneTimePrekeys(20);

  await apiClient.uploadPrekeys(
    token,
    deviceId: deviceId,
    signedPrekeyBase64: base64Encode(signedPrekey.publicKey),
    signedPrekeySignatureBase64: base64Encode(signedPrekey.signature),
    oneTimePrekeysBase64: oneTimePrekeys.map(base64Encode).toList(),
  );

  await KeyStore.saveDeviceId(deviceId);
}