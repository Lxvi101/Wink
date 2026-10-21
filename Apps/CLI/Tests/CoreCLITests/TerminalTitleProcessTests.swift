import Darwin
import Foundation
import Testing
@testable import WinkCLI

@Suite(.tags(.safe), .serialized)
struct TerminalTitleProcessTests {
    @Test
    func `timeout preserves the terminal title error`() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec /bin/sleep 30"]

        try process.run()
        let pid = process.processIdentifier
        defer {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
            process.waitUntilExit()
        }

        #expect(throws: TerminalTitleProcessWaitError.self) {
            try waitForTerminalTitleProcessExit(process, timeoutSeconds: 0.05)
        }

        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
    }

    @Test
    func `updateTerminalTitle reaps a wedged vt on PATH`() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("wink-vt-title-\(UUID().uuidString)", isDirectory: true)
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let pidFile = scratch.appendingPathComponent("vt.pid")
        let vt = bin.appendingPathComponent("vt")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "$WINK_VT_PID_FILE"
        trap '' TERM
        exec /bin/sleep 30
        """
        try script.write(to: vt, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vt.path)

        let previousPath = getenv("PATH").map { String(cString: $0) }
        let previousPidFile = getenv("WINK_VT_PID_FILE").map { String(cString: $0) }
        setenv("PATH", "\(bin.path):\(previousPath ?? "/usr/bin:/bin")", 1)
        setenv("WINK_VT_PID_FILE", pidFile.path, 1)
        defer {
            if let previousPath {
                setenv("PATH", previousPath, 1)
            } else {
                unsetenv("PATH")
            }
            if let previousPidFile {
                setenv("WINK_VT_PID_FILE", previousPidFile, 1)
            } else {
                unsetenv("WINK_VT_PID_FILE")
            }
        }

        updateTerminalTitle("wink-vt-title-timeout")

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
