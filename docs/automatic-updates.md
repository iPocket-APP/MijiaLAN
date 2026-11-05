# Rust 桌面自动更新

与原生版共用 `https://mijialan-updates.ipocket.xyz`，按路径隔离：

| 客户端 | 更新源 | 安装方式 |
| --- | --- | --- |
| 原生 macOS | `/appcast.xml` | 原生 Sparkle，现有密钥保持不变 |
| Rust macOS Apple Silicon | `/rs/macos-arm64/appcast.xml` | Sparkle 2.10.1，签名、公证的 ZIP |
| Rust macOS Intel | `/rs/macos-x86_64/appcast.xml` | Sparkle 2.10.1，签名、公证的 ZIP |
| Rust Windows x64 | `/rs/windows-x86_64/appcast.xml` | WinSparkle 0.9.4，当前用户 MSI |

Rust 使用独立 Ed25519 公钥，固定在 `updates.json`；共享部署所信任的原生和 Rust 公钥保存在 `update-site.json`。macOS 的 bundle ID、设备凭据、HomeKit 身份和数据目录均不变；Windows 的安装目录、UpgradeCode、凭据和数据目录沿用已有 Rust 版。原生版和 Rust 版不会相互替换。

设置、应用菜单和系统托盘均提供“检查更新”。自动检查可以关闭；应用更新组件与短暂显示的托盘面板分开持有。安装更新会短暂停止 HomeKit 桥。Windows MSI 安装后，从开始菜单重新打开客户端；便携 ZIP 只提供手动更新，不会悄悄另装一份。演示、预览、临时模式和 CLI 不初始化更新组件。

## 发布流程

1. **先合入 main 的共享站点配置**：对应本地工作副本 `MijiaLAN-update-site`，包含 `scripts/update_site.py`、`update-site.json`、`shared-update-site.yml`，以及两个原生发布工作流的合并站点步骤。原生根路径与公钥不变。
2. 将独立 Rust Ed25519 的 32 字节私钥种子以 Base64 存入 `macos-release` 环境的 `RUST_UPDATE_PRIVATE_KEY`。私钥不得进入 Git、Release、构建产物或日志。轮换密钥需要迁移方案，不能直接替换已发布客户端所信任的公钥。
3. Rust 的 Build 验证 Windows、Apple Silicon 和 Intel，打包固定校验值的上游运行库，并运行 `--updater-smoke`。该模式加载真实运行库和公钥，但不启动检查、不访问设备或凭据、不保存更新偏好。
4. Signed desktop release 复用验证过的二进制，分别签名、公证两个 Mac 架构。Ubuntu 收集包时写入发布构建号，生成 MSI、平台 appcast、签名的 `rust-update-feeds.zip` 和总校验清单。Windows CI 程序和 DLL 字节保持不变。
5. 默认 `publish=false`，只产出可体验的 Actions artifacts。正式发布前检查 main 中的共享服务和 Rust 公钥是否已匹配；发布仍使用 `rs-vVERSION-bBUILD`，不占用原生版 Latest。
6. Rust Release 公开后，触发 main 的共享站点工作流并等待结果。部署账号和 `github-pages` 环境继续在 main 使用；无需允许 Rust 分支直接部署 Pages。

所有 Rust 发布构建号必须全局递增，范围 `1..65535`。两个平台使用构建号比较更新；MSI 产品版本使用 `major.minor.build`，展示版本保留 Cargo 版本，避免同一个 `0.1.0` 的不同构建漏更新或降级。

## 共享域名的覆盖保护

GitHub Pages 部署替换整个站点。所有新发布和恢复工作流使用同一并发组 `mijialan-update-pages`，在锁内重新收集完整站点：

- 原生更新保留 `/appcast.xml`。后续原生 Release 同时保存 `native-appcast.xml` 快照；即使部署排队被替代，另一版本的工作流也能从公开 Release 恢复最新原生源，并验证签名及包内身份、构建号。
- 从公开 Rust Releases 中读取独立签名的 feed bundle，拒绝跨版本、平台、架构、根路径、重复路径或额外文件。
- 每个平台独立选择最新签名源；新 ARM 包不会删除已有 Intel 源。
- 下载对应公开更新包并验证 Ed25519、包长和仓库路径，再部署；任一验证失败，不发布残缺站点。
- 部署后逐路径比对线上 appcast 字节。恢复时可在 main 手动运行 `Refresh shared update feeds`，无需重新编译、签名或修改 Release 附件。

旧 Rust 包没有更新组件，需要手动安装首次带自动更新的发布包。此后才能收到应用内更新。不要用旧版、只包含原生根目录的 Pages 部署流程覆盖新站点。
