import WinkCore
import Testing

struct WinkPermissionOnboardingPolicyTests {
    @Test
    func `Signing migration notice appears once for existing users`() {
        #expect(WinkPermissionOnboardingPolicy.currentVersion == 2)
        #expect(
            WinkPermissionOnboardingPolicy.decision(
                seenVersion: 1,
                hasSeen: true,
                hasRequiredPermissions: false
            ) == .show
        )
        #expect(
            WinkPermissionOnboardingPolicy.decision(
                seenVersion: 1,
                hasSeen: true,
                hasRequiredPermissions: true
            ) == .show
        )
        #expect(
            WinkPermissionOnboardingPolicy.decision(
                seenVersion: 0,
                hasSeen: false,
                hasRequiredPermissions: true
            ) == .markComplete
        )
        #expect(
            WinkPermissionOnboardingPolicy.decision(
                seenVersion: 2,
                hasSeen: true,
                hasRequiredPermissions: false
            ) == .skip
        )
        #expect(
            WinkPermissionOnboardingPolicy.decision(
                seenVersion: 2,
                hasSeen: false,
                hasRequiredPermissions: false
            ) == .show
        )
    }
}
