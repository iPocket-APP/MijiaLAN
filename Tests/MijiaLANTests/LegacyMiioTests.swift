import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

private let token = "00112233445566778899aabbccddeeff"

private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var config: LocalHomeConfig
    init(_ config: LocalHomeConfig) { self.config = config }
    var value: LocalHomeConfig { lock.withLock { config } }
}

private final class WattsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var watts: [String: Double] = [:]
    var value: [String: Double] { lock.withLock { watts } }
    func set(_ new: [String: Double]) { lock.withLock { watts = new } }
}

private func device(_ did: String, _ model: String, host: String) -> LocalDevice {
    LocalDevice(did: did, name: model, model: model, host: host, token: token)
}

struct LegacyMiioProfileTests {
    @Test("Legacy values convert to MIoT and back")
    func conversions() throws {
        let ac = try #require(LegacyMiioProfile.forModel("lumi.acpartner.mcn02"))
        let mode = try #require(ac.property(siid: 2, piid: 2))
        #expect(mode.miotValue(.string("heat")) == .number(3))
        #expect(mode.legacyArgument(.number(4)) == .string("wind"))
        #expect(mode.miotValue(.string("turbo")) == nil)
        let power = try #require(ac.property(siid: 2, piid: 1))
        #expect(power.miotValue(.string("on")) == .bool(true))
        #expect(power.legacyArgument(.bool(false)) == .string("off"))
        #expect(ac.property(siid: 5, piid: 1)?.setter == nil)

        let lamp = try #require(LegacyMiioProfile.forModel("yeelink.light.lamp4"))
        // Yeelight sends numbers as strings.
        #expect(lamp.property(siid: 2, piid: 2)?.miotValue(.string("71")) == .number(71))
        #expect(LegacyMiioProfile.forModel("cuco.plug.v3") == nil)
    }
}

/// hass-xiaomi-miot's tables as `scripts/import_hass_xiaomi_miot.py` converts them.
struct ImportedLegacyTableTests {
    @Test("Every converted property loads, and the checked tables keep priority")
    func loadsCompletely() throws {
        let url = try #require(LegacyMiioProfile.importedTableURL)
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let models = try #require(document["models"] as? [String: [String: Any]])
        #expect(models.count >= 150)
        for (model, entry) in models where LegacyMiioProfile.profiles[model] == nil {
            let properties = try #require(entry["properties"] as? [[String: Any]])
            let profile = try #require(LegacyMiioProfile.forModel(model), "\(model)")
            #expect(profile.properties.count == properties.count, "\(model)")
            #expect(profile.properties.filter(\.isWritable).count == properties.filter { $0["write"] != nil }.count, "\(model)")
        }
        #expect(LegacyMiioProfile.forModel("chuangmi.plug.m3")?.source == .verified)
        #expect(LegacyMiioProfile.forModel("yeelink.light.lamp4")?.property(siid: 2, piid: 2)?.setter == "set_bright")
        #expect(LegacyMiioProfile.forModel("midea.aircondition.xa2")?.source == .hassXiaomiMiot(base: "midea.aircondition.xa1"))
        #expect(LegacyMiioProfile.forModel("cuco.plug.v3") == nil)
    }

    @Test("The values hass-xiaomi-miot computes with Jinja templates come out the same")
    func transforms() {
        typealias Property = LegacyMiioProfile.Property
        func make(_ read: Property.Read, _ write: Property.Write? = nil, suffix: [JSONValue] = []) -> Property {
            Property(siid: 2, piid: 1, name: "x", read: read, setter: write == nil ? nil : "set_x", write: write, suffix: suffix)
        }
        #expect(make(.number(ratio: 0.1, offset: 0, strip: nil)).miotValue(.string("253")) == .number(25.3))
        #expect(make(.number(ratio: 1, offset: 0, strip: "rpm")).miotValue(.string("1200rpm")) == .number(1200))
        #expect(make(.number(ratio: 1, offset: 1, strip: nil)).miotValue(.number(2)) == .number(3))
        #expect(make(.nonZero).miotValue(.number(3)) == .bool(true))
        #expect(make(.nonZero).miotValue(.number(0)) == .bool(false))
        let angle = make(.ifEquals(.string("off"), then: .number(0), else: .number(180)))
        #expect(angle.miotValue(.string("off")) == .number(0))
        #expect(angle.miotValue(.string("on")) == .number(180))
        #expect(make(.values(["low": 1], fallback: 0)).miotValue(.string("turbo")) == .number(0))
        #expect(make(.boolean).miotValue(.number(1)) == .bool(true))
        #expect(make(.boolean).miotValue(.string("off")) == .bool(false))

        #expect(make(.auto, .integer(ratio: 25, offset: 0)).legacyCall(.number(2))?.params == [.number(50)])
        #expect(make(.auto, .integer(ratio: 1, offset: -1)).legacyCall(.number(3))?.params == [.number(2)])
        #expect(make(.auto, .boolChoice(on: .string("swing"), off: .string("stop"))).legacyCall(.bool(true))?.params == [.string("swing")])
        #expect(make(.auto, .onOff, suffix: [.string("smooth"), .number(500)]).legacyCall(.bool(false))?.params
            == [.string("off"), .string("smooth"), .number(500)])
        let usb = make(.auto, .methodSwitch(on: "set_usb_on", off: "set_usb_off")).legacyCall(.bool(false))
        #expect(usb?.method == "set_usb_off")
        #expect(usb?.params == [])
    }

    @Test("Readings follow the spec format: 0 / 1 become a bool for a bool property")
    func resolvesAgainstSpec() throws {
        let profile = try #require(LegacyMiioProfile.forModel("deerma.humidifier.jsq"))
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(#"""
            {"type": "urn:miot-spec-v2:device:humidifier:0000A00E:deerma-jsq:1", "services": [{"iid": 2,
             "type": "urn:miot-spec-v2:service:humidifier:00007818:deerma-jsq:1", "properties": [
              {"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:deerma-jsq:1", "format": "bool", "access": ["read", "write"]},
              {"iid": 101, "type": "urn:miot-spec-v2:property:target-humidity:00000032:deerma-jsq:1", "format": "uint8", "access": ["read", "write"]}]}]}
            """#.utf8))
        #expect(profile.property(siid: 2, piid: 1)?.miotValue(.number(1)) == .number(1))
        let resolved = profile.resolved(with: schema)
        #expect(resolved.property(siid: 2, piid: 1)?.miotValue(.number(1)) == .bool(true))
        #expect(resolved.property(siid: 2, piid: 101)?.miotValue(.string("45")) == .number(45))
    }
}

struct LegacyLANTests {
    @Test("A Yeelight lamp is read with get_prop and written with its own setters")
    func yeelight() async throws {
        let network = FakeMiioNetwork()
        let lamp = network.add(host: "192.168.1.228", token: token, deviceID: 306)
        lamp.legacyProps = ["power": .string("off"), "bright": .string("71"), "ct": .string("2625")]
        let config = ConfigBox(LocalHomeConfig(devices: [device("306", "yeelink.light.lamp4", host: "192.168.1.228")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        _ = try await api.deviceList()

        let keys = [1, 2, 3, 4].map { MiotPropKey(did: "306", siid: 2, piid: $0) }
        let values = try await api.getProps(keys)
        #expect(values == [keys[0]: .bool(false), keys[1]: .number(71), keys[2]: .number(2625)])
        #expect(!lamp.receivedMethods.contains("get_properties"))

        try await api.setProps([
            MiotPropWrite(did: "306", siid: 2, piid: 1, value: .bool(true)),
            MiotPropWrite(did: "306", siid: 2, piid: 2, value: .number(30)),
            MiotPropWrite(did: "306", siid: 2, piid: 3, value: .number(5000)),
        ])
        #expect(lamp.legacyCalls == [#"set_power ["on"]"#, "set_bright [30]", #"set_ct_abx [5000,"smooth",500]"#])
        await #expect(throws: MiioError.unsupportedByLegacyDevice) {
            try await api.setProps([MiotPropWrite(did: "306", siid: 2, piid: 4, value: .number(1))])
        }
        #expect(await api.currentHealth()["306"]?.state == .online)
    }

    @Test("Repeated unsupported commands do not permanently exclude an answering device")
    func unknownLegacyModel() async throws {
        let network = FakeMiioNetwork()
        let old = network.add(host: "192.168.1.30", token: token, deviceID: 30)
        old.legacyProps = ["power": .string("on")]
        let config = ConfigBox(LocalHomeConfig(devices: [device("30", "lumi.acpartner.v9", host: "192.168.1.30")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        #expect(try await api.deviceList().first?.isOnline == true)

        let keys = [MiotPropKey(did: "30", siid: 2, piid: 1)]
        _ = try await api.getProps(keys)
        _ = try await api.getProps(keys)
        let health = try #require(await api.currentHealth()["30"])
        #expect(health.state == .offline)
        #expect(health.lastError != nil)

        // The next scheduled device probe may recover it; a timeout is not proof of a legacy dialect.
        let probes = old.receivedMethods.filter { $0 == "miIO.info" }.count
        #expect(try await api.deviceList().first?.isOnline == true)
        #expect(old.receivedMethods.filter { $0 == "miIO.info" }.count == probes + 1)
    }

    @Test("An imported table reads in its chunk size and writes through a method per value")
    func importedTable() async throws {
        let network = FakeMiioNetwork()
        let humidifier = network.add(host: "192.168.1.40", token: token, deviceID: 40)
        humidifier.legacyProps = ["OnOff_State": .number(1), "HumiSet_Value": .number(45), "Humidity_Value": .number(52)]
        let plug = network.add(host: "192.168.1.41", token: token, deviceID: 41)
        plug.legacyProps = ["on": .bool(true), "usb_on": .bool(false), "temperature": .number(33), "wifi_led": .string("off")]
        let config = ConfigBox(LocalHomeConfig(devices: [
            device("40", "deerma.humidifier.jsq", host: "192.168.1.40"), device("41", "chuangmi.plug.v3", host: "192.168.1.41"),
        ]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        _ = try await api.deviceList()

        let keys = [(2, 101), (3, 1), (5, 1)].map { MiotPropKey(did: "40", siid: $0.0, piid: $0.1) }
        let before = humidifier.legacyReads.count
        let values = try await api.getProps(keys)
        #expect(values[keys[0]] == .number(45))
        #expect(values[keys[1]] == .number(52))
        // hass-xiaomi-miot asks this model for one property per get_prop.
        #expect(Array(humidifier.legacyReads.dropFirst(before)) == [["HumiSet_Value"], ["Humidity_Value"], ["TipSound_State"]])
        #expect(!humidifier.receivedMethods.contains("get_properties"))

        try await api.setProps([MiotPropWrite(did: "41", siid: 3, piid: 1, value: .bool(true))])
        #expect(plug.legacyCalls == ["set_usb_on []"])
    }

    @Test("A first-generation Roborock is read with get_status and driven with its app methods")
    func roborock() async throws {
        let network = FakeMiioNetwork()
        let robot = network.add(host: "192.168.1.50", token: token, deviceID: 50)
        let ok = JSONValue.array([.string("ok")])
        robot.legacyProps = [:]
        robot.legacyReplies = [
            "get_status": .array([.object(["msg_ver": .number(2), "state": .number(8), "battery": .number(100), "fan_power": .number(60)])]),
            "app_start": ok, "app_pause": ok, "app_charge": ok, "app_stop": .array([.string("busy")]),
        ]
        let config = ConfigBox(LocalHomeConfig(devices: [device("50", "rockrobo.vacuum.v1", host: "192.168.1.50")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        _ = try await api.deviceList()

        let keys = [(2, 1), (2, 2), (3, 1), (3, 2)].map { MiotPropKey(did: "50", siid: $0.0, piid: $0.1) }
        let values = try await api.getProps(keys)
        // Roborock's charging (8) is MIoT status 3 and charging state 1; one get_status answers all four.
        #expect(values == [keys[0]: .number(3), keys[1]: .number(60), keys[2]: .number(100), keys[3]: .number(1)])
        #expect(robot.receivedMethods.filter { $0 == "get_status" }.count == 1)
        #expect(!robot.receivedMethods.contains("get_prop"))
        #expect(!robot.receivedMethods.contains("get_properties"))

        try await api.setProps([MiotPropWrite(did: "50", siid: 2, piid: 2, value: .number(77))])
        try await api.action(MiotActionCall(did: "50", siid: 2, aiid: 1, inputs: []))
        try await api.action(MiotActionCall(did: "50", siid: 3, aiid: 1, inputs: []))
        // The first generation is paused before it is sent home.
        #expect(robot.legacyCalls == ["set_custom_mode [77]", "app_start []", "app_pause []", "app_charge []"])

        // A reply other than ok fails the action, which is never resent.
        await #expect(throws: MiioError.self) { try await api.action(MiotActionCall(did: "50", siid: 2, aiid: 2, inputs: [])) }
        #expect(robot.legacyCalls.filter { $0.hasPrefix("app_stop") }.count == 1)
        // Identify has no legacy method.
        await #expect(throws: MiioError.unsupportedByLegacyDevice) {
            try await api.action(MiotActionCall(did: "50", siid: 4, aiid: 1, inputs: []))
        }
        #expect(robot.receivedMethods.filter { $0 == "action" }.isEmpty)
    }

    @Test("Roborock states follow python-miio where hass-xiaomi-miot shows them idle; later models go straight home")
    func roborockStates() throws {
        let v1 = try #require(LegacyMiioProfile.forModel("rockrobo.vacuum.v1"))
        let status = try #require(v1.property(siid: 2, piid: 1))
        for (state, miot) in [(5.0, 2.0), (6, 5), (15, 5), (10, 4), (100, 3), (12, 7), (14, 1)] {
            #expect(status.miotValue(.number(state)) == .number(miot), "\(state)")
        }
        #expect(v1.action(siid: 3, aiid: 1)?.methods == ["app_pause", "app_charge"])
        for model in ["roborock.vacuum.c1", "roborock.vacuum.e2", "roborock.vacuum.s5"] {
            let profile = try #require(LegacyMiioProfile.forModel(model))
            #expect(profile.source == .hassXiaomiMiot(base: "rockrobo.vacuum.v1"))
            #expect(profile.action(siid: 3, aiid: 1)?.methods == ["app_charge"])
        }
    }

    @Test("An IP with nothing behind it is offline right away, with a plain explanation")
    func hostUnreachable() async throws {
        let network = FakeMiioNetwork()
        let gone = network.add(host: "192.168.1.243", token: token, deviceID: 243, props: ["2.1": .bool(true)])
        let config = ConfigBox(LocalHomeConfig(devices: [device("243", "dmaker.fan.p28", host: "192.168.1.243")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        _ = try await api.deviceList()

        gone.unreachable = true
        _ = try await api.getProps([MiotPropKey(did: "243", siid: 2, piid: 1)])
        let health = try #require(await api.currentHealth()["243"])
        #expect(health.state == .offline)
        #expect(health.lastError?.contains("这个 IP 上没有设备") == true)
    }
}

/// The AC companion end to end: legacy reads become a climate device, the panel's mode change becomes
/// `set_power` + `set_mode` on the device, and swing and power, which MijiaCore does not read, ride along.
struct LegacyIntegrationTests {
    @Test("小米空调伴侣 2 shows up as an AC with swing and power, and takes mode, fan and swing changes")
    @MainActor
    func acPartner() async throws {
        let network = FakeMiioNetwork()
        let ac = network.add(host: "192.168.1.134", token: token, deviceID: 683)
        ac.legacyProps = ["power": .string("off"), "mode": .string("cool"), "tar_temp": .number(29),
                          "fan_level": .string("auto_fan"), "ver_swing": .string("on"), "load_power": .number(84)]
        let config = ConfigBox(LocalHomeConfig(devices: [device("683", "lumi.acpartner.mcn02", host: "192.168.1.134")]))
        let api = LANMiotAPI(config: { config.value }, transport: network)
        let provider = LocalHomeProvider.make(api: api, specSource: StubSpecSource(),
                                              pollInterval: .milliseconds(100), closedPollInterval: .milliseconds(100))
        let watts = WattsBox()
        await provider.observePower { watts.set($0) }
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.mijialan.legacy.\(UUID().uuidString)")

        let climate = try await waitFor { () -> ClimateSpec? in
            guard case .climate(let spec) = store.devices.first(where: { $0.id == "683" })?.kind, spec.swingMode != nil else { return nil }
            return spec
        }
        #expect(!climate.isOn)
        #expect(climate.targetTemperature == 29)
        #expect(climate.availableModes.contains("heat"))
        #expect(climate.fanMode == "Auto")
        #expect(climate.swingMode == "vertical")
        #expect(climate.availableSwingModes == ["off", "vertical"])
        _ = try await waitFor { watts.value["683"] == 84 ? true : nil }
        // Companions share the device's one get_prop per poll.
        let lastRead = try #require(ac.receivedPayloads.last.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0.prefix { $0 != 0 }) })
        #expect(lastRead["params"]?.arrayValue?.compactMap(\.stringValue).contains("load_power") == true)

        store.setClimateMode("683", mode: "heat")
        _ = try await waitFor { ac.legacyCalls.count >= 2 ? true : nil }
        #expect(ac.legacyCalls.prefix(2) == [#"set_power ["on"]"#, #"set_mode ["heat"]"#])

        store.setClimateFanMode("683", fanMode: "High")
        _ = try await waitFor { ac.legacyCalls.contains(#"set_fan_level ["large_fan"]"#) ? true : nil }
        store.setClimateSwingMode("683", swingMode: "off")
        _ = try await waitFor { ac.legacyCalls.contains(#"set_ver_swing ["off"]"#) ? true : nil }
        #expect(!ac.receivedMethods.contains("get_properties"))
        await provider.shutdown()
    }

    @MainActor
    private func waitFor<T>(timeout: Duration = .seconds(5), _ probe: @MainActor () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MiioError.timeout
    }
}
