import AppKit
import ApplicationServices
import Darwin

/// macOS charges a command-line tool's privacy permissions to the app that launched it: Claude Code in
/// Terminal needs Terminal to have Screen Recording, Cursor needs Cursor, and so on. Disclaiming that
/// responsibility makes wink-cua answer for itself, so one grant to Wink (the app bundle it ships in)
/// works for every client. The first process re-launches itself disclaimed, passes its stdio straight
/// through, and relays signals and the exit status. `WINK_CUA_DISCLAIM=0` turns it off.
enum Responsibility {
    private static let marker = "WINK_CUA_DISCLAIMED"

    static func disclaimIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[marker] == nil, environment["WINK_CUA_DISCLAIM"] != "0",
              let path = Bundle.main.executablePath,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return }
        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        guard setDisclaim(&attributes, 1) == 0 else { return }

        // The relaunched copy's parent is this process: tell it who really started the server.
        let pairs = environment.map { "\($0.key)=\($0.value)" } + ["\(marker)=1", "WINK_CUA_CLIENT_PID=\(getppid())"]
        let argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
        let env: [UnsafeMutablePointer<CChar>?] = pairs.map { strdup($0) } + [nil]
        defer { (argv + env).forEach { free($0) } }
        var child: pid_t = 0
        guard posix_spawn(&child, path, nil, &attributes, argv, env) == 0 else { return }

        // The client stops the server by signalling this process: pass it on.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { kill(child, sig) }
            source.resume()
            relays.append(source)
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1, errno == EINTR {}
        let code = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        exit(code)
    }

    private static var relays: [DispatchSourceSignal] = []
}

/// `wink-cua permissions [request accessibility|screen-recording]`: Wink's own grants, as JSON.
enum Permissions {
    static func run(_ arguments: [String]) -> Int32 {
        if arguments.first == "request", let which = arguments.dropFirst().first {
            switch which {
            case "accessibility":
                // Adds Wink to the list (switched off) and shows macOS's prompt.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case "screen-recording":
                _ = CGRequestScreenCaptureAccess()
            default:
                FileHandle.standardError.write("unknown permission \(which)\n".data(using: .utf8)!)
                return 2
            }
        }
        let status: [String: Any] = [
            "accessibility": AXIsProcessTrusted(),
            "screenRecording": CGPreflightScreenCaptureAccess(),
            "app": Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        return 0
    }
}
