import Darwin
import Foundation
import Testing
@testable import WinkBridge

@Suite(.serialized)
struct WinkBridgeSocketIOTests {
    @Test
    func `peer audit token binds exact process generation and signing identity`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }

        for descriptor in [sockets.reader, sockets.writer] {
            let identity = try WinkBridgeSocketIO.peerAuditIdentity(fd: descriptor)
            #expect(identity.processIdentifier == getpid())
            #expect(identity.processIdentifierVersion == audit_token_to_pidversion(identity.token))
            #expect(identity.effectiveUserIdentifier == geteuid())
            #expect(identity.tokenData.count == MemoryLayout<audit_token_t>.size)
            #expect(WinkBridgeCodeSignatureIdentity.codeSignatureHash(auditIdentity: identity) ==
                WinkBridgeCodeSignatureIdentity.codeSignatureHash(processIdentifier: getpid()))
        }
    }

    @Test
    func `unconnected socket has no peer audit identity`() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        #expect(throws: POSIXError.self) {
            _ = try WinkBridgeSocketIO.peerAuditIdentity(fd: descriptor)
        }
    }

    @Test
    func `read times out when peer remains idle`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }
        try WinkBridgeSocketIO.configureConnectedSocket(sockets.reader)

        do {
            _ = try WinkBridgeSocketIO.readAll(
                fd: sockets.reader,
                maxBytes: 1024,
                deadline: Date().addingTimeInterval(0.05))
            Issue.record("Expected idle read to time out")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }
    }

    @Test
    func `write times out when peer does not drain its socket`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }
        try WinkBridgeSocketIO.configureConnectedSocket(sockets.writer)

        var sendBufferBytes: Int32 = 4096
        #expect(setsockopt(
            sockets.writer,
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBufferBytes,
            socklen_t(MemoryLayout.size(ofValue: sendBufferBytes))) == 0)

        do {
            try WinkBridgeSocketIO.writeAll(
                fd: sockets.writer,
                data: Data(repeating: 0xAB, count: 8 * 1024 * 1024),
                deadline: Date().addingTimeInterval(0.05))
            Issue.record("Expected undrained write to time out")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }
    }

    @Test
    func `nonblocking transport preserves a complete payload`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }
        try WinkBridgeSocketIO.configureConnectedSocket(sockets.reader)
        try WinkBridgeSocketIO.configureConnectedSocket(sockets.writer)

        let expected = Data("bridge payload".utf8)
        try WinkBridgeSocketIO.writeAll(
            fd: sockets.writer,
            data: expected,
            deadline: Date().addingTimeInterval(1))
        #expect(shutdown(sockets.writer, SHUT_WR) == 0)

        let received = try WinkBridgeSocketIO.readAll(
            fd: sockets.reader,
            maxBytes: 1024,
            deadline: Date().addingTimeInterval(1))
        #expect(received == expected)
    }

    private static func socketPair() throws -> (reader: Int32, writer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }
}
