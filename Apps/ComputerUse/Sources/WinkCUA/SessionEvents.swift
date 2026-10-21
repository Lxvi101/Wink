import AppKit
import Darwin

/// Tells other apps when an agent starts and stops driving the Mac, and where it is working, so a
/// companion (XNotch's Computer Use extension, a menu bar item, …) can show it. Posted as distributed
/// notifications with plist user info:
///
///     dev.wink.cua.session.start   session, pid, client?, app?
///     dev.wink.cua.session.action  session, pid, tool, app?, bundleID?, x?, y?, windowX?, windowY?
///     dev.wink.cua.session.end     session, pid, reason ("idle" | "exit")
///
/// Points are in AppKit screen coordinates (origin at the bottom left of the primary display). `x`/`y`
/// is where the agent cursor is heading, sent only when it moves; `windowX`/`windowY` is the middle of
/// the window being read, sent by `get_app_state`, which leaves the cursor where it is. A session starts with
/// the first tool call and ends `WINK_CUA_SESSION_IDLE` seconds (default 20) after the last one, or
/// when the server exits. `WINK_CUA_EVENTS=0` turns the events off.
final class SessionEvents: @unchecked Sendable {
    static let shared = SessionEvents()

    static let startName = Notification.Name("dev.wink.cua.session.start")
    static let actionName = Notification.Name("dev.wink.cua.session.action")
    static let endName = Notification.Name("dev.wink.cua.session.end")

    private let enabled = ProcessInfo.processInfo.environment["WINK_CUA_EVENTS"] != "0"
    private let idleTimeout = max(1, Double(ProcessInfo.processInfo.environment["WINK_CUA_SESSION_IDLE"] ?? "") ?? 20)
    private let pid = Int(getpid())
    /// The process that launched the server: "claude", "codex", …
    private lazy var client: String? = Self.processName(getppid())
    private let queue = DispatchQueue(label: "wink-cua.session-events")
    private var session: String?
    private var tool = ""
    private var idleWork: DispatchWorkItem?

    /// A tool call is starting: opens a session if none is running and holds off the idle end.
    func toolStarted(_ name: String, app: String?) {
        guard enabled else { return }
        queue.sync {
            tool = name
            idleWork?.cancel()
            idleWork = nil
            guard session == nil else { return }
            let id = UUID().uuidString
            session = id
            var info: [String: Any] = ["session": id, "pid": pid]
            if let client { info["client"] = client }
            if let app { info["app"] = app }
            post(Self.startName, info)
        }
    }

    /// The tool call finished: the session ends if no other follows soon.
    func toolFinished() {
        guard enabled else { return }
        queue.sync {
            idleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.endLocked(reason: "idle") }
            idleWork = work
            queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
        }
    }

    /// Where the current tool is working, in global top-left coordinates (as the input APIs use):
    /// `cursor` when the agent cursor moves there, `window` for the window being read.
    func focus(cursor: CGPoint? = nil, window: CGPoint? = nil, app: AppSession) {
        guard enabled else { return }
        queue.sync {
            guard let session else { return }
            var info: [String: Any] = ["session": session, "pid": pid, "tool": tool, "app": app.name]
            if let bundleID = app.bundleID { info["bundleID"] = bundleID }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            if let cursor {
                info["x"] = Double(cursor.x)
                info["y"] = Double(primaryHeight - cursor.y)
            }
            if let window {
                info["windowX"] = Double(window.x)
                info["windowY"] = Double(primaryHeight - window.y)
            }
            post(Self.actionName, info)
        }
    }

    /// Ends the session now; call before the process exits.
    func end(reason: String) {
        guard enabled else { return }
        queue.sync { endLocked(reason: reason) }
    }

    private func endLocked(reason: String) {
        idleWork?.cancel()
        idleWork = nil
        guard let id = session else { return }
        session = nil
        post(Self.endName, ["session": id, "pid": pid, "reason": reason])
    }

    private func post(_ name: Notification.Name, _ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info,
                                                                     deliverImmediately: true)
    }

    /// Ends the session when the client kills the server instead of closing stdin.
    func endOnTermination() {
        guard enabled else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                self?.end(reason: "exit")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
