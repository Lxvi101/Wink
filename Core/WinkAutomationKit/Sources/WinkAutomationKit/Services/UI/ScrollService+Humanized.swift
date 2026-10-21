import AXorcist
import CoreGraphics
import Foundation
import WinkFoundation

struct TrackpadScrollSample: Sendable {
    let deltaX: Int32
    let deltaY: Int32
    let phase: Int64
    let momentumPhase: Int64
    let delay: TimeInterval
}

/// Builds bounded strokes with a finger acceleration curve followed by a decaying momentum tail.
/// Integer cumulative rounding preserves the requested distance, including very small strokes.
enum HumanizedScrollPlan {
    static func samples(
        amount: Int,
        direction: WinkFoundation.ScrollDirection,
        random: () -> Double = { Double.random(in: 0...1) }) -> [TrackpadScrollSample]
    {
        guard (1...50).contains(amount) else { return [] }
        var remaining = amount * 50
        var result: [TrackpadScrollSample] = []
        while remaining > 0 {
            let distance = min(remaining, 300)
            remaining -= distance
            let weights = (0..<42).map { index in
                let curve = index < 24
                    ? sin(Double(index + 1) / 32 * .pi)
                    : sin(24.0 / 32 * .pi) * exp(-Double(index - 23) / 5)
                return curve * (0.9 + 0.2 * random())
            }
            let total = weights.reduce(0, +)
            var cumulative = 0.0
            var emitted = 0
            for (index, weight) in weights.enumerated() {
                if index == 24 {
                    result.append(self.sample(delta: 0, direction: direction, phase: 4, momentum: 0, delay: 0.012))
                }
                cumulative += weight
                let position = index == 41 ? distance : Int((cumulative / total * Double(distance)).rounded())
                let delta = position - emitted
                emitted = position
                result.append(self.sample(
                    delta: delta,
                    direction: direction,
                    phase: index < 24 ? (index == 0 ? 1 : 2) : 0,
                    momentum: index >= 24 ? (index == 24 ? 1 : 2) : 0,
                    delay: 0.014 + 0.004 * random()))
            }
            result.append(self.sample(
                delta: 0,
                direction: direction,
                phase: 0,
                momentum: 3,
                delay: remaining > 0 ? 0.12 + 0.1 * random() : 0))
        }
        return result
    }

    private static func sample(
        delta: Int, direction: WinkFoundation.ScrollDirection, phase: Int64, momentum: Int64, delay: TimeInterval)
        -> TrackpadScrollSample
    {
        let signed = Int32(delta)
        let axes: (Int32, Int32) = switch direction {
        case .up: (0, signed)
        case .down: (0, -signed)
        case .left: (signed, 0)
        case .right: (-signed, 0)
        }
        return TrackpadScrollSample(
            deltaX: axes.0, deltaY: axes.1, phase: phase, momentumPhase: momentum, delay: delay)
    }
}

enum TrackpadScrollEvent {
    static func make(_ sample: TrackpadScrollSample, at point: CGPoint) throws -> CGEvent {
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .pixel,
            wheelCount: 2,
            wheel1: sample.deltaY,
            wheel2: sample.deltaX,
            wheel3: 0)
        else { throw UIAutomationError.failedToCreateEvent }
        event.location = point
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: sample.phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: sample.momentumPhase)
        return event
    }
}

extension ScrollService {
    func performHumanizedScroll(_ request: ScrollRequest, at point: CGPoint) async throws -> Int {
        let samples = HumanizedScrollPlan.samples(amount: request.amount, direction: request.direction)
        var emitted = 0
        var lastSample: TrackpadScrollSample?
        do {
            for sample in samples {
                try Task.checkCancellation()
                try self.postTrackpadSample(sample, at: point)
                emitted += 1
                lastSample = sample
                if sample.delay > 0 {
                    try await Task.sleep(for: .seconds(sample.delay))
                }
            }
            return emitted
        } catch {
            guard emitted > 0 else { throw error }
            // End an interrupted gesture without adding displacement. Never leave momentum active.
            if let lastSample, lastSample.phase == 1 || lastSample.phase == 2 || lastSample.momentumPhase == 1 ||
                lastSample.momentumPhase == 2
            {
                let ending = TrackpadScrollSample(
                    deltaX: 0,
                    deltaY: 0,
                    phase: lastSample.phase != 0 ? 8 : 0,
                    momentumPhase: lastSample.momentumPhase != 0 ? 3 : 0,
                    delay: 0)
                if (try? self.postTrackpadSample(ending, at: point)) != nil {
                    emitted += 1
                }
            }
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .init(emitted),
                message: "Humanized scroll interrupted after dispatch",
                hint: "Observe the target before retrying this scroll.",
                causeDescription: error.localizedDescription)
        }
    }
}
