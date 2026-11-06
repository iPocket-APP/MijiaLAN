# MijiaLAN TV 侧载实验版安装

当前版本为 **0.1.1 (3)**，分支 `MijiaLAN-tvOS`，标签 `tvos-v0.1.1-b3`，最低 tvOS 18。

`MijiaLAN-tvOS-0.1.1-b3.ipa` 是**供侧载工具重签的安装包**。App 和 NE 内含不使用个人证书的临时权限模板，便于重签工具识别 Network Extensions、App Groups 与共享 Keychain；它不是 Apple 授权给设备的 Ad Hoc 分发签名，不能直接安装。包中没有个人证书、私钥、描述文件或设备资料。

## Sideloadly 安装

1. 从 [Sideloadly 官网](https://sideloadly.io/) 安装当前版本。Apple TV 4K 无线侧载使用 Mac；Mac 和电视连接同一局域网。
2. 在电视打开「设置 → 遥控器与设备 → 遥控 App 与设备」，在 Sideloadly 或 Xcode 中完成配对。
3. 将上述 tvOS IPA 加入 Sideloadly，选择 Apple TV 和自己的 Apple 账号。
4. **保留所有 App Extensions / PlugIns**。不要启用删除扩展的选项；本 App 必须保留 Packet Tunnel 扩展。
5. 使用能授权 `packet-tunnel-provider` 的开发团队。普通免费账号可以侧载许多 App，但不能据此认为它能授权本实验的 NE 后台功能。App 与扩展的描述文件都须有 Network Extensions、同一个 App Group，以及至少一个相同的共享 Keychain 组。
6. 由 Sideloadly 重签并安装。安装后在「家庭桥接」启动服务，完成电视上的 VPN 和局域网系统确认，再进行后台读写验收。

运行时会从最终的 XML / DER 代码签名中读取实际共享权限，按 App 与 NE 的交集选择存储位置；Provider ID 从实际嵌入的扩展读取。工具修改 Bundle ID、团队前缀或共享组后，无需再手工修补旧 `PrototypeAppGroup` / `PrototypeKeychainGroup` Info.plist 值。原有且仍获授权的共享组优先保留。更换账号或 Bundle ID 可能形成新安装身份，不能保证访问旧身份的数据。

**签名工具不能补授 Apple 未授权的能力。** 若 Sideloadly 删除了 NE 权限，或生成的描述文件没有该能力，应在开发者后台核对两个实际 App ID 的能力并重新生成匹配描述文件。Sideloadly 官方更新记录将“自定义 entitlements”列为开发者计划账号和 Patreon 功能；本项目不承诺所有账号或工具选项均能完成授权，也不要求购买该功能。[官方更新记录](https://sideloadly.io/changelog)

## 导出后先检查

在 Mac 上导出 Sideloadly 重签后的 IPA，下载同一发行页的 `verify_sideload.py`，再运行：

```sh
python3 verify_sideload.py /path/to/resigned.ipa --report build/resigned-check.json
```

可增加 `--device YOUR_APPLE_TV_UDID`，私下检查两个描述文件是否均包含这台设备。报告不输出设备列表、证书内容或私钥。检查覆盖两个签名、真实平台、Provider、版本一致性、证书与描述文件、NE 授权及共享组交集；不会安装或启动 App。App Store 分发描述文件不能作为直接侧载设备授权。

原始分发包的检查需显式加 `--template`：

```sh
python3 verify_sideload.py MijiaLAN-tvOS-0.1.1-b3.ipa --template
```

这个模式仅检查权限模板，不表示可以安装。安装、NE 激活、HomeKit 可达和后台持续运行仍是不同验收步骤；当前没有 Apple TV 真机的完整 Sideloadly 验收记录。

## 从源码签名

```sh
git clone --branch MijiaLAN-tvOS https://github.com/iPocket-APP/MijiaLAN.git
cd MijiaLAN
brew install xcodegen
python3 Experiments/AppleTV/prepare.py
xcodegen generate --spec Experiments/AppleTV/project.yml
open Experiments/AppleTV/MijiaLANTVPrototype.xcodeproj
```

在两个 TV target 选择同一团队，为自己的账号设置可用的 Bundle ID、App Group 和共享 Keychain，再选择已配对 Apple TV 运行。App 与扩展的描述文件必须授权相同的共享组。

软件更新读取独立 TV 清单并展示发行页二维码，安装新版通过 Mac 重新侧载完成。覆盖更新应沿用账号、Bundle ID 和共享组；测试结束在 App 中停止桥接，自动重连默认关闭。

Packet Tunnel 承载网络监听属于 Apple [TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) 的不支持用途，继续保持自签实验定位。
