import Darwin
import Foundation

// MARK: - Server execution seam

protocol WinkBridgeAgentExecutionRunning: Sendable {
    func run(
        request: WinkBridgeAgentExecutionTraceRequest,
        peer: WinkBridgePeer,
        servingSocketPath: String) async throws -> WinkBridgeAgentExecutionTraceResponse
}

struct WinkBridgeLiveAgentExecutionRunner: WinkBridgeAgentExecutionRunning {
    // The signed operation bundle also carries a base64 canonical response, so raw streams must leave room for both.
    private static let maximumCombinedOutputBytes = 16 * 1024 * 1024
    private static let terminationGraceMilliseconds = 500
    private static let pipeDrainMilliseconds = 500

    func run(
        request: WinkBridgeAgentExecutionTraceRequest,
        peer: WinkBridgePeer,
        servingSocketPath: String) async throws -> WinkBridgeAgentExecutionTraceResponse
    {
        let worker = Task.detached(priority: .userInitiated) {
            try await self.runDetached(
                request: request,
                peer: peer,
                servingSocketPath: servingSocketPath)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // Keep hashing, signature checks, waitpid polling, and pipe ownership off the app's MainActor.
    // swiftlint:disable:next function_body_length
    private func runDetached(
        request: WinkBridgeAgentExecutionTraceRequest,
        peer: WinkBridgePeer,
        servingSocketPath: String) async throws -> WinkBridgeAgentExecutionTraceResponse
    {
        guard !servingSocketPath.isEmpty,
              servingSocketPath.first == "/",
              !servingSocketPath.utf8.contains(0)
        else {
            throw WinkBridgeAgentExecutionPreReleaseError.invalidRequest("Bridge socket path is invalid")
        }

        let executable = try WinkBridgeAgentExecutionExecutable.capturePeer(peer)
        let paths = try WinkBridgeAgentExecutionPaths.validateAndPrepare(request)
        let requestingPeer = WinkBridgeOperationProcessIdentity(
            processIdentifier: executable.processIdentifier,
            processStartIdentity: executable.processStartIdentity,
            codeSignatureHash: executable.codeSignatureHash)
        let challenge = try WinkBridgeAgentExecutionCoding.randomChallenge()
        let arguments = WinkBridgeAgentExecutionCoding.arguments(
            task: request.task,
            maxSteps: request.maxSteps,
            socketPath: servingSocketPath)
        let taskSHA256 = WinkBridgeAgentExecutionCoding.sha256(Data(request.task.utf8))
        let argumentsSHA256 = try WinkBridgeAgentExecutionCoding.sha256Canonical(arguments)
        let pipes = try WinkBridgeAgentExecutionPipes()
        let releaseGate: WinkBridgeAgentExecutionReleaseGate
        do {
            releaseGate = try WinkBridgeAgentExecutionReleaseGate(excludingDescriptors: [
                pipes.stdoutRead,
                pipes.stdoutWrite,
                pipes.stderrRead,
                pipes.stderrWrite,
            ])
        } catch {
            pipes.closeAll()
            throw error
        }
        let environment: WinkBridgeAgentExecutionEnvironment
        do {
            environment = try WinkBridgeAgentExecutionEnvironment.make(
                operationReceiptDirectoryPath: paths.operationReceiptDirectory.path,
                releaseGateDescriptor: releaseGate.childDescriptor,
                lockdownReadinessDescriptor: releaseGate.childReadinessDescriptor,
                releaseChallenge: challenge)
        } catch {
            pipes.closeAll()
            releaseGate.closeAll()
            throw error
        }

        let spawnedAt = WinkBridgeAgentExecutionCoding.nowMilliseconds()
        let processIdentifier: pid_t
        do {
            processIdentifier = try WinkBridgeAgentExecutionSpawn.spawnSuspended(
                executablePath: executable.path,
                arguments: arguments,
                environment: environment.values,
                pipes: pipes,
                releaseGate: releaseGate)
        } catch {
            pipes.closeAll()
            releaseGate.closeAll()
            if let error = error as? WinkBridgeAgentExecutionPreReleaseError {
                throw error
            }
            throw WinkBridgeAgentExecutionPreReleaseError.spawnFailed(error.localizedDescription)
        }
        let startDeadline = ContinuousClock.now.advanced(by: .milliseconds(request.startTimeoutMilliseconds))

        let pipeControl = WinkBridgeAgentExecutionPipeControl(
            maximumCombinedBytes: Self.maximumCombinedOutputBytes)
        let stdoutTask = Task.detached(priority: .userInitiated) {
            WinkBridgeAgentExecutionPipeReader.read(pipes.stdoutRead, control: pipeControl)
        }
        let stderrTask = Task.detached(priority: .userInitiated) {
            WinkBridgeAgentExecutionPipeReader.read(pipes.stderrRead, control: pipeControl)
        }

        let coordinationBytes: Data
        let acknowledgementBytes: Data
        let process: WinkBridgeAgentExecutionProcessIdentity
        let processCustody: WinkBridgeAgentExecutionProcessCustody
        let lockdownAcknowledgedAt: Int64
        let receiptPublishedAt: Int64
        let acknowledgedAt: Int64
        let releasedAt: Int64
        do {
            let child = try WinkBridgeAgentExecutionExecutable.captureChild(
                processIdentifier,
                expected: executable)
            process = WinkBridgeAgentExecutionProcessIdentity(
                processIdentity: .init(
                    processIdentifier: child.processIdentifier,
                    processStartIdentity: child.processStartIdentity,
                    codeSignatureHash: child.codeSignatureHash),
                executablePath: child.path,
                executableSHA256: child.sha256)
            processCustody = try WinkBridgeAgentExecutionProcessWait.captureProcessCustody(
                processIdentity: process.processIdentity)
            guard Darwin.kill(processIdentifier, SIGCONT) == 0 else {
                throw WinkBridgeAgentExecutionPreReleaseError.releaseFailed(errno)
            }
            try await releaseGate.waitForLockdown(challenge: challenge, deadline: startDeadline)
            lockdownAcknowledgedAt = WinkBridgeAgentExecutionCoding.nowMilliseconds()
            _ = try WinkBridgeAgentExecutionExecutable.captureChild(
                processIdentifier,
                expected: executable)
            receiptPublishedAt = WinkBridgeAgentExecutionCoding.nowMilliseconds()
            let receipt = WinkBridgeAgentExecutionCoordinationReceipt(
                challenge: challenge,
                requestingPeer: requestingPeer,
                process: process,
                bridgeSocketPath: servingSocketPath,
                runRootPath: paths.runRoot.path,
                coordinationReceiptPath: paths.coordinationReceipt.path,
                acknowledgementPath: paths.acknowledgement.path,
                operationReceiptDirectoryPath: paths.operationReceiptDirectory.path,
                taskSHA256: taskSHA256,
                maxSteps: request.maxSteps,
                startTimeoutMilliseconds: request.startTimeoutMilliseconds,
                runTimeoutMilliseconds: request.runTimeoutMilliseconds,
                arguments: arguments,
                argumentsSHA256: argumentsSHA256,
                backgroundOnly: true,
                allowForeground: false,
                shellAvailable: false,
                processCreationLimit: 0,
                environmentPolicyVersion: environment.policyVersion,
                environmentKeys: environment.keys,
                environmentSHA256: environment.sha256,
                spawnedAt: spawnedAt,
                lockdownAcknowledgedAt: lockdownAcknowledgedAt,
                publishedAt: receiptPublishedAt)
            coordinationBytes = try WinkBridgeAgentExecutionCoding.canonicalData(receipt)
            do {
                try WinkBridgePrivateReceiptArchive.writeAtomically(
                    coordinationBytes,
                    to: paths.coordinationReceipt)
            } catch {
                throw WinkBridgeAgentExecutionPreReleaseError.receiptPublicationFailed(
                    error.localizedDescription)
            }

            let acknowledgement = try await WinkBridgeAgentExecutionAcknowledgementReader.wait(
                at: paths.acknowledgement,
                deadline: startDeadline)
            acknowledgementBytes = acknowledgement.bytes
            try WinkBridgeAgentExecutionAcknowledgementReader.validate(
                acknowledgement.value,
                bytes: acknowledgement.bytes,
                receipt: receipt,
                receiptBytes: coordinationBytes)
            acknowledgedAt = WinkBridgeAgentExecutionCoding.nowMilliseconds()

            guard try WinkBridgeAgentExecutionAcknowledgementReader.stableRead(paths.coordinationReceipt) ==
                coordinationBytes,
                try WinkBridgeAgentExecutionAcknowledgementReader.stableRead(paths.acknowledgement) ==
                acknowledgementBytes
            else {
                throw WinkBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                    "coordination files changed before release")
            }
            try WinkBridgeAgentExecutionExecutable.revalidatePeer(peer, expected: executable)
            _ = try WinkBridgeAgentExecutionExecutable.captureChild(
                processIdentifier,
                expected: executable)
            try Task.checkCancellation()
            guard ContinuousClock.now < startDeadline else {
                throw WinkBridgeAgentExecutionPreReleaseError.acknowledgementTimedOut
            }
            try paths.provisionOperationReceiptDirectoryBeforeRelease()
            try WinkBridgeAgentExecutionExecutable.revalidatePeer(peer, expected: executable)
            _ = try WinkBridgeAgentExecutionExecutable.captureChild(
                processIdentifier,
                expected: executable)
            guard try WinkBridgeAgentExecutionAcknowledgementReader.stableRead(paths.coordinationReceipt) ==
                coordinationBytes,
                try WinkBridgeAgentExecutionAcknowledgementReader.stableRead(paths.acknowledgement) ==
                acknowledgementBytes
            else {
                throw WinkBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                    "coordination files changed before release")
            }
            try paths.revalidateBeforeRelease()
            try Task.checkCancellation()
            guard ContinuousClock.now < startDeadline else {
                throw WinkBridgeAgentExecutionPreReleaseError.acknowledgementTimedOut
            }
            try releaseGate.release(challenge: challenge)
            releasedAt = WinkBridgeAgentExecutionCoding.nowMilliseconds()
        } catch {
            releaseGate.closeAll()
            WinkBridgeAgentExecutionProcessWait.killSuspendedAndReap(processIdentifier)
            pipeControl.stop()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            if let error = error as? WinkBridgeAgentExecutionPreReleaseError {
                throw error
            }
            if error is CancellationError || Task.isCancelled {
                throw WinkBridgeAgentExecutionPreReleaseError.cancelledBeforeRelease
            }
            throw WinkBridgeAgentExecutionPreReleaseError.executableIdentityChanged
        }

        let terminal = await WinkBridgeAgentExecutionProcessWait.wait(
            processIdentifier,
            processCustody: processCustody,
            timeoutMilliseconds: request.runTimeoutMilliseconds,
            pipeControl: pipeControl,
            terminationGraceMilliseconds: Self.terminationGraceMilliseconds)
        await Self.finishPipeDrain(control: pipeControl)
        let stdoutCapture = await stdoutTask.value
        let stderrCapture = await stderrTask.value
        let stdout = WinkBridgeAgentExecutionByteEvidence(
            bytes: stdoutCapture.bytes,
            truncated: stdoutCapture.truncated,
            readErrorCode: stdoutCapture.readErrorCode)
        let stderr = WinkBridgeAgentExecutionByteEvidence(
            bytes: stderrCapture.bytes,
            truncated: stderrCapture.truncated,
            readErrorCode: stderrCapture.readErrorCode)
        let extracted = WinkBridgeAgentExecutionOutputExtractor.extract(
            stdout.bytes,
            outputOverflow: terminal.disposition == .outputOverflow,
            streamFailed: stdout.readErrorCode != nil || stdout.truncated || stderr.readErrorCode != nil ||
                stderr.truncated)

        return WinkBridgeAgentExecutionTraceResponse(
            process: process,
            requestingPeer: requestingPeer,
            bridgeSocketPath: servingSocketPath,
            runRootPath: paths.runRoot.path,
            coordinationReceiptPath: paths.coordinationReceipt.path,
            acknowledgementPath: paths.acknowledgement.path,
            operationReceiptDirectoryPath: paths.operationReceiptDirectory.path,
            taskSHA256: taskSHA256,
            maxSteps: request.maxSteps,
            startTimeoutMilliseconds: request.startTimeoutMilliseconds,
            runTimeoutMilliseconds: request.runTimeoutMilliseconds,
            arguments: arguments,
            argumentsSHA256: argumentsSHA256,
            backgroundOnly: true,
            allowForeground: false,
            shellAvailable: false,
            processCreationLimit: 0,
            environmentPolicyVersion: environment.policyVersion,
            environmentKeys: environment.keys,
            environmentSHA256: environment.sha256,
            stdout: stdout,
            stderr: stderr,
            coordinationReceipt: .init(bytes: coordinationBytes),
            acknowledgement: .init(bytes: acknowledgementBytes),
            processDisposition: terminal.disposition,
            outputDisposition: extracted.disposition,
            executionTrace: extracted.trace,
            exitCode: terminal.exitCode,
            terminationSignal: terminal.terminationSignal,
            spawnedAt: spawnedAt,
            lockdownAcknowledgedAt: lockdownAcknowledgedAt,
            coordinationReceiptPublishedAt: receiptPublishedAt,
            acknowledgedAt: acknowledgedAt,
            releasedAt: releasedAt,
            terminalObservationEndedAt: terminal.terminalObservationEndedAt)
    }

    private static func finishPipeDrain(control: WinkBridgeAgentExecutionPipeControl) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(self.pipeDrainMilliseconds))
        while ContinuousClock.now < deadline, !control.allReadersFinished {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                control.stop()
                return
            }
        }
        control.stop(markTruncated: !control.allReadersFinished)
    }
}
