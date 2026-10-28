import Foundation

/// JSON helpers shared by the store and the MCP adapters (which speak `[String: Any]`).
public enum WorkflowJSON {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return encoder
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
        try self.encoder(pretty: pretty).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Decodes a value that arrived as a JSON object (or a JSON string containing one) in tool arguments.
    public static func decode<T: Decodable>(_ type: T.Type, fromAny value: Any) throws -> T {
        if let text = value as? String {
            return try self.decode(type, from: Data(text.utf8))
        }
        guard JSONSerialization.isValidJSONObject(value) else {
            throw WorkflowError(.invalidArgument, "expected a JSON object")
        }
        return try self.decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    /// Encodable -> JSONSerialization object, for MCP structuredContent.
    public static func object<T: Encodable>(_ value: T) -> Any {
        guard let data = try? self.encode(value, pretty: false),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [:] }
        return object
    }

    public static func string<T: Encodable>(_ value: T) -> String {
        (try? self.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Readable explanation of a DecodingError (path + reason) for schema errors.
    public static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            let p = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "(root)" : p
        }
        switch decoding {
        case let .typeMismatch(_, c): return "\(path(c)): \(c.debugDescription)"
        case let .valueNotFound(_, c): return "\(path(c)): missing value"
        case let .keyNotFound(key, c): return "\(path(c)): missing key '\(key.stringValue)'"
        case let .dataCorrupted(c): return "\(path(c)): \(c.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}

public enum WorkflowClock {
    public static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    public static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

enum IDs {
    static func make(_ prefix: String) -> String {
        let stamp = String(Int(Date().timeIntervalSince1970), radix: 36)
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(prefix)_\(stamp)\(random)"
    }

    /// FNV-1a 64-bit, hex. Used for dedup fingerprints (not security).
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    static let safeID = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,63}$")

    static func isSafe(_ id: String) -> Bool {
        self.safeID.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    /// "Create Note!" -> "create_note"
    static func slug(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("_"), !out.isEmpty {
                out += "_"
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return String(out.prefix(48))
    }
}
