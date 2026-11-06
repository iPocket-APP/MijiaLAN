# GitHub 项目核对与原型改动

目标：核对“用 Network Extension 承载常驻服务”是否有公开实现，并找出可用于当前米家 / HomeKit 原型的具体配置。源码有实现、项目能编译、真机后台验收是三个不同的证据层级。

## 核对结果

| 项目与固定版本 | 实际实现 | 对当前实验的意义 |
| --- | --- | --- |
| [Passepartout](https://github.com/partout-io/passepartout/tree/ed2fcf25c0a68c50f36f3d8ab5b0f4821cd5fc09) | 支持 Apple TV 的 VPN 项目；PacketTunnelProvider 在扩展中创建并启动独立 TunnelContext | 支持 tvOS 上由 NE 拥有运行时的架构，不能据此证明 HAP 监听和米家设备验收通过 |
| [TunnelKit](https://github.com/partout-io/tunnelkit/tree/5cd1c64be666dd94ea65afcf3c5684fa2c87a925) | NetworkExtensionVPN 保存 / 重读配置后启动；手动断开同时关闭 On Demand；README 明确以 MockVPN 测试模拟器 | 可参考连接生命周期；模拟器展示连接状态不等于实际 NE 运行 |
| [Cell Tunnel](https://github.com/agoodkind/iphone-cell-tunnel/tree/257dab5183a96e80312aaf4b0f4b8ab898fe39f4) | iPhone NE 内运行 relay，虚拟地址使用主机掩码、不包含接管路由；模拟器另用进程内后端 | 与“扩展承载服务、物理网络正常通信”接近；iOS 实现不能直接替代 tvOS 验收 |
| [TG WS Proxy](https://github.com/ridiccur/tg-ws-proxy-ios/tree/2b2a7e20377b280f90939ac09a4d41826c0f9a6e) | iOS NE 内启动 loopback TCP 代理，`includedRoutes = []` | 提供了“NE 内确实运行监听服务”的源码例子；loopback 代理不同于对局域网开放的 HomeKit 桥 |
| [AmneziaWG Apple TV 原型](https://github.com/discreteagent/amneziawg-apple-tv/tree/0c2206b03c79d14b78be9692c4c1638e46df4bd8) | 有 tvOS target、NE 代码及“device or simulator”构建说明 | README 的 Prototype limitations 同时明确“Not built or run here”，因此不作为成功运行证据 |

### 关键源码

- Passepartout：[PacketTunnelProvider.swift](https://github.com/partout-io/passepartout/blob/ed2fcf25c0a68c50f36f3d8ab5b0f4821cd5fc09/app-apple/Passepartout/Tunnel/PacketTunnelProvider.swift)。扩展持有并启动 / 停止 context。
- TunnelKit：[README](https://github.com/partout-io/tunnelkit/blob/5cd1c64be666dd94ea65afcf3c5684fa2c87a925/README.md)、[NetworkExtensionVPN.swift](https://github.com/partout-io/tunnelkit/blob/5cd1c64be666dd94ea65afcf3c5684fa2c87a925/Sources/TunnelKitManager/NetworkExtensionVPN.swift)、[MockVPN.swift](https://github.com/partout-io/tunnelkit/blob/5cd1c64be666dd94ea65afcf3c5684fa2c87a925/Sources/TunnelKitManager/MockVPN.swift)。真实系统后端与模拟后端分开。
- Cell Tunnel：[Phone PacketTunnelProvider](https://github.com/agoodkind/iphone-cell-tunnel/blob/257dab5183a96e80312aaf4b0f4b8ab898fe39f4/Apps/PhoneTunnelProvider/PacketTunnelProvider.swift)、[SimulatorRelayBackend](https://github.com/agoodkind/iphone-cell-tunnel/blob/257dab5183a96e80312aaf4b0f4b8ab898fe39f4/Apps/iOS/Services/SimulatorRelayBackend.swift)。源码注释明确模拟器没有可启动的 nehelper，使用进程内 runtime。
- TG WS Proxy：[PacketTunnelProvider.swift](https://github.com/ridiccur/tg-ws-proxy-ios/blob/2b2a7e20377b280f90939ac09a4d41826c0f9a6e/Sources/Extension/PacketTunnelProvider.swift)。实际代码设置主机掩码、空 `includedRoutes` 及默认排除路由，在设置成功后启动 ProxyServer，在 stopTunnel 中关闭。README 的后台运行描述未在本机独立真机复验。
- AmneziaWG：[原型限制](https://github.com/discreteagent/amneziawg-apple-tv/blob/0c2206b03c79d14b78be9692c4c1638e46df4bd8/README.md#prototype-limitations)。检查此说明后排除了“已经在模拟器成功跑真实 NE”的解读。

搜索到的 Homebridge Apple TV / Bravia 插件主要是在 Linux / NAS 上把电视暴露给 HomeKit；MoonshineSG/vpn.tv 是控制 Raspberry Pi 上的 VPN。它们不能作为服务运行在 Apple TV 内的证据。

## 已采用的改动

实现继续使用项目现有的 Swift / NetworkExtension API：

1. `ExperimentalTunnelNetwork` 使用主机掩码和空接管路由，替换此前捕获 `198.18.0.2/32` 的实验路由。Provider 成功应用后把配置摘要传给 runtime，随后台证据记录。
2. 增加默认关闭的自动重连选项，启用时保存 `NEOnDemandRuleConnect`，覆盖 Wi-Fi / Ethernet 等接口变化。
3. 手动停止先关闭系统按需连接及该 VPN 配置，持久保存后停止会话。保存失败仍请求停止，并报告自动重连设置未能保存，避免显示为已彻底关闭。
4. 模拟器继续使用现有的同一业务 runtime 前台验证模式，记录 `executor=simulatorForeground`；不把该模式计为扩展后台验证。

## 结论与边界

后续已用 iOS 真机复验：空接管路由的 NE 在后台与 Mac UDP fixture 连续通信约六分钟，首次 HomeKit Bonjour 测试返回 `NoAuth / -65555`，见 [首次 iOS 验证记录](IOS_VALIDATION.md)。继续搜索并做移除 / 恢复配置对照后，已定位到本机系统还需扩展自身的 `NSBonjourServices` 列表；补齐后 NE 的外部加密 HAP 配对和控制通过。新增资料、探针及后台复验方法见 [NoAuth 排查](NOAUTH_INVESTIGATION.md)。参考项目中的 loopback / relay 实现仍不能替代本项目的实际局域网 HAP 验收。

公开项目中有同类服务宿主实现，足以支持继续做自用实验；尚未找到“普通 tvOS App 在模拟器启动真实 NE”的有效实现证据。当前机器已经独立确认模拟器缺少相应系统服务，修改隧道路由也不会改变配置读取阶段的 IPC 失败。

`NEOnDemandRuleConnect` 是重连策略，不是保持 CPU 执行或阻止系统睡眠的承诺。完成米家局域网控制、HAP 配对 / 订阅 / 写入，以及切后台、待机和网络恢复的真实验证仍需要 Apple TV。Apple 对 Packet Tunnel 承载网络监听服务的官方限制仍见 [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)。
