#if os(tvOS)
import SwiftUI

struct TVDeviceDetail: View {
    let home: TVHomePresentation
    let deviceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var error: String?
    @FocusState private var powerFocused: Bool
    private var item: TVDeviceItem? { home.items.first { $0.id == deviceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            if let item {
                HStack(spacing: 40) {
                    Image(systemName: item.symbol).font(.system(size: 110, weight: .light)).frame(width: 150)
                    TVSheetHeading(title: item.name, subtitle: "\(item.room) · \(item.status)")
                }.padding(.bottom, 18)
                Divider()
                TVInfoRow(title: "设备状态", value: item.online ? "在线" : "离线")
                if let on = item.isOn {
                    Button {
                        Task {
                            sending = true; error = nil
                            let succeeded = await home.setPower(id: deviceID, on: !on)
                            sending = false
                            if !succeeded { error = home.lastActionError ?? "设备暂时无法响应，请稍后重试。" }
                        }
                    } label: { TVActionLabel(title: sending ? "正在操作…" : (on ? "关闭设备" : "开启设备"), symbol: "power") }
                        .buttonStyle(TVFocusStyle(kind: .primary)).focusEffectDisabled().frame(width: 520)
                        .disabled(!item.online || sending).focused($powerFocused)
                        .accessibilityIdentifier("device.power")
                } else {
                    Text(item.online ? "这台设备没有可用的电源控制。" : "设备离线，恢复连接后可查看控制。")
                        .font(.system(size: 29)).foregroundStyle(TVTheme.secondary)
                }
                if let error { Text(error).font(.system(size: 27)).foregroundStyle(TVTheme.warning) }
            }
            Spacer(minLength: 0)
            Button("返回", action: { dismiss() }).font(.system(size: 29)).padding(20)
                .buttonStyle(TVFocusStyle()).focusEffectDisabled().accessibilityIdentifier("sheet.close")
        }.padding(.horizontal, 160).padding(.vertical, 100).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TVTheme.background).defaultFocus($powerFocused, true)
    }
}

struct TVPairingSheet: View {
    let home: TVHomePresentation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 42) {
            TVSheetHeading(title: "家庭配对", subtitle: home.isDesignPreview ? "界面预览，不会创建真实配对。" : "使用 iPhone 或 iPad 的「家庭」App。")
            if home.isDesignPreview {
                Label("示例：桥接已加入家庭", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 38)).foregroundStyle(TVTheme.sage)
            } else if home.paired {
                Label("桥接已加入家庭", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 38)).foregroundStyle(TVTheme.sage)
                Text("可以继续在「家庭」App 中查看和控制已连接的设备。")
                    .font(.system(size: 30)).foregroundStyle(TVTheme.secondary)
            } else if home.bridgeRunning, let code = home.tunnel.pairingCode {
                Text("在「家庭」中选择添加配件 → 更多选项，找到 MijiaLAN NE Experiment，再输入配对码。")
                    .font(.system(size: 30)).foregroundStyle(TVTheme.secondary)
                Text(code).font(.system(size: 82, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("配对码 \(code)").accessibilityIdentifier("pairing.code")
            } else {
                Text("请先开启家庭桥接，再查看配对信息。")
                    .font(.system(size: 32)).foregroundStyle(TVTheme.secondary)
            }
            Spacer(minLength: 0)
            Button("完成", action: { dismiss() }).font(.system(size: 32)).padding(.horizontal, 40).padding(.vertical, 24)
                .buttonStyle(TVFocusStyle(kind: .primary)).focusEffectDisabled().accessibilityIdentifier("sheet.close")
        }.padding(.horizontal, 160).padding(.vertical, 100).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TVTheme.background)
    }
}

struct TVConfigurationSheet: View {
    let home: TVHomePresentation
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var token = ""
    @State private var name = ""
    @State private var room = ""
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                TVSheetHeading(title: "配置局域网设备", subtitle: "先停止桥接，填写米家 Wi-Fi 设备的 IP 和 token。当前原型最多支持 4 台设备。")
                TextField("设备名称", text: $name).accessibilityIdentifier("configuration.name")
                TextField("房间，例如客厅", text: $room).accessibilityIdentifier("configuration.room")
                TextField("IP 地址，例如 192.168.1.50", text: $host).accessibilityIdentifier("configuration.host")
                SecureField("32 位局域网 token", text: $token).accessibilityIdentifier("configuration.token")
                if let error { Text(error).font(.system(size: 26)).foregroundStyle(TVTheme.warning) }
                HStack(spacing: 32) {
                    Button {
                        saveTask = Task {
                            error = nil
                            let saved = await home.tunnel.configureDevice(host: host, token: token, name: name, room: room, append: true)
                            guard !Task.isCancelled else { return }
                            if saved { token = ""; dismiss() } else { error = home.tunnel.message }
                        }
                    } label: { TVActionLabel(title: home.tunnel.busy ? "正在认证…" : "认证并保存") }
                        .buttonStyle(TVFocusStyle(kind: .primary)).focusEffectDisabled().frame(width: 420)
                        .disabled(home.tunnel.busy || home.tunnel.hasRunningService || host.isEmpty || token.isEmpty)
                        .accessibilityIdentifier("configuration.save")
                    Button("取消", action: { saveTask?.cancel(); token = ""; dismiss() }).padding(24)
                        .buttonStyle(TVFocusStyle()).focusEffectDisabled().accessibilityIdentifier("sheet.close")
                }.padding(.top, 12)
            }.font(.system(size: 30)).padding(.horizontal, 160).padding(.vertical, 90)
        }.background(TVTheme.background).scrollIndicators(.hidden)
            .onDisappear { saveTask?.cancel() }
    }
}

#endif
