import CryptoKit
import Foundation
import MijiaCore
import MijiaLAN
import Testing
@testable import MijiaHomeKitBridge

/// Apple Home keeps automations and room placement per service and characteristic ID. Paired built-in models must keep
/// their layout when category rules are added for other devices. The 2026-11-05 fingerprints record a deliberate
/// change: range-end and ± switches, fan gear and angle switches left Home, child locks became characteristics,
/// and the purifier's favorite level became its speed. On 2026-11-12 the health kettle's Start and Stop switches
/// became one main switch that reads its working state, keeping Start's identifiers.
struct BuiltInLayoutTests {
    /// SHA-256 prefixes of each plan's signature (service and characteristic IDs, types and ranges).
    static let signatures: [String: String] = [
        "careli.fryer.maf07c": "9cadc4533ded4707",
        "chuangmi.plug.m3": "e252186241d4a2ef",
        "chunmi.cooker.cmwy3": "4d0b1cb605cfa2a8",
        "chunmi.health_pot.a1": "2a08068e5c462547",
        "chunmi.juicer.a1": "5dc2bb8b474f8153",
        "cuco.plug.v3": "14bfa8f213237ea9",
        "dmaker.fan.p28": "a35283795e7d91fe",
        "lumi.acpartner.mcn02": "c062b90419d1bde8",
        "yeelink.light.lamp4": "83fcaae106347d09",
        "zhimi.airpurifier.rma1": "5b098c36d6826092"
    ]

    @Test("Built-in models keep their Home layout", arguments: DeviceSchema.bundledModels)
    func layout(model: String) throws {
        let schema = try #require(DeviceSchema.bundled(model: model))
        let s = DeviceSnapshot(device: LocalDevice(did: "123", name: "Test", model: model, host: "test", token: ""),
                               schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model))
        var home = MiotSynthesizer.synthesize(devices: [MiDeviceRecord(did: s.id, name: s.device.name, model: model, isOnline: false)],
                                              rooms: [], specs: [model: try #require(schema.coreSpec)], values: [:])
        if case .climate(var climate) = home.devices.first?.kind {
            climate.availableSwingModes = ["off", "vertical"]; climate.swingMode = "off"
            home.devices[0].kind = .climate(climate)
        }
        var ids: [String: UInt64] = [:]
        let plan = L10n.$overrideLanguage.withValue(.zhHans) {
            CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: home.devices.first, names: [:], identifiers: &ids)
        }
        let digest = SHA256.hash(data: Data(plan.signature.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        #expect(Self.signatures[model] == String(digest), "\(model)")
    }
}
