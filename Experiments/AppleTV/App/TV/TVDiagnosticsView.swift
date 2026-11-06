#if os(tvOS)
import SwiftUI
import TVPrototypeKit

struct TVDiagnosticsView: View {
    let home: TVHomePresentation
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDeviceID: String?
    @State private var expandedReading: String?
    @State private var expandedFailure: UUID?
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case back, generate, device(String), reading(String), failure(UUID) }
    private var report: PrototypeDiagnostics? { home.tunnel.diagnosticsReport }
    private var device: PrototypeDiagnostics.Device? { report?.devices.first { $0.did == selectedDeviceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 38) {
            HStack(spacing: 36) {
                Button(action: goBack) { Label("返回", systemImage: "chevron.left").font(.system(size: 28)).padding(20) }
                    .buttonStyle(TVFocusStyle()).focusEffectDisabled().focused($focus, equals: .back)
                    .accessibilityIdentifier("diagnostics.back")
                Text(device?.name ?? "诊断与报告").font(.system(size: 60, weight: .semibold))
                    .accessibilityIdentifier("diagnostics.title")
                Spacer()
                Text(sourceLabel).font(.system(size: 26)).foregroundStyle(TVTheme.secondary)
                    .accessibilityIdentifier("diagnostics.source")
            }
            HStack(alignment: .top, spacing: 70) {
                Group {
                    if let device { deviceSummary(device) } else { summary }
                }.frame(width: 610, alignment: .leading).frame(maxHeight: .infinity, alignment: .top).focusSection()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let device { deviceReadings(device) } else { deviceList }
                    }.padding(12)
                }.scrollIndicators(.hidden).frame(maxWidth: .infinity, maxHeight: .infinity).focusSection()
            }
        }.padding(.horizontal, 90).padding(.vertical, 65)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TVTheme.background).preferredColorScheme(.dark)
            .defaultFocus($focus, .generate)
            .onExitCommand(perform: goBack)
            .onChange(of: report?.id) { selectedDeviceID = nil; focus = .generate }
    }

    private var sourceLabel: String {
        guard let report else { return home.isDesignPreview ? "示例预览 · 未发起设备通信" : "等待生成诊断报告" }
        switch report.source {
        case .designPreview: return "示例报告 · 未发起设备通信"
        case .liveRuntime: return report.fixture ? "运行时采集 · 模拟设备" : "运行时采集 · 局域网设备"
        case .savedRuntime: return "历史记录 · 非当前状态"
        case .notRunning: return "服务未运行 · 属性尚未检查"
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接与桥接").font(.system(size: 36, weight: .semibold))
            info("VPN", home.isDesignPreview ? "未启动（示例）" : home.tunnel.vpnStatus)
            if let report {
                info("设备在线", "\(report.onlineCount) / \(report.devices.count)")
                info("读取异常", "\(report.failedReadingCount) 项")
                info("HomeKit 失败属性", "\(report.homeKitFailureCount) 项")
                Text("采集于 \(report.recordedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 25)).foregroundStyle(TVTheme.secondary)
            } else if let evidence = home.tunnel.evidence, !home.isDesignPreview {
                info("设备通信", "读 \(evidence.authenticatedReads) · 写 \(evidence.acknowledgedWrites)")
                info("后台通信", "读 \(evidence.backgroundReads) · 写 \(evidence.backgroundWrites)")
            }
            Button { Task { await home.collectDiagnostics() } } label: {
                TVActionLabel(title: home.tunnel.diagnosticsBusy ? "正在读取设备…" : (home.isDesignPreview ? "生成示例报告" : "生成诊断报告"), symbol: "doc.text.magnifyingglass")
            }.buttonStyle(TVFocusStyle(kind: .primary)).focusEffectDisabled()
                .focused($focus, equals: .generate).disabled(home.tunnel.busy || home.tunnel.diagnosticsBusy)
                .accessibilityIdentifier("diagnostics.generate")
            Text(home.tunnel.diagnosticsMessage).font(.system(size: 26)).foregroundStyle(TVTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("diagnostics.result")
            if let error = report?.collectionError {
                Text("采集提示：\(error)").font(.system(size: 25)).foregroundStyle(TVTheme.warning)
            }
            Text("报告包含设备名称与读数，不含 token、IP、MAC 地址或配对密钥。生成后可从本机预览下载；真机可通过设备工具取出。")
                .font(.system(size: 23)).foregroundStyle(TVTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var deviceList: some View {
        if let report {
            VStack(alignment: .leading, spacing: 12) {
                Text("桥接：\(bridgeStatus(report.bridge)) · \(report.paired ? "已配对" : "未配对")")
                    .font(.system(size: 28, weight: .medium)).accessibilityIdentifier("diagnostics.bridge")
                if let runtime = report.runtime {
                    Text("\(runtime.executor.rawValue) · \(runtime.transportKind ?? "未知传输")")
                    Text("认证通信：读 \(runtime.authenticatedReads) · 写 \(runtime.acknowledgedWrites) · 失败 \(runtime.transportFailures)")
                    Text("后台通信：读 \(runtime.backgroundReads) · 写 \(runtime.backgroundWrites)")
                }
                if let activation = report.activation, let domain = activation.errorDomain {
                    Text("扩展最近启动记录：\(activation.stage) · \(domain) / \(activation.errorCode ?? 0)")
                }
            }.font(.system(size: 24)).foregroundStyle(TVTheme.secondary).padding(.bottom, 22)
            Text("设备详情").font(.system(size: 36, weight: .semibold)).padding(.bottom, 12)
            ForEach(report.devices) { item in
                Button {
                    selectedDeviceID = item.did; expandedReading = nil; expandedFailure = nil; focus = .back
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(item.name).font(.system(size: 34, weight: .semibold)); Spacer(); Text(health(item.health)).font(.system(size: 26)) }
                        Text("读取异常 \(item.failedReadings) · HomeKit 失败 \(item.homeKitReadFailures.count)")
                            .font(.system(size: 25)).opacity(0.68)
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(TVFocusStyle(kind: .tile)).focusEffectDisabled().focused($focus, equals: .device(item.did))
                    .accessibilityIdentifier("diagnostics.device.\(item.did)")
            }
        } else {
            ContentUnavailableView("查看设备读数与失败原因", systemImage: "stethoscope",
                description: Text("生成报告后，可逐台查看设备重试状态、属性读数和 HomeKit 读取失败项。"))
                .frame(maxWidth: .infinity, minHeight: 500)
        }
    }

    private func deviceSummary(_ device: PrototypeDiagnostics.Device) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(device.model).font(.system(size: 30)).foregroundStyle(TVTheme.secondary)
            TVInfoRow(title: "连接状态", value: health(device.health))
            TVInfoRow(title: "最近在线", value: device.lastSeen?.formatted(date: .omitted, time: .standard) ?? "无记录")
            TVInfoRow(title: "连续重试失败", value: device.retryFailures.map { String($0) } ?? "未采集")
            TVInfoRow(title: "下次重试", value: device.isProbing == true ? "正在探测" : (device.nextRetryAt?.formatted(date: .omitted, time: .standard) ?? "无计划"))
            TVInfoRow(title: "家庭桥接", value: device.homeIncluded ? "已包含" : "未包含")
            if let error = device.lastError {
                Text(error).font(.system(size: 27)).foregroundStyle(TVTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("按确认可展开属性值或失败来源；完整数据保存在诊断报告中。")
                .font(.system(size: 25)).foregroundStyle(TVTheme.secondary)
        }
    }

    @ViewBuilder private func deviceReadings(_ device: PrototypeDiagnostics.Device) -> some View {
        if !device.homeKitReadFailures.isEmpty {
            Text("HomeKit 读取失败").font(.system(size: 34, weight: .semibold))
            ForEach(device.homeKitReadFailures) { failure in
                Button { expandedFailure = expandedFailure == failure.id ? nil : failure.id } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("服务 \(failure.service) · 属性 \(failure.characteristic)").font(.system(size: 29, weight: .semibold))
                        Text("状态 \(failure.status)").font(.system(size: 26)).opacity(0.7)
                        if expandedFailure == failure.id { Text(failure.source).font(.system(size: 25)).fixedSize(horizontal: false, vertical: true) }
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(TVFocusStyle(kind: .tile)).focusEffectDisabled().focused($focus, equals: .failure(failure.id))
            }
        }
        Text("设备属性 · \(device.readings.count)").font(.system(size: 34, weight: .semibold)).padding(.top, 12)
        if device.readings.isEmpty {
            Text("没有已采集的属性。服务运行后重新生成诊断报告。")
                .font(.system(size: 27)).foregroundStyle(TVTheme.secondary)
        }
        ForEach(device.readings) { reading in
            Button { expandedReading = expandedReading == reading.id ? nil : reading.id } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(reading.name).font(.system(size: 30, weight: .semibold)); Spacer(); Text(reading.available ? "正常" : "未读取成功").font(.system(size: 24)) }
                    Text(reading.id + (reading.code.map { " · code \($0)" } ?? "")).font(.system(size: 24)).opacity(0.65)
                    Text(reading.value ?? reading.error ?? "无有效读数").font(.system(size: 27))
                        .lineLimit(expandedReading == reading.id ? 20 : 2).frame(maxWidth: .infinity, alignment: .leading)
                    if expandedReading == reading.id {
                        if let error = reading.error, reading.value != nil { Text(error).font(.system(size: 25)) }
                        Text(reading.updatedAt?.formatted(date: .abbreviated, time: .standard) ?? "尚未取得更新时间")
                            .font(.system(size: 23)).opacity(0.65)
                    }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(TVFocusStyle(kind: .tile)).focusEffectDisabled().focused($focus, equals: .reading(reading.id))
                .accessibilityIdentifier("diagnostics.reading.\(reading.id)")
        }
    }

    private func health(_ value: String) -> String {
        switch value { case "online": "在线"; case "offline": "离线"; case "notChecked", "unknown": "尚未检查"; default: value }
    }
    private func bridgeStatus(_ value: String) -> String {
        switch value {
        case "running": return "运行中"
        case "stopped": return "未运行"
        case "waiting": return "等待设备"
        case "starting": return "启动中"
        default: return value
        }
    }
    private func info(_ title: String, _ value: String) -> some View {
        HStack(spacing: 24) {
            Text(title).foregroundStyle(TVTheme.secondary)
            Spacer(minLength: 15)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.system(size: 27)).padding(.vertical, 10)
    }
    private func goBack() {
        if let id = selectedDeviceID { selectedDeviceID = nil; focus = .device(id) }
        else { dismiss() }
    }
}
#endif
