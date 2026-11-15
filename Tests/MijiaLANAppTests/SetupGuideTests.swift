import Foundation
import MijiaCore
import MijiaHomeKitBridge
import Testing
@testable import MijiaLANApp

struct SetupGuideTests {
    @Test func launchResumesAnUnfinishedGuide() throws {
        let suite = "MijiaLAN.SetupGuideTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved: CredentialVault.Lookup = .value(Data())
        let guide = SetupGuideProgress(defaults: defaults)

        #expect(guide.shouldOpen(configuration: .missing))
        #expect(!guide.shouldOpen(configuration: saved))
        #expect(!guide.shouldOpen(configuration: .unavailable))

        #expect(guide.begin())
        let reopened = SetupGuideProgress(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.shouldOpen(configuration: saved))
        #expect(!reopened.shouldOpen(configuration: .unavailable))
        #expect(!reopened.begin())

        reopened.dismiss()
        #expect(!guide.shouldOpen(configuration: .missing))
        #expect(!guide.shouldOpen(configuration: saved))
    }

    @Test func pairingCodeAppearsWhenTheBridgeIsReady() {
        let uri = "X-HM://FIXTURE"
        let code = "031-45-154"
        let running = HomeKitBridgeController.Status.running(port: 12345)

        func state(_ status: HomeKitBridgeController.Status, enabled: Bool = true, paired: Bool = false,
                   resetting: Bool = false, refreshing: Bool = false, accessories: Int = 1) -> SetupGuideHomeState {
            SetupGuideHomeState(status: status, enabled: enabled, paired: paired, resetting: resetting, refreshingCode: refreshing,
                                accessories: accessories, uri: uri, code: code)
        }

        #expect(state(.starting) == .preparing)
        #expect(state(.failed("Unavailable")) == .failed("Unavailable"))
        #expect(state(running, enabled: false) == .bridgeOff)
        #expect(state(running, resetting: true) == .resetting)
        #expect(state(running, paired: true, resetting: true) == .resetting)
        #expect(state(running, refreshing: true) == .refreshingCode)
        #expect(state(running, accessories: 0) == .noAccessories)
        #expect(state(running) == .pairing(uri: uri, code: code))
        #expect(state(running, paired: true) == .paired)
    }
}
