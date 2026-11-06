# iOS / Apple TV Network Extension 最小实验

TV 独立发布分支为 `MijiaLAN-tvOS`，版本标签采用 `tvos-vVERSION-bBUILD`。首个自签实验预发布为 **0.1.0 (2)**；真机 Release IPA 未签名，安装要求与完整步骤见 [INSTALL.md](INSTALL.md)。此通道独立于 macOS 的 `v*` 和 Rust 的 `rs-*` 标签。

本目录是自签、自用的实验。App 配置设备、启动 VPN 配置并显示证据；`NEPacketTunnelProvider` 进程运行共享的米家控制和 HomeKit 桥。前台 App 不承担扩展模式下的轮询。最低 iOS 18 / tvOS 18。

iOS 与 tvOS 的 App 和 Tunnel target 直接使用同一份 `App/`、`Tunnel/` 及 `TVPrototypeKit` 源码，分别编译和签名。目录与旧包名保留，避免破坏既有 tvOS 构建路径。两端有独立 App Group / Keychain 命名空间，数据不会跨设备同步。证据的 `platform` 字段区分 iOS 与 tvOS，比较器不接受跨平台快照作为同一次验收。

首次真机测试见 [iOS 验证记录](IOS_VALIDATION.md)。后续配置对照定位了 `NoAuth / -65555`：本机 iOS 27.0.1 需要在扩展自身的 `NSBonjourServices` 中也声明所用类型；只保留容器 App 的声明会复现失败。普通 `NWListener` 和现有 HAP 运行时均可保留，详见 [NoAuth 排查与复验](NOAUTH_INVESTIGATION.md)。

最新 iPhone 复验通过：真实 UDP fixture、独立加密 HAP 客户端、5 分 10 秒后台窗口，79 次后台认证读取、19 次确认写入，匹配通知正常，零传输失败。定时自测写入关闭；外部测试共完成 23 次开关和通知，一项通过。

## tvOS 桥接中心界面

tvOS 使用第三版「桥接中心」的原生 SwiftUI 界面：深色侧栏、中央桥接状态与管理按钮、右侧设备状态。总览、设备、家庭桥接、设置均可用遥控器导航；设备页支持按房间和离线状态筛选，详情提供实际电源操作。配对页仅在真实服务可用时展示当前配对信息；设置中可认证、保存局域网设备，最多 4 台。iOS 保留实验诊断界面，两端继续共用 `TunnelModel` 与运行时。

正常启动显示已保存的实际配置和运行状态。Debug 参数 `--design-preview` 仅用于查看选定设计的 11 台示例设备，左下角标明「界面预览 · 示例数据」；此模式不打开共享容器、Keychain 或 VPN 配置，也不启动任何设备通信。`--simulator-fixture` 则启动真正的共享前台运行时，使用 1 台内存模拟净化器，界面明确标记「前台桥接」。两种模式的状态不混用。

界面代码位于 `App/TV/`，遥控器集成测试位于 `UITests/TVBridgeUITests.swift`。视觉比较与交互结果见 [design-qa.md](design-qa.md) 和 [TV_UI_VALIDATION.md](TV_UI_VALIDATION.md)。

「设置 → 诊断信息」已按 macOS 原生版补齐：重新采集逐台设备的健康、属性值与错误码、重试情况、HomeKit 失败属性和运行证据，支持遥控器进入设备详情及导出 JSON。浏览器预览可直接下载最近报告；示例与历史数据均有明确标签。字段、取出命令与验证范围见 [DIAGNOSTICS.md](DIAGNOSTICS.md)。

「设置 → 检查更新」读取独立 TV 清单，显示新版本、更新说明和发行页二维码；支持前台自动检查及缺少专用接口时的 GitHub 回退。纯示例模式不联网。服务端路径、通道与验证范围见 [UPDATES.md](UPDATES.md)。

浏览器手动体验使用 [电视专用预览入口](Preview/README.md)：显示真实模拟器画面，并在画面之外提供「打开应用」「应用设置」及方向 / 确认 / 返回按钮。普通 iOS 镜像的屏幕点击不适合作为 tvOS 触屏输入。主屏的正式实验入口使用绿色房屋图标；测试完成后移除独立 XCTest Runner，避免两个白色占位入口混淆。

Apple 在 [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) 中把 Packet Tunnel 承载网络监听服务列为不支持的用途。本实验只用于测量实际行为，不提供后台稳定运行或审核通过的承诺。

## 构建

需要 Xcode、目标平台 SDK 和 XcodeGen（本机已有）。从仓库根目录运行：

```sh
bash Experiments/AppleTV/build.sh simulator
```

也可以先运行 `python3 Experiments/AppleTV/prepare.py`，再打开本目录的 `MijiaLANTVPrototype.xcodeproj`。选 `MijiaLANTVPrototype` scheme 和 Apple TV 模拟器。

### iOS 真机实验

选 `MijiaLANiOSPrototype` scheme 和已配对的 iPhone / iPad。App ID 为 `com.ipocket.MijiaLAN.iOSPrototype`，扩展为 `.Tunnel`，App Group 为 `group.com.ipocket.MijiaLAN.iOSPrototype`。两个 target 必须使用同一开发团队，并在各自描述文件中包含同一个实验 App Group、`packet-tunnel-provider` 和共享 Keychain 权限。

iOS 两个 target 共用 `iOS/Prototype.entitlements`。App Group 写明确标识，不使用自定义构建变量作为权限值，避免 Xcode 的自动注册步骤忽略该组。首次签名若旧描述文件未包含该组，可在两个 target 的 Signing & Capabilities 中选择开发团队并刷新描述文件。

容器 App 继续声明局域网用途和 Bonjour 服务类型。当前实测系统还需在 `Tunnel/Info.plist` 重复 `_hap._tcp` 与 `_miio._udp` 的服务类型列表；这是有移除 / 恢复对照证据的兼容配置，不是增加新的 entitlement。扩展不另加局域网权限用途字符串；一般配置建议与本机观察的差异记录在排查报告中。

```sh
MIJIALAN_IOS_TEAM=YOUR_TEAM_ID bash Experiments/AppleTV/build.sh ios-device
```

`ios-simulator` 只用于前台界面 / 共享运行时检查，不能代替真机 NE。`ios-archive` 创建供本地签名分发的 Release Archive，不上传 App Store Connect。

先选择模拟设备并「启动扩展」，在手机上完成系统 VPN 和局域网授权。此时模拟设备依然在内存运行，HomeKit 使用实际网络服务；要从 Mac 或另一台设备测试 HAP TCP 与 Bonjour 可达性。然后返回主屏、切换其他 App、锁屏，分别保存 5 / 15 / 30 分钟证据。模拟设备验收只证明 iOS 扩展宿主与 HAP 路径；真实米家验收还要手动配置设备 IP / token，并检查实体设备状态。iOS 通过不代表 tvOS 已通过。

Debug 真机构建支持 `--start-extension-fixture`：选择专用模拟设备后尝试真正的系统 NE，便于命令行调试；`--stop-extension` 关闭本实验 VPN 及按需连接。不会自动读取生产设备配置。首次系统授权仍需在手机上完成。

Debug iOS 还提供「前台对照」与 `--device-foreground-fixture`：在同一台真机、相同签名下运行相同业务代码，切后台即停止，记录为 `executor=deviceForeground`。它用于对比 NE 的监听 / Bonjour 行为，不构成后台运行证据。首次局域网授权可能只在这一模式下弹出。

### 真实 UDP 的受控模拟设备

`UDPFixtureHost` 在 Mac 的指定局域网 IPv4 地址上提供一个模拟净化器，使用固定的公开 fixture token，不接触生产设备。先启动服务器，再以 Debug 参数启动手机 App：

```sh
swift run --package-path Experiments/AppleTV --scratch-path build/tvos-prototype-tests UDPFixtureHost MAC_LAN_IPV4 build/udp-fixture-stats.json 900
# 在另一个终端中：
xcrun devicectl device process launch --device DEVICE_UDID --terminate-existing com.ipocket.MijiaLAN.iOSPrototype -- --start-extension-udp-fixture MAC_LAN_IPV4
```

此模式保留 `fixture=true`，标记 `transportKind=udpFixture`，与内存模拟器 `memoryFixture`、真实设备 `udpDevice` 区分。miIO 请求通过真实局域网 UDP 往返，服务器输出独立报文计数。**默认关闭自测定时写入**，便于独立统计外部 HAP 控制。如果需要复现早期的 UDP 自测，改用 `--start-extension-udp-self-test MAC_LAN_IPV4`；此时 `fixtureSelfTestWrites=true`，定时开关不能算作外部 HomeKit 控制。服务器最多运行 30 分钟，示例为 15 分钟；测试结束先停止实验 VPN，再结束服务器。

已配对的真机可通过只读脚本保存脱敏证据。iOS 设备文件服务可能拒绝 App Group 访问，App 因此仅在前台把三份脱敏运行记录及可选网络探针记录暂存到自己的 `Documents/Diagnostics`；Keychain 材料不导出。基线与后台观察结束后均须打开 App，等待当前状态刷新，再采集快照。后台期间导出文件不会更新，其 `updatedAt` 来自真实运行时：

```sh
python3 Experiments/AppleTV/capture_device_evidence.py --device DEVICE_UDID --platform iOS --output build/validation/ios-ne/before
# 切后台后，从另一台设备操作桥，至少观察五分钟；重新打开 App 等状态刷新，再保存到 after。
python3 Experiments/AppleTV/capture_device_evidence.py --device DEVICE_UDID --platform iOS --output build/validation/ios-ne/after
python3 Experiments/AppleTV/compare_evidence.py build/validation/ios-ne/before/evidence.json build/validation/ios-ne/after/evidence.json --fixture-only
```

`--fixture-only` 的结果明确标记为模拟设备模式。配置真实米家设备后，去掉此参数才是原有的真实设备验收；两种模式不能混用。脚本仅复制脱敏 JSON，不导出 Keychain 或配对码。外部 HAP fixture 测试的私密输入 JSON 可增加 `host` 字段，指向真机局域网地址；未填写时仍连接模拟器 loopback。

Debug 的 `--diagnose-extension-network` 在专用模拟设备模式启动独立 TCP / Bonjour 探针；`--diagnose-foreground-network` 提供同机前台对照。探针只用于定位服务类型注册和端口可达性，结果写入 `network-diagnostics.json`。`processID` 必须与当前会话核对，历史探针文件不代表当前状态；正常后台验收不启用探针。

`prepare.py` 从原生端同路径的 `Vendor/MenuBarMijia` 本地 MijiaCore 和当前工作区的协议/桥接源代码生成 `.generated/` 本地包，不再依赖已经失效的上游仓库或 `.build/checkouts`。仅在副本上隔离 Mac 专用 HA 子进程和自更新驱动、睡眠断言，并使用独立的实验桥名称。源文件来源和摘要保存在 `.generated/MijiaTVDependencies/source-manifest.json`。修改共享源后要重新 prepare；同步核对见 [NATIVE_ALIGNMENT.md](NATIVE_ALIGNMENT.md)。

## 模拟器

1. tvOS 在「设置」选择「使用模拟设备」，再到「家庭桥接」按「开启桥接」；iOS 使用「前台测试」。这会验证界面、miIO 加密编解码、状态刷新，以及实际 HomeKit TCP 服务。设备本身由内存 fixture 模拟，没有真实 UDP 流量。
2. tvOS 在停止桥接后进入「设置 → 配置局域网设备」，填写真实设备 IP、32 位 token 和名称，再「认证并保存」。此模式使用实际 UDP，保存后重新开启桥接。
3. tvOS Debug 启动参数 `--start-extension-fixture` 或 iOS 的「启动扩展」直接尝试系统 VPN/扩展流程。若模拟器不支持或系统拒绝，界面显示错误，绝不自动降级为前台运行。tvOS 诊断页采集现有运行状态，真机的正常「开启桥接」使用系统扩展。
4. 前台测试随 App 进入后台而停止。`executor=simulatorForeground`、`fixture=true` 的记录不能作为扩展后台或真实设备验收证据。

Debug 启动参数 `--simulator-fixture` 自动进入模拟器前台测试，仅在模拟器构建处理；`--start-extension-fixture` 自动尝试模拟设备的真实扩展模式，也可在 Debug 真机使用。

模拟器构建仍需 Xcode 的临时签名来携带 Keychain / App Group entitlement；脚本使用 `CODE_SIGN_IDENTITY=-`。不要禁用模拟器代码签名，否则共享 Keychain 会返回权限错误。

## 真机签名与安装

在 Xcode 的 App 与 Tunnel 两个 target 选择同一个 Apple Developer Team，启用自动签名。需要以下能力的有效 tvOS 描述文件：

- Network Extensions：`packet-tunnel-provider`
- App Groups：`group.com.ipocket.MijiaLAN.TVPrototype`
- 共享 Keychain：`$(AppIdentifierPrefix)com.ipocket.MijiaLAN.TVPrototype.shared`

App ID 分别是 `com.ipocket.MijiaLAN.TVPrototype` 和其 `.Tunnel` 子 ID。它们与正式 Mac App 分离。开发签名需要有效开发证书和描述文件，临时 ad-hoc 签名无法替代真机 entitlement 授权。

```sh
MIJIALAN_TV_TEAM=YOUR_TEAM_ID bash Experiments/AppleTV/build.sh device
```

配对 Apple TV 后可在 Xcode 直接 Run。Archive 位于仓库 `build/MijiaLANTVPrototype.xcarchive`，只供本地分发，不上传 App Store Connect。首次启动扩展需要在电视上接受系统 VPN 授权。

## 后台验收

1. 先用模拟设备尝试扩展能否激活；成功后切到真实设备配置并重新启动。扩展连通与桥 TCP 可达是独立检查。
2. 前台确认真实设备认证读数增长，使用电源按钮完成一次受控操作。界面有意只提供电源操作，避免动作型设备的额外副作用。
3. 在另一台设备的「家庭」中手动添加 `MijiaLAN NE Experiment`，输入界面配对码，验证读、写和实际设备状态。
4. 保存 App Group 下 `evidence.json` 的基线；按 TV 键返回主屏并打开其他 App。观察至少 5、15、30 分钟，期间用 iPhone「家庭」读写设备并确认实体状态。重新打开实验 App 后保存第二份证据。
5. `backgroundReads` 只累计 App 标记为后台期间通过 token 校验、请求 ID 匹配且属性成功的回复；`backgroundWrites` 只累计同期间确认成功的写回复。心跳与 socket 收到数据不算设备连通。设备名、ID、时间和状态仍属私密诊断；token、配对码和桥身份均不写入证据。
6. 运行 `python3 Experiments/AppleTV/compare_evidence.py before.json after.json` 辅助检查同一扩展会话、真实设备、后台读写增长和桥状态。模拟器前台不能通过；`--fixture-only` 的通过结果始终标记为模拟设备模式，并要求 UDP fixture 关闭定时自测写入。
7. 另外测试 TV 待机/唤醒、断网恢复、VPN 停止重启和系统回收。`lastSystemEvent` 记录 `sleep` / `wake` / 停止原因；最大心跳间隔用于发现执行中断。App 切后台成功不等于系统待机时仍能运行。

扩展启动阶段及系统错误域/错误码写入 App Group 的 `activation.json`，用于区分读取配置、保存配置与真正启动扩展失败。已执行的验证和当前限制见 [VALIDATION.md](VALIDATION.md)。

## 排查模拟器 IPC failed

本机 tvOS 27.2 运行时没有 `nehelper` / `nesessionmanager` 可执行文件及服务注册项。独立最小 App 在 NE 权限、NE + Personal VPN 权限、Apple Development 签名三组条件下均无法读取 VPN 配置；全新模拟器也复现。因此当前错误来自模拟器缺少相应系统服务，增加 Personal VPN entitlement 或更换证书无法解决。

可复现的只读诊断：

```sh
python3 Experiments/AppleTV/diagnose_simulator.py --simulator "BOOTED_APPLE_TV_UDID"
```

脚本核对模拟器服务、原型签名及实际嵌入的权限，并编译、安装两个无项目依赖的最小 App，分别尝试读取 Packet Tunnel 和 Personal VPN 配置。它不会保存或启动 VPN；完成后移除诊断 App。可选 `--team "TEAM_ID" --development-identity "Apple Development: …"` 增加开发证书对照。

注意：Xcode 的模拟器权限在 Mach-O `__TEXT,__entitlements` / `__ents_der` 节中。只看 `codesign -d --entitlements` 可能得到空字典，不能据此认定模拟器丢失 NE 权限。

扩展使用 `198.18.0.1/32` 主机地址、空的 IPv4 接管路由和 loopback 形式的占位远端地址；没有默认路由、DNS/代理覆盖、IPv6 接管或远程 VPN 服务器。这些设置不请求接管其他目的地址；实际 UDP 通断、TCP 可达和 Bonjour 发布仍须真机检验。已应用的配置摘要会随扩展证据写入 `networkSettings`，比较器要求 IPv4/IPv6 接管路由均为零。

「下次启动扩展时自动重连」默认关闭。开启后，启动时保存覆盖任意网络接口的 `NEOnDemandRuleConnect`。按「停止」会先持久保存关闭按需连接及禁用该 VPN 配置，再请求停止会话；即使保存失败也会请求停止，并显示未能关闭自动重连的错误。偏好保留供下次手动启动使用。系统是否在断网/重启后自动恢复仍需真机观察。其他 VPN 配置可能与本实验互斥，测试结束用「停止」关闭实验配置。

配置选择及实现证据见 [GitHub 项目核对](GITHUB_RESEARCH.md)。

## 自动化测试

```sh
python3 Experiments/AppleTV/prepare.py
swift test --package-path Experiments/AppleTV --scratch-path build/tvos-prototype-tests
```

集成测试使用真实 loopback UDP、生产 miIO 加密/解析和独立的加密 HAP TCP 控制器，完成配对、验证、HomeKit 写入和后台标记后的统计。测试的执行进程为 Mac 测试宿主，不能证明 tvOS 扩展的后台行为。测试不访问生产设备或生产钥匙串。
