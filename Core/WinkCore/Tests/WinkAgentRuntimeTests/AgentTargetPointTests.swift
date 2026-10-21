import CoreGraphics
import Tachikoma
import Testing
@testable import WinkAgentRuntime

@MainActor
struct AgentTargetPointTests {
    @Test
    func `finite x and y arguments produce a target point`() {
        let arguments = AgentToolArguments([
            "x": AnyAgentToolValue(double: 120),
            "y": AnyAgentToolValue(double: 48.5),
        ])
        #expect(WinkAgentService.extractTargetPoint(from: arguments) == CGPoint(x: 120, y: 48.5))
    }

    @Test
    func `finite coordinate strings produce a target point`() {
        let arguments = AgentToolArguments(["coords": AnyAgentToolValue(string: "10, 20")])
        #expect(WinkAgentService.extractTargetPoint(from: arguments) == CGPoint(x: 10, y: 20))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func `non-finite x and y arguments are ignored`(value: Double) {
        let arguments = AgentToolArguments([
            "x": AnyAgentToolValue(double: value),
            "y": AnyAgentToolValue(double: 10),
        ])
        #expect(WinkAgentService.extractTargetPoint(from: arguments) == nil)
    }

    @Test(arguments: ["nan,20", "10,inf", "-infinity,0"])
    func `non-finite coordinate strings are ignored`(raw: String) {
        // Double() accepts these spellings, but none of them is a screen position.
        let arguments = AgentToolArguments(["coords": AnyAgentToolValue(string: raw)])
        #expect(WinkAgentService.extractTargetPoint(from: arguments) == nil)
    }
}
