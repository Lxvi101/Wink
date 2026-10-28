import Foundation

/// `${name}` input references inside workflow strings. `$${` writes a literal `${`.
/// No expressions, functions or code: substitution only.
public enum Template {
    public struct Problem: Error, CustomStringConvertible {
        public var description: String
    }

    private static func isNameStart(_ c: Character) -> Bool { c == "_" || (c.isASCII && c.isLetter) }
    private static func isNameChar(_ c: Character) -> Bool { c == "_" || (c.isASCII && (c.isLetter || c.isNumber)) }

    /// Parses into literal and reference segments.
    static func parse(_ text: String) throws -> [(literal: String, reference: String?)] {
        var out: [(String, String?)] = []
        var literal = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "$" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "$",
                   text.index(after: next) < text.endIndex, text[text.index(after: next)] == "{" {
                    literal += "${"
                    i = text.index(next, offsetBy: 2)
                    continue
                }
                if next < text.endIndex, text[next] == "{" {
                    guard let close = text[next...].firstIndex(of: "}") else {
                        throw Problem(description: "unterminated ${ in \"\(Redactor.clip(text, 60))\"")
                    }
                    let name = String(text[text.index(after: next)..<close])
                    guard let first = name.first, self.isNameStart(first), name.allSatisfy(self.isNameChar),
                          name.count <= 64 else {
                        throw Problem(description: "invalid input reference ${\(Redactor.clip(name, 40))}")
                    }
                    out.append((literal, name))
                    literal = ""
                    i = text.index(after: close)
                    continue
                }
            }
            literal.append(c)
            i = text.index(after: i)
        }
        if !literal.isEmpty || out.isEmpty { out.append((literal, nil)) }
        return out
    }

    public static func references(in text: String) throws -> [String] {
        try self.parse(text).compactMap(\.reference)
    }

    public static func render(_ text: String, inputs: [String: String]) throws -> String {
        try self.parse(text).map { segment in
            guard let name = segment.reference else { return segment.literal }
            guard let value = inputs[name] else { throw Problem(description: "unknown input ${\(name)}") }
            return segment.literal + value
        }.joined()
    }

    /// Escapes a literal so it renders back to itself.
    public static func escape(_ literal: String) -> String {
        literal.replacingOccurrences(of: "${", with: "$${")
    }
}
