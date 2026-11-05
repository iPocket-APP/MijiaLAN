import AppKit
import Observation
import OSLog
import Sparkle

/// One updater for the application lifetime, independent of the transient menu-bar panel.
@MainActor
@Observable
final class AppUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var canCheckForUpdates = false
    private(set) var availableVersion: String?
    private(set) var startupError: String?
    var automaticallyChecksForUpdates = false {
        didSet {
            guard !synchronizing else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    var automaticallyDownloadsUpdates = false {
        didSet {
            guard !synchronizing else { return }
            controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var synchronizing = false

    func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        // UI previews, package smoke checks and tests must never contact the live feed or save updater preferences.
        guard controller == nil, environment["MIJIALAN_EPHEMERAL"] != "1",
              environment["MIJIALAN_UI_PREVIEW"] != "1" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        do {
            try controller.updater.start()
        } catch {
            startupError = error.localizedDescription
            Logger(subsystem: "com.mijialan.MijiaLAN", category: "Updates")
                .error("Could not start updater: \(error.localizedDescription, privacy: .public)")
        }
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.synchronizeSettings() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.synchronizeSettings() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.synchronizeSettings() }
            }
        ]
        synchronizeSettings()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    private func synchronizeSettings() {
        guard let updater = controller?.updater else { return }
        synchronizing = true
        defer { synchronizing = false }
        canCheckForUpdates = startupError == nil && updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    // Scheduled checks advertise an update in our panel instead of stealing focus from another app.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
