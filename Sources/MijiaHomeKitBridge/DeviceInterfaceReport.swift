import Foundation
import MijiaCore
import MijiaLAN

public enum DeviceInterfaceReport {
    /// Generated from the same catalog and Home plan used at runtime; contains no device credentials.
    @MainActor public static func markdown() -> String {
        let devices = DeviceSchema.bundledModels.enumerated().map { index, model in
            LocalDevice(did: String(index + 100), name: model, model: model, host: "", token: "")
        }
        let config = LocalHomeConfig(devices: devices)
        let api = LANMiotAPI(config: { config })
        let controller = DeviceController(api: api, config: { config })
        let home = controller.synthesizedHome()
        var lines = ["# 设备接口矩阵", "", "由 `mijia-lan matrix` 根据运行时能力目录生成。10 个型号；cuco.plug.v3 的两台设备复用同一适配。", "",
            "规格和协议测试不能证明固件已支持局域网接口。下列实机状态统一保持待验证；本机读取证据另见验收报告。待确认字段不发送猜测命令。", "",
            "MIoT 编号以服务和属性／动作定位；数值是设备原始单位。动作参数严格依规格 in 顺序，out 定义保留。Home 无适合控件的读数留在 Mac。", ""]
        for device in devices {
            guard let s = controller.snapshots[device.did] else { continue }
            var ids: [String: UInt64] = [:]
            let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: home.devices.first { $0.id == s.id }, names: [:], identifiers: &ids)
            lines += ["## \(device.model)", "", "规格：`\(s.schema.type)`。Home 服务 \(plan.services.count) 个。", "",
                "| 接口 | 类型／权限／范围 | 实际协议与参数 | 状态反馈 | Mac | Home | 验证状态 |",
                "|---|---|---|---|---|---|---|"]
            for c in s.capabilities {
                let bounds = c.range.map { $0.map { String($0) }.joined(separator: " / ") } ?? ""
                let options = c.options.map { "\($0.value)=\($0.title)" }.joined(separator: "、")
                let access = (c.readable ? "R" : "") + (c.writable ? "W" : "") + (c.prepared ? " 待应用" : "")
                let protocolText: String
                if c.kind == .action, let legacy = LegacyMiioProfile.forModel(device.model) {
                    protocolText = legacy.action(siid: c.siid, aiid: c.iid).map { $0.methods.joined(separator: " → ") + "（旧 miIO）" } ?? "旧 miIO 映射待确认"
                } else if c.kind == .action {
                    protocolText = "action \(c.siid).\(c.iid), in=\(c.inputs), out=\(c.outputs)"
                } else if let legacy = LegacyMiioProfile.forModel(device.model) {
                    if let property = legacy.property(siid: c.siid, piid: c.iid) {
                        let argument: String = switch property.write {
                        case .onOff: "on/off 字符串"
                        case .value, nil: "数字"
                        case .string: "文本"
                        case .integer: "整数"
                        case .values(let table): table.sorted { $0.value < $1.value }.map { "\($0.value)→\($0.key)" }.joined(separator: ",")
                        case .boolChoice(let on, let off): "\(on.compactJSONString)/\(off.compactJSONString)"
                        case .methodSwitch(let on, let off): "\(on)/\(off)"
                        }
                        protocolText = (legacy.statusMethod.map { "\($0) → \(property.name)" } ?? "get_prop [\(property.name)]") + "; " + (property.setter.map { "\($0) [\(argument)\(property.setterSuffix.isEmpty ? "" : ", " + property.setterSuffix.map(\.compactJSONString).joined(separator: ", "))]" } ?? "只读")
                            + (legacy.source == .verified ? "" : "（hass-xiaomi-miot 映射）")
                    } else { protocolText = "旧 miIO 映射待确认" }
                } else if c.prepared && !c.writable && !c.readable {
                    protocolText = "仅作为 action in 参数 \(c.siid).\(c.iid)，不读写属性"
                } else {
                    protocolText = ([c.readable ? "get_properties" : nil, c.writable ? "set_properties" : nil].compactMap { $0 }.joined(separator: " / ")) + " \(c.siid).\(c.iid)"
                }
                let cleaningSwitch = plan.bindings.values.contains { binding in
                    if case .cleaning(let start, let dock, _) = binding { [start, dock].contains(c.id) } else { false }
                }
                let kettleMenus = plan.bindings.values.contains { binding in
                    if case .kettleMenu(let start, let stop, let mode, _) = binding { [start, stop, mode].contains(c.id) } else { false }
                }
                // A characteristic of a Home service is native; one on a Switch service is a named switch.
                var native = device.model == "lumi.acpartner.mcn02" && [2, 3].contains(c.siid), switches = false
                for service in plan.services {
                    for characteristic in service.characteristics {
                        switch plan.bindings[characteristic.iid] {
                        case .property(let id, _)?, .option(let id, _)?, .action(let id)?:
                            guard id == c.id else { continue }
                            if service.type == .switch { switches = true } else { native = true }
                        default: continue
                        }
                    }
                }
                let feedback = c.prepared ? "待选值独立保存；运行后读实际状态" : c.readable ? "逐属性返回码＋回读＋时间" : c.kind == .action ? "动作返回码＋运行状态确认" : "接受回执；完成状态待确认"
                let mac = [DeviceCapability.Control.toggle: "开关", .number: "精确输入", .choice: "选项", .button: "动作按钮", .reading: "实际读数", .unsupported: "待确认清单"][c.control] ?? ""
                let home = cleaningSwitch ? "清扫开关（开=开始清扫，关=回充）"
                    : kettleMenus ? "菜单开关（开=用该菜单开始，关=停止该菜单；火力、自选只在 Mac）" : !native && !switches ? "Mac 保留"
                    : native && switches ? "原生服务＋具名开关" : native ? "原生服务"
                    : c.kind == .action || c.control == .button ? "回弹按钮"
                    : c.control == .number ? "精选预设开关" : c.control == .choice ? "具名选项开关" : "具名开关"
                let evidence = c.limitation ?? (c.control == .unsupported ? "规格保留；未启用" : "规格已核对；自动化协议测试；实机待验证")
                lines.append("| \(c.id) \(clean(c.displayTitle)) | \(c.format) \(access) \(bounds) \(clean(options)) \(c.displayUnit) | \(clean(protocolText)) | \(feedback) | \(mac) | \(home) | \(clean(evidence)) |")
            }
            lines += ["", "不纳入日常控制：设备信息、恢复出厂、工程自检、固件／日志维护、未解析复合计划。原始规格完整保存在 `Sources/MijiaLAN/Resources/Specs/\(device.model).json`。", ""]
        }
        lines += ["## 兼容与证据边界", "", "- 空调 Home 当前温度来自目标温度占位，不属于实测室温。", "- 风扇速度读写百分比风速（p28 为 8.1），挡位 2.2 由同一滑块覆盖，不再单列；仅有挡位时滑块按挡位等分。智能风对应 Home 的「自动」，童锁并入风扇服务；0% 只关闭电源。", "- 数值属性只以审核过的预设进入 Home，不再生成最小值、最大值和加减开关；摇头角度留在 Mac。未内置型号的厂商私有字段只在 Mac 显示。", "- 净化器速度读写最爱档位，调节时同时切到最爱模式；空调风速挡位合为速度滑块，滑块最低为自动。童锁并入风扇、净化器、暖风机、空调和加湿器服务。浴霸按 homebridge-miot 映射为只制热的暖风机：开关读写暖风，没有暖风开关时读写「暖风」模式；灯为带亮度的灯泡；设定温度超过 38 °C 的留在 Mac，完全没有温度的以暖风开关为主控件。", "- 未内置型号只为日常控件生成开关：设置类（提示音、指示灯、屏幕、童锁、延时、勿扰、开发者模式等）和超过 6 项的选项留在 Mac，附加开关每台最多 10 个；只有「关闭」和另一项的选项合为一个开关。内置型号保留审核过的开关。", "- 名称取规格注释的首个名称，不带说明和取值列表；同一设备内名称不重复：先用注释里的具体名称，再加服务限定（左键、冷藏室、新风），仍重复时编号。设备主服务以外的电源开关以所在部件命名，如浴霸的「照明」。内置型号保留审核过的名称，只在重复时编号。", "- 配件标识和服务名称独立持久化；离线不会删除控件。", "- cuco 电量原始值的说明为 0.01 kWh；普通与扩展字段分别保留。未声明单位的厂商数值仍显示原始值。", "- 接受回执和状态确认分开记录。非幂等动作不会自动重发。", ""]
        return lines.joined(separator: "\n")
    }
    private static func clean(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "／").replacingOccurrences(of: "\n", with: " ") }
}
