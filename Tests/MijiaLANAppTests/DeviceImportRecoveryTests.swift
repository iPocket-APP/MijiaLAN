// Exercises the actual QR, miIO and persistence entry points using the Debug preview LAN.
#if DEBUG
import Foundation
import MijiaCore
import MijiaLAN
import MijiaSupport
import Testing
@testable import MijiaLANApp

@MainActor
struct DeviceImportRecoveryTests {
    private let oldDevice = LocalDevice(did: "123", name: "Existing lamp", model: "yeelink.light.lamp4", host: "192.0.2.3",
                                        token: String(repeating: "0", count: 32))

    @Test("Unlocking before the next import merges into the previously unreadable list")
    func lockedAtLaunch() async throws {
        let fixture = Fixture()
        let original = LocalHomeConfig(devices: [oldDevice])
        try #require(fixture.vault.set(original.encoded(), for: AppModel.configAccount))
        fixture.readable.withLock { $0 = false }
        let app = fixture.app()
        defer { app.devices.shutdown() }
        #expect(app.configurationError == .unavailable)
        await app.startCloudImport().value
        guard case .failed = app.importState else { Issue.record("Locked import reported success"); return }
        #expect(try fixture.saved().devices == [oldDevice])

        fixture.readable.withLock { $0 = true }
        await app.startCloudImport().value
        guard case .completed(0, _) = app.importState else { Issue.record("Unlocked import failed"); return }
        #expect(app.configurationError == nil)
        #expect(app.config.devices == [oldDevice])
        #expect(try fixture.saved() == app.config)
        #expect(app.config.skipped.map(\.did) == ["blt.fixture"])
    }

    @Test("An undecodable device list is kept byte for byte on every attempted update")
    func invalidSavedData() async throws {
        let fixture = Fixture()
        let bytes = Data(#"{"devices":[],"skipped":"unsupported format"}"#.utf8)
        try #require(fixture.vault.set(bytes, for: AppModel.configAccount))
        let app = fixture.app()
        defer { app.devices.shutdown() }
        #expect(app.configurationError == .invalidData)
        await app.startCloudImport().value
        guard case .failed = app.importState else { Issue.record("Invalid list was replaced"); return }
        app.remove(oldDevice)
        #expect(app.configurationError == .invalidData)
        #expect(fixture.vault.lookup(AppModel.configAccount) == .value(bytes))
    }

    @Test("Retrying Keychain access after unlocking reloads the saved devices without another import")
    func retryLockedConfiguration() throws {
        let fixture = Fixture()
        let original = LocalHomeConfig(devices: [oldDevice])
        try #require(fixture.vault.set(original.encoded(), for: AppModel.configAccount))
        fixture.readable.withLock { $0 = false }
        let app = fixture.app()
        defer { app.devices.shutdown() }
        fixture.readable.withLock { $0 = true }
        app.retryLoadingConfiguration()
        #expect(app.configurationError == nil)
        #expect(app.config == original)
        #expect(app.devices.snapshots[oldDevice.did]?.primaryPower != nil)
    }

    @Test("Manual addition only confirms a successful save and clears an earlier success on failure")
    func manualWriteFailure() async throws {
        let fixture = Fixture()
        let app = fixture.app()
        defer { app.devices.shutdown() }
        await app.addManually(host: oldDevice.host, token: oldDevice.token, name: "First name")?.value
        #expect(app.lastManualAddSummary?.contains("First name") == true)
        let saved = try fixture.saved()
        fixture.writable.withLock { $0 = false }
        await app.addManually(host: oldDevice.host, token: oldDevice.token, name: "Second name")?.value
        #expect(app.configurationError == .writeFailed)
        #expect(app.manualAddError != nil)
        #expect(app.lastManualAddSummary == nil)
        #expect(app.config == saved)
        #expect(try fixture.saved() == saved)
    }

    @Test("Import saves immediately and a late specification cannot recreate a removed device or change its replacement")
    func changesDuringDownload() async throws {
        let fixture = Fixture()
        let cloud = ImportTransport(devices: [.object([
            "did": .string(oldDevice.did), "model": .string("fixture.light.one"), "name": .string("Generic"),
            "localip": .string(oldDevice.host), "token": .string(oldDevice.token)
        ])])
        await fixture.specServer.holdIndex()
        let app = fixture.app(cloud: cloud)
        defer { app.devices.shutdown() }
        let importing = app.startCloudImport()
        for _ in 0..<500 where !(await fixture.specServer.waiting) { try await MonotonicClock.sleep(for: .milliseconds(5)) }
        #expect(await fixture.specServer.waiting)
        #expect(app.config.devices.first?.model == "fixture.light.one")
        #expect(try fixture.saved() == app.config)
        switch app.importState {
        case .completed(let count, _): #expect(count == 1)
        default: Issue.record("Import is waiting for the public specification")
        }
        app.retryDevices([oldDevice.did])
        app.remove(oldDevice)
        await app.addManually(host: oldDevice.host, token: oldDevice.token, name: oldDevice.name)?.value
        await fixture.specServer.releaseIndex()
        await importing.value
        try await waitForRetry(app)
        #expect(try fixture.saved().devices.map(\.model) == [oldDevice.model])
        #expect(app.config.devices.first?.specType == nil)
    }

    @Test("Retry restores a missing schema without a login and reopening offline keeps the device controls")
    func retryMissingSpecification() async throws {
        let fixture = Fixture()
        var generic = oldDevice
        generic.model = "fixture.light.one"
        try #require(fixture.vault.set(LocalHomeConfig(devices: [generic]).encoded(), for: AppModel.configAccount))
        await fixture.specServer.setOffline(true)
        let first = fixture.app()
        defer { first.devices.shutdown() }
        first.retryDevices([generic.did])
        try await waitForRetry(first)
        #expect(first.devices.snapshots[generic.did] == nil)
        await fixture.specServer.setOffline(false)
        first.retryDevices([generic.did])
        try await waitForRetry(first)
        #expect(first.devices.snapshots[generic.did]?.primaryPower != nil)
        #expect(await first.devices.lan.diagnostics()[generic.did]?.endpoint?.lastAuthenticatedReplyAt != nil)
        #expect(try fixture.saved().devices.first?.specType == FixtureSpecServer.type)
        try FileManager.default.removeItem(at: fixture.archive.cacheDirectory)
        await fixture.specServer.setOffline(true)
        let count = await fixture.specServer.requests
        let reopened = fixture.app()
        defer { reopened.devices.shutdown() }
        #expect(reopened.devices.snapshots[generic.did]?.primaryPower != nil)
        #expect(await fixture.specServer.requests == count)
    }

    @Test("A restored file for a known type is usable even if another device's new type could not be saved")
    func partialRecoveryOnWriteFailure() async throws {
        let fixture = Fixture()
        var known = oldDevice
        known.model = "fixture.light.known"
        known.specType = FixtureSpecServer.type
        var unknown = oldDevice
        unknown.did = "124"
        unknown.model = "fixture.light.one"
        let original = LocalHomeConfig(devices: [known, unknown])
        try #require(fixture.vault.set(original.encoded(), for: AppModel.configAccount))
        fixture.writable.withLock { $0 = false }
        let app = fixture.app()
        defer { app.devices.shutdown() }
        app.retryDevices([known.did, unknown.did])
        try await waitForRetry(app)
        #expect(app.configurationError == .writeFailed)
        #expect(try fixture.saved() == original)
        #expect(app.devices.snapshots[known.did]?.primaryPower != nil)
        #expect(app.devices.snapshots[unknown.did] == nil)
        fixture.writable.withLock { $0 = true }
        app.retryDevices([unknown.did])
        try await waitForRetry(app)
        #expect(try fixture.saved().devices.last?.specType == FixtureSpecServer.type)
        #expect(app.devices.snapshots[unknown.did]?.primaryPower != nil)
    }

    private func waitForRetry(_ app: AppModel) async throws {
        for _ in 0..<500 where !app.retryingDeviceIDs.isEmpty { try await MonotonicClock.sleep(for: .milliseconds(5)) }
        try #require(app.retryingDeviceIDs.isEmpty)
    }

    @MainActor private final class Fixture {
        let backing = SecretVault.Storage.memory()
        let readable = LockedState(initialState: true)
        let writable = LockedState(initialState: true)
        let specServer = FixtureSpecServer()
        let suite = "test.mijialan.import.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var vault: SecretVault { SecretVault(storage: backing) }
        var archive: DeviceSpecArchive { .init(directory: root.appendingPathComponent("specs"), cacheDirectory: root.appendingPathComponent("cache")) }

        deinit {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func app(cloud: ImportTransport = ImportTransport()) -> AppModel {
            let storage = SecretVault.Storage(
                read: { [readable, backing] in readable.withLock { $0 } ? backing.read() : .unavailable },
                write: { [writable, backing] in writable.withLock { $0 } && backing.write($0) }
            )
            return AppModel(environment: ["MIJIALAN_UI_PREVIEW": "1"], secretStorage: storage, cloudTransport: cloud,
                            specs: archive, specTransport: specServer, ephemeralDefaultsSuite: suite)
        }

        func saved() throws -> LocalHomeConfig {
            guard case .value(let data) = vault.lookup(AppModel.configAccount) else { throw CocoaError(.fileReadUnknown) }
            return try #require(LocalHomeConfig.decode(data))
        }
    }
}

private actor FixtureSpecServer: MiHTTPTransport {
    static let type = "urn:miot-spec-v2:device:light:0000A001:recovery-test:1"
    private var hold = false
    private var offline = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var requests = 0
    var waiting: Bool { gate != nil }

    func holdIndex() { hold = true }
    func releaseIndex() { hold = false; gate?.resume(); gate = nil }
    func setOffline(_ value: Bool) { offline = value }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        requests += 1
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let body: String
        if url.lastPathComponent == "instances" {
            if hold { await withCheckedContinuation { gate = $0 } }
            body = #"{"instances":[{"model":"fixture.light.one","type":"\#(Self.type)","version":1}]}"#
        } else {
            body = #"{"type":"\#(Self.type)","description":"Light","services":[{"iid":2,"type":"urn:miot-spec-v2:service:light:00007802:test:1","description":"Light","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:test:1","description":"Power","format":"bool","access":["read","write"]}]}]}"#
        }
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
#endif
