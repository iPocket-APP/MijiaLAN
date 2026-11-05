import Foundation
import HAPCore
import MijiaCore
@testable import MijiaLAN
import Synchronization
import Testing
@testable import MijiaHomeKitBridge

@MainActor
struct WireHomeKitIntegrationTests {
    // Multiple independent controllers exercise response/event frame ordering under concurrent load.
    @Test("Real miIO UDP and encrypted HAP TCP preserve invalid reads, recovery, UTF-8 limits and pairing rollback", arguments: 0..<8)
    func udpTCPAndRollback(_ iteration: Int) async throws {
        let fixture = try await Fixture.make()
        let first = WireHAPController(port: fixture.port)
        let retry = WireHAPController(port: fixture.port)
        do {
            try await first.connect()
            try await first.pair(setupCode: fixture.code)
            try await first.verify()
            await fixture.settle()
            #expect(fixture.bridge.isPaired)
            let identity = await first.accessoryIdentifier
            let key = await first.accessoryKey
            let uri = fixture.bridge.setupURI
            let good = try json(await first.request("GET", "/accessories"))
            try validateStrings(good)
            let device = try #require(good["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
            let chars = device["services"]?.arrayValue?.flatMap { $0["characteristics"]?.arrayValue ?? [] } ?? []
            let humidity = try #require(chars.first { $0["type"]?.stringValue == "10" })
            let temperature = try #require(chars.first { $0["type"]?.stringValue == "11" })
            let humidityIID = try #require(humidity["iid"]?.intValue)
            #expect(humidity["value"]?.doubleValue == 45)
            #expect(abs(try #require(temperature["value"]?.doubleValue) - 21.6) < 1e-8)
            #expect(await first.receivedFrames > 1)
            #expect(await first.largestFrame <= 1024)
            // This request also exercises a request spanning multiple authenticated 1024-byte frames.
            let subscription = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(humidityIID)), "ev": .bool(true)])]),
                "padding": .string(String(repeating: "x", count: 2500))])
            #expect(try await first.request("PUT", "/characteristics", body: data(subscription)).status == 204)
            let initial = try await event(first, iid: humidityIID)
            #expect(initial["value"]?.doubleValue == 45)

            fixture.device.setPhase(1)
            await fixture.devices.refreshNow()
            await fixture.settle()
            let unavailable = try await event(first, iid: humidityIID)
            #expect(unavailable["status"]?.intValue == -70402)
            #expect(unavailable["value"] == nil)
            let bad = try json(await first.request("GET", "/accessories"))
            let badDevice = try #require(bad["accessories"]?.arrayValue?.first { $0["aid"]?.intValue == 2 })
            for c in badDevice["services"]?.arrayValue?.flatMap({ $0["characteristics"]?.arrayValue ?? [] }) ?? [] {
                if ["B0", "A9", "10", "11"].contains(c["type"]?.stringValue ?? "") { #expect(c["value"] == .null) }
            }
            let read = try await first.request("GET", "/characteristics?id=2.\(humidityIID)")
            #expect(read.status == 207)
            #expect(try json(read)["characteristics"]?.arrayValue?.first?["status"]?.intValue == -70402)
            fixture.device.setPhase(2)
            await fixture.devices.refreshNow()
            await fixture.settle()
            #expect(try await event(first, iid: humidityIID)["value"]?.doubleValue == 55)

            let active = try #require(chars.first { $0["type"]?.stringValue == "B0" }?["iid"]?.intValue)
            let invalid = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(active)), "value": .number(2.5)])])])
            let rejected = try await first.request("PUT", "/characteristics", body: data(invalid))
            #expect(rejected.status == 207)
            #expect(try json(rejected)["characteristics"]?.arrayValue?.first?["status"]?.intValue == -70410)

            let nameIID = try #require(chars.first { $0["type"]?.stringValue == "E3" }?["iid"]?.intValue)
            let long = String(repeating: "中", count: 22)
            let rename = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(nameIID)), "value": .string(long)])])])
            #expect(try json(await first.request("PUT", "/characteristics", body: data(rename)))["characteristics"]?.arrayValue?.first?["status"]?.intValue == -70410)
            let legal = String(repeating: "中", count: 20) + "abcd"
            let subscribeName = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(nameIID)), "ev": .bool(true)])])])
            #expect(try await first.request("PUT", "/characteristics", body: data(subscribeName)).status == 204)
            _ = try await event(first, iid: nameIID)
            let validRename = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(Double(nameIID)), "value": .string(legal)])])])
            #expect(try await first.request("PUT", "/characteristics", body: data(validRename)).status == 204)
            #expect(try await event(first, iid: nameIID)["value"]?.stringValue == legal)
            let noEvents = JSONValue.object(["characteristics": .array([.object(["aid": .number(2), "iid": .number(2), "ev": .bool(true)])])])
            #expect(try json(await first.request("PUT", "/characteristics", body: data(noEvents)))["characteristics"]?.arrayValue?.first?["status"]?.intValue == -70406)
            try validateStrings(json(await first.request("GET", "/accessories")))
            #expect(fixture.devices.snapshots["77"]?.device.name == fixture.originalName)
            #expect(fixture.device.encryptedRequests > 0)
            #expect(fixture.device.writes == 0)
            #expect(fixture.device.error == nil)

            let id = first.identifier
            let remove = TLV8.encode([(6, Data([1])), (0, Data([4])), (1, Data(id.utf8))])
            #expect(try await first.request("POST", "/pairings", body: remove).status == 200)
            await fixture.settle()
            #expect(!fixture.bridge.isPaired)
            #expect(try await first.request("GET", "/accessories").status == 470)
            await first.close()
            try await retry.connect()
            try await retry.pair(setupCode: fixture.code)
            try await retry.verify()
            #expect(await retry.accessoryIdentifier == identity)
            #expect(await retry.accessoryKey == key)
            #expect(try await retry.request("GET", "/accessories").status == 200)
            await fixture.settle()
            #expect(fixture.bridge.isPaired)
            #expect(fixture.bridge.setupURI == uri)
            #expect(fixture.device.writes == 0)
        } catch {
            await first.close(); await retry.close(); await fixture.stop()
            throw error
        }
        await first.close(); await retry.close(); await fixture.stop()
    }

    private func event(_ client: WireHAPController, iid: Int) async throws -> JSONValue {
        for _ in 0..<30 {
            let message = try await client.nextEvent()
            let value = try json(message)
            if let c = value["characteristics"]?.arrayValue?.first(where: { $0["aid"]?.intValue == 2 && $0["iid"]?.intValue == iid }) { return c }
        }
        throw WireHAPController.Failure.invalidHTTP
    }
    private func json(_ message: WireHAPController.Message) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: message.body)
    }
    private func data(_ value: JSONValue) throws -> Data { try JSONEncoder().encode(value) }
    private func validateStrings(_ json: JSONValue) throws {
        for accessory in json["accessories"]?.arrayValue ?? [] {
            for c in accessory["services"]?.arrayValue?.flatMap({ $0["characteristics"]?.arrayValue ?? [] }) ?? [] where c["format"]?.stringValue == "string" {
                if let value = c["value"]?.stringValue { #expect(value.utf8.count <= 64) }
            }
        }
    }

    @MainActor private struct Fixture {
        let device: LoopbackMiioDevice
        let api: LANMiotAPI
        let devices: DeviceController
        let store: HomeStore
        let bridge: HomeKitBridgeController
        let suite: String
        let defaults: UserDefaults
        let originalName: String
        let port: UInt16
        let code: String

        static func make() async throws -> Fixture {
            let device = try LoopbackMiioDevice()
            let name = String(repeating: "测试空气净化器🙂", count: 12)
            let local = LocalDevice(did: "77", name: name, model: LoopbackMiioDevice.model, host: "127.0.0.1", token: LoopbackMiioDevice.token)
            let config = LocalHomeConfig(devices: [local])
            let api = LANMiotAPI(config: { config }, transport: LoopbackMiioTransport(port: device.port))
            let devices = DeviceController(api: api, config: { config })
            await devices.refreshNow()
            #expect(devices.snapshots["77"]?.isOnline == true)
            let suite = "test.mijialan.wire.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(false, forKey: HomeKitBridgeController.keepAwakeKey)
            let store = HomeStore(provider: CapabilityHomeProvider(controller: devices), defaultsSuiteName: suite)
            for _ in 0..<100 where !store.hasReceivedInitialSnapshot { try await Task.sleep(for: .milliseconds(2)) }
            let storage = VaultStorage()
            let vault = HomeKitBridgeVault(load: { storage.data.withLock { $0.map { .value($0) } ?? .missing } },
                save: { value in storage.data.withLock { $0 = value }; return true })
            let bridge = HomeKitBridgeController(vault: vault, defaults: defaults, port: 0, loopbackOnly: true)
            bridge.attach(to: store, capabilities: devices)
            await bridge.waitUntilIdle()
            guard case .running(let port) = bridge.status, let code = bridge.setupCode else {
                bridge.isEnabled = false
                await bridge.waitUntilIdle()
                devices.shutdown()
                await api.shutdown()
                await device.stop()
                defaults.removePersistentDomain(forName: suite)
                throw WireHAPController.Failure.closed
            }
            return Fixture(device: device, api: api, devices: devices, store: store, bridge: bridge,
                           suite: suite, defaults: defaults, originalName: name, port: port, code: code)
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
            await device.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private final class VaultStorage: Sendable { let data = Mutex<Data?>(nil) }
