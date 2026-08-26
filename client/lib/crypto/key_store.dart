import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/debug_log.dart';

/// Хранит и генерирует все криптографические ключи устройства.
///
/// ВАЖНО про архитектуру (открытый вопрос, который распланируем отдельно):
/// identity-ключ здесь сделан на Ed25519 — он умеет ТОЛЬКО подписывать
/// (это нужно прямо сейчас, чтобы подписать signed prekey). Настоящий X3DH
/// требует, чтобы identity-ключ ещё и участвовал в Диффи-Хеллмане (DH) —
/// а Ed25519-ключ для этого не подходит напрямую. Signal решает это через
/// схему XEdDSA. Мы это пока откладываем — вернёмся отдельно, когда будем
/// делать сам X3DH-обмен при первом сообщении новому собеседнику.
class KeyStore {
  static const _storage = FlutterSecureStorage();
  static const _identityDhPrivateKey = 'identity_dh_private_key';
  static const _identityDhPublicKey = 'identity_dh_public_key';
  static const _identityDhSignature = 'identity_dh_signature';
  static const _identityPrivateKey = 'identity_private_key';
  static const _identityPublicKey = 'identity_public_key';
  static const _signedPrekeyPrivateKey = 'signed_prekey_private_key';
  static const _signedPrekeyPublicKey = 'signed_prekey_public_key';
  static const _oneTimePrekeysKey = 'one_time_prekeys';
  static const _deviceIdKey = 'device_id';

  /// Возвращает существующий identity-ключ, либо создаёт новый — если
  /// это первый запуск приложения на этом устройстве.
  static Future<SimpleKeyPair> getOrCreateIdentityKeyPair() async {
    final storedPrivate = await _storage.read(key: _identityPrivateKey);
    final storedPublic = await _storage.read(key: _identityPublicKey);

    if (storedPrivate != null && storedPublic != null) {
      return SimpleKeyPairData(
        base64Decode(storedPrivate),
        publicKey: SimplePublicKey(
          base64Decode(storedPublic),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      );
    }

    final keyPair = await Ed25519().newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();

    await _storage.write(
      key: _identityPrivateKey,
      value: base64Encode(privateBytes),
    );
    await _storage.write(
      key: _identityPublicKey,
      value: base64Encode(publicKey.bytes),
    );

    return keyPair;
  }

  /// Возвращает существующую пару X25519-ключей для Диффи-Хеллмана (identity
  /// DH key), либо создаёт новую и сразу подписывает её публичную часть
  /// Ed25519-ключом — эта подпись доказывает собеседнику, что именно
  /// владелец identity-ключа выпустил этот DH-ключ, а не подменил его сервер.
  static Future<({SimpleKeyPair keyPair, List<int> signature})>
  getOrCreateIdentityDhKeyPair(SimpleKeyPair identityKeyPair) async {
    final storedPrivate = await _storage.read(key: _identityDhPrivateKey);
    final storedPublic = await _storage.read(key: _identityDhPublicKey);
    final storedSignature = await _storage.read(key: _identityDhSignature);

    if (storedPrivate != null &&
        storedPublic != null &&
        storedSignature != null) {
      final keyPair = SimpleKeyPairData(
        base64Decode(storedPrivate),
        publicKey: SimplePublicKey(
          base64Decode(storedPublic),
          type: KeyPairType.x25519,
        ),
        type: KeyPairType.x25519,
      );
      return (keyPair: keyPair, signature: base64Decode(storedSignature));
    }

    final dhKeyPair = await X25519().newKeyPair();
    final privateBytes = await dhKeyPair.extractPrivateKeyBytes();
    final publicKey = await dhKeyPair.extractPublicKey();

    final signature = await Ed25519().sign(
      publicKey.bytes,
      keyPair: identityKeyPair,
    );

    await _storage.write(
      key: _identityDhPrivateKey,
      value: base64Encode(privateBytes),
    );
    await _storage.write(
      key: _identityDhPublicKey,
      value: base64Encode(publicKey.bytes),
    );
    await _storage.write(
      key: _identityDhSignature,
      value: base64Encode(signature.bytes),
    );

    return (keyPair: dhKeyPair, signature: signature.bytes);
  }

  /// Генерирует новый signed prekey (X25519, для будущего Диффи-Хеллмана),
  /// подписывает его identity-ключом, сохраняет приватную часть локально.
  static Future<({List<int> publicKey, List<int> signature})>
  createSignedPrekey(SimpleKeyPair identityKeyPair) async {
    final prekeyPair = await X25519().newKeyPair();
    final prekeyPrivate = await prekeyPair.extractPrivateKeyBytes();
    final prekeyPublic = await prekeyPair.extractPublicKey();

    await _storage.write(
      key: _signedPrekeyPrivateKey,
      value: base64Encode(prekeyPrivate),
    );
    await _storage.write(
      key: _signedPrekeyPublicKey,
      value: base64Encode(prekeyPublic.bytes),
    );

    final signature = await Ed25519().sign(
      prekeyPublic.bytes,
      keyPair: identityKeyPair,
    );

    return (publicKey: prekeyPublic.bytes, signature: signature.bytes);
  }

  /// Генерирует пачку одноразовых prekeys (X25519), сохраняет приватные
  /// части локально — понадобятся позже, когда кто-то начнёт X3DH-обмен
  /// с этим устройством и использует один из этих ключей.
  ///
  /// ДОБАВЛЯЕТ к уже сохранённым, а не затирает их — эта функция вызывается
  /// не только один раз при первой регистрации устройства (device_setup.dart),
  /// но и при пополнении пула (см. services/prekey_replenisher.dart), когда
  /// часть из ранее выгруженных на сервер ключей ещё не израсходована.
  /// Раньше (до появления пополнения) перезапись была безобидна, потому что
  /// функция и так вызывалась ровно один раз за всё время жизни устройства —
  /// но перезаписывать было бы уже нельзя: это стёрло бы приватные части
  /// ещё не использованных, но уже отданных серверу ключей, и когда кто-то
  /// начал бы X3DH именно с одним из них, findOneTimePrekeyPair ничего бы
  /// не нашёл.
  static Future<List<List<int>>> createOneTimePrekeys(int count) async {
    final publicKeys = <List<int>>[];
    final newlyStored = <Map<String, String>>[];

    for (var i = 0; i < count; i++) {
      final pair = await X25519().newKeyPair();
      final private = await pair.extractPrivateKeyBytes();
      final public = await pair.extractPublicKey();

      publicKeys.add(public.bytes);
      newlyStored.add({
        'public': base64Encode(public.bytes),
        'private': base64Encode(private),
      });
    }

    final existingRaw = await _storage.read(key: _oneTimePrekeysKey);
    final existing = existingRaw == null
        ? <Map<String, String>>[]
        : (jsonDecode(existingRaw) as List<dynamic>)
              .map((e) => (e as Map<String, dynamic>).cast<String, String>())
              .toList();

    await _storage.write(
      key: _oneTimePrekeysKey,
      value: jsonEncode([...existing, ...newlyStored]),
    );

    return publicKeys;
  }

  /// Убирает приватную часть уже ИЗРАСХОДОВАННОГО one-time prekey — вызывать
  /// сразу после успешного использования в establishIncomingSessionRaw
  /// (x3dh.dart). Ключ одноразовый по определению (в этом и весь смысл
  /// forward secrecy четвёртого DH в X3DH): если оставить приватную часть
  /// лежать в хранилище и дальше, компрометация диска задним числом
  /// расшифровывает и самое первое сообщение переписки тоже, а не только
  /// текущие.
  static Future<void> deleteOneTimePrekeyPair(String publicKeyBase64) async {
    final stored = await _storage.read(key: _oneTimePrekeysKey);
    if (stored == null) return;
    final list = (jsonDecode(stored) as List<dynamic>)
        .map((e) => (e as Map<String, dynamic>).cast<String, String>())
        .toList();
    final before = list.length;
    list.removeWhere((entry) => entry['public'] == publicKeyBase64);
    if (list.length == before) return;
    await _storage.write(key: _oneTimePrekeysKey, value: jsonEncode(list));
  }

  static Future<String?> getStoredDeviceId() {
    return _storage.read(key: _deviceIdKey);
  }

  static Future<void> saveDeviceId(String deviceId) {
    return _storage.write(key: _deviceIdKey, value: deviceId);
  }

  /// Полностью стирает все ключи и device_id с устройства. Используется
  /// при выходе из аккаунта — без этих ключей переписку восстановить
  /// невозможно, поэтому это необратимое действие.
  static Future<void> clearAll() async {
    await _storage.deleteAll();
  }

  /// Загружает уже сохранённый signed prekey — без генерации нового.
  /// Нужен получателю при входящем X3DH.
  static Future<SimpleKeyPair?> getStoredSignedPrekeyPair() async {
    final storedPrivate = await _storage.read(key: _signedPrekeyPrivateKey);
    final storedPublic = await _storage.read(key: _signedPrekeyPublicKey);
    if (storedPrivate == null || storedPublic == null) return null;

    return SimpleKeyPairData(
      base64Decode(storedPrivate),
      publicKey: SimplePublicKey(
        base64Decode(storedPublic),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
  }

  /// Ищет сохранённый one-time prekey по его публичной части — нужен,
  /// когда собеседник использовал конкретно этот ключ в своём заголовке.
  static Future<SimpleKeyPair?> findOneTimePrekeyPair(
    String publicKeyBase64,
  ) async {
    final stored = await _storage.read(key: _oneTimePrekeysKey);
    if (stored == null) return null;

    final list = jsonDecode(stored) as List<dynamic>;
    for (final entry in list) {
      final map = entry as Map<String, dynamic>;
      if (map['public'] == publicKeyBase64) {
        DebugLog.log('KeyStore one-time prekey lookup pubkey=$publicKeyBase64 FOUND');
        return SimpleKeyPairData(
          base64Decode(map['private'] as String),
          publicKey: SimplePublicKey(
            base64Decode(map['public'] as String),
            type: KeyPairType.x25519,
          ),
          type: KeyPairType.x25519,
        );
      }
    }
    DebugLog.log(
      'KeyStore one-time prekey lookup pubkey=$publicKeyBase64 NOT FOUND '
      '(already consumed earlier, or never belonged to this device — X3DH '
      'will proceed without the 4th DH)',
    );
    return null;
  }
}
