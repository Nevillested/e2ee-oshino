import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'key_store.dart';

List<int> base64DecodeSafe(String value) => base64Decode(value);

const _hkdfInfoRoot = 'OshinobuX3DHRoot';
final _x25519 = X25519();
final _ed25519 = Ed25519();

class X3dhOutgoing {
  final List<int> rootKey;
  final SimpleKeyPair ephemeralKeyPair;
  final Map<String, dynamic> initHeader;
  X3dhOutgoing({
    required this.rootKey,
    required this.ephemeralKeyPair,
    required this.initHeader,
  });
}

Future<X3dhOutgoing> establishOutgoingRoot({
  required Map<String, dynamic> bundle,
  required String myDeviceId,
}) async {
  final remoteIdentityPubkey = SimplePublicKey(
    base64Decode(bundle['identity_pubkey'] as String),
    type: KeyPairType.ed25519,
  );
  final remoteIdentityDhBytes = base64Decode(
    bundle['identity_dh_pubkey'] as String,
  );
  final remoteIdentityDhSignature = base64Decode(
    bundle['identity_dh_signature'] as String,
  );
  final remoteSignedPrekeyBytes = base64Decode(
    bundle['signed_prekey'] as String,
  );
  final remoteSignedPrekeySignature = base64Decode(
    bundle['signature'] as String,
  );
  final remoteOneTimePrekeyBase64 = bundle['one_time_prekey'] as String?;

  final signedPrekeyValid = await _ed25519.verify(
    remoteSignedPrekeyBytes,
    signature: Signature(
      remoteSignedPrekeySignature,
      publicKey: remoteIdentityPubkey,
    ),
  );
  final identityDhValid = await _ed25519.verify(
    remoteIdentityDhBytes,
    signature: Signature(
      remoteIdentityDhSignature,
      publicKey: remoteIdentityPubkey,
    ),
  );
  if (!signedPrekeyValid || !identityDhValid) {
    throw Exception(
      'Подпись ключей собеседника недействительна — возможна подмена',
    );
  }

  final remoteIdentityDhKey = SimplePublicKey(
    remoteIdentityDhBytes,
    type: KeyPairType.x25519,
  );
  final remoteSignedPrekey = SimplePublicKey(
    remoteSignedPrekeyBytes,
    type: KeyPairType.x25519,
  );
  final remoteOneTimePrekey = remoteOneTimePrekeyBase64 != null
      ? SimplePublicKey(
          base64Decode(remoteOneTimePrekeyBase64),
          type: KeyPairType.x25519,
        )
      : null;

  final myIdentityKeyPair = await KeyStore.getOrCreateIdentityKeyPair();
  final myIdentityDhResult = await KeyStore.getOrCreateIdentityDhKeyPair(
    myIdentityKeyPair,
  );
  final myIdentityDhKeyPair = myIdentityDhResult.keyPair;

  final ephemeralKeyPair = await _x25519.newKeyPair();
  final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();

  final dh1 = await _x25519.sharedSecretKey(
    keyPair: myIdentityDhKeyPair,
    remotePublicKey: remoteSignedPrekey,
  );
  final dh2 = await _x25519.sharedSecretKey(
    keyPair: ephemeralKeyPair,
    remotePublicKey: remoteIdentityDhKey,
  );
  final dh3 = await _x25519.sharedSecretKey(
    keyPair: ephemeralKeyPair,
    remotePublicKey: remoteSignedPrekey,
  );

  final ikm = <int>[
    ...List.filled(32, 0xFF),
    ...await dh1.extractBytes(),
    ...await dh2.extractBytes(),
    ...await dh3.extractBytes(),
  ];

  if (remoteOneTimePrekey != null) {
    final dh4 = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: remoteOneTimePrekey,
    );
    ikm.addAll(await dh4.extractBytes());
  }

  final rootKey = await _deriveRootKey(ikm);

  return X3dhOutgoing(
    rootKey: rootKey,
    ephemeralKeyPair: ephemeralKeyPair,
    initHeader: {
      'sender_device_id': myDeviceId,
      'sender_identity_dh_pubkey': base64Encode(
        (await myIdentityDhKeyPair.extractPublicKey()).bytes,
      ),
      'ephemeral_pubkey': base64Encode(ephemeralPublicKey.bytes),
      'used_one_time_prekey': remoteOneTimePrekeyBase64,
    },
  );
}

/// Вычисляет только корневой ключ для стороны-получателя первого сообщения.
Future<List<int>?> establishIncomingSessionRaw(
  Map<String, dynamic> header,
) async {
  final senderIdentityDhBytes = header['sender_identity_dh_pubkey'] as String?;
  final senderEphemeralBytes = header['ephemeral_pubkey'] as String?;
  if (senderIdentityDhBytes == null || senderEphemeralBytes == null)
    return null;

  final senderIdentityDhKey = SimplePublicKey(
    base64Decode(senderIdentityDhBytes),
    type: KeyPairType.x25519,
  );
  final senderEphemeralKey = SimplePublicKey(
    base64Decode(senderEphemeralBytes),
    type: KeyPairType.x25519,
  );
  final usedOneTimePrekeyBase64 = header['used_one_time_prekey'] as String?;

  final myIdentityKeyPair = await KeyStore.getOrCreateIdentityKeyPair();
  final myIdentityDhResult = await KeyStore.getOrCreateIdentityDhKeyPair(
    myIdentityKeyPair,
  );
  final myIdentityDhKeyPair = myIdentityDhResult.keyPair;
  final mySignedPrekeyPair = await KeyStore.getStoredSignedPrekeyPair();
  if (mySignedPrekeyPair == null) return null;

  final dh1 = await _x25519.sharedSecretKey(
    keyPair: mySignedPrekeyPair,
    remotePublicKey: senderIdentityDhKey,
  );
  final dh2 = await _x25519.sharedSecretKey(
    keyPair: myIdentityDhKeyPair,
    remotePublicKey: senderEphemeralKey,
  );
  final dh3 = await _x25519.sharedSecretKey(
    keyPair: mySignedPrekeyPair,
    remotePublicKey: senderEphemeralKey,
  );

  final ikm = <int>[
    ...List.filled(32, 0xFF),
    ...await dh1.extractBytes(),
    ...await dh2.extractBytes(),
    ...await dh3.extractBytes(),
  ];

  if (usedOneTimePrekeyBase64 != null) {
    final myOtp = await KeyStore.findOneTimePrekeyPair(usedOneTimePrekeyBase64);
    if (myOtp != null) {
      final dh4 = await _x25519.sharedSecretKey(
        keyPair: myOtp,
        remotePublicKey: senderEphemeralKey,
      );
      ikm.addAll(await dh4.extractBytes());
      // Одноразовый — и по названию, и по гарантии forward secrecy: как
      // только он реально использован в DH, приватную часть больше не
      // держим на диске (см. docstring у deleteOneTimePrekeyPair).
      await KeyStore.deleteOneTimePrekeyPair(usedOneTimePrekeyBase64);
    }
  }

  return _deriveRootKey(ikm);
}

Future<List<int>> _deriveRootKey(List<int> ikm) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: const [],
    info: utf8.encode(_hkdfInfoRoot),
  );
  return derived.extractBytes();
}
