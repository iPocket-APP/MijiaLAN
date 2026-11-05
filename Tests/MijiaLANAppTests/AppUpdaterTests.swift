import Testing
@testable import MijiaLANApp

@MainActor
struct AppUpdaterTests {
    @Test("Ephemeral smoke checks never start the live updater")
    func ephemeralProfile() {
        let updater = AppUpdater()
        updater.start(environment: ["MIJIALAN_EPHEMERAL": "1"])
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.automaticallyChecksForUpdates)
        #expect(updater.startupError == nil)
        updater.checkForUpdates()
    }

    @Test("Isolated UI previews never start the live updater")
    func isolatedPreview() {
        let updater = AppUpdater()
        updater.start(environment: ["MIJIALAN_UI_PREVIEW": "1"])
        #expect(!updater.canCheckForUpdates)
        #expect(updater.availableVersion == nil)
        #expect(updater.supportsGentleScheduledUpdateReminders)
    }
}
