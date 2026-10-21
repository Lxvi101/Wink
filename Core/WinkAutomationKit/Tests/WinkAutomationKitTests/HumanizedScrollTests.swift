import AXorcist
import CoreGraphics
import Foundation
import struct WinkFoundation.DesktopActionFailure
import struct WinkFoundation.DesktopActionOutcome
import enum WinkFoundation.ScrollDirection
import Testing
@testable import WinkAutomationKit

struct HumanizedScrollTests {
    @Test(arguments: [1, 3, 6, 7, 50])
    func `strokes preserve distance and end each phase`(amount: Int) {
        for direction in [ScrollDirection.up, .down, .left, .right] {
            let samples = HumanizedScrollPlan.samples(amount: amount, direction: direction, random: { 0.5 })
            let strokes = (amount * 50 + 299) / 300
            #expect(samples.count == strokes * 44)
            let x = samples.reduce(0) { $0 + Int($1.deltaX) }
            let y = samples.reduce(0) { $0 + Int($1.deltaY) }
            switch direction {
            case .up: #expect(x == 0 && y == amount * 50)
            case .down: #expect(x == 0 && y == -amount * 50)
            case .left: #expect(x == amount * 50 && y == 0)
            case .right: #expect(x == -amount * 50 && y == 0)
            }
            for start in stride(from: 0, to: samples.count, by: 44) {
                #expect(samples[start].phase == 1)
                #expect(samples[start + 24].phase == 4)
                #expect(samples[start + 24].deltaX == 0 && samples[start + 24].deltaY == 0)
                #expect(samples[start + 25].momentumPhase == 1)
                #expect(samples[start + 43].momentumPhase == 3)
            }
            #expect(samples.allSatisfy { $0.delay >= 0 && $0.delay <= 0.22 })
        }
    }

    @Test
    func `pixel events retain location continuous flag and gesture phase`() throws {
        let sample = TrackpadScrollSample(deltaX: 0, deltaY: -12, phase: 2, momentumPhase: 0, delay: 0.016)
        let point = CGPoint(x: 120, y: 240)
        let event = try TrackpadScrollEvent.make(sample, at: point)
        #expect(event.location == point)
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -12)
        #expect(event.getIntegerValueField(.scrollWheelEventScrollPhase) == 2)
        #expect(event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0)
    }

    @Test
    func `humanized requests round trip and legacy requests keep their default`() throws {
        let legacy = try JSONDecoder().decode(ScrollRequest.self, from: Data(#"{"direction":"down","amount":3}"#.utf8))
        #expect(!legacy.humanized)
        let request = ScrollRequest(direction: .down, amount: 3, foreground: true, humanized: true)
        let decoded = try JSONDecoder().decode(ScrollRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.humanized)
        try decoded.validateHumanized()
        for invalid in [
            ScrollRequest(direction: .down, amount: 3, humanized: true),
            ScrollRequest(direction: .down, amount: 0, foreground: true, humanized: true),
            ScrollRequest(direction: .down, amount: 51, foreground: true, humanized: true),
            ScrollRequest(direction: .down, amount: 3, smooth: true, foreground: true, humanized: true),
            ScrollRequest(direction: .down, amount: 3, delay: 1, foreground: true, humanized: true),
        ] {
            #expect(throws: (any Error).self) { try invalid.validateHumanized() }
        }
    }
}

@MainActor
struct HumanizedScrollCancellationTests {
    @Test
    func `cancellation closes the gesture and retains dispatched count`() async throws {
        let driver = HumanizedScrollTestDriver()
        let service = ScrollService(snapshotManager: InMemorySnapshotManager(), syntheticInputDriver: driver)
        let operation = Task {
            try await service.performHumanizedScroll(
                ScrollRequest(direction: .down, amount: 1, foreground: true, humanized: true), at: .zero)
        }
        while driver.samples.isEmpty {
            await Task.yield()
        }
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Expected cancellation after a dispatched prefix")
        } catch let failure as DesktopActionFailure {
            #expect(driver.samples.last?.phase == 8)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == driver.samples.count)
        }
    }

    @Test
    func `pre-cancelled gestures dispatch nothing`() async {
        let driver = HumanizedScrollTestDriver()
        let service = ScrollService(snapshotManager: InMemorySnapshotManager(), syntheticInputDriver: driver)
        let operation = Task {
            try await service.performHumanizedScroll(
                ScrollRequest(direction: .down, amount: 1, foreground: true, humanized: true), at: .zero)
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(driver.samples.isEmpty)
    }
}

@MainActor
private final class HumanizedScrollTestDriver: SyntheticInputDriving {
    var samples: [TrackpadScrollSample] = []

    func trackpadScroll(_ sample: TrackpadScrollSample, at _: CGPoint) throws {
        self.samples.append(sample)
    }

    func click(at _: CGPoint, button _: MouseButton, count _: Int) throws -> DesktopActionOutcome {
        throw CancellationError()
    }

    func click(
        at _: CGPoint,
        button _: MouseButton,
        count _: Int,
        targetProcessIdentifier _: pid_t) async throws -> DesktopActionOutcome
    {
        throw CancellationError()
    }

    func move(to _: CGPoint) throws {}
    func currentLocation() -> CGPoint? {
        .zero
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) async throws {}
    func scroll(deltaX _: Double, deltaY _: Double, at _: CGPoint?) throws {}
    func type(_: String, delayPerCharacter _: TimeInterval) throws {}
    func tapKey(_: SpecialKey, modifiers _: CGEventFlags) throws {}
    func hotkey(keys _: [String], holdDuration _: TimeInterval) throws {}
}
