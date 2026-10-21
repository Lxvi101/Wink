import Testing

struct InputAutomationSafetyTests {
    @Test
    func `allows bundled Playground apps by default`() {
        #expect(InputAutomationSafety.isAllowedFrontmostApplication(
            bundleIdentifier: "boo.wink.playground",
            environment: [:]))
        #expect(InputAutomationSafety.isAllowedFrontmostApplication(
            bundleIdentifier: "boo.wink.playground.debug",
            environment: [:]))
        #expect(InputAutomationSafety.isAllowedFrontmostApplication(
            bundleIdentifier: "boo.wink.wink.testhost",
            environment: [:]))
    }

    @Test
    func `rejects unrelated frontmost app by default`() {
        #expect(!InputAutomationSafety.isAllowedFrontmostApplication(
            bundleIdentifier: "com.apple.TextEdit",
            environment: [:]))
    }

    @Test
    func `custom allowed bundle list replaces defaults`() {
        let environment = [
            "WINK_INPUT_AUTOMATION_ALLOWED_BUNDLE_IDS": "com.example.SafeHost, com.example.Other",
        ]

        #expect(InputAutomationSafety.isAllowedFrontmostApplication(
            bundleIdentifier: "com.example.SafeHost",
            environment: environment))
        #expect(!InputAutomationSafety.isAllowedFrontmostApplication(
            bundleIdentifier: "boo.wink.playground",
            environment: environment))
    }

    @Test
    func `explicit unsafe override allows any frontmost app`() {
        let environment = ["WINK_ALLOW_UNSAFE_INPUT_AUTOMATION": "true"]

        #expect(InputAutomationSafety.canRunInCurrentDesktopSession(
            environment: environment,
            frontmostApplication: nil))
    }
}
