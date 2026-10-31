import Foundation

/// JSON-значение с точным разделением целых и дробных чисел: конверты и
/// состояние ratchet должны давать ту же строку AAD, что и Android
/// (`message_number=5`, а не `5.0`), — Foundation `Any` этого не гарантирует.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Содержимое примитива как текст (как `JsonPrimitive.contentOrNull` в Kotlin):
    /// строка — без кавычек, число — как в JSON, null — nil.
    public var primitiveContent: String? {
        switch self {
        case .null: return nil
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): return s
        case .array, .object: return encoded()
        }
    }

    // MARK: - кодирование

    public func encoded() -> String {
        let data = (try? JSONEncoder.oshinobu.encode(self)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// без ExpressibleByNilLiteral: `dict["x"] = nil` обязан удалять ключ, а не писать JSON null
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public extension JSONValue {
    /// Опциональная строка → .string или .null (как `put(name, String?)` в Kotlin).
    static func optional(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
}

public extension JSONEncoder {
    /// Без экранирования "/" — как kotlinx.serialization.
    static let oshinobu: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
}
