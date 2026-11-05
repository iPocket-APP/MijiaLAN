import Foundation
import Testing
import HAPCore
import HAPCrypto
import HAPTransport
import MijiaCore
import MijiaLAN
@testable import MijiaHomeKitBridge

struct HomeKitAttributeDatabaseTests {
    /// Validate the JSON handed to Apple Home, rather than comparing mapper constants to themselves.
    /// iOS rejects the entire bridge with HMErrorDomain 66 when a short UUID starts with zero.
    @Test("The accessory database uses canonical HAP type UUIDs for every supported device")
    func canonicalTypeUUIDs() async throws {
        let bridge = HAPBridge(info: AccessoryInfo(
            name: "Test Bridge", manufacturer: "MijiaLAN", model: "Test", serialNumber: "test-bridge",
            firmwareRevision: "1.0.0"
        ))
        let devices = [
            HomeKitAccessoryMapperTests.light(),
            HomeKitAccessoryMapperTests.climate(modes: ["off", "auto", "cool", "heat", "dry", "fan_only"]),
            SmartDevice(id: "fan", name: "Fan", roomId: "room", roomName: "Room", model: "test.fan",
                        isOnline: true, kind: .fan(FanSpec(entityId: "fan.test", isOn: false))),
            SmartDevice(id: "plug", name: "Plug", roomId: "room", roomName: "Room", model: "test.plug",
                        isOnline: true, kind: .plug(PlugSpec(switchEntityId: "switch.test", isOn: false))),
            SmartDevice(id: "sensor", name: "Sensor", roomId: "room", roomName: "Room", model: "test.sensor",
                        isOnline: true, kind: .sensor(SensorSpec(temperature: 25, humidity: 50, battery: 90))),
        ]
        for device in devices {
            let plan = try #require(HomeKitAccessoryMapper.plan(for: device, name: device.name))
            await bridge.addAccessory(info: plan.info, services: plan.services)
        }

        let accessories = try await accessoryDatabase(bridge)
        #expect(accessories.count == devices.count + 1)

        var foundCoolingThreshold = false
        var configuredSwitchNames: [String] = []
        for accessory in accessories {
            let services = try #require(accessory["services"] as? [[String: Any]])
            for service in services {
                let characteristics = try #require(service["characteristics"] as? [[String: Any]])
                for object in [service] + characteristics {
                    let type = try #require(object["type"] as? String)
                    #expect(type.range(of: "^[1-9A-F][0-9A-F]{0,7}$", options: .regularExpression) != nil,
                            "Noncanonical HAP type \(type) at aid=\(accessory["aid"]!), iid=\(object["iid"]!)")
                }
                if service["type"] as? String == "BC" {
                    foundCoolingThreshold = characteristics.contains { $0["type"] as? String == "D" }
                }
                if service["type"] as? String == "49" {
                    let name = try #require(characteristics.first { $0["type"] as? String == "E3" },
                                            "Apple Home needs Configured Name to label these additional switches")
                    #expect(Set(try #require(name["perms"] as? [String])) == ["pr", "pw", "ev"])
                    configuredSwitchNames.append(try #require(name["value"] as? String))
                }
            }
        }
        #expect(foundCoolingThreshold, "The cooling threshold must be encoded as D, never 0D")
        #expect(configuredSwitchNames == ["除湿模式", "仅送风"])
    }

    @Test("Only the fan itself is published as primary, so Home builds the tile around it rather than a switch")
    func primaryService() async throws {
        let model = "dmaker.fan.p28"
        let schema = try #require(DeviceSchema.bundled(model: model))
        let s = DeviceSnapshot(device: LocalDevice(did: "123", name: "Fan", model: model, host: "", token: ""), schema: schema,
                               capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model))
        var ids: [String: UInt64] = [:]
        let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: nil, names: [:], identifiers: &ids)
        let bridge = HAPBridge(info: AccessoryInfo(
            name: "Test Bridge", manufacturer: "MijiaLAN", model: "Test", serialNumber: "test-bridge", firmwareRevision: "1.0.0"
        ))
        await bridge.addAccessory(info: plan.info, services: plan.services, aid: 2, servicesHaveStableIIDs: true)
        let accessory = try #require(try await accessoryDatabase(bridge).first { $0["aid"] as? Int == 2 })
        let services = try #require(accessory["services"] as? [[String: Any]])
        #expect(services.count > 2)
        #expect(services.filter { $0["primary"] as? Bool == true }.map { $0["type"] as? String } == ["B7"])
    }

    /// The `GET /accessories` JSON exactly as an authenticated controller receives it.
    private func accessoryDatabase(_ bridge: HAPBridge) async throws -> [[String: Any]] {
        let identity = HAPIdentity()
        let pairings = InMemoryPairingStore()
        let deviceID = "AA:BB:CC:DD:EE:FF"
        let verify = PairVerifyStateMachine(identity: identity, pairingStore: pairings, deviceID: deviceID)
        try await VerifiedTestController.authenticate(verify, store: pairings)
        let handler = CharacteristicProtocol(
            bridge: bridge,
            pairingStateMachine: PairingStateMachine(
                setupCode: "031-45-154", identity: identity, pairingStore: pairings, deviceID: deviceID
            ),
            pairVerifyStateMachine: verify,
            pairingStore: pairings, identity: identity
        )
        let response = try await handler.handleRequest(HTTPRequest(method: "GET", path: "/accessories"))
        #expect(response.statusCode == 200)
        let json = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return try #require(json["accessories"] as? [[String: Any]])
    }
}
