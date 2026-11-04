# GitHub Actions macOS 正式签名

普通 `ci.yml` 执行 macOS / Windows 构建验证。`release-macos.yml` 单独处理 Apple Silicon 正式签名、公证和 DMG / ZIP 封装，不在 pull request 事件中运行，也不自动创建 GitHub Release。

## Environment

仓库 `iPocket-APP/MijiaLAN` 使用 `macos-release` 环境，只允许 `MijiaLAN-rs` 分支和 `rs-v*` 标签。环境规则可以预先存在，匹配的分支和标签需要实际推送后才能使用。

| 配置类型 | 名称 | 用途 |
| --- | --- | --- |
| Secret | `MACOS_CERTIFICATE_P12_BASE64` | 包含 Developer ID Application 私钥的加密 P12，转 Base64 |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | P12 加密密码 |
| Secret | `APPLE_API_KEY_P8_BASE64` | App Store Connect 团队 API Key，转 Base64 |
| Variable | `MIJIALAN_SIGNING_IDENTITY` | 对应证书的 SHA-1 指纹或名称 |
| Variable | `APPLE_API_KEY_ID` | 团队 API Key ID |
| Variable | `APPLE_API_ISSUER_ID` | 团队 API issuer UUID |

私钥只写入环境 Secrets；Git 中保留脚本和说明。`gh secret set --repo iPocket-APP/MijiaLAN --env macos-release NAME` 可从标准输入接收值，并在发送前加密。不要将秘密作为命令行字面量、日志或 Actions artifact 保存。Team API Key 按角色可访问整个团队的应用，不能按单个 App 隔离；CI 专用 Key 应选择足够完成公证的权限，并独立管理和撤销。

## 运行方式

手动运行选择 `MijiaLAN-rs` 分支及正整数 build 号。GitHub 要求带 `workflow_dispatch` 的 workflow 文件位于默认分支，才提供对应手动入口；仅在 Rust 分支保留 workflow 时可使用标签事件触发。

标签格式为 `rs-v<version>-b<build>`，例如 `rs-v0.1.0-b4`。workflow 核对 Cargo 版本、build 号以及提交是否属于 `origin/MijiaLAN-rs` 历史，在导入密钥前拒绝不匹配的版本或来源。

Runner 在 `$RUNNER_TEMP` 创建独立临时钥匙串，导入指定证书，并检查配置的签名身份。公证 P8 文件的权限受 `umask 077` 保护。`package-macos-release.sh` 在 CI 使用 `APPLE_API_KEY_PATH`、`APPLE_API_KEY_ID`、`APPLE_API_ISSUER_ID`；本地仍支持 `MIJIALAN_NOTARY_PROFILE`。

流程依次运行 Release 测试、构建、Developer ID / Hardened Runtime 签名、App 公证与票据附加、DMG 公证与票据附加及 Gatekeeper 检查。只有最终 DMG、ZIP、SHA-256 清单上传到本次运行的 Actions artifact。这些文件在 Runner 上生成，不进入源码 Git 历史。

无论打包结果如何，清理步骤恢复钥匙串搜索列表、删除临时钥匙串和私钥文件。环境、凭据和脚本已配置不等于 CI 已通过，必须另行完成一次真实 workflow 运行。密钥授权和源码提交按用户当前授权范围执行。
