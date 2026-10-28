import Foundation

/// Scrubs credentials and personal data from text before it is stored in recordings, diagnostics or
/// feedback. Conservative by design: false positives cost a little readability, misses leak secrets.
public enum Redactor {
    private static func compile(_ specs: [(String, String)]) -> [(NSRegularExpression, String)] {
        specs.compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }
    }

    /// Home-directory paths first, so the opaque-token rule below doesn't swallow long paths.
    private static let pathRules = compile([(#"/Users/[^/\s"']+"#, "~")])

    /// Credentials. Text matching any of these is never recorded verbatim.
    private static let secretRules = compile([
        (#"(?i)\b(password|passwd|pwd|passcode|secret|token|api[_-]?key|access[_-]?key|authorization|cookie|session[_-]?id)(\s*[:=]\s*)("[^"]*"|'[^']*'|\S+)"#,
         "$1$2[REDACTED]"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "[REDACTED_JWT]"),
        (#"\b(sk|pk|rk)[-_][A-Za-z0-9_-]{16,}\b"#, "[REDACTED_KEY]"),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, "[REDACTED_KEY]"),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#, "[REDACTED_KEY]"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "[REDACTED_KEY]"),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
        // long opaque tokens (hex/base64/url-safe) with at least one digit, so ordinary words survive
        (#"(?<![A-Za-z0-9+/_-])(?=[A-Za-z0-9+/_-]*\d)[A-Za-z0-9+/_-]{32,}={0,2}"#, "[REDACTED_TOKEN]"),
    ])

    /// Personal data that is fine to keep out of reports but is not a credential.
    private static let piiRules = compile([
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[EMAIL]"),
        (#"\b(?:\d[ -]?){13,19}\b"#, "[NUMBER]"),
    ])

    private static func apply(_ rules: [(NSRegularExpression, String)], _ text: String) -> String {
        var out = text
        for (regex, template) in rules {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    public static func redact(_ text: String) -> String {
        self.apply(self.piiRules, self.apply(self.secretRules, self.apply(self.pathRules, text)))
    }

    /// True when the text contains something credential-like; such text is never recorded verbatim.
    public static func looksSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return self.secretRules.contains { $0.0.firstMatch(in: text, range: range) != nil }
    }

    public static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// Redact, flatten control characters and clip.
    public static func sanitize(_ text: String, limit: Int) -> String {
        let flat = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) && $0 != "\n" ? " " : String($0) }
            .joined()
        return self.clip(self.redact(flat), limit)
    }
}
