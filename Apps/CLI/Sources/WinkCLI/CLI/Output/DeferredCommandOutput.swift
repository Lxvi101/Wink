import Darwin
import Foundation

enum DeferredCommandOutput {
    static func run<T>(
        bufferingOutput: Bool,
        operation: () async throws -> T
    ) async throws -> T {
        guard bufferingOutput else {
            return try await operation()
        }

        let inheritedTerminalOutput = TerminalDetector.standardOutputFileDescriptor
        let capture = try FileDescriptorOutputCapture()
        let terminalOutput = inheritedTerminalOutput ?? capture.originalStandardOutputDescriptor
        let result: T
        do {
            result = try await TerminalDetector.$standardOutputFileDescriptor.withValue(terminalOutput) {
                try await operation()
            }
        } catch {
            let shouldReplay = !(error is CancellationError)
            // Preserve the command's primary error even if restoring or replaying output fails.
            Logger.shared.flush()
            try? capture.finish(replayingOutput: shouldReplay)
            throw error
        }

        Logger.shared.flush()
        try capture.finish(replayingOutput: true)
        return result
    }
}

private nonisolated enum DeferredCommandOutputError: LocalizedError {
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .posix(operation, code):
            "Failed to \(operation): \(String(cString: strerror(code)))"
        }
    }
}

private final nonisolated class FileDescriptorOutputCapture {
    private var stdoutCapture: Int32 = -1
    private var stderrCapture: Int32 = -1
    private var originalStdout: Int32 = -1
    private var originalStderr: Int32 = -1
    private var stdoutRedirected = false
    private var stderrRedirected = false
    private var finished = false

    var originalStandardOutputDescriptor: Int32 {
        self.originalStdout
    }

    init() throws {
        // Keep output emitted before this command outside its deferred transaction.
        _ = fflush(nil)

        do {
            self.stdoutCapture = try Self.makeTemporaryFile(named: "stdout")
            self.stderrCapture = try Self.makeTemporaryFile(named: "stderr")
            self.originalStdout = try Self.duplicate(STDOUT_FILENO, named: "stdout")
            self.originalStderr = try Self.duplicate(STDERR_FILENO, named: "stderr")

            try Self.redirect(self.stdoutCapture, to: STDOUT_FILENO, named: "stdout")
            self.stdoutRedirected = true
            try Self.redirect(self.stderrCapture, to: STDERR_FILENO, named: "stderr")
            self.stderrRedirected = true
        } catch {
            self.restoreIgnoringErrors()
            self.closeDescriptors()
            throw error
        }
    }

    deinit {
        guard !self.finished else { return }
        _ = fflush(nil)
        self.restoreIgnoringErrors()
        self.closeDescriptors()
    }

    func finish(replayingOutput: Bool) throws {
        guard !self.finished else { return }

        _ = fflush(nil)
        try self.restore()

        defer {
            self.finished = true
            self.closeDescriptors()
        }

        if replayingOutput {
            try Self.replay(from: self.stdoutCapture, to: self.originalStdout, named: "stdout")
            try Self.replay(from: self.stderrCapture, to: self.originalStderr, named: "stderr")
        }
    }

    private func restore() throws {
        var firstError: (any Error)?

        if self.stdoutRedirected {
            do {
                try Self.redirect(self.originalStdout, to: STDOUT_FILENO, named: "stdout")
                self.stdoutRedirected = false
            } catch {
                firstError = error
            }
        }

        if self.stderrRedirected {
            do {
                try Self.redirect(self.originalStderr, to: STDERR_FILENO, named: "stderr")
                self.stderrRedirected = false
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func restoreIgnoringErrors() {
        if self.stdoutRedirected, dup2(self.originalStdout, STDOUT_FILENO) != -1 {
            self.stdoutRedirected = false
        }
        if self.stderrRedirected, dup2(self.originalStderr, STDERR_FILENO) != -1 {
            self.stderrRedirected = false
        }
    }

    private func closeDescriptors() {
        Self.close(&self.stdoutCapture)
        Self.close(&self.stderrCapture)
        Self.close(&self.originalStdout)
        Self.close(&self.originalStderr)
    }

    private static func makeTemporaryFile(named stream: String) throws -> Int32 {
        var template = Array("\(NSTemporaryDirectory())wink-\(stream).XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            let descriptor = mkstemp(baseAddress)
            if descriptor != -1 {
                _ = unlink(baseAddress)
            }
            return descriptor
        }
        guard descriptor != -1 else {
            throw DeferredCommandOutputError.posix(
                operation: "create deferred \(stream) output",
                code: errno
            )
        }
        Self.setCloseOnExec(descriptor)
        return descriptor
    }

    private static func duplicate(_ descriptor: Int32, named stream: String) throws -> Int32 {
        let duplicate = dup(descriptor)
        guard duplicate != -1 else {
            throw DeferredCommandOutputError.posix(
                operation: "duplicate \(stream)",
                code: errno
            )
        }
        Self.setCloseOnExec(duplicate)
        return duplicate
    }

    private static func redirect(_ source: Int32, to destination: Int32, named stream: String) throws {
        guard dup2(source, destination) != -1 else {
            throw DeferredCommandOutputError.posix(
                operation: "redirect \(stream)",
                code: errno
            )
        }
    }

    private static func replay(from source: Int32, to destination: Int32, named stream: String) throws {
        guard lseek(source, 0, SEEK_SET) != -1 else {
            throw DeferredCommandOutputError.posix(
                operation: "rewind deferred \(stream) output",
                code: errno
            )
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(source, bytes.baseAddress, bytes.count)
            }
            if bytesRead == 0 {
                return
            }
            if bytesRead == -1 {
                if errno == EINTR {
                    continue
                }
                throw DeferredCommandOutputError.posix(
                    operation: "read deferred \(stream) output",
                    code: errno
                )
            }

            var offset = 0
            while offset < bytesRead {
                let bytesWritten = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destination,
                        bytes.baseAddress?.advanced(by: offset),
                        bytesRead - offset
                    )
                }
                if bytesWritten == -1 {
                    if errno == EINTR {
                        continue
                    }
                    throw DeferredCommandOutputError.posix(
                        operation: "replay deferred \(stream) output",
                        code: errno
                    )
                }
                offset += bytesWritten
            }
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFD)
        if flags != -1 {
            _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    private static func close(_ descriptor: inout Int32) {
        guard descriptor != -1 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }
}
