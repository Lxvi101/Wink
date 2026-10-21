import WinkFoundation
import Testing
@testable import WinkAgentRuntime
@_spi(Testing) import WinkAutomationKit
@testable import WinkCore
@testable import WinkVisualizer

@Suite(.tags(.fast))
struct ElementRoleResolverTests {
    @Test
    func `Editable groups become text fields`() {
        let info = ElementRoleInfo(
            role: "AXGroup",
            roleDescription: nil,
            isEditable: true)

        let resolved = ElementRoleResolver.resolveType(baseType: .group, info: info)
        #expect(resolved == .textField)
    }

    @Test
    func `Role description hint promotes group`() {
        let info = ElementRoleInfo(
            role: "AXGroup",
            roleDescription: "text field",
            isEditable: false)

        let resolved = ElementRoleResolver.resolveType(baseType: .group, info: info)
        #expect(resolved == .textField)
    }

    @Test
    func `Other groups stay grouped`() {
        let info = ElementRoleInfo(
            role: "AXGroup",
            roleDescription: "group",
            isEditable: false)

        let resolved = ElementRoleResolver.resolveType(baseType: .group, info: info)
        #expect(resolved == .group)
    }
}
