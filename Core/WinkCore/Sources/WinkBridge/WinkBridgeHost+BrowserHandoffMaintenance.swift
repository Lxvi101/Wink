import Foundation

extension WinkBridgeHost {
    func startBrowserHandoffMaintenanceIfNeeded() {
        guard self.browserHandoffMaintenanceTask == nil,
              self.server.supportsBrowserHandoffMaintenance
        else { return }
        let server = self.server
        let intervalMilliseconds = self.browserHandoffMaintenanceIntervalMilliseconds
        self.browserHandoffMaintenanceTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(intervalMilliseconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await server.scheduleBrowserHandoffMaintenance()
            }
        }
    }

    func startBrowserHandoffShutdownMaintenance() {
        guard self.server.supportsBrowserHandoffMaintenance else { return }
        Self.continueBrowserHandoffShutdownMaintenance(
            server: self.server,
            intervalMilliseconds: self.browserHandoffMaintenanceIntervalMilliseconds)
    }

    nonisolated static func continueBrowserHandoffShutdownMaintenance(
        server: WinkBridgeServer,
        intervalMilliseconds: Int64)
    {
        Task.detached(priority: .utility) {
            while await server.scheduleBrowserHandoffShutdownMaintenance() {
                try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
            }
        }
    }
}
