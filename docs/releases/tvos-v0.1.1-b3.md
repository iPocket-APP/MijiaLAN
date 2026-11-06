# MijiaLAN TV 0.1.1 (3) · Sideloadly 侧载适配实验版

从独立 `MijiaLAN-tvOS` 分支发布，支持 tvOS 18 及以上。

修复侧载更换签名身份后，App 与 Network Extension 仍使用旧共享组、Keychain 前缀和固定 Provider ID 的问题。运行时读取安装包最终的 XML / DER 签名，选择双方实际获授权的共享组，并由 NE 独立核对传入的共享权限。

- IPA 为 App 和 NE 保留证书无关的权限模板，便于重签工具识别 Packet Tunnel、App Groups 与共享 Keychain。
- 从实际嵌入的扩展发现 Provider ID，支持重签后的 Bundle ID 与 App ID prefix；扩展丢失、共享权限缺失或身份不一致会明确报错。
- 附带 `verify_sideload.py`，可在 Mac 检查模板，或检查重签导出包的 App / NE 签名、真实设备描述文件、NE 授权、共享权限和设备注册。
- 提供 Sideloadly 安装说明、GitHub 参考资料与验证边界，详见附件 `INSTALL.md`、`SIDELOADING.md`。

**IPA 必须由用户用能够授权 Network Extensions 的开发团队重签。** 临时权限模板不等于 Apple 的 Ad Hoc 设备授权；普通免费侧载账号不能因此获得 NE 权限。请保留全部 App Extensions / PlugIns，App 和 NE 均须有匹配的设备描述文件。包中没有个人证书、私钥、描述文件或设备列表。

已完成 tvOS arm64 Release Archive，共享运行时 18 项执行通过、2 项集成用例跳过（含 7 项签名专项通过），IPA 变异校验 5 项通过，模拟器界面回归 3 项通过。实体 iPhone 已验证现有描述文件授权、新 NE 进程读取共享配置和短时后台轮询；故意将旧 Info.plist 共享值改错并重签后，新 NE 仍成功读取配置和启动桥。Sideloadly 已实际载入 tvOS 候选 IPA，但尚未产生账号重签导出包；没有 Apple TV 真机，**tvOS 上的重签安装、NE 激活和后台 HomeKit 控制仍未验收**。

更新仍通过 Mac 重新侧载安装，电视内只检查版本和显示发行页二维码。Packet Tunnel 承载网络监听属于 Apple TN3120 的不支持用途，继续保持自签实验定位。
