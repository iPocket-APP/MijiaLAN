import Foundation
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN
import Testing
@testable import MijiaLANApp

@MainActor
struct DiagnosticReportTests {
    @Test("A report names the Home characteristics that fail to read and never carries a token or address")
    func allowList() throws {
        let token = "00112233445566778899aabbccddeeff"
        let schema = try #require(DeviceSchema.bundled(model: "dmaker.fan.p28"))
        let device = LocalDevice(did: "123", name: "落地扇", model: "dmaker.fan.p28", host: "192.168.31.57", token: token,
                                 mac: "AA:BB:CC:DD:EE:FF", specType: schema.type)
        var s = DeviceSnapshot(device: device, schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: device.model),
                               health: LANDeviceHealth(state: .online, lastError: "timeout"))
        s.readings["p:2:3"] = DeviceReading(value: .number(9), code: 0)
        s.readings["p:2:1"] = DeviceReading(code: -4001, error: "rejected")
        let failure = HomeKitBridgeController.ReadFailure(deviceID: "123", service: "49", characteristic: "25", source: "p:2:1 direct", status: -70402)
        let data = try #require(DiagnosticReport.json(
            snapshots: [s], retryStates: [:], hidden: [], failures: [failure],
            bridge: .init(status: "running(port: 51826)", paired: true, accessories: 1, keepsMacAwake: false),
            revisions: (structure: 1, values: 2)))

        let text = String(decoding: data, as: UTF8.self)
        for secret in [token, "192.168.31.57", "AA:BB:CC:DD:EE:FF"] { #expect(!text.contains(secret)) }
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["paired"] as? Bool == true)
        let row = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(row["specType"] as? String == schema.type)
        #expect(row["homeKitSupported"] as? Bool == true)
        #expect(row["lastError"] as? String == "timeout")
        let failures = try #require(row["homeKitReadFailures"] as? [[String: Any]])
        #expect(failures.count == 1)
        #expect(failures.first?["source"] as? String == "p:2:1 direct")
        #expect(failures.first?["status"] as? Int == -70402)
        let readings = try #require(row["readings"] as? [[String: Any]])
        #expect(readings.first { $0["id"] as? String == "p:2:1" }?["code"] as? Int == -4001)
        #expect(readings.first { $0["id"] as? String == "p:2:3" }?["value"] as? String == "9")
    }

    @Test("Without a mail app that takes attachments, the fallback link still addresses support with the subject and body")
    func mailtoFallback() throws {
        let body = "请描述遇到的问题：\n\n诊断文件 & 附件"
        let url = try #require(DiagnosticReport.mailtoURL(subject: "MijiaLAN 诊断信息 · 0.1.5 (6)", body: body))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == "contact@ipocket.xyz")
        #expect(components.queryItems?.first { $0.name == "subject" }?.value == "MijiaLAN 诊断信息 · 0.1.5 (6)")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == body)
        #expect(!url.absoluteString.contains(" "))
    }
}
