import MijiaCore
import MijiaHomeKitBridge
import SwiftUI

struct SetupGuideProgress {
    private enum Status: String {
        case inProgress
        case dismissed
    }

    private static let key = "setup_guide_progress"
    let defaults: UserDefaults

    private var status: Status? {
        defaults.string(forKey: Self.key).flatMap(Status.init(rawValue:))
    }

    func shouldOpen(configuration: CredentialVault.Lookup) -> Bool {
        guard configuration != .unavailable else { return false }
        switch status {
        case .inProgress: return true
        case .dismissed: return false
        case nil: return configuration == .missing
        }
    }

    func begin() -> Bool {
        let firstOpening = status == nil
        defaults.set(Status.inProgress.rawValue, forKey: Self.key)
        return firstOpening
    }

    func dismiss() { defaults.set(Status.dismissed.rawValue, forKey: Self.key) }
}

struct SetupGuide: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: HomeKitBridgeController
    @ObservedObject var session: PanelSession
    let navigate: (ControlCenterRoute) -> Void
    let onFinish: () -> Void

    var body: some View {
        let home = SetupGuideHomeState(
            status: bridge.status, enabled: bridge.isEnabled, paired: bridge.isPaired,
            refreshingCode: bridge.isRefreshingSetupCode, accessories: bridge.exposedDeviceCount,
            uri: bridge.setupURI, code: bridge.setupCode
        )
        VStack(alignment: .leading, spacing: 14) {
            progress(imported: showsHome)
            if showsHome {
                SetupGuideHomeStep(bridge: bridge, state: home,
                                   manageDevices: { navigate(.settingsHomeKit) }, onFinish: onFinish)
                if case .completed = model.importState {
                    RememberImportedLoginControl(model: model)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text(L10n.tr("连接你的米家设备", "Connect Your Xiaomi Home Devices"))
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(L10n.tr("选择与手机「米家」App 一致的服务器地区，扫码导入已有设备。",
                             "Choose the same region as in the Xiaomi Home app on your phone, then scan to import your devices."))
                    .font(.callout).foregroundStyle(.secondary)
                DeviceImportCard(model: model, showsRegionPicker: true, requiresQRCode: true, onCancel: model.cancelImport,
                                 onViewDevices: { navigate(.settingsDevices) })
                if !model.config.devices.isEmpty {
                    Button(L10n.tr("用已导入的设备继续", "Continue with Existing Devices")) {
                        model.cancelImport()
                        session.setupGuideUsesExistingDevices = true
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
            if !showsHome || home != .paired {
                Button(L10n.tr("稍后设置", "Set Up Later"), action: onFinish)
                    .buttonStyle(.plain).foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 18)
    }

    private var showsHome: Bool {
        if case .completed(let count, _) = model.importState, count > 0 { return true }
        return session.setupGuideUsesExistingDevices && !model.config.devices.isEmpty
    }

    private func progress(imported: Bool) -> some View {
        HStack(spacing: 10) {
            Label(L10n.tr("导入米家设备", "Import Devices"), systemImage: imported ? "checkmark.circle.fill" : "1.circle.fill")
                .foregroundStyle(imported ? Color.green : Color.blue)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            Label(L10n.tr("家庭配对", "Pair with Home"), systemImage: "2.circle.fill")
                .foregroundStyle(imported ? Color.blue : Color.secondary)
        }
        .font(.callout.weight(.medium))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(imported ? L10n.tr("第 2 步，共 2 步，家庭配对", "Step 2 of 2, Pair with Home")
                                     : L10n.tr("第 1 步，共 2 步，导入米家设备", "Step 1 of 2, Import Devices"))
    }

}

enum SetupGuideHomeState: Equatable {
    case bridgeOff
    case preparing
    case refreshingCode
    case failed(String)
    case noAccessories
    case pairing(uri: String?, code: String)
    case paired

    init(status: HomeKitBridgeController.Status, enabled: Bool, paired: Bool,
         refreshingCode: Bool, accessories: Int, uri: String?, code: String?) {
        guard enabled else { self = .bridgeOff; return }
        if refreshingCode { self = .refreshingCode; return }
        switch status {
        case .running where paired:
            self = .paired
        case .failed(let message):
            self = .failed(message)
        case .running where accessories == 0:
            self = .noAccessories
        case .running:
            self = code.map { .pairing(uri: uri, code: $0) } ?? .preparing
        case .stopped, .waitingForDevices, .starting:
            self = .preparing
        }
    }
}

private struct SetupGuideHomeStep: View {
    let bridge: HomeKitBridgeController
    let state: SetupGuideHomeState
    let manageDevices: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state == .paired ? L10n.tr("家庭桥接已配对", "Home Bridge Paired") : L10n.tr("添加到 Apple「家庭」", "Add to Apple Home"))
                .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)

            SettingsGroup {
                VStack(spacing: 12) {
                    switch state {
                    case .bridgeOff:
                        Text(L10n.tr("开启家庭桥接后即可显示配对码。", "Enable the Home bridge to show its pairing code."))
                            .foregroundStyle(.secondary)
                        primaryButton(L10n.tr("启用家庭桥接", "Enable Home Bridge")) { bridge.isEnabled = true }
                    case .preparing:
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在准备家庭桥接…", "Preparing the Home bridge…"))
                        Text(L10n.tr("请保持 Mac 与设备连接同一局域网，并在 macOS 提示时允许本地网络访问。",
                                     "Keep your Mac and devices on the same local network. Allow local network access if macOS asks."))
                            .font(.caption).foregroundStyle(.secondary)
                    case .refreshingCode:
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在更新家庭配对码…", "Updating the Home pairing code…"))
                    case .failed(let message):
                        Label(L10n.tr("家庭桥接未能启动", "The Home Bridge Couldn’t Start"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        primaryButton(L10n.tr("重试", "Retry"), action: bridge.retryStart)
                    case .noAccessories:
                        Label(L10n.tr("暂时没有可加入「家庭」的设备", "No Devices Available to Add to Home"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        Text(L10n.tr("在「管理家庭设备」中查看设备支持情况，并选择要添加的设备。",
                                     "Open Manage Home Devices to check compatibility and select which devices to add."))
                            .foregroundStyle(.secondary)
                        primaryButton(L10n.tr("管理家庭设备", "Manage Home Devices"), action: manageDevices)
                    case .pairing(let uri, let code):
                        pairingInstructions(uri: uri, code: code)
                        Button(L10n.tr("重新获取家庭配对码", "Get a New Home Pairing Code"), action: bridge.refreshSetupCode)
                            .buttonStyle(.bordered)
                        if let error = bridge.setupCodeRefreshError {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    case .paired:
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 32)).foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text(L10n.tr("可以在 iPhone 或 iPad 的「家庭」中查看配件并分配房间。",
                                     "Open Home on your iPhone or iPad to see accessories and assign them to rooms."))
                            .foregroundStyle(.secondary)
                        primaryButton(L10n.tr("完成", "Done"), action: onFinish)
                    }
                }
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(16)
            }
        }
    }

    private func pairingInstructions(uri: String?, code: String) -> some View {
        VStack(spacing: 10) {
            Text(L10n.tr("在 iPhone 或 iPad 上打开「家庭」，点「+」→「添加配件」。",
                         "Open Home on your iPhone or iPad and tap + → Add Accessory."))
            HomePairingCode(uri: uri, code: code, size: 156)
            Text(L10n.tr("扫描二维码，或手动输入 8 位设置码。若提示「未认证配件」，选择「仍然添加」。",
                         "Scan the QR code or enter the 8-digit setup code. If Home shows an uncertified accessory warning, choose Add Anyway."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.tr("请让 Mac 和 iPhone 或 iPad 保持在同一局域网。", "Keep your Mac and iPhone or iPad on the same local network."))
                .font(.caption).foregroundStyle(.secondary)
            Label(L10n.tr("等待「家庭」配对", "Waiting for Home to Pair"), systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
    }
}

struct HomePairingCode: View {
    let uri: String?
    let code: String
    var size: CGFloat = 132

    var body: some View {
        VStack(spacing: 8) {
            if let uri, let image = QRCode.image(for: uri) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: size, height: size)
                    .padding(20).background(.white, in: .rect(cornerRadius: 8))
                    .accessibilityLabel(L10n.tr("家庭配对二维码", "Home pairing QR code"))
            }
            Text(code)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .accessibilityLabel(L10n.tr("家庭手动设置码 \(code)", "Home manual setup code \(code)"))
        }
    }
}
