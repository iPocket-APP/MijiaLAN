#if os(tvOS)
import SwiftUI

struct TVDevicesPage: View {
    let home: TVHomePresentation
    let openDevice: (String) -> Void
    let configure: () -> Void
    @State private var filter = "全部"
    @FocusState private var filterFocus: String?
    private var filters: [String] { ["全部"] + Set(home.items.map(\.room)).sorted() + ["离线"] }
    private var filtered: [TVDeviceItem] {
        home.items.filter { filter == "全部" || (filter == "离线" ? !$0.online : $0.room == filter) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            HStack(alignment: .firstTextBaseline) {
                Text("设备").font(.system(size: 64, weight: .semibold)).accessibilityIdentifier("devices.title")
                Spacer()
                if !home.isDesignPreview {
                    Button(action: configure) { TVActionLabel(title: "配置设备", symbol: "plus") }
                        .buttonStyle(TVFocusStyle()).focusEffectDisabled().frame(width: 340)
                        .disabled(home.tunnel.busy || home.tunnel.hasRunningService)
                        .accessibilityIdentifier("devices.configure")
                }
            }
            HStack(spacing: 16) {
                ForEach(filters, id: \.self) { room in
                    Button { filter = room } label: { Text(room).font(.system(size: 28)).padding(.vertical, 16).padding(.horizontal, 26) }
                        .buttonStyle(TVFocusStyle(kind: .navigation(selected: filter == room))).focusEffectDisabled()
                        .focused($filterFocus, equals: room)
                        .accessibilityIdentifier("devices.filter.\(room)")
                }
            }.focusSection().defaultFocus($filterFocus, "全部")
            if filtered.isEmpty {
                ContentUnavailableView("没有符合条件的设备", systemImage: "square.grid.2x2", description: Text("试试其他房间或查看全部设备。"))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 28) {
                        ForEach(filtered) { item in
                            Button { openDevice(item.id) } label: {
                                HStack(spacing: 28) {
                                    Image(systemName: item.symbol).font(.system(size: 54, weight: .light)).frame(width: 72)
                                    VStack(alignment: .leading, spacing: 14) {
                                        Text(item.name).font(.system(size: 36, weight: .semibold))
                                        Text("\(item.room) · \(item.status)").font(.system(size: 27)).opacity(0.67)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(32).frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
                            }.buttonStyle(TVFocusStyle(kind: .tile)).focusEffectDisabled()
                                .accessibilityIdentifier("devices.item.\(item.id)")
                        }
                    }.padding(10)
                }.scrollIndicators(.hidden).focusSection()
            }
        }.padding(.horizontal, 90).padding(.top, 80).padding(.bottom, 60)
    }
}

struct TVBridgePage<Focus: Hashable>: View {
    let home: TVHomePresentation
    let actionFocus: FocusState<Focus?>.Binding
    let actionValue: Focus
    let pair: () -> Void
    let diagnostics: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 42) {
                Text("家庭桥接").font(.system(size: 64, weight: .semibold)).accessibilityIdentifier("bridge.title")
                HStack(alignment: .top, spacing: 64) {
                    TVBridgeGlyph(running: home.bridgeRunning, size: 150)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(home.title).font(.system(size: 44, weight: .semibold))
                        Text(home.subtitle).font(.system(size: 29)).foregroundStyle(TVTheme.secondary)
                        Text(home.countText).font(.system(size: 28)).foregroundStyle(TVTheme.secondary)
                    }.padding(.top, 10)
                }
                VStack(spacing: 0) {
                    TVInfoRow(title: "家庭状态", value: home.paired ? "已加入家庭" : (home.bridgeRunning ? "等待配对" : "等待开启"))
                    Divider()
                    TVInfoRow(title: "运行方式", value: home.isDesignPreview ? "界面预览" : (home.foreground ? "前台预览" : (home.bridgeRunning ? "后台扩展" : "未启动")))
                }
                HStack(spacing: 28) {
                    Button { Task { await home.toggleBridge() } } label: {
                        TVActionLabel(title: home.tunnel.busy ? "正在处理…" : (home.bridgeRunning || home.tunnel.hasRunningService ? "停止桥接" : "开启桥接"),
                                      symbol: home.bridgeRunning || home.tunnel.hasRunningService ? "stop" : "power")
                    }.buttonStyle(TVFocusStyle(kind: .primary)).focusEffectDisabled().frame(width: 400)
                        .focused(actionFocus, equals: actionValue).disabled(home.tunnel.busy)
                        .accessibilityIdentifier("bridge.toggle")
                    Button(action: pair) { TVActionLabel(title: "配对信息", symbol: "iphone") }
                        .buttonStyle(TVFocusStyle()).focusEffectDisabled().frame(width: 330)
                        .disabled(!home.pairingAvailable).accessibilityIdentifier("bridge.pairing")
                }.focusSection()
                if let error = home.lastActionError {
                    Text(error).font(.system(size: 27)).foregroundStyle(TVTheme.warning).fixedSize(horizontal: false, vertical: true)
                }
                #if targetEnvironment(simulator)
                Text("模拟器使用前台预览；切后台后停止。后台扩展需要对应平台的真机。")
                    .font(.system(size: 26)).foregroundStyle(TVTheme.secondary)
                #endif
                Button(action: diagnostics) {
                    Text("查看诊断信息").font(.system(size: 27)).padding(.vertical, 18).padding(.horizontal, 12)
                }.buttonStyle(TVFocusStyle()).focusEffectDisabled().accessibilityIdentifier("bridge.diagnostics")
            }.padding(.horizontal, 100).padding(.vertical, 80)
        }.scrollIndicators(.hidden)
    }
}

struct TVSettingsPage: View {
    let home: TVHomePresentation
    let configure: () -> Void
    let diagnostics: () -> Void
    let updates: () -> Void
    let updateAvailable: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("设置").font(.system(size: 64, weight: .semibold)).accessibilityIdentifier("settings.title")
                VStack(spacing: 0) {
                    TVInfoRow(title: "设备来源", value: home.isDesignPreview ? "示例数据" : (home.tunnel.configuration.fixture ? "模拟设备" : "局域网设备"))
                    Divider()
                    TVInfoRow(title: "连接方式", value: "本地网络")
                }
                if !home.isDesignPreview {
                    Button(action: configure) { TVActionLabel(title: "配置局域网设备", symbol: "plus") }
                        .buttonStyle(TVFocusStyle(kind: .primary)).focusEffectDisabled().frame(width: 540)
                        .disabled(home.tunnel.busy || home.tunnel.hasRunningService).accessibilityIdentifier("settings.configure")
                    Button { home.tunnel.selectFixture() } label: { TVActionLabel(title: "使用模拟设备", symbol: "play.rectangle") }
                        .buttonStyle(TVFocusStyle()).focusEffectDisabled().frame(width: 540)
                        .disabled(home.tunnel.busy || home.tunnel.hasRunningService).accessibilityIdentifier("settings.fixture")
                    Button { home.tunnel.autoReconnect.toggle() } label: {
                        HStack {
                            Text("自动重连")
                            Spacer()
                            Text(home.tunnel.autoReconnect ? "已开启" : "已关闭").opacity(0.7)
                        }.font(.system(size: 31)).padding(28)
                    }.buttonStyle(TVFocusStyle(kind: .tile)).focusEffectDisabled()
                        .disabled(home.tunnel.busy || home.tunnel.hasRunningService).accessibilityIdentifier("settings.reconnect")
                    Text("更改设备或自动重连前，请先停止桥接。设备密钥仅保存在本机实验钥匙串。")
                        .font(.system(size: 26)).foregroundStyle(TVTheme.secondary)
                }
                Button(action: diagnostics) { TVActionLabel(title: "诊断信息", symbol: "waveform.path.ecg") }
                    .buttonStyle(TVFocusStyle()).focusEffectDisabled().frame(width: 440)
                    .accessibilityIdentifier("settings.diagnostics")
                Button(action: updates) {
                    TVActionLabel(title: updateAvailable ? "软件更新 · 发现新版本" : "检查更新", symbol: "arrow.down.circle")
                }.buttonStyle(TVFocusStyle()).focusEffectDisabled().frame(width: 600)
                    .accessibilityIdentifier("settings.updates")
                if !home.isDesignPreview {
                    Text(home.tunnel.message).font(.system(size: 26)).foregroundStyle(TVTheme.secondary)
                }
                Text("MijiaLAN · tvOS 0.1\n米家局域网控制与 HomeKit 桥接")
                    .font(.system(size: 25)).foregroundStyle(TVTheme.secondary).padding(.top, 18)
            }.padding(.horizontal, 100).padding(.vertical, 80)
        }.scrollIndicators(.hidden).focusSection()
    }
}
#endif
