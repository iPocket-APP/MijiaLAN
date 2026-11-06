# iPhone NE 的 HomeKit NoAuth 排查 — 2026-11-05

环境：iPhone 12 Pro Max，iOS 27.0.1，Xcode 27.2。分支：`codex/tvos-network-extension-prototype`。只使用专用模拟设备，没有读取生产 token 或操作真实家电。

## 定位结果与最小修复

**本机的 `-65555` 来自扩展缺少 Bonjour 服务类型声明。** 容器 App 的 `Info.plist` 已有声明及局域网授权；在 `Tunnel/Info.plist` 也加入以下列表后，`DNSServiceRegister` 返回成功，原有 HAP 运行时可以通过外部加密客户端完成配对、开 / 关与读回：

```xml
<key>NSBonjourServices</key>
<array>
    <string>_hap._tcp</string>
    <string>_miio._udp</string>
</array>
```

保留原有 `NWListener`、miIO 传输与签名能力。没有增加 entitlement、默认路由、代理或额外后台模式；扩展不另加 `NSLocalNetworkUsageDescription`。一般情况下，Apple [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 要求把隐私及 Bonjour 声明放在容器 App。本次重复服务列表是针对所测系统、有配置对照证据的兼容处理，不作为所有系统的通用要求。

| 真机对照 | Bonjour 注册 | TCP / HAP |
| --- | --- | --- |
| 容器有声明，扩展无声明 | `_hap._tcp` / `_miio._udp` 均同步返回 `-65555`；指定 Wi-Fi 或默认域不改善 | 独立 TCP 探针可连接；业务桥按启动失败清理 listener |
| 扩展增加服务列表及局域网用途字符串 | 注册返回 0 | 不启用探针的 NE 完成外部加密 HAP 配对、开关和读回 |
| 扩展只保留服务列表，移除用途字符串 | 注册返回 0 | 普通 / Wi-Fi `NWListener`、带 Bonjour 的 listener、BSD listener 均被 Mac 实际连接 |
| 再移除扩展服务列表，其他代码不变 | 四种注册对照均重新返回 `-65555` | 普通 / Wi-Fi `NWListener` 与 BSD listener 仍可实际连接 |
| 最终恢复服务列表 | HAP 业务桥正常启动 | 外部 HAP、真实 UDP fixture 的 315 秒后台观察通过 |

因此，最初的 NoAuth 不能据此认定 NE 禁止全部局域网监听。本轮新探针首次“ready 后全部端口拒绝”的观察也不能支持该结论：探针曾因回调继承 MainActor 隔离而退出进程，退出后的端口自然不可达。该探针问题已修复，复测确认现有 `NWListener` 可以使用，不引入 BSD HAP 替代实现。

## 最终后台复验：通知匹配修正后

最终独立外部 HAP 测试执行 374.690 秒，一项通过，正常退出；共完成 23 次开关、读回和匹配当前状态的加密 EVENT 通知。

| 检查 | 结果 |
| --- | --- |
| App 切到系统设置的后台窗口 | 310.008 秒，约 5 分 10 秒 |
| 扩展会话 / PID | 前后相同 |
| 后台认证读取 / 确认写入 | 79 / 19 |
| 返回 App 前已匹配的写入通知 | 19 |
| 写入来源 | 独立加密 HAP 客户端；定时自测写入关闭 |
| Mac 模拟器独立 UDP 回复增量 | 99，包含采集边界的额外请求 |
| 传输失败 / 最大采样心跳间隔 | 0 / 5.329 秒 |
| 观察结束时的桥 | 运行、已配对 |
| 后台新建 TCP 连接 | 后台约 302 秒时连接成功 |
| 完整比较器与外部通知测试 | 均通过；`overallFixtureAcceptancePassed=true` |

最终结果保存在 `notification-retest/background-summary.json`。这证明所测窗口中，NE 的 HAP 配对、订阅、读写、通知与真实局域网 UDP fixture 可以共同运行；仍不等于真实家电或 Apple TV 验收。

结束后已确认临时控制器配对移除、输入配对文件删除、Mac UDP 模拟器进程及端口关闭，并在手机界面观察到 VPN「已断开」及自动重连已关闭。停用 VPN 后界面的旧业务快照不会再更新，不能把旧快照的 `running` 状态当作仍在运行；停止状态以 VPN 连接状态及清理记录为准。

## 首次后台读写窗口与通知测试修正

| 检查 | 结果 |
| --- | --- |
| 实验 App 切到系统设置的持续时间 | 315.002 秒，约 5 分 15 秒 |
| 扩展会话与进程 | 前后同一会话 ID / PID |
| 后台认证读取增量 | 80 |
| 后台确认写入增量 | 19；来自独立加密 HAP 控制器，`fixtureSelfTestWrites=false` |
| Mac UDP 模拟器独立回复增量 | 102；前后采集时间还包含前后台切换时的请求 |
| 传输失败 | 0 |
| 最大采样心跳间隔 | 5.330 秒 |
| 桥状态 | `running`，观察结束采样时仍已配对 |
| 独立 Bonjour 解析 | App 后台时解析到桥服务、端口及已配对 TXT 状态 |
| 新建 TCP 连接 | App 后台约 220 秒时连接成功 |
| 完整比较器 | `mode=fixtureOnly`、`indicatorsPassed=true`，包括关闭定时自测及无新增失败的检查 |

上述首次窗口的后台读写及比较器通过。其通知测试随后因测试器把订阅初始状态归到后续写入而失败，首次完整外部测试没有算通过。已在独立客户端增加 GET 响应屏障，先清除更早的缓存事件，再等待匹配当前写入值的 EVENT；30 秒真机对照的两次开关和通知通过，完整后台复验单独保存在 `notification-retest/`。后台计数来自扩展实际确认的 miIO UDP 请求，不是仅凭心跳、VPN 图标或内存模拟器得出的结论。

## GitHub 资料与采用范围

- [LiveContainer #1519](https://github.com/LiveContainer/LiveContainer/issues/1519) 报告宿主缺少服务类型列表时，Bonjour 返回相同 NoAuth，普通 TCP / UDP 则正常。它提供了检查声明的线索；它不是 NE 案例，本项目结论来自上述独立真机对照。
- [NewNode 的 Tunnel/Info.plist](https://github.com/clostra/newnode/blob/1dcdbbc7e8de78e041526a10449367b21fd00398/ios/vpn/Tunnel/Info.plist) 和 [Nostr VPN 的 PacketTunnel/Info.plist](https://github.com/mmalmi/nostr-vpn/blob/827bcee7ce109a5e8aba37b0605b136da8532f8a/ios/PacketTunnel/Info.plist) 均直接在 Packet Tunnel 扩展中声明 Bonjour 服务列表，提供了同类配置的源码参考；不是本项目 HomeKit 通过的替代证据。
- [AzadiTunnel LANProxyBridge.swift](https://github.com/polamgh/AzadiTunnel/blob/492d8c7131875c7a5d0edb1c7a2b12b06419d967/AzadiTunnelPacketTunnel/LANProxyBridge.swift) 展示 NE 中的局域网 `NWListener`，并记录固定 Wi-Fi 地址可能返回 EINVAL、退回端口监听的路径。本项目探针同样测得 `requiredLocalEndpoint` 指定地址会返回 EINVAL，普通端口 listener 可连接。未复制该项目实现。
- [Gelato PacketTunnelProvider.swift](https://github.com/StreamingTelligence/Gelato/blob/2de03abbbaf3c6077edbef274092bad651ebad42/device-sdk/ios/PacketTunnel/PacketTunnelProvider.swift) 包含 NE 内 `DNSServiceRegister` 的实现。只把它作为 API 用法参考，不据其代码存在推断真机运行成功。
- [TDS-Carplay PacketTunnelProvider.swift](https://github.com/thomasdye12/TDS-Carplay/blob/67659078a405102c7120e1d0962d3f03816ac12d/SelfAirPlayTunnel/PacketTunnelProvider.swift) 通过 `packetFlow` 注入合成 Bonjour 包，面向本机虚拟隧道。它不等于向物理局域网发布 HAP，本项目未采用这种路径。

Apple [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) 对使用 Packet Tunnel 承载网络监听服务的用途限制仍然存在。本次自用实验测量实际行为，不改变该 API 的支持范围。

## 验证方法与实现

1. Debug 的 `NetworkDiagnosticProbe` 分别记录 TCP listener、Bonjour 注册结果及实际接受连接数。所有 GCD / Network 回调显式为 `@Sendable`，只将计数更新送回 MainActor；C 注册探针只记录同步策略结果。真机复测触发接受连接和注册成功后，探针继续运行。
2. 最终常规 NE 模式不启用探针。关闭 UDP fixture 自测定时写入，证据明确记录 `fixtureSelfTestWrites=false`。自测写入改为单独的 `--start-extension-udp-self-test` 参数；配置校验只允许专用 UDP fixture 启用。
3. Mac 运行独立的 miIO UDP 模拟器与独立加密 HAP 客户端。客户端先配对、验证，订阅电源特征通知；手机切到系统设置后，每 15 秒开 / 关一次，检查 HAP 读回及对应的加密 EVENT 通知。
4. 返回实验 App 采集同一 NE 会话的后台计数。比较器新增“自测写入已关闭”和“没有新增传输失败”检查，防止定时自测冒充外部 HAP 控制。
5. 测试结束移除临时控制器配对，停止实验 VPN 及 Mac UDP 模拟器。临时输入配对文件在脚本 finally 中删除；证据不导出设备 token、配对码或桥密钥。

## 私密本地证据

证据位于仓库 `build/validation/ios-ne-noauth-investigation-20261105/`，不进入版本控制：

- `bonjour-declaration-only/`、`repaired-probe-after-connect/`、`reverted-declaration-control/`：配置对照、注册返回码和独立 TCP 连接结果。
- `ne-external-hap.log`：首次修复后 NE 的外部 HAP 测试，一项通过。
- `final-bundle-declarations.json`：最终签名包实际携带的两个服务列表，扩展无用途字符串。
- `background-before/`、`background-after/`：同一扩展会话的前后证据和独立 UDP 服务器计数。
- `external-hap-checkpoint.local.json`、`background-external-hap.log`：外部读写及对应通知的累计证据。
- `bonjour-background.local.txt`：App 在后台时，Mac 实际解析到 HAP 服务、端口与已配对状态。
- `new-tcp-connection-in-background.local.json`：后台期间新建 TCP 连接的独立检查。
- `notification-retest/`：修正事件匹配后的完整复验，包含前后证据、外部测试退出结果、310 秒后台窗口、最终汇总及清理记录；最终外部测试一项通过。

主机运行时测试位于 `build/ios-ne-noauth-host-tests.log`：三项执行通过，一项外部连接测试按条件跳过。iOS / tvOS 模拟器编译通过；模拟器编译不替代真机 NE 验收。

本次不建立 Apple「家庭」App UI、真实米家家电、Apple TV、锁屏 / 待机、网络切换或长期稳定性结论。
