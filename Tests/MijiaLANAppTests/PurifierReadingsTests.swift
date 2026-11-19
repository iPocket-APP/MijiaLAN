import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaLANApp

struct PurifierReadingsTests {
    private func snapshot(model: String = "zhimi.airpurifier.rma1") throws -> DeviceSnapshot {
        let schema = try #require(DeviceSchema.bundled(model: model))
        let device = LocalDevice(did: "purifier", name: "Test", model: model, host: "192.0.2.2", token: String(repeating: "0", count: 32))
        return DeviceSnapshot(device: device, schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model),
                              health: LANDeviceHealth(state: .online))
    }

    @Test("The 4 Lite shows its environmental and filter readings on standby and while running", arguments: [false, true])
    func powerStates(on: Bool) throws {
        var device = try snapshot()
        device.readings = [
            "p:2:1": .init(value: .bool(on)),
            "p:3:4": .init(value: .number(0)), "p:3:7": .init(value: .number(23.4)), "p:3:1": .init(value: .number(52)),
            "p:4:1": .init(value: .number(76)), "p:4:4": .init(value: .number(137)), "p:4:3": .init(value: .number(44))
        ]
        let readings = try L10n.$overrideLanguage.withValue(.en) { try #require(PurifierReadings(device)) }
        #expect(readings.particulate?.formatted == "0 µg/m³")
        #expect(readings.temperature?.value == 23.4)
        #expect(readings.temperature?.unit == "℃")
        #expect(readings.humidity?.formatted == "52%")
        #expect(readings.filterText == "76% · 137 d")
        let chinese = L10n.$overrideLanguage.withValue(.zhHans) { PurifierReadings(device) }
        #expect(chinese?.filterText == "76% · 137 天")
    }

    @Test("Failed and missing reads cannot display stale or invented values")
    func unavailableReadings() throws {
        var device = try snapshot()
        device.readings = [
            "p:3:4": .init(value: .number(12), code: -4003),
            "p:4:1": .init(value: .number(76), error: "fixture read failed"),
            "p:4:4": .init(value: .number(0))
        ]
        let readings = try L10n.$overrideLanguage.withValue(.en) { try #require(PurifierReadings(device)) }
        #expect(try #require(readings.particulate).value == nil)
        #expect(try #require(readings.temperature).value == nil)
        #expect(try #require(readings.filterLife).value == nil)
        #expect(readings.filterText == "0 d")
        device.readings.removeAll()
        let empty = try #require(PurifierReadings(device))
        #expect(empty.hasEnvironment && empty.hasFilter)
        #expect(empty.filterText == nil)
    }

    @Test("Only declared readable sensors appear, even when a model uses different property IDs")
    func capabilitySelection() throws {
        var device = try snapshot()
        var pm = try #require(device.capability("environment", "pm2.5-density"))
        pm.siid = 7
        pm.iid = 9
        pm.id = DeviceCapability.propertyID(pm.siid, pm.iid)
        var humidity = try #require(device.capability("environment", "relative-humidity"))
        humidity.readable = false
        device.capabilities = [pm, humidity]
        device.readings = [pm.id: .init(value: .number(8))]
        let readings = try #require(PurifierReadings(device))
        #expect(readings.particulate?.value == 8)
        #expect(readings.temperature == nil)
        #expect(readings.humidity == nil)
        #expect(!readings.hasFilter)
        device.capabilities = [humidity]
        #expect(PurifierReadings(device) == nil)
    }

    @Test("An unreachable purifier or a different kind of device has no live readings card")
    func eligibility() throws {
        var device = try snapshot()
        device.readings["p:3:4"] = .init(value: .number(8))
        for state: LANDeviceHealth.State in [.unknown, .offline, .tokenRejected, .unsupported] {
            device.health.state = state
            #expect(PurifierReadings(device) == nil)
        }
        let lamp = try snapshot(model: "yeelink.light.lamp4")
        #expect(PurifierReadings(lamp) == nil)
    }

    #if DEBUG
    @Test("Normal polling fills the standby purifier detail from the preview LAN")
    @MainActor func standbyPolling() async throws {
        let device = try #require(ControlCenterPreview.config.devices.first { $0.did == "purifier" })
        let config = LocalHomeConfig(devices: [device])
        let api = LANMiotAPI(config: { config }, transport: ControlCenterPreviewTransport())
        let controller = DeviceController(api: api, config: { config })
        defer { controller.shutdown() }
        await controller.refreshNow()
        let result = try #require(controller.snapshots[device.did])
        #expect(result.value("air-purifier", "on")?.boolValue == false)
        let readings = try #require(PurifierReadings(result))
        #expect(readings.particulate?.value == 8)
        #expect(readings.temperature?.value == 23.4)
        #expect(readings.humidity?.value == 52)
        #expect(readings.filterLife?.value == 76)
        #expect(readings.filterTime?.value == 137)
    }
    #endif
}
