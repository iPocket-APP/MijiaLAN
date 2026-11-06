# MijiaLAN TV 0.1.0 (2) · 自签实验预发布

从独立 `MijiaLAN-tvOS` 分支发布，支持 tvOS 18 及以上。

**IPA 未签名，安装前需要自己的 Apple Developer 团队与适用的 tvOS 描述文件，同时签名 App 和 Network Extension。** 详细步骤见附带的 `INSTALL.md` 或源码中的 `Experiments/AppleTV/INSTALL.md`。

- 原生「桥接中心」：总览、设备、家庭桥接、设置，支持遥控器导航和独立 TV 图标。
- 局域网设备认证、配置及电源控制；共用原生端的 miIO / MIoT 和 HomeKit 业务代码。
- 诊断报告、逐台设备属性和错误信息、JSON 导出与敏感字段脱敏。
- 线上检查更新、版本说明及发行页面二维码，使用独立 TV 更新服务。
- 包含 iPhone NE 实验中经对照修复的 Bonjour 服务声明；iOS 与 tvOS 分别编译签名。

已验证模拟器界面、遥控器、受控加密 UDP / HAP 测试及线上版本检查。**Apple TV 真机、真实家电和 tvOS NE 后台持续运行尚未验收。** iPhone 的受控后台验证不代表 Apple TV 已通过。

本次发布已完成 tvOS arm64 Release Archive，TV 共享测试 11 项执行通过、1 项外部集成用例跳过，原生设备能力与 HomeKit 映射回归 45 项通过。此前遥控器回归 9 项和线上 HTTPS 检查 1 项通过。

此版本提供实验包及源码，不是 App Store / TestFlight 发行，也不提供电视内自动安装。Packet Tunnel 承载监听服务属于 Apple TN3120 的不支持用途，保持自签实验定位。

附件包括 arm64 真机 Release IPA、SHA-256 校验、未签名状态清单和安装说明。请在自行签名及安装后按 README 的前台、后台和停止流程验证。
