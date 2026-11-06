# iOS Network Extension 真机验证 — 2026-11-05

这是首次测试记录。后续通过移除 / 恢复扩展服务声明定位并修复了 `NoAuth`，NE 的外部加密 HAP 对照已通过；最新后台复验见 [NoAuth 排查与复验](NOAUTH_INVESTIGATION.md)。下文保留首次失败的测量与限制。

分支：`codex/tvos-network-extension-prototype`。环境：Xcode 27.2，iPhone 12 Pro Max，iOS 27.0.1。iOS / tvOS 使用相同业务与 provider 源码，分别构建、签名；本记录不代替 Apple TV 真机验收。

**结果：NE 中的局域网 UDP 模拟设备后台通信通过；NE 中的 HomeKit 桥未通过。** 没有读取生产设备 token，也没有操作真实米家设备。

## 结果表

| 检查 | 结果 |
| --- | --- |
| iOS App / 扩展开发签名、描述文件、共享 App Group / Keychain、安装与启动 | 通过；两个描述文件均包含 NE、共享组和测试设备 |
| 真实系统 NE 激活 | 通过；`executor=networkExtension`，provider 与 App 是独立进程 |
| 同一台手机、最终代码的前台 HAP TCP 对照 | 通过；Mac 经局域网完成加密配对、会话验证、模拟净化器开 / 关及读回；结束移除临时配对 |
| NE 后台真实 UDP 往返 | 通过；观察 383 秒，后台认证读取增加 220，确认写入增加 73，独立 Mac 服务器回复报文增加 293 |
| NE 后台执行连续性 | 同一会话 / PID，无传输失败，最大采样心跳间隔 5.421 秒 |
| NE 的 Bonjour 发布 | 未通过；`registrationFailed(code: -65555)`，即 `kDNSServiceErr_NoAuth` |
| NE 的局域网 HAP 配对 / 控制 | 未通过；桥未正常发布和配对，完整比较器返回 `indicatorsPassed=false` |
| iOS 与 tvOS Simulator App / 扩展编译 | 通过；编译不能证明模拟器能启动 NE |
| Mac 共享运行时自动测试 | 三项执行通过，外部连接测试默认按条件跳过；真机外部 HAP 对照另行执行，一项通过 |

## 后台 UDP 测量方法

手机使用 `transportKind=udpFixture`、`fixture=true`。Mac 的 `UDPFixtureHost` 只模拟一个使用公开固定 token 的净化器，实际接收 / 回复经 miIO 加密与认证的 UDP 报文。它与手机处于同一局域网，统计由独立进程写入文件。

保存基线后，通过设备工具打开手机系统设置，使实验 App 进入后台；383 秒后返回实验 App。前后证据的扩展会话 ID / PID 相同，`backgroundReads` 增加 220，`backgroundWrites` 增加 73；Mac 回复计数的增量为两者之和 293。认证读取总增量为 234，其中还包含前后台切换时的读取。

**73 次写入来自仅对专用 UDP fixture 启用的扩展自测定时器，不是 HomeKit 请求。** 这个结果证明本次观察期间 iOS NE 能持续运行所用的米家 UDP 协议路径，不能作为外部 HomeKit 控制或真实家电验收。

扩展请求主机掩码、空 IPv4 / IPv6 接管路由，不配置默认路由、DNS 或代理。证据记录的是请求并成功提交的设置摘要，不是整个系统路由表。

## HomeKit 失败定位

1. 初次签名缺少共享 App Group。改为明确的 entitlement 标识，启用自动注册并刷新开发描述文件后，App 和 provider 均能访问共享配置，NE 成功激活。这一签名问题已经解决。
2. 用户分别完成 VPN 配置授权和局域网授权；授权后重启 NE，Bonjour 仍返回 `-65555`。该错误与 `kDNSServiceErr_PolicyDenied`（`-65570`）不同，不能仅按“未点局域网允许”解释。
3. 临时改用 `NWListener.service` 发布 Bonjour，并另做显式 Wi-Fi 接口约束。内部服务曾显示运行，但 Mac 经手机 IPv4 / IPv6 均无法连接 HAP 端口；同期手机设备服务端口可连接。同一手机的前台运行时可以完成实际 HAP TCP 控制。
4. 上述临时适配未改善 NE 的局域网可达性，已撤销。最终代码保留原有 HAP 实现，只在实验副本中增加原始监听错误，并在启动失败时关闭 listener。
5. 最终签名构建的前台对照再次通过外部加密 HAP 测试。当前阻塞集中在已测设备上 NE 宿主的服务发布 / 可达路径，而非共享业务运行时无法完成 HAP 协议。
6. 最终代码的 NE 短测再次记录相同的 `-65555`；关闭失败 listener 后，provider 仍能完成启动，证据中的桥端口为空。随后停用 VPN，并在手机界面确认「已断开」。此次停止未留下 provider 的 `stoppedAt` 回调记录，不能用该旧快照单独判断停止状态。

Apple 的 [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) 将 Packet Tunnel 承载网络监听服务列为不支持的用途。[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 说明 NE provider 的局域网访问与容器 App 授权的关系，以及扩展所需的隐私声明应放在容器 App。错误码定义见 Apple 的 [dns_sd.h](https://github.com/apple-oss-distributions/mDNSResponder/blob/main/mDNSShared/dns_sd.h)。本次结果仅覆盖所测系统与实现，不外推所有 iOS / tvOS 版本。

## 证据与复现边界

私密本地证据位于仓库 `build/validation/ios-ne-20261105/`，不进入版本控制：

- `background-before/`、`background-after/`：前后扩展快照及独立 UDP 服务器计数。
- `background-summary.json`：后台持续时间、读写增量、间隔及明确的 `fullBridgeGoalPassed=false`。
- `full-acceptance.json`：fixture 模式完整比较器结果；桥运行和配对检查失败。
- `final-foreground-external-hap.log`：最终代码在真机前台的独立 HAP 客户端测试，一项通过。
- `signing.json`：两个签名及开发描述文件能力核对。
- `udp-server-cleanup.json`：模拟服务器停止记录。
- `final-extension-failure-cleanup/`：最终构建的 NE 失败路径复测；`cleanup-verification.json` 记录手机 VPN 断开观察、服务器进程及端口检查。

`build/ios-prototype-host-tests.log` 保存默认主机测试，`build/ios-prototype-device.log` 保存真机签名构建。iOS 设备文件服务不能直接读取本机 App Group 时，由 App 在前台暂存三份脱敏 JSON 到自己的 `Documents/Diagnostics`；后台期间暂存副本不更新，须返回 App 等待刷新后再采集。证据不导出 token、配对码或桥身份。

本次只完成切换其他 App 的约六分钟观察。锁屏 / 休眠、15 / 30 分钟、系统回收、网络切换、On Demand 恢复、真实家电及 Apple TV 验收均未通过本次测试建立。实验 VPN 与 Mac UDP 模拟服务器在测量后停止。
