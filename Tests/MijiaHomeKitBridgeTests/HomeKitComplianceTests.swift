import Foundation
import HAPCore
import HAPTransport
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaHomeKitBridge

struct HomeKitComplianceTests {
    @Test("A missing humidity threshold retains generic power and choice controls", arguments: ["zhimi-ca4", "xiaomi-13l"])
    func missingHumidityThreshold(_ file: String) throws {
        var s = try snapshot(file)
        s.capabilities.removeAll { $0.name == "target-humidity" }
        let p = plan(s)
        #expect(!p.services.contains { $0.type.rawValue == "BD" })
        #expect(p.services.contains { $0.type == .outlet })
        #expect(p.services.contains { $0.type == .humiditySensor })
        let choice = try #require(s.controls.first { $0.control == .choice })
        #expect(p.bindings.values.contains { if case .option(let id, _) = $0 { id == choice.id } else { false } })
    }

    @Test("An unusable threshold cannot create an incomplete humidifier", arguments: ["readOnly", "missingRange", "outsideRange", "reversedRange", "zeroStep"])
    func unusableHumidityThreshold(_ condition: String) throws {
        var s = try snapshot("zhimi-ca4")
        let i = try #require(s.capabilities.firstIndex { $0.name == "target-humidity" })
        switch condition {
        case "readOnly": s.capabilities[i].writable = false
        case "missingRange": s.capabilities[i].range = nil
        case "outsideRange": s.capabilities[i].range = [120, 140, 1]
        case "reversedRange": s.capabilities[i].range = [80, 30, 1]
        default: s.capabilities[i].range = [30, 80, 0]
        }
        let p = plan(s)
        #expect(!p.services.contains { $0.type.rawValue == "BD" })
        #expect(p.services.contains { $0.type == .outlet })
    }

    @Test("Legacy climates without native target modes retain power and supported switches", arguments: [[], ["off"], ["dry"], ["fan_only"], ["dry", "fan_only"]])
    func legacyModeFallback(_ modes: [String]) throws {
        let device = HomeKitAccessoryMapperTests.climate(mode: modes.first ?? "off", modes: modes)
        let p = try #require(HomeKitAccessoryMapper.plan(for: device, name: device.name))
        #expect(!p.services.contains { $0.type == HomeKitAccessoryMapper.heaterCoolerService })
        #expect(p.services.contains { $0.type == .outlet })
        #expect(p.services.filter { $0.type == .switch }.count == modes.filter { ["dry", "fan_only"].contains($0) }.count)
        #expect(HomeKitAccessoryMapper.values(for: device)[.climateTargetState] == nil)
        #expect(HomeKitAccessoryMapper.write(.outletOn, value: .bool(false), to: device) == (modes.first == "off" || modes.isEmpty ? nil : .power(false)))
    }

    @Test("Schema modes override a legacy layout that would invent auto", arguments: [false, true])
    func capabilityModeFallback(_ staleLegacyModes: Bool) throws {
        var s = try bundledSnapshot("lumi.acpartner.mcn02")
        let i = try #require(s.capabilities.firstIndex { $0.id == "p:2:2" })
        s.capabilities[i].options = s.capabilities[i].options.filter { [2, 4].contains($0.value) }
        let legacy = HomeKitAccessoryMapperTests.climate(mode: "dry", modes: staleLegacyModes ? ["auto", "heat", "cool", "dry", "fan_only"] : ["dry", "fan_only"])
        let p = plan(s, legacy: legacy)
        #expect(!p.services.contains { $0.type == HomeKitAccessoryMapper.heaterCoolerService })
        #expect(p.services.contains { $0.type == .outlet })
        let modes = p.bindings.values.compactMap { binding -> Double? in
            if case .option("p:2:2", let value) = binding { value.doubleValue } else { nil }
        }
        #expect(modes.sorted() == [2, 4])
    }

    @Test("Changed legacy mode encodings use schema commands instead of fixed addresses")
    func changedModeEncoding() throws {
        var s = try bundledSnapshot("lumi.acpartner.mcn02")
        let i = try #require(s.capabilities.firstIndex { $0.id == "p:2:2" })
        for j in s.capabilities[i].options.indices where s.capabilities[i].options[j].description == "Cool" {
            s.capabilities[i].options[j].value = 9
        }
        let p = plan(s, legacy: HomeKitAccessoryMapperTests.climate())
        let c = try #require(p.services.first { $0.type == HomeKitAccessoryMapper.heaterCoolerService }?
            .characteristics.first { $0.type == HomeKitAccessoryMapper.targetHeaterCoolerState })
        let binding = try #require(p.bindings[c.iid])
        #expect(try CapabilityHomeKitMapper.commands(binding, value: .uint8(2), snapshot: s) == [.set("p:2:2", .number(9)), .set("p:2:1", .bool(true))])
    }

    @Test("Duplicate properties and duplicate options cannot duplicate service or characteristic IIDs")
    func duplicateIdentifiers() async throws {
        var s = try snapshot("zhimi-ca4")
        s.schema.type = "audit"
        let toggle = try #require(s.capabilities.first { $0.name == "on" })
        var choice = try #require(s.capabilities.first { $0.control == .choice })
        choice.options += choice.options
        s.capabilities = [toggle, toggle, choice, choice]
        let p = plan(s)
        let bridge = HAPBridge(info: p.info)
        await bridge.addAccessory(info: p.info, services: p.services, aid: 2, servicesHaveStableIIDs: true)
        let accessory = try #require(await bridge.accessoryDatabase().first { $0.aid == 2 })
        let iids = accessory.services.flatMap { [$0.iid] + $0.characteristics.map(\.iid) }
        #expect(iids.count == Set(iids).count)
        #expect(p.bindings.count == p.services.flatMap(\.characteristics).count)
        #expect(p.omittedServiceCount == 0)
        for service in accessory.services {
            #expect(service.characteristics.count == Set(service.characteristics.map(\.type)).count)
        }
    }

    @Test("The 100-service limit includes accessory information and leaves complete services", arguments: [98, 99, 100, 120])
    func serviceLimit(_ count: Int) async throws {
        var s = try snapshot("zhimi-ca4")
        s.schema.type = "audit"
        let original = try #require(s.capabilities.first { $0.name == "on" })
        s.capabilities = (1...count).map { i in
            var c = original
            c.id = "p:99:\(i)"; c.siid = 99; c.iid = i; c.service = "audit"; c.name = "switch-\(i)"
            return c
        }
        var ids: [String: UInt64] = [:]
        let p = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: nil, names: [:], identifiers: &ids)
        let bridge = HAPBridge(info: p.info)
        await bridge.addAccessory(info: p.info, services: p.services, aid: 2, servicesHaveStableIIDs: true)
        let accessory = try #require(await bridge.accessoryDatabase().first { $0.aid == 2 })
        #expect(accessory.services.count == min(count + 1, 100))
        #expect(p.omittedServiceCount == max(0, count - 99))
        #expect(p.services.allSatisfy { Set($0.characteristics.map(\.type.rawValue)) == ["25", "23", "E3"] })
        let before = ids
        let repeated = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: nil, names: [:], identifiers: &ids)
        #expect(ids == before)
        #expect(repeated.databaseSignature == p.databaseSignature)
        #expect(repeated.omittedServiceCount == p.omittedServiceCount)
    }

    @Test("Curtains start unavailable and return whole percentages for nonzero ranges", arguments: [10.0, 110, 310])
    func curtainPercentage(_ raw: Double) throws {
        var s = try snapshot("dooya-m2")
        for i in s.capabilities.indices where ["current-position", "target-position"].contains(s.capabilities[i].name) {
            s.capabilities[i].range = [10, 310, 1]
        }
        let p = plan(s)
        let service = try #require(p.services.first { $0.type == .windowCovering })
        for type in [HAPCharacteristicType.currentPosition, .targetPosition] {
            let c = try #require(service.characteristics.first { $0.type == type })
            let binding = try #require(p.bindings[c.iid])
            #expect(c.format == .uint8)
            #expect(c.value == nil)
            #expect(CapabilityHomeKitMapper.value(binding, snapshot: s, legacyValues: [:], names: [:]) == nil)
            s.health = LANDeviceHealth(state: .online)
            let id = type == .currentPosition ? "p:2:6" : "p:2:7"
            s.readings[id] = DeviceReading(value: .number(raw), code: 0)
            #expect(CapabilityHomeKitMapper.value(binding, snapshot: s, legacyValues: [:], names: [:]) == .float(((raw - 10) / 3).rounded()))
            s.health = LANDeviceHealth()
        }
    }

    @Test("Malformed readings never become HomeKit values, even outside the normal polling path", arguments: [JSONValue.number(-1), .number(101), .number(.nan), .number(.infinity), .string("50"), .bool(true)])
    func invalidReading(_ raw: JSONValue) throws {
        var s = try bundledSnapshot("dmaker.fan.p28")
        s.health = LANDeviceHealth(state: .online)
        s.readings["p:2:1"] = DeviceReading(value: .bool(true), code: 0)
        s.readings["p:8:1"] = DeviceReading(value: raw, code: 0)
        #expect(CapabilityHomeKitMapper.value(.property("p:8:1", .fanSpeed), snapshot: s, legacyValues: [:], names: [:]) == nil)
    }

    private func snapshot(_ file: String) throws -> DeviceSnapshot {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Specs"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(contentsOf: url))
        return makeSnapshot(schema, model: "test.audit.\(file)")
    }
    private func bundledSnapshot(_ model: String) throws -> DeviceSnapshot {
        makeSnapshot(try #require(DeviceSchema.bundled(model: model)), model: model)
    }
    private func makeSnapshot(_ schema: DeviceSchema, model: String) -> DeviceSnapshot {
        DeviceSnapshot(device: LocalDevice(did: "audit", name: "Audit", model: model, host: "", token: ""),
                       schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model))
    }
    private func plan(_ s: DeviceSnapshot, legacy: SmartDevice? = nil) -> CapabilityHomeKitPlan {
        var ids: [String: UInt64] = [:]
        return CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: legacy, names: [:], identifiers: &ids)
    }
}
