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

    @Test("A report shows commands as sent, Home's view and held settings, and flags an ignored command and a tile without a main service")
    func commandsAndHome() throws {
        let model = "chunmi.health_pot.a1"
        let schema = try #require(DeviceSchema.bundled(model: model))
        let device = LocalDevice(did: "433", name: "养生壶", model: model, host: "192.168.1.199", token: "00112233445566778899aabbccddeeff")
        var s = DeviceSnapshot(device: device, schema: schema, capabilities: DeviceCapabilityCatalog.capabilities(schema: schema, model: model),
                               health: LANDeviceHealth(state: .online))
        s.readings["p:2:1"] = DeviceReading(value: .number(1), code: 0)
        s.prepared["p:2:3"] = .number(5)
        // The 2026-11-12 case: the start went out with a bare argument, got no reply, and reads went on working.
        var ignored = DeviceCommandRecord(at: Date(), source: .mac, capabilityID: "a:2:1",
                                          request: #"action {"aiid":1,"did":"433","in":[5],"siid":2}"#, statusBefore: 1)
        ignored.outcome = .failed; ignored.errorCode = "unanswered"; ignored.statusAfter = 1; ignored.onlineAfter = true
        var held = DeviceCommandRecord(at: Date(), source: .appleHome, capabilityID: "p:2:3", request: nil)
        held.outcome = .prepared; held.onlineAfter = true
        var link = LANLinkStats(since: Date())
        link.reads = 60; link.recentMilliseconds = [25, 118, 240, 307]
        let sensor = HomeKitBridgeController.PublishedService(key: "sensor:p:5:4", type: "Temperature Sensor", isPrimary: false, name: "温度", characteristics: [
            .init(type: "Current Temperature", source: "p:5:4 direct", value: .number(44), status: 0),
        ])
        let menu = HomeKitBridgeController.PublishedService(key: "control:p:2:3=5", type: "Switch", isPrimary: false, name: "下次菜单·保温", characteristics: [
            .init(type: "On", source: "p:2:3=5", value: .bool(true), status: 0),
        ])
        let data = try #require(DiagnosticReport.json(
            snapshots: [s], retryStates: [:], hidden: [], failures: [],
            bridge: .init(status: "running(port: 51826)", paired: true, accessories: 1, keepsMacAwake: false),
            revisions: (structure: 1, values: 2), commands: ["433": [held, ignored]],
            lan: ["433": LANDeviceDiagnostics(firmware: "2.1.8_0006", link: link)],
            home: ["433": [sensor, menu]], excludedServices: ["433": ["control:p:2:3=7"]]))

        let text = String(decoding: data, as: UTF8.self)
        for secret in ["00112233445566778899aabbccddeeff", "192.168.1.199"] { #expect(!text.contains(secret)) }
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let findings = try #require(json["findings"] as? [[String: Any]])
        #expect(findings.map { $0["kind"] as? String } == ["commandUnansweredWhileOnline", "noPrimaryHomeService"])
        #expect(findings[0]["request"] as? String == ignored.request)
        #expect(findings[1]["firstService"] as? String == "Temperature Sensor")
        #expect(findings[1]["switchesOn"] as? [String] == ["下次菜单·保温"])

        let row = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(row["firmware"] as? String == "2.1.8_0006")
        #expect(row["prepared"] as? [String: String] == ["p:2:3": "5"])
        let commands = try #require(row["commands"] as? [[String: Any]])
        #expect(commands.map { $0["source"] as? String } == ["appleHome", "mac"])
        #expect(commands[0]["request"] == nil)
        #expect(commands[1]["errorCode"] as? String == "unanswered")
        let linkRow = try #require(row["link"] as? [String: Any])
        #expect(linkRow["reads"] as? Int == 60)
        #expect(linkRow["p95Milliseconds"] as? Int == 307)
        let homeRow = try #require(row["home"] as? [String: Any])
        #expect(homeRow["excluded"] as? [String] == ["control:p:2:3=7"])
        let services = try #require(homeRow["services"] as? [[String: Any]])
        #expect(services.map { $0["primary"] as? Bool } == [false, false])
        #expect((services[1]["characteristics"] as? [[String: Any]])?.first?["value"] as? String == "true")
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
