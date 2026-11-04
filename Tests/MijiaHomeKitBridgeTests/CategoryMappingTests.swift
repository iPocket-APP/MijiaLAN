import Foundation
import HAPCore
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaHomeKitBridge

/// Native services for categories without a bundled spec, following homebridge-miot. Specs are real miot-spec.org
/// instances, trimmed; the model names are placeholders so no legacy miIO table applies.
struct CategoryMappingTests {
    @Test("A humidifier is a humidifier: humidity, threshold within the spec range, water level as a percentage")
    func humidifier() throws {
        var s = try snapshot("zhimi-ca4", model: "test.humidifier.ca4")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type.rawValue == "BD" })
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "B3", "B4", "10", "CA", "B5"])
        #expect(characteristic(service, "B3").validValues == [0, 1, 2])
        #expect(characteristic(service, "B4").validValues == [1])
        #expect(characteristic(service, "CA").minValue == 30)
        #expect(characteristic(service, "CA").maxValue == 80)
        // Humidity lives in the humidifier; temperature remains its own sensor.
        #expect(!plan.services.contains { $0.type == .humiditySensor })
        #expect(plan.services.contains { $0.type == .temperatureSensor })

        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:2:7"] = DeviceReading(value: .number(64), code: 0)
        #expect(value(plan, service, "B3", s) == .uint8(2))
        #expect(value(plan, service, "B5", s) == .float(50))
        s.readings["p:2:1"] = DeviceReading(value: .bool(false), code: 0)
        #expect(value(plan, service, "B3", s) == .uint8(0))
        #expect(try commands(plan, service, "CA", .float(45), s) == [.set("p:2:6", .number(45))])
        #expect(try commands(plan, service, "B4", .uint8(1), s) == [])
    }

    @Test("A dehumidifier dehumidifies, with its own threshold characteristic")
    func dehumidifier() throws {
        var s = try snapshot("xiaomi-13l", model: "test.derh.13l")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type.rawValue == "BD" })
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "B3", "B4", "10", "C9"])
        #expect(characteristic(service, "B3").validValues == [0, 1, 3])
        #expect(characteristic(service, "B4").validValues == [2])
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        #expect(value(plan, service, "B3", s) == .uint8(3))
    }

    @Test("A heater heats only, and reads its own thermometer")
    func heater() throws {
        var s = try snapshot("zhimi-za2", model: "test.heater.za2")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type.rawValue == "BC" })
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "B1", "B2", "11", "12", "36"])
        #expect(characteristic(service, "B2").validValues == [1])
        #expect(characteristic(service, "12").minValue == 16)
        #expect(characteristic(service, "12").maxValue == 28)
        #expect(plan.services.contains { $0.type == .humiditySensor })
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:2"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:5:8"] = DeviceReading(value: .number(19.5), code: 0)
        #expect(value(plan, service, "B1", s) == .uint8(2))
        #expect(value(plan, service, "11", s) == .float(19.5))
    }

    @Test("An air conditioner offers the modes it has; dry and fan stay named switches")
    func airConditioner() throws {
        var s = try snapshot("xiaomi-mc4", model: "test.aircondition.mc4")
        // MijiaCore synthesizes a climate for it too; its fixed 2.x / 3.x addresses only fit the AC companion.
        let device = try #require(smart(s))
        let plan = try plan(s, legacyDevice: device)
        #expect(!plan.bindings.values.contains { if case .legacy = $0 { true } else { false } })
        let service = try #require(plan.services.first { $0.type.rawValue == "BC" })
        #expect(service.characteristics.map(\.type.rawValue) == ["B0", "B1", "B2", "11", "D", "12", "36", "B6"])
        #expect(characteristic(service, "B2").validValues == [1, 2])
        #expect(characteristic(service, "D").minStep == 0.5)
        let modeSwitches = plan.bindings.values.compactMap { binding -> Double? in
            if case .option("p:2:2", let v) = binding { v.doubleValue } else { nil }
        }
        #expect(modeSwitches.sorted() == [3, 4])

        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        for (mode, current, target) in [(2.0, UInt8(3), UInt8(2)), (5, 2, 1), (3, 1, 1)] {
            s.readings["p:2:2"] = DeviceReading(value: .number(mode), code: 0)
            #expect(value(plan, service, "B1", s) == .uint8(current))
            #expect(value(plan, service, "B2", s) == .uint8(target))
        }
        #expect(try commands(plan, service, "B2", .uint8(2), s) == [.set("p:2:2", .number(2)), .set("p:2:1", .bool(true))])
        #expect(throws: HAPError.self) { try commands(plan, service, "B2", .uint8(0), s) }
    }

    @Test("A curtain moves to a position and reports which way it is going")
    func curtain() throws {
        var s = try snapshot("dooya-m2", model: "test.curtain.m2")
        let plan = try plan(s)
        let service = try #require(plan.services.first { $0.type == .windowCovering })
        #expect(service.characteristics.map(\.type.rawValue) == ["6D", "7C", "72"])
        s.health = LANDeviceHealth(state: .online)
        for (status, state) in [(0.0, UInt8(0)), (1, 2), (2, 1)] {
            s.readings["p:2:4"] = DeviceReading(value: .number(status), code: 0)
            #expect(value(plan, service, "72", s) == .uint8(state))
        }
        #expect(try commands(plan, service, "7C", .uint8(40), s) == [.set("p:2:7", .number(40))])
        // Open / pause / close remain buttons.
        #expect(plan.bindings.values.filter { if case .option("p:2:2", _) = $0 { true } else { false } }.count == 3)
    }

    @Test("Without a humidity reading a humidifier stays an outlet with named switches")
    func fallback() throws {
        var s = try snapshot("zhimi-ca4", model: "test.humidifier.ca4")
        s.capabilities.removeAll { $0.name == "relative-humidity" }
        let plan = try plan(s)
        #expect(!plan.services.contains { $0.type.rawValue == "BD" })
        #expect(plan.services.contains { $0.type == .outlet })
    }

    private func snapshot(_ file: String, model: String) throws -> DeviceSnapshot {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Specs"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        return DeviceSnapshot(device: LocalDevice(did: "9", name: "Test", model: model, host: "test", token: ""),
                              schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model))
    }
    private func plan(_ s: DeviceSnapshot, legacyDevice: SmartDevice? = nil) throws -> CapabilityHomeKitPlan {
        var ids: [String: UInt64] = [:]
        let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: legacyDevice, names: [:], identifiers: &ids)
        let all = plan.services.flatMap { [$0.iid] + $0.characteristics.map(\.iid) }
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { $0 >= 8 })
        return plan
    }
    private func smart(_ s: DeviceSnapshot) -> SmartDevice? {
        guard let core = s.schema.coreSpec else { return nil }
        let home = MiotSynthesizer.synthesize(devices: [MiDeviceRecord(did: s.id, name: s.device.name, model: s.device.model, isOnline: false)],
                                              rooms: [], specs: [s.device.model: core], values: [:])
        return home.devices.first
    }
    private func characteristic(_ service: HAPService, _ type: String) -> HAPCharacteristic {
        service.characteristics.first { $0.type.rawValue == type }!
    }
    private func value(_ plan: CapabilityHomeKitPlan, _ service: HAPService, _ type: String, _ s: DeviceSnapshot) -> HAPCharacteristicValue? {
        plan.bindings[characteristic(service, type).iid].flatMap { CapabilityHomeKitMapper.value($0, snapshot: s, legacyValues: [:], names: [:]) }
    }
    private func commands(_ plan: CapabilityHomeKitPlan, _ service: HAPService, _ type: String, _ value: HAPCharacteristicValue,
                          _ s: DeviceSnapshot) throws -> [CapabilityCommand] {
        try CapabilityHomeKitMapper.commands(try #require(plan.bindings[characteristic(service, type).iid]), value: value, snapshot: s)
    }
}
