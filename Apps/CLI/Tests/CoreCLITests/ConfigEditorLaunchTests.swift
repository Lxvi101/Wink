import Commander
import Darwin
import Foundation
import WinkCore
import Testing
@testable import WinkCLI

@Suite(.tags(.safe), .serialized)
struct ConfigEditorLaunchTests {
    @Test
    func `EditCommand terminates env options before an option-like editor`() {
        let arguments = ConfigCommand.EditCommand.editorProcessArguments(
            editor: "-S/usr/bin/touch /tmp/pwned",
            configPath: "/tmp/config.json"
        )

        #expect(arguments == ["--", "-S/usr/bin/touch /tmp/pwned", "/tmp/config.json"])
    }

    @Test
    func `EditCommand preserves a normal editor after the env option terminator`() {
        let arguments = ConfigCommand.EditCommand.editorProcessArguments(
            editor: "/usr/bin/nano",
            configPath: "/tmp/config.json"
        )

        #expect(arguments == ["--", "/usr/bin/nano", "/tmp/config.json"])
    }

    @Test
    func `EditCommand leaves the editor wait unbounded unless timeout is set`() {
        let command = ConfigCommand.EditCommand()
        #expect(command.timeout == nil)
    }

    @Test
    func `CLI print-path does not create configuration or launch an editor`() async throws {
        try await self.withTempConfigDir { dir in
            let resolved = try CommanderRuntimeRouter.resolve(argv: [
                "wink", "config", "edit", "--print-path",
                "--editor", dir.appendingPathComponent("missing-editor").path,
            ])
            var command = try CommanderCLIBinder.instantiateCommand(
                ofType: ConfigCommand.EditCommand.self,
                parsedValues: resolved.parsedValues
            )

            #expect(command.printPath)
            try await command.run(using: self.makeRuntime())
            #expect(!FileManager.default.fileExists(atPath: WinkCore.ConfigurationManager.configPath))
        }
    }

    @Test
    func `EditCommand bounds a non-exiting editor`() async throws {
        try await self.withTempConfigDir { dir in
            let fileManager = FileManager.default
            let editor = dir.appendingPathComponent("hanging-editor")
            let pidFile = dir.appendingPathComponent("editor.pid")
            let script = """
            #!/bin/sh
            printf '%s\\n' "$$" > "\(pidFile.path)"
            trap '' TERM
            exec /bin/sleep 60
            """
            try script.write(to: editor, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editor.path)

            var command = ConfigCommand.EditCommand()
            command.editor = editor.path
            // Give the shell time to record its PID under CPU contention before the timeout reaps it.
            command.timeout = .seconds(3)

            let runtime = self.makeRuntime()
            let startedAt = ContinuousClock.now
            let exitCode = await #expect(throws: ExitCode.self) {
                try await command.run(using: runtime)
            }
            #expect(exitCode == ExitCode.failure)
            // The three-second timeout permits two more seconds of termination cleanup.
            // Leave generous scheduling headroom while staying far below the editor's 60-second natural exit.
            #expect(startedAt.duration(to: .now) < .seconds(20))

            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try #require(Int32(pidText))
            errno = 0
            #expect(kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    private func makeRuntime() -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: WinkServices()
        )
    }

    private func withTempConfigDir(_ body: (URL) async throws -> Void) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-cli-config-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let environmentKeys = [
            "PEEKABOO_CONFIG_DIR",
            "WINK_CONFIG_NONINTERACTIVE",
            "WINK_CONFIG_DISABLE_MIGRATION",
        ]
        let previous = Dictionary(uniqueKeysWithValues: environmentKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("WINK_CONFIG_NONINTERACTIVE", "1", 1)
        setenv("WINK_CONFIG_DISABLE_MIGRATION", "1", 1)
        WinkCore.ConfigurationManager.shared.resetForTesting()

        defer {
            for key in environmentKeys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            WinkCore.ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        try await body(tempDir)
    }
}
