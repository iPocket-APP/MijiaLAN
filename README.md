# MijiaLAN · 米家局域网桥

**简体中文** · [English](README.en.md)

在 Mac 菜单栏控制米家 Wi-Fi 设备，并通过局域网把它们接入 Apple「家庭」。

[下载](https://github.com/iPocket-APP/MijiaLAN/releases/latest) · [使用](#使用) · [设备支持](#设备支持) · [常见问题](#常见问题) · [隐私](#隐私) · [开发](#开发)

MijiaLAN 用 miIO / MIoT 协议直接和局域网里的设备通信。凭据只需导入一次：用米家 App 扫码从小米云取回，或手动填写已有的 token。之后的日常控制都走局域网。Mac 同时作为 HomeKit 桥，让 iPhone、Apple Watch、HomePod 和 Siri 也能控制这些设备。

## 功能

- **菜单栏面板**：控制中心式的设备磁贴，电源开关、详情页和离线原因都在面板里。左键显示或隐藏面板，右键菜单可以打开设置或退出。
- **Apple 家庭桥接**：按设备类型提供灯、插座、风扇、空气净化器、空调和传感器服务，可以逐台选择是否桥接。
- **两边状态一致**：Mac 与「家庭」共用同一套能力目录、轮询和命令执行。模式、亮度、色温、温度、风速、摆动、读数和厨房设备菜单按机型提供。
- **凭据只存在本机**：设备 token、设备清单和 HomeKit 配对信息保存在 macOS 钥匙串，不保存小米云登录会话。
- **自动找回 IP**：定期广播发现设备，路由器重新分配地址后按设备 ID 更新。
- **内置软件更新**：在设置或菜单栏右键菜单中检查更新。默认每天检查，自动下载和退出时安装可选择开启。
- **后台开销小**：离线设备的重试间隔逐步拉长，最长 24 小时；面板隐藏 30 秒后释放界面，再次打开时保留页面、滚动位置和输入草稿。详见[性能与后台运行说明](docs/performance.md)。
- **中英文界面**：跟随系统或单独设置 App 语言，支持浅色和深色外观。

## 下载与安装

最新原生 Swift 正式版见 [GitHub Releases](https://github.com/iPocket-APP/MijiaLAN/releases/latest)。Rust 版使用独立分支和 `rs-` 标签。

1. 在 [GitHub Releases](https://github.com/iPocket-APP/MijiaLAN/releases/latest) 下载 `MijiaLAN-<版本号>-universal.dmg`，打开后把 `MijiaLAN.app` 拖进「应用程序」。也提供 ZIP 包和 `SHA256SUMS.txt` 校验值。
2. 启动 App。macOS 询问「本地网络」权限时选择允许。

发行包使用 Developer ID 签名，启用 Hardened Runtime 并经过 Apple 公证，App 与 DMG 都附有公证票据。

从 0.1.6 起可在 App 内更新；更早版本需要先手动安装一次。软件更新通过 `mijialan-updates.ipocket.xyz` 获取清单，从 GitHub Releases 下载并校验签名。安装会重启 App，家庭桥接会短暂离线，钥匙串中的设备和配对资料继续保留。

**系统要求**

- macOS 15 或更高版本；Apple Silicon 或 Intel Mac，发行包同时包含两种架构。
- Mac 与设备的网络互通；HomeKit 发现还需要 Bonjour / mDNS 可达。
- 扫码导入和获取尚未缓存的设备规格需要联网。

## 使用

1. 打开菜单栏面板，进入设置。
2. 选择服务器地区，点击「扫码导入设备」，用手机的米家 App 扫码确认。已有凭据时，也可以手动填写设备 IP 和 32 位十六进制 token。
3. 在 HomeKit 设置里选择要放进「家庭」的设备。已经原生接入 HomeKit 的设备可以取消桥接，避免重复。
4. 在 iPhone「家庭」中选择 **+ → 添加配件**，扫描桥的二维码。HomeKit 会提示这是未认证配件，确认后继续添加。

## 设备支持

MijiaLAN 控制能在局域网里直接访问的 Wi-Fi 设备，按适配程度分三类：

| 类别 | 范围 | 适配方式 |
| --- | --- | --- |
| 内置适配 | 下表 10 个型号 | 规格随 App 打包，接口逐项核对；离线启动也保留控件 |
| 其他 MIoT 设备 | miot-spec.org 上有规格的 Wi-Fi 型号 | 导入时获取一次规格并缓存，按类别生成通用控件 |
| 早期 miIO 设备 | 约 160 个只认 `get_prop` / `set_*` 的旧型号，以及用 `get_status` 汇报状态的老款石头扫地机 | 使用转换或移植自 [hass-xiaomi-miot](https://github.com/al-one/hass-xiaomi-miot) 的映射表 |

内置适配的型号：

| 类别 | 型号 |
| --- | --- |
| 插座 | `chuangmi.plug.m3`、`cuco.plug.v3` |
| 空气净化器 | `zhimi.airpurifier.rma1` |
| 台灯 | `yeelink.light.lamp4` |
| 空调伴侣 | `lumi.acpartner.mcn02` |
| 循环扇 | `dmaker.fan.p28` |
| 破壁料理机 | `chunmi.juicer.a1` |
| 养生壶 | `chunmi.health_pot.a1` |
| 空气炸锅 | `careli.fryer.maf07c` |
| 电饭煲 | `chunmi.cooker.cmwy3` |

通用控件在「家庭」里的样子：灯、风扇和空气净化器使用对应的原生服务；加湿器、除湿机、取暖器、空调和窗帘也使用原生服务，扫地机显示为一个开关，这六类的规则参照 [homebridge-miot](https://github.com/merdok/homebridge-miot)。其他带电源开关的设备显示为插座，温度、湿度等读数显示为传感器。Mac 面板按规格生成开关、选项、数值和读数；参数定义不清的属性暂不写入，设备信息、自检等服务不显示。

**暂不支持**：蓝牙设备、Zigbee / 蓝牙 Mesh 网关子设备、云端灯组，以及靠命令而不是属性汇报状态的早期 miIO 型号。例外是米家扫地机器人（`rockrobo.vacuum.v1`）和石头 `roborock.vacuum.c1`、`e2`、`s5`：它们通过 `get_status` 和 `app_start` / `app_stop` / `app_charge` 控制，映射未经本项目实机验证。

**验证边界**：规格、协议映射和自动化测试不代表每个固件都完成了实机验收，后两类设备没有经过本项目实机验证。规格里标为可写的属性，固件也不一定接受局域网写入。

**控制上的约定**

- 厨房设备的选择菜单只设置待应用参数，开始烹饪需要单独执行动作。
- 扫地机的开关打开时开始清扫，关闭时回充；设备上报正在清扫时开关显示为开。停止、暂停、扫拖等不带参数的动作显示为具名开关，需要房间或区域参数的动作不提供。
- 参数含义没有确认的接口不会发送猜测命令。
- 「家庭」没有合适原生控件的功能，用具名开关或预设表达；部分读数只在 Mac 上显示。
- 空调和取暖器没有温度读数时，「当前温度」用设定温度占位，不是实测室温。

逐项权限、参数和验证状态可用 `mijia-lan matrix` 查看。需要保存报告时，运行 `mkdir -p build/reports && swift run mijia-lan matrix > build/reports/device-interface-matrix.md`；生成的报告不纳入版本控制。

## 常见问题

**Mac 需要一直开着吗？**
需要。桥运行在这个 App 里，Mac 休眠、关机或退出 App 时，「家庭」里的设备会显示「无响应」。App 默认阻止闲置休眠，可以在设置中关闭。在家以外远程控制或运行自动化，还需要 HomePod 或 Apple TV 等家居中枢。

**添加时提示「未认证配件」？**
正常。MijiaLAN 是社区项目，没有 HomeKit / MFi 认证，确认后即可继续添加。

**iPhone 找不到桥？**
确认 iPhone 和 Mac 在同一个局域网，网络允许 Bonjour / mDNS，并且在「系统设置 › 隐私与安全性 › 本地网络」中允许了 MijiaLAN。

**设备显示离线？**
IP 变化会自动找回。设备重新配网后 token 可能改变，需要重新导入。云端没有返回有效 token 或 IP，或者固件没有开放局域网接口的设备，无法控制。

## 隐私

MijiaLAN 没有自建云服务，也没有广告或分析 SDK。扫码导入会连接小米服务；导入或手动添加设备时，可能从 `miot-spec.org` 获取规格。设备控制使用 UDP 54321，Apple「家庭」通过局域网 HAP 桥访问设备。

源码中的测试 token 和预览数据都是示例。真实设备清单、钥匙串数据、配对码、诊断记录和本机截图不属于仓库发布内容。诊断导出不包含 token 或配对密钥，但仍可能含设备名称、ID、状态和时间，分享前请检查。

完整数据流、命令行注意事项和开源检查范围见[隐私说明](PRIVACY.md)。

## 开发

### 从源码构建

需要提供 **Swift 6.4 或更高版本**的 Xcode 或命令行工具；首次下载 SwiftPM 依赖需要联网。

```bash
git clone https://github.com/iPocket-APP/MijiaLAN.git
cd MijiaLAN
./scripts/build_app.sh
open build/MijiaLAN.app
```

脚本默认生成临时签名的 `build/MijiaLAN.app`，只用于本机运行，不会提交 Apple 公证；`./scripts/build_app.sh debug` 构建 Debug 版。正式发行流程见[发行说明](docs/releasing.md)。

### 测试与命令行工具

```bash
swift test
swift test --package-path Vendor/MenuBarMijia --scratch-path "$PWD/.build/mijiacore-tests" -c release
swift run mijia-lan discover
swift run mijia-lan matrix
```

CLI 还提供 `info`、`get`、`set`、`call`、`spec`，以及从标准输入读取设备清单的 `status`。不带参数运行 `swift run mijia-lan` 可以查看用法。

`discover` 默认不打印 token，只有明确传入 `--show-tokens` 才输出旧固件可能暴露的 token。其他命令的 token 参数可能进入终端历史和进程参数，请优先用 App 导入凭据。

### 模拟设备与截图

构建 Debug 版后，可以用模拟设备直接运行：

```bash
MIJIALAN_UI_PREVIEW=1 "$(swift build --show-bin-path)/MijiaLANApp"
```

| 环境变量 | 用途 |
| --- | --- |
| `MIJIALAN_UI_PREVIEW=1` | 仅 Debug：使用模拟设备和内存凭据，关闭 HomeKit 桥及真实设备发现 |
| `MIJIALAN_EPHEMERAL=1` | 使用内存凭据和单独的偏好设置域，不读取真实钥匙串；仍可能发送网络请求 |
| `MIJIALAN_SEED_CONFIG=<path>` | 配合临时模式，从本地 JSON 载入测试设备；文件可能包含凭据 |
| `MIJIALAN_DIAGNOSTICS_OUTPUT=<path>` | 导出读数和错误；文件仍属于私密诊断数据 |
| `MIJIALAN_SNAPSHOT=<path>` | 渲染面板截图；可用 `MIJIALAN_SNAPSHOT_DELAY` 指定等待秒数 |
| `MIJIALAN_UI_THEME=dark/light` | 配合截图选择外观 |
| `MIJIALAN_UI_PAGE=<did>/settings` | 选择截图初始页面，默认首页 |
| `MIJIALAN_UI_EXPAND=<did>,…` | 在「管理家庭设备」中展开这些设备的功能列表 |
| `MIJIALAN_SNAPSHOT_WINDOW=<seconds>` | 打开原生交互预览窗口 |

### 更新 hass-xiaomi-miot 映射表

```bash
python3 -I scripts/import_hass_xiaomi_miot.py <path>/miio2miot_specs.py <commit>
```

脚本只解析、不执行上游文件，输出 `Sources/MijiaLAN/Resources/hass-xiaomi-miot-miio2miot.json`。转换规则和改动见 [Vendor/hass-xiaomi-miot](Vendor/hass-xiaomi-miot/README.md)。

### 目录结构

| 目录 | 内容 |
| --- | --- |
| `Sources/MijiaLAN` | miIO 协议、发现、设备导入、凭据存储、能力目录和共享控制器 |
| `Sources/MijiaHomeKitBridge` | HomeKit 配件映射、桥接和配对状态 |
| `Sources/MijiaLANApp` | SwiftUI / AppKit 菜单栏界面 |
| `Sources/mijia-lan` | 命令行工具 |
| `Tests` | 协议、能力、安全边界、HomeKit 和本地化测试 |
| `Vendor/MenuBarMijia` | 自行维护的 MijiaCore 源码、资源、测试和原始 MIT 许可证 |
| `Vendor/hap-swift` | 保留原许可证的 HAP 实现及本地修复 |
| `Vendor/hass-xiaomi-miot` | 映射表的上游许可证和转换说明 |
| `Vendor/homebridge-miot` | HomeKit 类别规则的上游许可证和移植说明 |
| `scripts` | 打包、发行和映射表转换脚本 |

## 协议与致谢

本项目的原创代码使用 [MIT License](LICENSE)，版权归 iPocket-APP。第三方组件保留各自的许可证：

- [MijiaCore / MenuBarMijia](Vendor/MenuBarMijia/README.md)（MIT）：扫码登录、MIoT 规格解析、设备合成和 HomeStore，现由本项目内置维护。
- [hap-swift](https://github.com/acumen-dev/hap-swift)（Apache-2.0）：HomeKit Accessory Protocol 实现，内置副本包含本地修复。
- [hass-xiaomi-miot](https://github.com/al-one/hass-xiaomi-miot)（Apache-2.0）：早期 miIO 型号的属性映射表，转换后随 App 分发。
- [homebridge-miot](https://github.com/merdok/homebridge-miot)（MIT）：加湿器、除湿机、取暖器、空调、窗帘和扫地机的 HomeKit 服务映射规则，用 Swift 重写。
- Apple Swift 开源库及其他间接依赖：详见[第三方声明](THIRD_PARTY_NOTICES.md)。

本项目为社区项目，与小米、米家或 Apple 无隶属关系，也未获得 HomeKit / MFi 认证。第三方协议、服务及商标的权利不由本项目的 MIT 许可证授予。
