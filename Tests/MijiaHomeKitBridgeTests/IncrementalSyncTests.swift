import Foundation
import Testing
import HAPCore
import HAPTransport
import MijiaCore
@testable import MijiaLAN
@testable import MijiaHomeKitBridge

@MainActor
struct IncrementalSyncTests {
    @Test("Invalid firmware readings become unavailable and recover without rebuilding the accessory")
    func invalidReadings() async throws {
        let fixture = try await Fixture.make()
        let before = fixture.bridge.syncStatistics
        let iid = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        for raw in [JSONValue.number(-1), .number(101), .string("50"), .bool(true)] {
            await fixture.transport.set("8.1", raw)
            await fixture.devices.refreshNow()
            await fixture.settle()
            #expect(fixture.devices.snapshots["123"]?.value("p:8:1") == nil)
            #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .communicationFailure)
            #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(50))
        }
        await fixture.transport.set("8.1", .number(50))
        await fixture.devices.refreshNow()
        await fixture.settle()
        #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .success)
        #expect(fixture.bridge.syncStatistics.planBuilds == before.planBuilds)
        await fixture.stop()
    }

    @Test("Truncated devices publish at most 100 services, report omissions and clear warnings when hidden")
    func serviceLimitWarnings() async throws {
        let identifier = UUID().uuidString
        let properties: [[String: Any]] = (1...120).map { i in
            ["iid": i, "type": "urn:miot-spec-v2:property:\(i == 1 ? "on" : "toggle-\(i)"):00000006:audit:1",
             "format": "bool", "access": ["read", "write"]]
        }
        let json: [String: Any] = ["model": "test.audit.\(identifier)",
            "type": "urn:miot-spec-v2:device:outlet:0000A002:audit-\(identifier):1",
            "services": [["iid": 2, "type": "urn:miot-spec-v2:service:outlet:00007803:audit:1", "properties": properties]]]
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: JSONSerialization.data(withJSONObject: json))
        let fixture = try await Fixture.make(schema: schema)
        let accessory = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 })
        #expect(accessory.services.count == 100)
        let warning = try #require(fixture.bridge.serviceLimitWarnings.first)
        #expect(warning.id == "123")
        #expect(warning.deviceName == "Fan")
        #expect(warning.omittedServiceCount == 21)
        fixture.store.hideDevice("123")
        await fixture.settle()
        #expect(fixture.bridge.serviceLimitWarnings.isEmpty)
        fixture.store.unhideDevice("123")
        await fixture.settle()
        #expect(fixture.bridge.serviceLimitWarnings.first?.omittedServiceCount == 21)
        await fixture.stop()
        #expect(fixture.bridge.serviceLimitWarnings.isEmpty)
    }

    @Test("Changing only the allowed climate modes refreshes the Home database while preserving IIDs")
    func climateModeConstraints() async throws {
        let url = try #require(Bundle.module.url(forResource: "xiaomi-mc4", withExtension: "json", subdirectory: "Specs"))
        var schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        let identifier = UUID().uuidString
        schema.model = "test.audit.\(identifier)"
        schema.type = "urn:miot-spec-v2:device:air-conditioner:0000A004:audit-\(identifier):1"
        let fixture = try await Fixture.make(schema: schema)
        let before = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 })
        let beforeTarget = try #require(before.services.flatMap(\.characteristics).first { $0.type.rawValue == "B2" })
        let configuration = await fixture.hap.currentConfigurationNumber
        #expect(beforeTarget.validValues == [1, 2])
        let si = try #require(schema.services.firstIndex { $0.name == "air-conditioner" })
        let pi = try #require(schema.services[si].properties.firstIndex { $0.name == "mode" })
        schema.services[si].properties[pi].valueList?.append(.init(value: 0, description: "Auto"))
        try JSONEncoder().encode(schema).write(to: #require(fixture.schemaURL), options: .atomic)
        fixture.devices.reconcileConfiguration(force: true)
        await fixture.settle()
        let after = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 })
        let afterTarget = try #require(after.services.flatMap(\.characteristics).first { $0.type.rawValue == "B2" })
        #expect(afterTarget.validValues == [0, 1, 2])
        #expect(afterTarget.iid == beforeTarget.iid)
        #expect(after.services.map(\.iid) == before.services.map(\.iid))
        #expect(await fixture.hap.currentConfigurationNumber > configuration)
        await fixture.stop()
    }

    @Test("Unchanged polls do not rebuild HomeKit plans, write defaults, or push characteristic actors")
    func unchangedPolls() async throws {
        let fixture = try await Fixture.make()
        let before = fixture.bridge.syncStatistics
        let configuration = await fixture.hap.currentConfigurationNumber
        let database = await fixture.hap.accessoryDatabase()
        for _ in 0..<20 { await fixture.devices.refreshNow() }
        await fixture.settle()
        let after = fixture.bridge.syncStatistics
        #expect(after.planBuilds == before.planBuilds)
        #expect(after.characteristicUpdates == before.characteristicUpdates)
        #expect(after.readStatusUpdates == before.readStatusUpdates)
        #expect(after.layoutWrites == before.layoutWrites)
        #expect(after.identifierWrites == before.identifierWrites)
        #expect(await fixture.hap.currentConfigurationNumber == configuration)
        #expect(await fixture.hap.accessoryDatabase().map(\.aid) == database.map(\.aid))
        await fixture.stop()
    }

    @Test("A value change updates its characteristics without rebuilding services or changing AIDs and IIDs")
    func changedValue() async throws {
        let fixture = try await Fixture.make()
        let before = fixture.bridge.syncStatistics
        let old = await fixture.hap.accessoryDatabase()
        let configuration = await fixture.hap.currentConfigurationNumber
        await fixture.transport.set("8.1", .number(70))
        await fixture.devices.refreshNow()
        await fixture.settle()
        let after = fixture.bridge.syncStatistics
        #expect(after.planBuilds == before.planBuilds)
        #expect(after.characteristicUpdates > before.characteristicUpdates)
        #expect(after.readStatusUpdates == before.readStatusUpdates)
        #expect(after.layoutWrites == before.layoutWrites)
        #expect(await fixture.hap.currentConfigurationNumber == configuration)
        let current = await fixture.hap.accessoryDatabase()
        #expect(current.map(\.aid) == old.map(\.aid))
        #expect(current.flatMap(\.services).flatMap(\.characteristics).map(\.iid) == old.flatMap(\.services).flatMap(\.characteristics).map(\.iid))
        let iid = try #require(current.first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(70))
        await fixture.stop()
    }

    @Test("Same-value offline recovery restores read status without touching the layout or pairing identity")
    func recovery() async throws {
        let fixture = try await Fixture.make()
        let uri = fixture.bridge.setupURI
        let configuration = await fixture.hap.currentConfigurationNumber
        let iid = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        let events = CapturedEvents()
        await fixture.hap.subscribe(connectionID: 7, aid: 2, iid: iid)
        await fixture.hap.setCharacteristicChangeHandler { _, data in await events.append(data) }
        let before = fixture.bridge.syncStatistics
        await fixture.transport.setOffline(true)
        await fixture.devices.refreshNow()
        await fixture.settle()
        #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .communicationFailure)
        await fixture.transport.setOffline(false)
        await fixture.devices.retry(did: "123")
        await fixture.settle()
        #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .success)
        #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(50))
        #expect(fixture.bridge.syncStatistics.planBuilds == before.planBuilds)
        #expect(await fixture.hap.currentConfigurationNumber == configuration)
        #expect(fixture.bridge.setupURI == uri)
        #expect(fixture.bridge.isPaired)
        for _ in 0..<100 where await events.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await events.count >= 1)
        await fixture.stop()
    }

    @Test("A delayed unavailable notification cannot overtake its same-value recovery", arguments: [false, true])
    func notificationRecoveryOrder(_ subscribingWhileUnavailable: Bool) async throws {
        let fixture = try await Fixture.make()
        do {
            let iid = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
            let events = CapturedEvents()
            if !subscribingWhileUnavailable { await fixture.hap.subscribe(connectionID: 7, aid: 2, iid: iid) }
            await fixture.hap.setCharacteristicChangeHandler { _, data in
                // A suspended send exposes whether a newer notification can pass it.
                if String(decoding: data, as: UTF8.self).contains("-70402") {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                await events.append(data)
            }
            await fixture.hap.setReadStatus(aid: 2, iid: iid, status: .communicationFailure)
            if subscribingWhileUnavailable { await fixture.hap.subscribe(connectionID: 7, aid: 2, iid: iid) }
            await fixture.hap.updateCharacteristic(aid: 2, iid: iid, value: .float(50))
            for _ in 0..<200 where await events.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
            let payloads = await events.captured()
            let changes = try payloads.map { raw -> JSONValue in
                let separator = try #require(raw.range(of: Data("\r\n\r\n".utf8)))
                let json = try JSONDecoder().decode(JSONValue.self, from: Data(raw[separator.upperBound...]))
                return try #require(json["characteristics"]?.arrayValue?.first)
            }
            #expect(changes.count == 2)
            #expect(changes.first?["status"]?.intValue == -70402)
            #expect(changes.last?["value"]?.doubleValue == 50)
            #expect(changes.last?["status"] == nil)
            #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .success)
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }

    @Test("Same-value HomeKit writes still force a confirmation event after delta suppression")
    func forcedConfirmation() async throws {
        let fixture = try await Fixture.make()
        let events = CapturedEvents()
        let iid = try #require(await fixture.hap.accessoryDatabase().first { $0.aid == 2 }?.services.flatMap(\.characteristics).first { $0.type == .rotationSpeed }?.iid)
        await fixture.hap.subscribe(connectionID: 7, aid: 2, iid: iid)
        await fixture.hap.setCharacteristicChangeHandler { _, data in await events.append(data) }
        try await fixture.hap.writeCharacteristic(aid: 2, iid: iid, value: .float(50))
        await fixture.settle()
        for _ in 0..<100 where await events.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await events.count >= 1)
        #expect(await fixture.hap.readStatus(aid: 2, iid: iid) == .success)
        #expect(await fixture.hap.readCharacteristic(aid: 2, iid: iid) == .float(50))
        await fixture.stop()
    }

    @Test("Hiding and restoring a capability device reuses its reserved identifiers")
    func hideRestore() async throws {
        let fixture = try await Fixture.make()
        let old = await fixture.hap.accessoryDatabase().first { $0.aid == 2 }
        fixture.store.hideDevice("123")
        await fixture.settle()
        #expect(await fixture.hap.accessoryDatabase().count == 1)
        fixture.store.unhideDevice("123")
        await fixture.settle()
        let restored = await fixture.hap.accessoryDatabase().first { $0.aid == 2 }
        #expect(restored?.services.map(\.iid) == old?.services.map(\.iid))
        #expect(restored?.services.flatMap(\.characteristics).map(\.iid) == old?.services.flatMap(\.characteristics).map(\.iid))
        await fixture.stop()
    }

    @MainActor private struct Fixture {
        let api: LANMiotAPI
        let devices: DeviceController
        let store: HomeStore
        let bridge: HomeKitBridgeController
        let hap: HAPBridge
        let transport: SyncTestTransport
        let defaults: UserDefaults
        let suite: String
        let schemaURL: URL?

        static func make(schema: DeviceSchema? = nil) async throws -> Fixture {
            let suite = "test.mijialan.incremental.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(false, forKey: HomeKitBridgeController.keepAwakeKey)
            let model = schema?.model ?? "dmaker.fan.p28"
            let schemaURL: URL?
            if let schema {
                let directory = LocalHomeProvider.specCacheDirectory.appendingPathComponent("instances")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(schema.type.replacingOccurrences(of: ":", with: "_") + ".json")
                try JSONEncoder().encode(schema).write(to: url, options: .atomic)
                schemaURL = url
            } else { schemaURL = nil }
            let device = LocalDevice(did: "123", name: "Fan", model: model, host: "test", token: String(repeating: "0", count: 32), specType: schema?.type)
            let config = LocalHomeConfig(devices: [device])
            let transport = SyncTestTransport(model: model)
            let api = LANMiotAPI(config: { config }, transport: transport)
            let devices = DeviceController(api: api, config: { config })
            await devices.refreshNow()
            let store = HomeStore(provider: CapabilityHomeProvider(controller: devices), defaultsSuiteName: suite)
            for _ in 0..<100 where !store.hasReceivedInitialSnapshot { try await Task.sleep(for: .milliseconds(2)) }
            var secrets = HomeKitBridgeSecrets.generate()
            secrets.pairings = ["existing-controller": Data(repeating: 1, count: 32)]
            let data = try #require(secrets.encoded())
            let bridge = HomeKitBridgeController(vault: HomeKitBridgeVault(load: { .value(data) }, save: { _ in true }), defaults: defaults, port: 0)
            bridge.attach(to: store, capabilities: devices)
            await bridge.waitUntilIdle()
            let hap = try #require(bridge.bridge)
            let result = Fixture(api: api, devices: devices, store: store, bridge: bridge, hap: hap, transport: transport, defaults: defaults, suite: suite, schemaURL: schemaURL)
            await result.settle()
            return result
        }
        func settle() async {
            for _ in 0..<10 { await Task.yield() }
            await bridge.waitUntilIdle()
        }
        func stop() async {
            bridge.isEnabled = false
            await bridge.waitUntilIdle()
            devices.shutdown()
            await api.shutdown()
            defaults.removePersistentDomain(forName: suite)
            if let schemaURL { try? FileManager.default.removeItem(at: schemaURL) }
        }
    }
}

private actor CapturedEvents {
    private var values: [Data] = []
    var count: Int { values.count }
    func append(_ data: Data) { values.append(data) }
    func captured() -> [Data] { values }
}

private actor SyncTestTransport: MiioTransport {
    private let token = Data(repeating: 0, count: 16)
    private let model: String
    private var offline = false
    private var values: [String: JSONValue] = ["2.1": .bool(true), "8.1": .number(50)]
    init(model: String = "dmaker.fan.p28") { self.model = model }
    func set(_ key: String, _ value: JSONValue) { values[key] = value }
    func setOffline(_ value: Bool) { offline = value }
    func exchange(_ packet: Data, host: String, port: UInt16, timeout: Duration) async throws -> Data {
        if offline { throw MiioError.hostUnreachable }
        if packet == MiioPacket.hello {
            return Data([0x21, 0x31, 0, 32, 0, 0, 0, 0, 0, 0, 0, 123, 0, 0, 0x13, 0x88] + [UInt8](repeating: 255, count: 16))
        }
        let (_, payload) = try MiioPacket.decode(packet, token: token)
        let request = try JSONDecoder().decode(JSONValue.self, from: payload.prefix { $0 != 0 })
        let method = request["method"]?.stringValue ?? ""
        let args = request["params"]?.arrayValue ?? []
        let result: JSONValue
        switch method {
        case "miIO.info": result = .object(["model": .string(model)])
        case "get_properties":
            result = .array(args.map { p in
                let key = "\(p["siid"]?.intValue ?? 0).\(p["piid"]?.intValue ?? 0)"
                return .object(["siid": p["siid"] ?? .null, "piid": p["piid"] ?? .null,
                    "code": values[key] == nil ? .number(-4003) : .number(0), "value": values[key] ?? .null])
            })
        case "set_properties":
            result = .array(args.map { p in
                let key = "\(p["siid"]?.intValue ?? 0).\(p["piid"]?.intValue ?? 0)"
                values[key] = p["value"]
                return .object(["code": .number(0)])
            })
        default: throw MiioError.unsupportedByLegacyDevice
        }
        let reply = JSONValue.object(["id": request["id"] ?? .number(0), "result": result])
        return try MiioPacket.encode(Data(reply.compactJSONString.utf8) + [0], token: token, deviceID: 123, stamp: 5000)
    }
    func broadcast(_ packet: Data, port: UInt16, duration: Duration, rounds: Int) async throws -> [MiioDatagram] { [] }
}
