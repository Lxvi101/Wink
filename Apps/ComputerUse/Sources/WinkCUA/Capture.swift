import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct WindowShot {
    let jpeg: Data
    let pixelWidth: Int
    let pixelHeight: Int
    /// Screenshot pixels per screen point.
    let scale: CGFloat
}

/// Holds an async result that may arrive after the waiter has given up.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ result: Result<T, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Captures a single window (even when covered or in the background) with ScreenCaptureKit.
/// Shareable content is cached because enumerating it costs far more than the capture itself.
final class WindowCapturer: @unchecked Sendable {
    private var cached: SCShareableContent?
    private var cachedAt = Date.distantPast
    private let lock = NSLock()

    /// ScreenCaptureKit sometimes never calls back (display asleep, screen locked, replayd stuck).
    /// Requests are served one at a time, so an unbounded wait here froze the whole server.
    private static let timeout: TimeInterval = 8

    private func blocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.set(.success(try await work())) } catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.timeout) == .success, let result = box.get() else {
            lock.lock(); cached = nil; lock.unlock()
            throw ToolError("screen capture timed out after \(Int(Self.timeout))s (display asleep or capture service busy)")
        }
        return try result.get()
    }

    private func window(id: CGWindowID) throws -> SCWindow? {
        lock.lock()
        if Date().timeIntervalSince(cachedAt) < 3, let hit = cached?.windows.first(where: { $0.windowID == id }) {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let content = try blocking { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        lock.lock(); cached = content; cachedAt = Date(); lock.unlock()
        return content.windows.first(where: { $0.windowID == id })
    }

    func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = try? self.window(id: 0) }
    }

    func capture(windowID: CGWindowID, maxDimension: CGFloat, quality: CGFloat) throws -> WindowShot {
        guard let window = try window(id: windowID) else {
            throw ToolError("window \(windowID) is not capturable (minimised, closed or on another space)")
        }
        let frame = window.frame
        var scale: CGFloat = 1
        let longest = max(frame.width, frame.height)
        if longest > maxDimension { scale = maxDimension / longest }
        let config = SCStreamConfiguration()
        config.width = max(1, Int((frame.width * scale).rounded()))
        config.height = max(1, Int((frame.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .nominal
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try blocking { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ToolError("could not create JPEG encoder")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("JPEG encoding failed") }
        return WindowShot(jpeg: data as Data, pixelWidth: image.width, pixelHeight: image.height,
                          scale: CGFloat(image.width) / max(frame.width, 1))
    }
}
