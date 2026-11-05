# 原生版与 Rust 版共用更新域名

原生客户端继续读取 `https://mijialan-updates.ipocket.xyz/appcast.xml`，原生签名公钥和客户端配置不变。Rust 客户端分别读取 `/rs/macos-arm64/appcast.xml`、`/rs/macos-x86_64/appcast.xml`、`/rs/windows-x86_64/appcast.xml`，并使用独立 Rust 更新公钥。

`update-site.json` 只包含域名、仓库和两套公钥，不含私钥。`scripts/update_site.py` 从已公开的 Release 附件重建完整站点，验证签名、长度、版本和平台路径。Rust feed bundle 同样有独立 Ed25519 签名，只有其三个规定的路径可以进入站点。各平台保留自己的最新更新；原生与 Rust 不会互相覆盖。

`native-release.yml`、`native-update-feed.yml` 和新增 `shared-update-site.yml` 使用相同的部署并发组，在锁内收集全部更新源。原生发布传入本次已经验证的根 appcast；Rust 发布后通过 Actions API 请求 main 的 `Refresh shared update feeds`，等待实际部署与公开路径验证完成。Pages 环境继续由 main 使用。

先合入这部分服务配置，再发布带自动更新的 Rust 包。Rust 分支的 `macos-release` 环境需要独立 `RUST_UPDATE_PRIVATE_KEY`，与此处 Rust 公钥对应；原生 `SPARKLE_PRIVATE_KEY` 保持不变。Rust 发布继续是 `rs-vVERSION-bBUILD` prerelease，不改变原生 Latest。

运行 `python3 -m unittest discover -s scripts/tests -v` 验证共享站点逻辑。手动恢复可运行 `Refresh shared update feeds`；该操作只验证和重新部署现有公开 Release 的更新源，不会上传或改写应用包。
