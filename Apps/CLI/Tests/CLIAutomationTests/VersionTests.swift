import Foundation
import Testing
@testable import WinkCLI

@Suite(.tags(.safe))
struct VersionTests {
    @Test
    func `Version follows semantic versioning format`() throws {
        let version = Version.current

        // Version should be in format "Wink X.Y.Z" or "Wink X.Y.Z-prerelease"
        let versionRegex = try NSRegularExpression(pattern: #"^Wink \d+\.\d+\.\d+(-[\w\.]+)?$"#)
        let range = NSRange(location: 0, length: version.utf16.count)
        let matches = versionRegex.matches(in: version, range: range)

        #expect(!matches.isEmpty, "Version '\(version)' should follow semantic versioning format")
    }

    @Test
    func `Version components are valid numbers`() throws {
        let version = Version.current

        // Remove "Wink " prefix
        let versionNumber = version.replacingOccurrences(of: "Wink ", with: "")

        // Split by prerelease identifier first
        let versionParts = versionNumber.split(separator: "-")
        let semverPart = String(versionParts[0])

        let components = semverPart.split(separator: ".")

        #expect(components.count == 3)

        let major = try #require(Int(components[0]))
        let minor = try #require(Int(components[1]))
        let patch = try #require(Int(components[2]))

        #expect(major >= 0)
        #expect(minor >= 0)
        #expect(patch >= 0)
    }

    @Test
    func `Version is consistent across calls`() {
        let version1 = Version.current
        let version2 = Version.current

        #expect(version1 == version2)
    }

    @Test
    func `Version string is not empty`() {
        #expect(!Version.current.isEmpty)
        #expect(Version.current.count >= 14) // Minimum: "Wink 0.0.0"
    }

    @Test
    func `Version can be used in user agent strings`() {
        let userAgent = "Wink/\(Version.current)"

        #expect(userAgent.hasPrefix("Wink/"))
        #expect(userAgent.count > 18) // "Wink/" + "Wink " + at least "0.0.0"
    }
}
