# tvOS 桥接中心实现与验证 · 2026-11-05

## 检查更新 · 2026-11-06

设置新增「检查更新」，独立页面显示当前版本、数字构建号比较、更新说明、发行页二维码及前台自动检查偏好。服务端提供独立 TV JSON，并保留现有原生 / Rust appcast；实现与上线边界见 [UPDATES.md](UPDATES.md)。

线上服务已部署并通过模拟器实际检查：`build/validation/tvos-updates-deploy-20261106/ui-tests-production-v3.xcresult`，**1 passed / 0 failed**。不带测试数据参数启动，手动检查确认来源「TV 更新服务」、结果「暂未发现可用的 TV 安装包」。已查看同目录实际截图 `updates-production-service.png`。首轮阻塞来自 LuLu 授权，本次验收放行后原有请求实现通过；测试新增的放行规则和 Runner 均已清理。该结果不代表 Apple TV 真机升级验收。

最终 `build/validation/tvos-updates-20261106/ui-tests-final.xcresult`：**9 passed / 0 failed / 0 skipped**。两个新增测试分别覆盖纯示例操作 / 返回，以及实际 loopback HTTP 服务生成的清单 / 新版本 / 二维码。截图同目录 `updates-http-service.png` 和 `updates-preview.png` 已查看；iOS 共用代码编译通过。浏览器手动导航和确认也已验证，当前停在明确标记为示例数据的软件更新页。

## 诊断功能补齐 · 2026-11-06

旧诊断页只有状态和通信计数，现替换为 `App/TV/TVDiagnosticsView.swift` 全屏原生诊断。字段参考 macOS 的 `DiagnosticReport.swift`，采集层为 `Sources/TVPrototypeKit/PrototypeDiagnostics.swift`。入口是设置或家庭桥接页的诊断按钮；设备详情展示健康、最近在线、重试、属性值 / code / 错误以及 HomeKit 失败来源。完整字段和运行方式见 [DIAGNOSTICS.md](DIAGNOSTICS.md)。

| 检查 | 最终结果 |
| --- | --- |
| tvOS Debug 编译及原有 5 项遥控流程 | 通过 |
| 实际共享前台运行时采集、进入设备 77 的 14 项属性、菜单逐级返回 | 通过 |
| 11 台纯示例报告与明确来源标签 | 通过 |
| 设置入口焦点可达性 | 首轮发现问题，修复 ScrollView focusSection 后通过 |
| 错误码、HomeKit 失败属性、重试字段、自由文本脱敏、停止后的状态边界 | 新增 4 项共享诊断测试通过 |
| SwiftPM 完整测试 | 7 项执行通过，1 项外部模拟器桥集成用例跳过 |
| iOS 共用代码 Debug 编译 | 通过，未安装到实体设备 |
| 浏览器进入原生诊断、生成、下载 JSON | 通过，下载字节与原生导出文件一致 |
| 模拟器固定文件取出脚本 | 通过 |

最终结果包：`build/validation/tvos-diagnostics-20261106/ui-tests-final.xcresult`，**7 passed / 0 failed / 0 skipped**，运行时警告为空。原生截图在同目录的 `diagnostics-live-summary.png`、`diagnostics-live-device.png` 和 `diagnostics-preview-summary.png`。手动预览保留在 `http://localhost:3202/` 的示例诊断页，已移除独立测试 Runner。

实际运行时采集使用 tvOS 27.2 Simulator 的前台共享代码和内存模拟设备。后台计数没有增长，不构成 tvOS NE 后台或真实米家设备证据；Apple TV 真机文件取出与后台行为仍待硬件验证。

以下为最初界面实现记录。

采用用户选择的第三版「桥接中心」，在现有实验分支 `codex/tvos-network-extension-prototype` 实现原生 SwiftUI 界面。没有修改正式 macOS 界面，没有提交、推送或上传发行包。

## 交付内容

- `App/TV/TVBridgeShell.swift`：侧栏导航、桥接总览、主要焦点和原生弹层路由。
- `App/TV/TVHomePresentation.swift`：把同一 `TunnelModel` 的配置、服务状态、脱敏证据映射到界面；以会话有效性和 15 秒内更新时间防止把历史记录显示为正在运行。
- `App/TV/TVComponents.swift`：深色配色、SF Symbols、遥控器焦点、减少动态效果偏好。
- `App/TV/TVPages.swift`：房间 / 离线筛选、家庭桥接启停和配对入口、设置与诊断入口。
- `App/TV/TVSheets.swift`：设备电源操作、实际配对状态、局域网设备认证保存、诊断信息。设备配置支持追加及房间，最多 4 台；token 不进入诊断信息，取消认证会取消保存任务，持久写入前检查任务取消。
- `UITests/TVBridgeUITests.swift`：5 项原生遥控器集成测试，新增 XcodeGen UI 测试 target。

`MijiaLANTVPrototypeApp.swift` 仅在 tvOS 显示新界面；iOS 保留诊断界面。`TunnelModel` 的配置与控制请求现在返回成功与否，供界面展示操作结果。桥接协议、NE Provider 和签名配置没有因界面重做而更改。

## 最终检查

环境：Xcode、tvOS 27.2 Simulator（24K150），Apple TV 4K 1080p，截图 1920×1080。iOS 编译使用 iOS 27.0 Simulator / iPhone 18 Pro 目标，不启动或安装到实体 iPhone。

| 检查 | 结果 |
| --- | --- |
| tvOS Debug 编译、安装和启动 | 通过 |
| 初始主按钮焦点、进入桥接、关闭 / 开启、菜单返回 | 通过 |
| 进入示例设备详情、操作电源、返回后状态刷新 | 通过 |
| `--simulator-fixture` 实际前台运行时、净化器开关、停止桥接 | 通过 |
| 查看全部设备、遥控器选择离线筛选 | 通过 |
| 从总览进入设置、打开配置、空表单禁止保存、菜单取消 | 通过 |
| iOS Debug 共用代码编译 | 通过 |
| 完整与局部设计核对 | 通过，见 `design-qa.md` |

最终测试包：仓库根目录下 `build/validation/tvos-bridge-ui-20261105/ui-tests-v6.xcresult`，**5 passed / 0 failed / 0 skipped**，无运行时警告。此前测试暴露的单设备焦点区域与侧栏导航问题均已修复；最终包为修复后的完整回归。

XcodeBuildMCP 日志：

- `~/Library/Developer/XcodeBuildMCP/workspaces/MijiaLAN-5c9f717f3c72/logs/test_sim_2026-11-05T03-57-26-483Z_pid10832_bb1344e5.log`
- `~/Library/Developer/XcodeBuildMCP/workspaces/MijiaLAN-5c9f717f3c72/logs/build_sim_2026-11-05T03-59-17-766Z_pid10832_b0191832.log`（iOS 编译）

## 运行与复现

打开 `MijiaLANTVPrototype.xcodeproj`，选择 `MijiaLANTVPrototype` scheme 和 Apple TV 模拟器。Product → Test 可运行 5 项测试。新机器按 README 先生成依赖和 Xcode 工程；模拟器仍需临时签名携带 Keychain / App Group 权限。

Debug 的 Scheme → Run → Arguments：

- `--design-preview`：第三版设计的 11 台示例设备；不启动 NE 或业务通信、不读取共享容器或 Keychain。截图 `Design/implemented-overview.png` 来自此模式，左下角有示例标记。
- `--simulator-fixture`：真正的共享 HAP / miIO 前台运行时，使用内存模拟设备。电源测试通过此路径，不是修改界面示例数组。
- 无参数：读取实验 App 自己保存的实际配置；「设置」可配置局域网设备，「家庭桥接」可启动、停止和查看配对信息。

当前手动预览入口见下方补充记录，已切换为电视专用导航页面。

## 证据范围

此次实际控制测试使用内存 fixture，没有真实米家设备或真实 UDP 流量。配置表单已验证进入、空值保存禁用和取消，未输入真实设备 token。Apple TV 真机、实体遥控器、VoiceOver、4K 布局及 NE 后台持续性尚未验收。

当前 tvOS 模拟器的系统 NE 服务缺失问题依然存在；新界面在模拟器正常启动的是明确标记的前台模式，切后台会停止。iPhone 先前的 NE 后台验证详见 `NOAUTH_INVESTIGATION.md`，不能据此认定 Apple TV 真机已通过。

## 后续修正：主屏图标与手动预览入口

用户反馈的截图实际为 tvOS 主屏：系统设置加两个白色图标。两个白色入口分别是实验 App 和 `MijiaLANTVUITests-Runner`；后者由 XCTest 启动，不能作为产品入口。

- 新增 tvOS 专用 `AppIcon.brandassets`：400×240 的 1x / 2x 分层主屏图标、1280×768 大图及两种 Top Shelf 1x / 2x 图。复用现有白色房屋 SVG 和绿色背景；可用 `render-tv-assets.swift` 重现导出。XcodeGen 将资源仅接入 tvOS App。
- 实际安装后的 `Info.plist` 有 `CFBundleIcons.CFBundlePrimaryIcon=App Icon`，`assetutil` 查到分层与 1x / 2x 图。主屏截图 `build/validation/tvos-bridge-ui-20261105/home-icon-verified.jpg` 已确认绿色房屋图标显示，白色测试运行器在最终测试后已卸载。
- 普通 serve-sim 预览按触屏转发点击、且 tvOS 元数据缺失，不能直接当作电视触屏。新增 `Preview/` 本机页面，沿用真实画面，提供明确导航和遥控按钮；不转发视频上的鼠标触摸。入口 `http://localhost:3202/`，底层画面服务仍为仅本机访问的 3200。
- Debug 纯示例模式接受限定的 `mijialantv-preview://navigate/<page>` 导航，真实模式与 Release 不处理这些页面切换；没有配置、真实控制或 VPN 动作。示例模式总览的返回键留在 App 内，避免误退回主屏。

最终回归：`build/validation/tvos-bridge-ui-20261105/ui-tests-v7-icons-preview.xcresult`，**5 passed / 0 failed / 0 skipped**。初始焦点测试额外验证示例总览按菜单键仍在前台。

手动浏览器复核通过：从主屏点「打开应用」进入原生总览；「应用设置」显示 `settings.diagnostics` 和 App 设置标题；「设备」显示设备筛选；「家庭桥接」显示 `bridge.toggle`。网页「确认」实际把原生桥接按钮从「停止桥接」切为「开启桥接」，再次确认恢复，然后「返回」回到总览。最终预览停在原生 App 设置页，明确标记示例数据。没有启动 NE 或控制真实设备。
