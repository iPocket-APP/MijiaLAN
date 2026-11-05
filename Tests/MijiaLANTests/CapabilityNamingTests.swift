import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

/// Titles come from the shared vocabulary, then the spec's comments. Home and the Mac panel list a device's controls
/// side by side, so a title must say what it controls and no two may be alike.
struct CapabilityNamingTests {
    @Test("A spec comment gives its name, not the explanation or value list after it", arguments: [
        ("加热档位\n0-关\n1-小\n2-中", "加热档位"),
        ("夜灯App设置开关（用于智能夜灯设置）", "夜灯App设置开关"),
        ("电机反向 【 0: 正向（默认） 1: 反向】", "电机反向"),
        ("龙头默认模式开关；0：亮屏显示息屏前模式", "龙头默认模式开关"),
        ("获取日志数据；", "获取日志数据"),
        ("开启时长;关闭时长;日期;开始时间", "开启时长;关闭时长;日期;开始时间"),
        ("重置设备标志0云端待重置1设备待重置2云端设备都已重置", "重置设备标志"),
        ("按摩力度1挡", "按摩力度1挡"),
        ("地图类型 0:实时图 1:指哪图", "地图类型"),
        ("AI 识别开关 AI 识别开关关闭：脏污识别开关自动关闭", "AI 识别开关"),
        ("30%湿度", "30%湿度"),
    ])
    func comment(text: String, name: String) {
        #expect(CapabilityNames.comment(text) == name)
    }

    @Test("A placeholder comment is no name")
    func placeholder() {
        #expect(CapabilityNames.comment("null") == nil)
        #expect(CapabilityNames.comment("  ") == nil)
        #expect(CapabilityNames.comment(nil) == nil)
    }

    @Test("Repeated titles take the spec's own name, then the service's, then a number")
    func distinctTitles() throws {
        let titles = try L10n.$overrideLanguage.withValue(.zhHans) { try Dictionary(uniqueKeysWithValues: capabilities().map { ($0.id, $0.title) }) }
        // Keys of a wall switch: the comment names each one, and the service names each mode.
        #expect(titles["p:2:1"] == "左键")
        #expect(titles["p:3:1"] == "右键")
        #expect(titles["p:2:2"] == "左键模式")
        #expect(titles["p:3:2"] == "右键模式")
        #expect(titles["p:4:1"] == "左键按键模式")
        // A power switch outside the device's own service is the part it switches.
        #expect(titles["p:5:1"] == "照明")
        // Fridge chambers: specific comments first, otherwise the chamber.
        #expect(titles["p:6:1"] == "冷藏室")
        #expect(titles["p:6:2"] == "速冷模式")
        #expect(titles["p:6:3"] == "冷藏室温度")
        #expect(titles["p:7:3"] == "冷冻室温度")
        // Filters with nothing to tell them apart are numbered; a named kind keeps its name.
        #expect(titles["p:8:1"] == "滤芯寿命")
        #expect(titles["p:9:1"] == "滤芯寿命 2")
        #expect(titles["p:10:1"] == "新风滤芯寿命")
        #expect(titles["p:2:4"] == "电机反向")
    }

    @Test("Option explanations go unless they tell two options apart; a null comment falls back to the description")
    func optionTitles() throws {
        let status = try L10n.$overrideLanguage.withValue(.zhHans) { try #require(try capabilities().first { $0.id == "p:2:5" }) }
        #expect(L10n.$overrideLanguage.withValue(.zhHans) { status.options.map(\.title) } == ["待机", "充电中", "充电中(断点中)", "暂停", "故障"])
    }

    @Test("English titles are unique and never Chinese")
    func english() throws {
        let titles = try L10n.$overrideLanguage.withValue(.en) { try capabilities().map(\.title) }
        #expect(Set(titles).count == titles.count)
        #expect(!titles.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } })
        #expect(titles.contains("Light"))
    }

    @Test("Reviewed models keep their curated names; repeats only gain a number", arguments: DeviceSchema.bundledModels)
    func reviewed(model: String) throws {
        let schema = try #require(DeviceSchema.bundled(model: model))
        for language in [AppLanguage.zhHans, .en] {
            let titles = L10n.$overrideLanguage.withValue(language) {
                DeviceCapabilityCatalog.capabilities(schema: schema, model: model).map(\.title).filter { !$0.isEmpty }
            }
            #expect(Set(titles).count == titles.count, "\(model) \(language)")
        }
        if model == "chunmi.health_pot.a1" {
            let titles = L10n.$overrideLanguage.withValue(.zhHans) {
                Dictionary(uniqueKeysWithValues: DeviceCapabilityCatalog.capabilities(schema: schema, model: model).map { ($0.id, $0.title) })
            }
            #expect(titles["p:2:3"] == "菜单")
            #expect(titles["p:5:18"] == "菜单 2")
        }
    }

    private func capabilities() throws -> [DeviceCapability] {
        let schema = try JSONDecoder().decode(DeviceSchema.self, from: Data(Self.spec.utf8))
        return DeviceCapabilityCatalog.capabilities(schema: schema, model: "test.switch.naming")
    }

    private static func property(_ iid: Int, _ name: String, _ comment: String?, format: String = "bool", write: Bool = true, options: String = "") -> String {
        let comment = comment.map { #", "comment": "\#($0)""# } ?? ""
        let access = write ? #"["read", "write", "notify"]"# : #"["read", "notify"]"#
        let list = options.isEmpty ? "" : #", "value-list": [\#(options)]"#
        return #"{"iid": \#(iid), "type": "urn:miot-spec-v2:property:\#(name):00000001:test:1", "description": "\#(name)"\#(comment), "format": "\#(format)", "access": \#(access)\#(list)}"#
    }
    private static func service(_ iid: Int, _ name: String, _ description: String, _ properties: [String]) -> String {
        #"{"iid": \#(iid), "type": "urn:miot-spec-v2:service:\#(name):00007801:test:1", "description": "\#(description)", "properties": [\#(properties.joined(separator: ", "))]}"#
    }
    private static let modes = #"{"value": 0, "description": "Wired And Wireless", "comment": "有线和无线开关"}, {"value": 1, "description": "Wireless", "comment": "无线开关"}"#
    private static let spec = #"{"type": "urn:miot-spec-v2:device:switch:0000A003:test:1", "services": ["# + [
        service(2, "switch", "Left Switch Service", [
            property(1, "on", "左键"), property(2, "mode", "模式", format: "uint8", options: modes),
            property(4, "motor-reverse", "电机反向 【 0: 正向（默认） 1: 反向】"),
            property(5, "status", "状态", format: "uint8", write: false, options: #"""
                {"value": 0, "description": "Idle", "comment": "待机"}, {"value": 1, "description": "Charging", "comment": "充电中"},
                {"value": 2, "description": "Charging Breakpoint", "comment": "充电中(断点中)"}, {"value": 3, "description": "Pause", "comment": "null"},
                {"value": 4, "description": "Error", "comment": "故障（E1，见说明书）"}
                """#),
        ]),
        service(3, "switch", "Right Switch Service", [property(1, "on", "右键"), property(2, "mode", "模式", format: "uint8", options: modes)]),
        service(4, "switch-sensor", "Left Switch Sensor", [property(1, "mode", "模式", format: "uint8", options: modes)]),
        service(5, "light", "Light", [property(1, "on", "开关")]),
        service(6, "fridge-chamber", "Refrigerating Chamber", [
            property(1, "on", nil), property(2, "mode", "速冷模式"), property(3, "temperature", "温度", format: "float", write: false),
        ]),
        service(7, "fridge-chamber", "Freezing Chamber", [
            property(1, "on", "开关"), property(2, "mode", "速冻模式"), property(3, "temperature", "温度", format: "float", write: false),
        ]),
        service(8, "filter", "Filter", [property(1, "filter-life-level", "滤芯剩余寿命", format: "uint8", write: false)]),
        service(9, "filter", "Filter", [property(1, "filter-life-level", "滤芯剩余寿命", format: "uint8", write: false)]),
        service(10, "filter", "Fresh Air Filter", [property(1, "filter-life-level", "滤芯剩余寿命", format: "uint8", write: false)]),
    ].joined(separator: ", ") + "]}"
}
