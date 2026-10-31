import CryptoKit
import Foundation

public struct AppLockSettings: Sendable, Equatable {
    public var enabled = false
    public var timeoutSeconds = 60
    public var biometricEnabled = false
    public var hasPin = false
    public var pinLength = 4

    public init(enabled: Bool = false, timeoutSeconds: Int = 60, biometricEnabled: Bool = false, hasPin: Bool = false, pinLength: Int = 4) {
        self.enabled = enabled
        self.timeoutSeconds = timeoutSeconds
        self.biometricEnabled = biometricEnabled
        self.hasPin = hasPin
        self.pinLength = pinLength
    }
}

/// Блокировка приложения (как AppLockStore на Android): PIN = hex(SHA-256(pin ‖ соль)) в Keychain.
public final class AppLockStore: @unchecked Sendable {
    private enum K {
        static let enabled = "app_lock_enabled"
        static let timeout = "app_lock_timeout_seconds"
        static let biometric = "app_lock_biometric_enabled"
        static let pinHash = "app_lock_pin_hash"
        static let pinSalt = "app_lock_pin_salt"
        static let pinLength = "app_lock_pin_length"
    }

    private let secure: SecureStore
    public let state: StateValue<AppLockSettings>

    public init(secure: SecureStore) {
        self.secure = secure
        state = StateValue(AppLockSettings())
        state.value = load()
    }

    public func load() -> AppLockSettings {
        AppLockSettings(
            enabled: secure.read(K.enabled) == "true",
            timeoutSeconds: Int(secure.read(K.timeout) ?? "") ?? 60,
            biometricEnabled: secure.read(K.biometric) == "true",
            hasPin: secure.read(K.pinHash) != nil,
            pinLength: Int(secure.read(K.pinLength) ?? "") ?? 4
        )
    }

    private func hash(_ pin: String, saltHex: String) -> String {
        let salt = stride(from: 0, to: saltHex.count, by: 2).compactMap { i -> UInt8? in
            let start = saltHex.index(saltHex.startIndex, offsetBy: i)
            return UInt8(saltHex[start..<saltHex.index(start, offsetBy: 2)], radix: 16)
        }
        return SHA256.hash(data: Data(pin.utf8) + Data(salt)).map { String(format: "%02x", $0) }.joined()
    }

    public func setPin(_ pin: String) {
        let salt = randomBytes(16).map { String(format: "%02x", $0) }.joined()
        secure.write(K.pinSalt, salt)
        secure.write(K.pinHash, hash(pin, saltHex: salt))
        secure.write(K.pinLength, String(pin.count))
        state.value = load()
    }

    public func checkPin(_ pin: String) -> Bool {
        guard let salt = secure.read(K.pinSalt), let stored = secure.read(K.pinHash) else { return false }
        return constantTimeEquals(Data(hash(pin, saltHex: salt).utf8), Data(stored.utf8))
    }

    public func removePin() {
        for k in [K.pinHash, K.pinSalt, K.pinLength, K.enabled, K.biometric] { secure.delete(k) }
        state.value = load()
    }

    public func setEnabled(_ on: Bool) { secure.write(K.enabled, on ? "true" : "false"); state.value = load() }
    public func setBiometric(_ on: Bool) { secure.write(K.biometric, on ? "true" : "false"); state.value = load() }
    public func setTimeout(_ seconds: Int) { secure.write(K.timeout, String(seconds)); state.value = load() }
}
