# TV 检查更新 · 2026-11-06

tvOS 可以通过 URLSession 读取 HTTPS 版本信息并显示更新提示。Sparkle 的安装框架只支持 macOS，不是 TV 版本检查的前提。

依据与参考：

- [Apple：从服务器读取数据到内存](https://developer.apple.com/documentation/foundation/fetching-website-data-into-memory)。
- [Sparkle 官方平台说明](https://sparkle-project.org/)。
- [tvbox-silicon 的发布说明](https://github.com/jo32/tvbox-silicon/blob/main/Docs/DEVELOPMENT.md)：Apple TV 读取 JSON、比较版本 / 构建号、显示更新链接二维码。此处独立实现，没有引入其代码或依赖。

## 使用

进入「设置 → 检查更新」。页面显示当前版本 / 构建号、检查结果、数据来源、成功时间、新版本说明和发行页面二维码。检查只读取公开版本数据，不发送米家设备、token 或 HomeKit 信息，不下载或安装执行文件。自签版通过配对 Mac 覆盖安装；本功能不调用 Sparkle，不启停 NE 或改写配对。

自动检查默认开启，可在更新页关闭。它随 App 进入前台触发，当前进程内两次自动检查至少间隔六小时，手动检查不受间隔限制；没有后台计时器或 NE 保活任务。

默认接口为 `https://mijialan-updates.ipocket.xyz/tvos/releases.json`。只接收 tvOS / 本实验 bundle ID / selfSigned 通道的清单。按数值构建号比较，不把 `10` 排在 `2` 之前；较低构建号不会提示降级。

专用接口返回 HTTP 404 时，回退到 GitHub 最近 100 条公开发行记录。只识别 `tvos-vVERSION-bBUILD` 标签及非空的 `MijiaLAN-tvOS-VERSION-bBUILD.ipa`，支持已公开 prerelease；Mac / Rust、draft、缺包或错误包名均排除。网络失败、其他 HTTP 错误和无效 JSON 显示检查失败，不会当作「已是最新」。数据为空时显示「暂未发现可用的 TV 安装包」。

专用接口已在 2026-11-06 部署上线：[tvos/releases.json](https://mijialan-updates.ipocket.xyz/tvos/releases.json)，HTTP 200 / application/json。首次上线时 `releases` 为空，随后从独立 `MijiaLAN-tvOS` 分支发布首个 [0.1.0 (2) 自签实验版](https://github.com/iPocket-APP/MijiaLAN/releases/tag/tvos-v0.1.0-b2)。IPA 未签名，安装要求见 [INSTALL.md](INSTALL.md)。服务端改动经 [PR #9](https://github.com/iPocket-APP/MijiaLAN/pull/9) 合入主分支 `1feb4780406c595cb606010e3ab1331063392948`，[初次部署工作流](https://github.com/iPocket-APP/MijiaLAN/actions/runs/42207580629) 成功。上线前后四个原生 / Rust 更新源的 SHA-256 均一致。

随后发布的 [0.1.1 (3) Sideloadly 适配实验版](https://github.com/iPocket-APP/MijiaLAN/releases/tag/tvos-v0.1.1-b3) 为 App / NE 保留了供个人重签的权限模板，仍须具备 NE 授权的设备描述文件。默认 TV 接口已实际返回此版本，TV 共用解码器的在线清单输入测试通过：build 2 能发现 build 3，build 3 不提示重复更新。四个原生 / Rust 更新源的 SHA-256 再次核对一致；Mac 稳定发行仍为 v0.1.7。

GitHub Pages 的发布传播可能需要约十分钟，见 [GitHub 官方说明](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site)。部署成功后须继续核对默认接口的实际内容，不能仅凭上传 / 部署步骤成功判断新版已可见。

上线后已用 tvOS 27.2 Simulator 验收真实 HTTPS 请求：`testUpdateCheckUsesDeployedTVService` 通过（1 passed / 0 failed），App 不带预览或本地服务参数启动，遥控器进入更新页并手动检查，确认来源为「TV 更新服务」、结果为「暂未发现可用的 TV 安装包」，没有走 GitHub 回退。该测试须显式设置测试运行器环境变量 `MIJIALAN_LIVE_UPDATE_TEST=1`，平时跳过。结果包为 `build/validation/tvos-updates-deploy-20261106/ui-tests-production-v3.xcresult`，实际截图为同目录 `updates-production-service.png`。

首次包发布后，线上 UI 验收按实际清单接受「无可用包」「当前已是最新版本」或「发现新版本」三种成功状态；有更新时必须展示二维码，其余状态不展示。可先用受信任的 HTTP 客户端下载线上 JSON，再设置 `MIJIALAN_LIVE_FEED_FILE=/absolute/path/releases.json` 运行 `TVUpdateFeedTests`，验证实际生产清单可由客户端解码，且较旧构建能发现最新包、当前构建不会重复提示。这样不会把尚未发布包时的空清单断言长期固定在线上测试中。

0.1.0 (2) 已于 2026-11-06 20:06（Asia/Shanghai）公开为预发布版。[TV 云端构建](https://github.com/iPocket-APP/MijiaLAN/actions/runs/42213665748) 与 [更新清单刷新](https://github.com/iPocket-APP/MijiaLAN/actions/runs/42215196036) 均成功。四个附件匿名下载均为 HTTP 200，SHA-256 与发布前一致；原生 / Rust 四个更新源逐字节未变，GitHub latest 仍为原生 `v0.1.7`。从不带查询参数的生产地址下载到的清单包含构建 2，经实际客户端库的 5 项版本检查测试通过。发布后的这一步验证了生产清单与客户端解码 / 版本比较，没有重新运行模拟器 UI 或声称 Apple TV 真机通过。

首轮线上请求被 Mac 的 LuLu 授权弹窗阻塞；授权本次测试后，原有 `URLSession.shared` 实现正常通过。未保留试验中的传输配置改动。验收后已删除本次安装路径新增的放行规则，保留既有规则；没有启用全局模拟器或 DNS 放行。测试 Runner 已卸载。Apple TV 真机的网络和升级仍需硬件验收。

## 预览与验证

浏览器 `http://localhost:3202/` 新增「软件更新」入口。纯设计模式手动检查显示明确的示例版本，不发起网络请求，也不展示指向未发布版本的二维码。

Debug 本地联调参数：`--update-feed-test http://127.0.0.1:3203/tvos/releases.json`，只接受 loopback HTTP 地址，Release 忽略该参数。页面会标明本地测试数据。联调用 JSON 由服务端真实采集器从受控 Release 数据生成，不发布到线上。

版本筛选、平台 / 通道 / bundle 校验、URL 限定、数字构建号及无效 JSON 边界由 `TVUpdateFeedTests` 覆盖。`testUpdateCheckUsesActualLocalServer` 运行实际 URLSession → HTTP 服务 → JSON 解码 → 版本提示 → 二维码流程；`testUpdateCheckPreviewAndMenuReturn` 检查示例标记、遥控器操作和菜单返回。最终结果见 `build/validation/tvos-updates-20261106/`。

最终验证：9 项 XCUIRemote 测试通过，0 失败 / 0 跳过；共享 SwiftPM 测试 11 项执行通过、1 项外部桥用例跳过；服务端 TV 筛选与整站保留共 13 项测试通过。iOS 共用代码编译通过。初轮两项 UI 测试因只向下寻找诊断入口而错过新入口上方的诊断按钮，改为按实际焦点位置选择上下方向后，完整回归通过；产品入口均可遥控到达。已查看 `updates-http-service.png` 和 `updates-preview.png` 的 1920×1080 实际截图，主要操作、说明和来源标签完整可读。

浏览器手动点击「软件更新」进入原生页面，再按「确认」完成示例检查；原生 UI 快照确认新版本和示例标签。预览保留在该页，测试 Runner 已移除。联调用的 3203 HTTP 服务在验证后关闭，浏览器预览的 3200 / 3202 服务保留。

TestFlight 与 App Store 的安装、Apple TV 真机扫码和实际覆盖升级尚未验证。本次实现只检查并呈现可用的自签 TV 发布版本。
