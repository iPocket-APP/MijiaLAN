# MijiaLAN TV 实验版安装

此版本从独立 `MijiaLAN-tvOS` 分支发布，版本标签为 `tvos-v0.1.0-b2`，App 版本为 **0.1.0 (2)**。它是供自行签名测试的预发布版本，尚未完成 Apple TV 真机后台验收。

## 下载文件

- `MijiaLAN-tvOS-0.1.0-b2.ipa`：tvOS 真机 arm64 Release 包，包含 Packet Tunnel 扩展。**未签名，不能直接安装**；不包含开发者证书、描述文件或设备资料。
- `SHA256SUMS.txt`：IPA 的 SHA-256 校验值。
- `tvos-package.json`：版本、构建号、源码提交、目标平台及未签名状态。
- 源码 ZIP / tar.gz：GitHub 在同一版本标签下提供的完整源码。

需要 tvOS 18 或更新版本、Mac、Xcode，以及能为 App 与扩展授权 Network Extensions、App Groups 和共享 Keychain 的 Apple Developer 团队。需要给实际 Apple TV 配对并生成适用描述文件；iOS 描述文件不能替代 tvOS 描述文件。

## 推荐：从同一版本源码签名安装

```sh
git clone --branch tvos-v0.1.0-b2 https://github.com/iPocket-APP/MijiaLAN.git
cd MijiaLAN
brew install xcodegen
python3 Experiments/AppleTV/prepare.py
xcodegen generate --spec Experiments/AppleTV/project.yml
open Experiments/AppleTV/MijiaLANTVPrototype.xcodeproj
```

在 `MijiaLANTVPrototype` 和 `MijiaLANTVTunnel` 两个 target 中选择同一团队。使用自己的开发者团队时，为两个 target 选择可用的唯一 bundle ID，扩展 ID 应为 App ID 后加 `.Tunnel`；同时更新两份 TV entitlement 文件中的 App Group，并在 `PROTOTYPE_BASE_ID` / `PROTOTYPE_APP_GROUP` 构建设置中填写对应标识。两个 target 的 App Group、共享 Keychain 前缀和 Network Extension 权限必须一致且由各自的 tvOS 描述文件授权。iOS target 的权限文件独立，不用修改。

配对 Apple TV，选择 `MijiaLANTVPrototype` scheme 和该设备，直接 Run；也可先用 `MIJIALAN_TV_TEAM=YOUR_TEAM_ID bash Experiments/AppleTV/build.sh device` 生成有签名的 Archive，再通过 Xcode 分发给已授权设备。覆盖安装时须沿用自己的团队、bundle ID 与 App Group，以便继续使用原有设备和 HomeKit 配对资料。

已有完整重签工具链时，也可用 IPA 作为输入；必须同时重签嵌入的 `.appex` 和 App，嵌入对应的 tvOS 描述文件，并按授权前缀修正两个 Info.plist 的 `PrototypeKeychainGroup`、`PrototypeAppGroup` 与签名 entitlement。普通只重签主 App 的工具不足以运行本实验。

## 首次运行

1. 在「设置」配置设备，或选择专用模拟设备；模拟器只能验证明确标记的前台模式。
2. 在「家庭桥接」开启桥接，在设备上接受 VPN 及局域网权限提示。
3. 通过另一台设备验证 HomeKit 读写，再切到后台观察；不能把 iPhone 的 NE 测试或模拟器前台状态当作 Apple TV 后台验收。
4. 测试结束在 App 中停止桥接。自动重连默认关闭。

软件更新会检查独立 TV 清单并展示版本说明及发行页二维码。此自签实验版通过已配对的 Mac 覆盖安装新版本，不提供电视上的自动安装。

Packet Tunnel 中运行网络监听服务属于 Apple [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) 列明的不支持用途。本版本保留实验性质，不以后台稳定性或 App Store 审核作为已完成能力。
