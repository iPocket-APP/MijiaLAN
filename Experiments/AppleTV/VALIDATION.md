# 验证记录 — 2026-11-04

后续的 iOS 真机 NE、后台 UDP 与 HomeKit 失败对照见 [2026-11-05 iOS 验证记录](IOS_VALIDATION.md)。下文保留原有 tvOS 验证结果。

## 2026-11-05：参考 GitHub 实现后的复验

已核对 Passepartout、TunnelKit、Cell Tunnel、TG WS Proxy 的固定版本源码，详见 [GitHub 调研](GITHUB_RESEARCH.md)。原型改为主机掩码和空接管路由；增加默认关闭的 On Demand 自动重连，手动停止先持久关闭策略，再停止会话。扩展成功应用设置后，证据中增加路由、DNS 和代理配置摘要。

- 共享运行时集成测试通过：两个测试执行通过，外部模拟器连接测试按条件跳过；包含真实 loopback UDP、miIO 加密和 HAP TCP 配对、写入、读回及后台标记后的自动轮询。
- 更新后的 tvOS Simulator App 和扩展编译并启动成功。
- 独立 HAP 客户端对更新后正在运行的模拟器 App 完成加密配对、验证、模拟设备开 / 关和读回，测试通过并移除临时配对；仅证明前台运行时可用。
- 更新后的 tvOS 真机架构 Release Archive 编译通过，仍为未签名产物。
- 再次实际请求启动 NE，仍在 `loadingPreferences` 返回 `NEVPNErrorDomain / 5 / IPC failed`。记录保存在 `build/validation/tvos-github-research-20261105/activation.json`，外部 HAP 测试日志为同目录 `external-hap.log`。
- 本次设备清单未发现可用的 Apple TV 真机；On Demand、空路由实际生效、局域网 HAP 可达性及后台持续运行仍未完成真机验收。此改动不会修复模拟器在读取系统配置阶段的 IPC 失败。

分支：`codex/tvos-network-extension-prototype`。环境：Xcode 27.2，tvOS 27.2 SDK，Apple TV 4K 模拟器（1080p，tvOS 27.2）。原型及平台适配副本均位于实验目录，已有 Mac 开发改动保留。

## 已验证

| 检查 | 结果 |
| --- | --- |
| tvOS Simulator App 与 Packet Tunnel 扩展编译 | 通过 |
| 模拟器临时签名、共享 Keychain、App Group、界面启动 | 通过 |
| 主机集成测试：真实 loopback UDP、miIO 加密、HAP TCP 配对/验证/写入/读回 | 通过 |
| 主机集成测试：后台标记后无界面请求，自动轮询继续增长 | 通过；仅证明共享运行时，宿主是 Mac 测试进程 |
| 独立客户端连接实际运行的 tvOS 模拟器 App，完成加密配对、模拟设备开/关及读回 | 通过；测试结束移除临时配对 |
| 模拟器前台测试切到系统设置 | 按设计停止；证据为 `appPhase=background`、`bridgeStatus=stopped`，原 TCP 监听关闭 |
| tvOS 真机架构 Release Archive | 编译通过；未签名，不可直接安装真机 |
| tvOS 开发签名 | 未通过；Xcode 报告缺少可用于生成 tvOS 开发描述文件的已注册设备 |

默认自动测试为两个通过、一个外部连接测试按条件跳过。外部连接测试另行对已运行的模拟器执行，一项通过。测试对象均为模拟设备，没有读取生产设备 token 或对真实设备执行写入。

## Network Extension 的实际结果

在模拟器上调用 `NETunnelProviderManager.loadAllFromPreferences()` 时失败：

```text
stage: loadingPreferences
errorDomain: NEVPNErrorDomain
errorCode: 5
message: IPC failed
```

系统日志同时记录 `nehelper` XPC 连接无效，底层 `NEConfigurationErrorDomain Code=11`。流程尚未进入保存 VPN 配置或启动 provider 的阶段；未产生 `executor=networkExtension` 的运行证据。

### IPC 失败的进一步定位

本机 tvOS 27.2 运行时缺少 `usr/libexec/nehelper`、`usr/libexec/nesessionmanager`，`System/Library/LaunchDaemons` 中没有相应服务注册项，模拟器的已注册服务中也没有这两个服务。

原型 App 与扩展的签名校验均通过。实际 Mach-O 中的 `__TEXT,__entitlements` 包含 `packet-tunnel-provider`，App Group 及共享 Keychain 权限和前缀一致。模拟器的代码签名 entitlement 字典为空不代表丢失模拟权限；Xcode 将模拟权限嵌入 Mach-O 的独立节中。

`Diagnostics/NEPreferencesProbe.swift` 是只依赖系统框架的独立最小 App，没有米家代码、HomeKit 桥、provider、App Group、Keychain 或预存 VPN 配置。每组分别调用 `NETunnelProviderManager.loadAllFromPreferences()` 和 `NEVPNManager.shared().loadFromPreferences()`，只读取，不保存或启动 VPN。

| 环境与签名对照 | 两个 API 的结果 |
| --- | --- |
| 原模拟器，NE entitlement，临时签名 | 均返回 `NEVPNErrorDomain / 5 / IPC failed` |
| 原模拟器，NE + Personal VPN entitlement，临时签名 | 相同 |
| 原模拟器，NE + Personal VPN entitlement，Apple Development 证书签名 | 相同 |
| 全新 Apple TV 模拟器，NE entitlement，临时签名 | 相同 |
| 全新 Apple TV 模拟器，NE + Personal VPN entitlement，临时签名 | 相同 |

全新模拟器也缺少同样的服务，排除了旧设备数据、残留 VPN 配置与一次性服务故障。所有对照 App 的签名校验通过，读操作均实际执行并写出结果；测试结束移除对照 App，专为测试创建的模拟器已删除。

**结论：当前 Xcode 27.2 / tvOS 27.2 模拟器的 IPC 失败来自缺少 Network Extension 的系统基础设施，无法通过修改本项目配置、增加 Personal VPN entitlement 或更换签名证书修复。** 此结论只覆盖已检查的运行时，不等于已经验证真机后台保活的可行性，也不外推所有未来 tvOS 版本。

[Apple DTS 关于模拟器 NE 基础设施的说明](https://developer.apple.com/forums/thread/46004)早在 iOS 模拟器上解释过类似限制；本次 tvOS 结论以本机运行时检查和上述独立对照结果为依据。App 现在将已观察到的模拟器 IPC 错误显示为系统服务不可用，保留原始错误记录及「前台测试」入口。

## 下一步真机验收

1. 在 Xcode 配对并注册 Apple TV，给两个 target 生成包含 Network Extension、App Group 和共享 Keychain 的 tvOS 开发签名。
2. 先用模拟设备验证 provider 激活、配对和后台 HAP TCP 可达，再配置一台可安全开关的真实设备。
3. 返回电视主屏并使用其他 App，分别观察 5、15、30 分钟；由 iPhone「家庭」读写，并确认实体设备实际变化。
4. 比较同一扩展会话的后台认证读写、设备新鲜读数、桥接状态和心跳中断，另外测试系统待机/唤醒与网络恢复。

## 本地证据

仓库 `build/validation/tvos-network-extension-20261104/` 保存外部 HAP 测试日志、前台服务停止后的脱敏证据、扩展启动失败记录和模拟器系统日志。`build/tvos-prototype-tests.log` 为最新自动测试日志，`build/tvos-prototype-device.log` 为开发签名失败日志，`build/tvos-prototype-device-unsigned.log` 为真机架构 Archive 日志。生成的配对码临时输入文件已删除。

`build/validation/tvos-ipc-investigation-20261104/report.json` 保存原模拟器的服务、嵌入权限、签名校验及三组 API 对照；`build/validation/tvos-ipc-investigation-20261104-clean/report.json` 保存全新模拟器的两组对照，`cleanup.json` 记录测试模拟器的清理结果。复现脚本为 `diagnose_simulator.py`。

上述目录均不进入版本控制；设备名、ID 和时间仍属于私密诊断数据。
