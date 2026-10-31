import Foundation
import Security

// Хранилища ключ-значение, в которых живёт состояние приложения. На iOS формат
// свой (наследия Flutter, как на Android, здесь нет), имена ключей — те же, что
// у Android, чтобы код сервисов совпадал один в один.
//  - [SecureStore] — Keychain (ключи, сессии ratchet, переписка);
//  - [Prefs]       — UserDefaults (токен, флаги, счётчики);
//  - [AppDirs]     — каталоги приложения.

/** Зашифрованное хранилище строк. */
public protocol SecureStore: AnyObject, Sendable {
    func read(_ key: String) -> String?
    func write(_ key: String, _ value: String)
    func delete(_ key: String)
    func readAll() -> [String: String]
    func deleteAll()
}

/** Незашифрованные настройки. */
public protocol Prefs: AnyObject, Sendable {
    func string(_ key: String) -> String?
    func long(_ key: String) -> Int64?
    func double(_ key: String) -> Double?
    func bool(_ key: String) -> Bool?
    func stringList(_ key: String) -> [String]?
    func set(_ key: String, _ value: String)
    func set(_ key: String, _ value: Int64)
    func set(_ key: String, _ value: Double)
    func set(_ key: String, _ value: Bool)
    func set(_ key: String, _ value: [String])
    func remove(_ key: String)
}

public struct AppDirs: Sendable {
    /** Постоянные данные (журнал, отправки, вложения). */
    public let documents: URL
    /** Служебные файлы приложения (не видны пользователю в «Файлах»). */
    public let support: URL
    /** Кэш — система может стереть. */
    public let temp: URL

    public init(documents: URL, support: URL, temp: URL) {
        self.documents = documents
        self.support = support
        self.temp = temp
        for d in [documents, support, temp] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    /// Стандартные каталоги приложения на iOS.
    public static func standard() -> AppDirs {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Oshinobu")
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Oshinobu")
        return AppDirs(documents: docs, support: support, temp: caches)
    }
}

/**
 * Keychain. Доступ — после первой разблокировки после включения: входящий пуш
 * и звонок должны расшифровываться и при заблокированном экране. Только это
 * устройство (ThisDeviceOnly): ключи E2EE не уезжают в iCloud и в резервные копии —
 * после переустановки устройство регистрируется заново, как на Android.
 */
public final class KeychainSecureStore: SecureStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    public init(service: String = "space.oshino.oshinobu.secure") { self.service = service }

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func read(_ key: String) -> String? {
        lock.sync {
            var q = base(key)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    public func write(_ key: String, _ value: String) {
        lock.sync {
            let data = Data(value.utf8)
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(base(key) as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = base(key)
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }

    public func delete(_ key: String) {
        lock.sync { _ = SecItemDelete(base(key) as CFDictionary) }
    }

    public func readAll() -> [String: String] {
        lock.sync {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [:] }
            var m: [String: String] = [:]
            for item in items {
                if let k = item[kSecAttrAccount as String] as? String, let d = item[kSecValueData as String] as? Data, let v = String(data: d, encoding: .utf8) {
                    m[k] = v
                }
            }
            return m
        }
    }

    public func deleteAll() {
        lock.sync { _ = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
    }
}

public final class UserDefaultsPrefs: Prefs, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func string(_ key: String) -> String? { defaults.string(forKey: key) }
    public func long(_ key: String) -> Int64? { (defaults.object(forKey: key) as? NSNumber)?.int64Value }
    public func double(_ key: String) -> Double? { (defaults.object(forKey: key) as? NSNumber)?.doubleValue }
    public func bool(_ key: String) -> Bool? { (defaults.object(forKey: key) as? NSNumber)?.boolValue }
    public func stringList(_ key: String) -> [String]? { defaults.stringArray(forKey: key) }
    public func set(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
    public func set(_ key: String, _ value: Int64) { defaults.set(NSNumber(value: value), forKey: key) }
    public func set(_ key: String, _ value: Double) { defaults.set(value, forKey: key) }
    public func set(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }
    public func set(_ key: String, _ value: [String]) { defaults.set(value, forKey: key) }
    public func remove(_ key: String) { defaults.removeObject(forKey: key) }
}

/// Хранилища в памяти — для тестов.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String]

    public init(_ initial: [String: String] = [:]) { map = initial }

    public func read(_ key: String) -> String? { lock.sync { map[key] } }
    public func write(_ key: String, _ value: String) { lock.sync { map[key] = value } }
    public func delete(_ key: String) { lock.sync { _ = map.removeValue(forKey: key) } }
    public func readAll() -> [String: String] { lock.sync { map } }
    public func deleteAll() { lock.sync { map.removeAll() } }
}

public final class InMemoryPrefs: Prefs, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: Any] = [:]

    public init() {}

    public func string(_ key: String) -> String? { lock.sync { map[key] as? String } }
    public func long(_ key: String) -> Int64? { lock.sync { map[key] as? Int64 } }
    public func double(_ key: String) -> Double? { lock.sync { map[key] as? Double } }
    public func bool(_ key: String) -> Bool? { lock.sync { map[key] as? Bool } }
    public func stringList(_ key: String) -> [String]? { lock.sync { map[key] as? [String] } }
    public func set(_ key: String, _ value: String) { lock.sync { map[key] = value } }
    public func set(_ key: String, _ value: Int64) { lock.sync { map[key] = value } }
    public func set(_ key: String, _ value: Double) { lock.sync { map[key] = value } }
    public func set(_ key: String, _ value: Bool) { lock.sync { map[key] = value } }
    public func set(_ key: String, _ value: [String]) { lock.sync { map[key] = value } }
    public func remove(_ key: String) { lock.sync { _ = map.removeValue(forKey: key) } }
}
