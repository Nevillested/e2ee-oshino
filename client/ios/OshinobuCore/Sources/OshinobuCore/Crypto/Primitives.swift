import CryptoKit
import Foundation
import Security

// Криптографические примитивы: X25519, Ed25519, HMAC-SHA256, HKDF, AES-256-GCM
// (nonce 12, тег 16) — те же форматы ключей и результатов, что у Android
// (core/crypto/Primitives.kt). Всё — CryptoKit, без сторонних библиотек.

public enum CryptoError: Error, Equatable {
    case badKeyLength
    case lowOrderPublicKey
    case signatureInvalid
    case badEnvelope(String)
    case authenticationFailed
}

public func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return data
}

public func b64(_ data: Data) -> String { data.base64EncodedString() }

public func unb64(_ s: String) throws -> Data {
    guard let d = Data(base64Encoded: s) else { throw CryptoError.badEnvelope("не base64") }
    return d
}

public func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}

/// Пара X25519. Приватный ключ — 32 байта как есть (без клампинга): CryptoKit,
/// как и BouncyCastle на Android, клампит скаляр сам при каждом умножении.
public struct X25519KeyPair: Sendable {
    public let privateKey: Data
    public let publicKey: Data

    public init(privateKey: Data, publicKey: Data) throws {
        guard privateKey.count == 32, publicKey.count == 32 else { throw CryptoError.badKeyLength }
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    public static func generate() -> X25519KeyPair { try! fromPrivate(randomBytes(32)) }

    public static func fromPrivate(_ privateKey: Data) throws -> X25519KeyPair {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        return try X25519KeyPair(privateKey: privateKey, publicKey: key.publicKey.rawRepresentation)
    }

    public func sharedSecret(_ remotePublic: Data) throws -> Data {
        guard remotePublic.count == 32 else { throw CryptoError.badKeyLength }
        let me = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let them = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublic)
        let secret = try me.sharedSecretFromKeyAgreement(with: them).withUnsafeBytes { Data($0) }
        // нулевой общий секрет — публичный ключ малого порядка (подмена)
        if secret.allSatisfy({ $0 == 0 }) { throw CryptoError.lowOrderPublicKey }
        return secret
    }
}

/// Пара Ed25519; [seed] — 32-байтный приватный seed (RFC 8032), как на Android.
public struct Ed25519KeyPair: Sendable {
    public let seed: Data
    public let publicKey: Data

    public static func generate() -> Ed25519KeyPair { try! fromSeed(randomBytes(32)) }

    public static func fromSeed(_ seed: Data) throws -> Ed25519KeyPair {
        guard seed.count == 32 else { throw CryptoError.badKeyLength }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return Ed25519KeyPair(seed: seed, publicKey: key.publicKey.rawRepresentation)
    }

    public func sign(_ message: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
    }

    public static func verify(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

public func hmacSha256(key: Data, data: Data) -> Data {
    // пустой ключ по RFC 2104 эквивалентен ключу из нулей — как на Android
    let k = SymmetricKey(data: key.isEmpty ? Data(count: 32) : key)
    return Data(HMAC<SHA256>.authenticationCode(for: data, using: k))
}

/// HKDF-SHA256 (RFC 5869), по умолчанию с пустой солью — побайтно как Android.
public func hkdfSha256(ikm: Data, info: Data, length: Int, salt: Data = Data()) -> Data {
    let prk = hmacSha256(key: salt, data: ikm)
    var out = Data()
    var prev = Data()
    var counter: UInt8 = 1
    while out.count < length {
        prev = hmacSha256(key: prk, data: prev + info + Data([counter]))
        out.append(prev.prefix(length - out.count))
        counter &+= 1
    }
    return out
}

/// Результат AES-GCM: шифротекст и тег отдельно.
public struct SealedBox: Sendable {
    public let nonce: Data
    public let ciphertext: Data
    public let mac: Data
}

public enum AesGcm {
    public static let nonceBytes = 12
    public static let tagBytes = 16

    public static func encrypt(key: Data, plaintext: Data, aad: Data? = nil, nonce: Data = randomBytes(12)) throws -> SealedBox {
        let k = SymmetricKey(data: key)
        let n = try AES.GCM.Nonce(data: nonce)
        let box = try aad.map { try AES.GCM.seal(plaintext, using: k, nonce: n, authenticating: $0) }
            ?? AES.GCM.seal(plaintext, using: k, nonce: n)
        return SealedBox(nonce: nonce, ciphertext: box.ciphertext, mac: box.tag)
    }

    /// Бросает [CryptoError.authenticationFailed], если ключ/nonce/AAD не те или данные подменены.
    public static func decrypt(key: Data, box: SealedBox, aad: Data? = nil) throws -> Data {
        do {
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: box.nonce), ciphertext: box.ciphertext, tag: box.mac)
            let k = SymmetricKey(data: key)
            return try aad.map { try AES.GCM.open(sealed, using: k, authenticating: $0) } ?? AES.GCM.open(sealed, using: k)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}
