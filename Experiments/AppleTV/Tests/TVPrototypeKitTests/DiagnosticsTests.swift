import Foundation
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN
import Synchronization
import Testing
@testable import TVPrototypeKit

@MainActor struct DiagnosticsTests {
    @Test("Report preserves failed HomeKit properties and retry state while redacting free-form readings and errors")
    func nativeReportParityAndRedaction() throws {
        let token = "00112233445566778899aabbccddeeff"
        let address = "192.168.31.57"
        let mac = "AA:BB:CC:DD:EE:FF"
        let setup = "123-45-678"
        let schema = try #require(DeviceSchema.bundled(model: "dmaker.fan.p28"))
        let device = LocalDevice(did: "123", name: "落地扇", model: "dmaker.fan.p28", host: address, token: token, mac: mac)
        let configuration = PrototypeConfiguration(home: LocalHomeConfig(devices: [device]))
        let sensitiveError = "rejected \(token) \(address) \(mac) \(setup) fe80::abcd%en0"
        var snapshot = DeviceSnapshot(device: device, schema: schema,
            capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: device.model),
            health: LANDeviceHealth(state: .online, lastError: sensitiveError))
        snapshot.readings["p:2:3"] = DeviceReading(value: .number(9), code: 0)
        snapshot.readings["p:2:1"] = DeviceReading(value: .string(sensitiveError), code: -4001, error: sensitiveError)
        let failure = HomeKitBridgeController.ReadFailure(deviceID: "123", service: "49", characteristic: "25", source: "p:2:1 direct", status: -70402)
        var evidence = PrototypeEvidence(executor: .networkExtension, fixture: false)
        evidence.bridgeStatus = "running"; evidence.paired = true
        let retry = ProbeRetryState(consecutiveFailures: 3, nextRetryAt: Date().addingTimeInterval(60))
        let report = PrototypeDiagnostics.capture(id: UUID(), configuration: configuration, evidence: evidence,
            snapshots: [snapshot], retries: ["123": retry], failures: [failure], accessories: 1,
            revisions: (1, 2), pairingCode: setup)
        let data = try report.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        for secret in [token, address, mac, setup, "fe80::abcd%en0"] { #expect(!text.contains(secret)) }
        let row = try #require(report.devices.first)
        #expect(report.source == .liveRuntime)
        #expect(report.paired)
        #expect(row.model == device.model)
        #expect(row.retryFailures == 3)
        #expect(row.nextRetryAt == retry.nextRetryAt)
        #expect(row.homeKitReadFailures.first?.status == -70402)
        #expect(row.homeKitReadFailures.first?.source == "p:2:1 direct")
        #expect(row.readings.first { $0.id == "p:2:3" }?.value == "9")
        #expect(row.readings.first { $0.id == "p:2:1" }?.code == -4001)
        #expect(report.failedReadingCount > 0)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["recordedAt"] is String)
        #expect(json["devices"] is [[String: Any]])
    }

    @Test("A stopped runtime cannot make old running evidence look like a fresh successful diagnosis")
    func unavailableDoesNotClaimFreshness() throws {
        var evidence = PrototypeEvidence(executor: .networkExtension, fixture: true)
        evidence.bridgeStatus = "running"; evidence.paired = true
        let report = PrototypeDiagnostics.unavailable(configuration: .fixtureConfiguration, evidence: evidence)
        #expect(report.source == .notRunning)
        #expect(report.bridge == "stopped")
        #expect(!report.paired)
        #expect(report.devices.first?.health == "notChecked")
        #expect(report.devices.first?.readings.isEmpty == true)
    }

    @Test("Activation export carries only the stage and system error code, never the raw localized message")
    func activationProjection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = PrototypeStorage(directory: directory, storesPairingCode: false)
        try storage.saveActivation(stage: "loadingPreferences", error: NSError(domain: "NEConfigurationErrorDomain", code: 11,
            userInfo: [NSLocalizedDescriptionKey: "private 192.168.1.7 00112233445566778899aabbccddeeff"]))
        let summary = try #require(storage.activationSummary())
        let text = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(summary.errorCode == 11)
        #expect(summary.stage == "loadingPreferences")
        #expect(!text.contains("192.168.1.7"))
        #expect(!text.contains("00112233445566778899aabbccddeeff"))
    }

    @Test("Diagnostic IPC refreshes real runtime readings, writes a request-matched report, and sends no power writes")
    func runtimeCollection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tv-diagnostics-\(UUID())")
        let suite = "tv-diagnostics-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = PrototypeStorage(directory: directory, storesPairingCode: false)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let blob = Mutex<Data?>(nil)
        let vault = HomeKitBridgeVault(load: { blob.withLock { $0.map(CredentialVault.Lookup.value) ?? .missing } },
            save: { data in blob.withLock { $0 = data }; return true })
        let service = try PrototypeRuntime(configuration: .fixtureConfiguration, executor: .hostTest,
            storage: storage, defaults: defaults, bridgeVault: vault, loopbackOnly: true)
        do {
            try await service.start()
            let before = service.evidence
            let id = UUID()
            let reply = await service.handle(.diagnostics(id: id))
            #expect(reply.error == nil)
            let report = try #require(storage.diagnostics())
            #expect(report.id == id)
            #expect(report.runtime?.sessionID == before.sessionID)
            #expect(report.source == .liveRuntime)
            #expect(report.fixture)
            #expect(report.runtime?.authenticatedReads ?? 0 > before.authenticatedReads)
            #expect(report.runtime?.acknowledgedWrites == before.acknowledgedWrites)
            #expect(service.evidence.devices.first?.isOn == before.devices.first?.isOn)
            #expect(report.devices.first?.readings.isEmpty == false)
            #expect(try JSONEncoder().encode(reply).count < 4096)
            let text = String(decoding: try report.jsonData(), as: UTF8.self)
            #expect(!text.contains(PrototypeConfiguration.fixtureConfiguration.home.devices[0].token))
            #expect(!text.contains("127.0.0.1"))
            if let code = service.bridge.setupCode { #expect(!text.contains(code)) }
            await service.stop()
        } catch { await service.stop(); throw error }
    }
}
