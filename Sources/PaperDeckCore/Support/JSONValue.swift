import Foundation

/// A Sendable, Codable JSON tree — used for the agent's JSON schema, the CLI's
/// structured_output and lenient envelope decoding.
package enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    package init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    package subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    package var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    package var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    package var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    package var intValue: Int? {
        guard let d = doubleValue, d.isFinite, abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }
    package var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    package var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    package var isNull: Bool { if case .null = self { return true }; return false }

    /// Compact, key-sorted serialization (stable for hashing and argv).
    package func compactString() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? enc.encode(self)) ?? Data("null".utf8), as: UTF8.self)
    }

    /// Round-trips any Encodable value into a JSONValue tree.
    package static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this tree into a Decodable type.
    package func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
