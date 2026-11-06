# tvOS 诊断与报告 · 2026-11-06

入口为「设置 → 诊断信息」，也可从「家庭桥接 → 查看诊断信息」进入。按「生成诊断报告」重新读取当前设备；选中设备后可查看属性、错误码、重试和 HomeKit 失败来源。返回键先退出设备详情，再关闭诊断页。采集只读，不执行电源写入。

浏览器预览打开 `http://localhost:3202/`，点「诊断」，再用下方「确认」触发原生页面的生成按钮。页面上方「下载诊断报告」下载最近生成的 JSON，旁边显示来源与采集时间。纯示例预览的按钮写明「生成示例报告」，不会发起网络通信。

## 对照 macOS 原生版

参考 `Sources/MijiaLANApp/DiagnosticReport.swift` 的字段白名单；未引入 AppKit、Finder 或邮件流程。

| 内容 | TV 实现 |
| --- | --- |
| App 与环境 | 版本、构建号、平台、系统、采集及导出时间 |
| 桥接 | 状态、有效运行端口、配对状态、附件数、结构与数值修订号 |
| 每台设备 | did、名称、型号、健康状态、是否纳入桥接、Spec 类型、最近错误及在线时间 |
| 重试 | 连续失败次数、下次重试时间、是否正在探测 |
| 属性 | ID、名称、JSON 字符串形式的值、原始 code、错误、更新时间、可用性 |
| HomeKit 读取失败 | 服务、特征、源属性及 HAP 状态码 |
| 实验运行环境 | 会话 ID、执行进程类型、传输类型、认证读写及后台读写计数、传输失败数、隧道路由摘要 |
| NE 激活 | 最近阶段、时间、系统错误域和错误码；不导出任意原始错误消息 |

UI 展示摘要及设备详情，完整字段保留在 JSON 中。正常模式的数据来自共享 DeviceController / HomeKitBridgeController；展示数组不充当实际运行时证据。

## 采集与历史记录

容器 App 发送带 UUID 的 `diagnostics` 请求。实际运行进程刷新设备、等待桥接快照更新，将完整报告原子写入 App Group 的 `runtime-diagnostics.json`，IPC 只返回小型运行证据。容器须核对本次 UUID，再生成自己的导出文件。NE 请求超时为 30 秒，其他控制请求仍为 5 秒。

| source | 含义 |
| --- | --- |
| `liveRuntime` | 本次请求从运行进程采集；仍需检查 `fixture`、执行类型与时间 |
| `savedRuntime` | 本次采集不可用，使用同会话、同设备集合和同 fixture 类型的历史快照；显示历史提示与原采集时间 |
| `notRunning` | 没有可用的运行快照；设备为 `notChecked`，不沿用旧证据的运行中 / 已配对状态 |
| `designPreview` | 11 台设计示例设备；没有打开共享容器、Keychain、VPN 或设备网络 |

运行中的 `memoryFixture` 是共享业务代码加内存模拟设备，不是实际米家 UDP；`simulatorForeground` 不是 NE 后台。`recordedAt` 是快照时间，`exportedAt` 是容器写出时间，重新导出不会把历史采集时间改成现在。失败、缺少匹配报告或历史回退会保留采集提示。

## 数据与取出方式

使用明确 DTO，永不序列化 LocalDevice、配置、token、端点、桥身份或配对密钥。已知 token / host / MAC / 配对码，以及自由文本中的 IPv4、IPv6、MAC、32 位十六进制 token、配对码形式会脱敏。报告仍包含设备名称、did 和读数，属于用户自己的诊断数据。

手动生成的导出文件固定为 App 自己的数据容器内：

```text
Library/Caches/Diagnostics/MijiaLAN-Diagnostics.json
```

预览服务只绑定 loopback，固定读取本实验 App 的上述文件；下载无自动生成副作用，不接受任意文件、bundle 或外部主机输入。报告最大 8 MiB，页面显示最近文件的来源与时间。它不会自动在电视上开 HTTP 服务。

也可从仓库根目录复制已经生成的报告：

```sh
python3 Experiments/AppleTV/capture_diagnostics.py --simulator TV_SIMULATOR_UDID --output build/tv-diagnostics.json
python3 Experiments/AppleTV/capture_diagnostics.py --device PAIRED_APPLE_TV_ID --output build/tv-diagnostics.json
```

脚本仅复制这一个文件，不复制 Keychain 或配置。模拟器路径已验证；真实 Apple TV 的 devicectl 文件服务路径尚待设备验证。缓存可能被系统清理，文件缺失时请在 TV App 中重新生成。

## 验证记录

证据目录：`build/validation/tvos-diagnostics-20261106/`。

- 共享 SwiftPM 测试：7 项执行通过，1 项需要外部模拟器桥的集成用例跳过。新增 4 项诊断测试覆盖原始错误码、HomeKit `-70402` 与源属性、重试信息、自由文本脱敏、停止后的历史边界、激活字段白名单，以及实际运行进程的请求匹配、刷新和只读采集。
- tvOS 27.2 / 1080p：7 项 XCUIRemote 测试通过，0 失败 / 0 跳过，运行时警告为空。包括现有 5 项控制流程，以及运行时 fixture 报告 / 设备详情、纯示例标签两项诊断流程。
- 首轮测试发现实际运行模式设置页的诊断入口无法稳定从侧栏向右到达；补上设置滚动区的 focusSection 后，定向与最终完整回归通过。
- 浏览器手动导航、原生生成、报告时间更新、下载均通过。下载的 `MijiaLAN-TV-Diagnostics.json` 与原生容器导出文件逐字节相同，示例报告为 11 台设备 / 9 台在线。
- `capture_diagnostics.py` 的模拟器取出路径通过；iOS 共用代码 Debug 编译通过，未重新安装或启用 iPhone NE。

最终 UI 结果包为 `ui-tests-final.xcresult`，原生截图为 `diagnostics-live-summary.png`、`diagnostics-live-device.png` 和 `diagnostics-preview-summary.png`。测试结束已移除独立 XCTest Runner，保留实验 App 和绿色房屋图标。

此次 tvOS 实际运行采集使用前台共享运行时和内存模拟设备。没有 Apple TV 硬件、真实米家设备或 tvOS NE 后台持续运行的新验收结果。
