# 隐私与数据流

扫码登录连接 `account.xiaomi.com`，登录凭据交换连接 `sts.api.io.mi.com` 等小米域名，设备导入连接对应地区的 `api.io.mi.com`。登录跳转仅接受 HTTPS 的小米域名。登录会话不持久化。

设备规格来自 `miot-spec.org`，下载后保存在应用数据目录。日常读写使用 UDP 54321，设备发现使用本地广播。HomeKit 桥通过 TCP 和 mDNS 与家庭客户端通信。

普通设备清单保存名称、ID、型号、IP、房间和桥接偏好，不含 Token。凭据加密文件保存 Token、HomeKit 私钥、配对信息和布局编号。加密密钥只保存在系统凭据服务中。没有明文后备存储。

CLI 输出和错误不包含 Token；但设备名称、IP、ID 和状态也可能是私密信息，分享诊断记录前请自行检查。扫码二维码和 HomeKit 配对码也应视为凭据，不要公开发布。

应用没有自建云服务、遥测或广告 SDK。退出应用会停止桥接；面板收起时后台功能继续运行。

正式桌面包通过 `mijialan-updates.ipocket.xyz` 检查 Rust 版更新，更新包从 GitHub Releases 下载。macOS 使用 Sparkle，Windows MSI 安装版使用 WinSparkle；两者会验证更新包的 Ed25519 签名。可以在设置中关闭自动检查；Mac 可选择提前下载并在退出时自动安装，未选择时和 Windows 一样由更新窗口确认安装。更新检查不发送设备清单、Token 或 HomeKit 配对信息；演示、预览和 CLI 不检查更新。Windows 便携版保留手动更新方式。

主动导出的诊断报告包含设备名称、标识、读数、错误及家庭桥状态，按字段白名单生成，并过滤凭据、网络地址和配对码。报告仅保存到本机，不会自动上传；Mac 位于 `~/Library/Logs/MijiaLAN Rust`，Windows/Linux 位于独立应用数据目录的 `Logs`。邮件入口打开待发送草稿，附件需由用户查看并决定是否分享。
