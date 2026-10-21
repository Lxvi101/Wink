import Foundation

enum ApplicationIdentifierResolver {
    static func resolve(
        _ value: String,
        cwd: String = FileManager.default.currentDirectoryPath
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") else { return trimmed }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let absolutePath = expanded.hasPrefix("/")
            ? expanded
            : NSString(string: cwd).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolutePath).standardizedFileURL.path
    }
}
