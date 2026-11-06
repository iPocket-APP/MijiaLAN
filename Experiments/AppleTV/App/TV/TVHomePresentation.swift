#if os(tvOS)
import Foundation
import Observation
import TVPrototypeKit

struct TVDeviceItem: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var room: String
    var symbol: String
    var online: Bool
    var isOn: Bool?
    var detail: String?

    var status: String {
        guard online else { return "离线" }
        return detail ?? isOn.map { $0 ? "已开启" : "已关闭" } ?? "已连接"
    }

    static func symbol(for model: String) -> String {
        if model.contains("airpurifier") { return "air.purifier" }
        if model.contains("light") || model.contains("lamp") { return "lamp.desk" }
        if model.contains("fan") { return "fan" }
        if model.contains("vacuum") { return "robotic.vacuum" }
        if model.contains("humidifier") { return "humidifier" }
        if model.contains("kettle") { return "mug" }
        if model.contains("cooker") { return "oven" }
        return "powerplug" }
}

/// A scene-owned presentation adapter. Its injected TunnelModel identity is stable for the
/// scene lifetime; all live state remains owned by that model, not copied into UI samples.
@Observable @MainActor
final class TVHomePresentation {
    let tunnel: TunnelModel
    let isDesignPreview: Bool
    var previewBridgeEnabled = true
    var lastActionError: String?
    private var samples: [TVDeviceItem] = [
        .init(id: "preview-lamp", name: "台灯", room: "卧室", symbol: "lamp.desk", online: true, isOn: true),
        .init(id: "preview-purifier", name: "净化器", room: "客厅", symbol: "air.purifier", online: true, isOn: true, detail: "自动"),
        .init(id: "preview-plug", name: "插座", room: "客厅", symbol: "powerplug", online: true, isOn: false),
        .init(id: "preview-fan", name: "循环扇", room: "卧室", symbol: "fan", online: true, isOn: false),
        .init(id: "preview-humidifier", name: "加湿器", room: "卧室", symbol: "humidifier", online: true, isOn: true),
        .init(id: "preview-vacuum", name: "扫地机器人", room: "客厅", symbol: "robotic.vacuum", online: true, isOn: false),
        .init(id: "preview-cooker", name: "电饭煲", room: "厨房", symbol: "oven", online: true, isOn: false),
        .init(id: "preview-light", name: "落地灯", room: "客厅", symbol: "lamp.floor", online: true, isOn: true),
        .init(id: "preview-socket", name: "空调插座", room: "卧室", symbol: "powerplug", online: true, isOn: false),
        .init(id: "preview-kettle", name: "养生壶", room: "厨房", symbol: "mug", online: false, isOn: nil),
        .init(id: "preview-fryer", name: "空气炸锅", room: "厨房", symbol: "oven", online: false, isOn: nil)
    ]

    init(tunnel: TunnelModel, isDesignPreview: Bool) {
        self.tunnel = tunnel; self.isDesignPreview = isDesignPreview
    }

    var hasFreshSession: Bool {
        guard tunnel.hasRunningService, let evidence = tunnel.evidence, evidence.stoppedAt == nil else { return false }
        return Date().timeIntervalSince(evidence.updatedAt) < 15
    }
    var bridgeRunning: Bool {
        isDesignPreview ? previewBridgeEnabled : hasFreshSession && tunnel.evidence?.bridgeStatus == "running"
    }
    var paired: Bool { isDesignPreview ? previewBridgeEnabled : bridgeRunning && tunnel.evidence?.paired == true }
    var foreground: Bool { !isDesignPreview && tunnel.hasRunningService && tunnel.evidence?.executor != .networkExtension }
    var items: [TVDeviceItem] {
        if isDesignPreview { return samples }
        let evidence = tunnel.evidence?.devices ?? []
        return tunnel.configuration.home.devices.map { device in
            let reading = evidence.first { $0.id == device.did }
            let room = device.roomName ?? (tunnel.configuration.fixture ? "模拟设备" : "未分组")
            return TVDeviceItem(id: device.did, name: device.name, room: room,
                symbol: TVDeviceItem.symbol(for: device.model), online: hasFreshSession && reading?.online == true,
                isOn: reading?.isOn)
        }
    }
    var onlineCount: Int { items.filter(\.online).count }
    var offlineCount: Int { items.count - onlineCount }
    var countText: String {
        if !isDesignPreview && !tunnel.hasRunningService { return "\(items.count) 台设备已配置" }
        return "\(onlineCount) 台设备在线" + (offlineCount > 0 ? " · \(offlineCount) 台离线" : "")
    }
    var title: String {
        if bridgeRunning { return foreground ? "前台桥接已开启" : "家庭桥接已开启" }
        if tunnel.busy { return "正在连接家庭桥接" }
        if hasFreshSession, tunnel.evidence?.bridgeStatus.hasPrefix("failed:") == true { return "家庭桥接需要处理" }
        return "家庭桥接未开启"
    }
    var subtitle: String {
        if isDesignPreview { return previewBridgeEnabled ? "米家设备已连接到家庭。" : "开启桥接，让设备连接到家庭。" }
        if foreground { return "模拟器前台预览，切后台后停止。" }
        if paired { return "米家设备已连接到家庭。" }
        if bridgeRunning { return "用 iPhone 的「家庭」App 添加桥接。" }
        return "连接局域网中的米家设备。"
    }
    var contextLabel: String? {
        if isDesignPreview { return "界面预览 · 示例数据" }
        if tunnel.configuration.fixture { return foreground ? "模拟设备 · 前台预览" : "模拟设备" }
        return nil
    }
    var pairingAvailable: Bool { bridgeRunning && (isDesignPreview || paired || tunnel.pairingCode != nil) }

    func collectDiagnostics() async {
        if !isDesignPreview { await tunnel.collectDiagnostics(); return }
        let now = Date()
        let rows = items.map { item -> PrototypeDiagnostics.Device in
            var row = PrototypeDiagnostics.Device(did: item.id, name: item.name, model: "demo.\(item.symbol)",
                health: item.online ? "online" : "offline")
            if let on = item.isOn {
                row.readings = [.init(id: "power", name: "电源", value: on ? "true" : "false", code: 0,
                    updatedAt: now, available: item.online)]
            }
            if item.online { row.lastSeen = now } else { row.lastError = "示例：设备离线" }
            return row
        }
        await tunnel.collectDiagnostics(preview: .init(source: .designPreview, fixture: true,
            bridge: previewBridgeEnabled ? "running" : "stopped", paired: previewBridgeEnabled,
            accessories: items.count, devices: rows))
    }

    func toggleBridge() async {
        lastActionError = nil
        if isDesignPreview { previewBridgeEnabled.toggle(); return }
        if tunnel.hasRunningService { await tunnel.stop(); return }
        #if targetEnvironment(simulator)
        await tunnel.startSimulatorForeground()
        #else
        await tunnel.startExtension()
        #endif
        if !tunnel.hasRunningService { lastActionError = tunnel.message }
    }
    func setPower(id: String, on: Bool) async -> Bool {
        lastActionError = nil
        if isDesignPreview {
            guard let i = samples.firstIndex(where: { $0.id == id }), samples[i].online else { return false }
            samples[i].isOn = on; samples[i].detail = nil
            return true
        }
        let succeeded = await tunnel.request(.power(did: id, on: on))
        if !succeeded { lastActionError = tunnel.message }
        return succeeded
    }
}
#endif
