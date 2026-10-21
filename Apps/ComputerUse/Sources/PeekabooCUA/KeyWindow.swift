import ApplicationServices
import Darwin

/// Makes a background app treat one of its windows as key *without* activating the app or reordering
/// windows, so key equivalents (cmd+a, cmd+c, …) find a first responder. Same WindowServer event record
/// as Peekaboo's `BackgroundWindowActivationDriver`, posted only to the target process.
enum KeyWindow {
    private typealias ResolvePSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias PostRecord = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32

    private static let resolvePSN: ResolvePSN? = {
        guard let lib = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let sym = dlsym(lib, "GetProcessForPID") else { return nil }
        return unsafeBitCast(sym, to: ResolvePSN.self)
    }()

    private static let post: PostRecord? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(lib, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(sym, to: PostRecord.self)
    }()

    @discardableResult
    static func makeKey(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let resolvePSN, let post else { return false }
        var psn: [UInt32] = [0, 0]
        guard psn.withUnsafeMutableBytes({ resolvePSN(pid, $0.baseAddress!) }) == 0 else { return false }
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x08] = 0x0D
        record[0x8A] = 0x01
        for byte in 0..<4 { record[0x3C + byte] = UInt8(truncatingIfNeeded: windowID >> (byte * 8)) }
        func send(_ bytes: [UInt8]) -> Int32 {
            psn.withUnsafeBytes { recipient in bytes.withUnsafeBytes { post(recipient.baseAddress!, $0.baseAddress!) } }
        }
        // 1) Tell the process its window is active (target-only; the real front app is unchanged).
        var ok = send(record) == 0
        // 2) Synthetic window-server "make key" pair so AppKit installs a key window / first responder.
        var key = [UInt8](repeating: 0, count: 0xF8)
        key[0x04] = 0xF8
        key[0x3A] = 0x10
        for byte in 0..<4 { key[0x3C + byte] = UInt8(truncatingIfNeeded: windowID >> (byte * 8)) }
        for i in 0x20..<0x30 { key[i] = 0xFF }
        key[0x08] = 0x01
        ok = send(key) == 0 && ok
        key[0x08] = 0x02
        ok = send(key) == 0 && ok
        return ok
    }
}
