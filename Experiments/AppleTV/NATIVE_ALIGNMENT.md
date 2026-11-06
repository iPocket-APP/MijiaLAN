# TV 与原生端修复对齐 · 2026-11-06

核对范围为当前工作区的设备控制 / HomeKit 源码，以及本机 `origin/main` 指向的原生 0.1.7 提交 `793da15776884f80457d562c2fdaf2273f265ad2`。没有将 Mac 专用界面或更新器整体合并到实验分支。

## 共享业务修复

`.generated/MijiaTVDependencies/source-manifest.json` 中的 84 个源文件摘要与当前源目录逐项一致，没有过期、缺失或新增未同步文件。App 和 NE target 都链接同一个 `TVPrototypeKit` / 共享依赖包。

已同步的修复包括：

- 固件返回 Spec 未列出的枚举时保留真实读数，不使所有选项或整个设备被误判为不可读；不把未知枚举送入旧版 MijiaCore 的状态映射。
- 设备数值验证及不能安全转为整数的数值保护。
- 灯具非 0–100 原始亮度范围与 HomeKit 百分比换算，以及缩放亮度写入 0 时关闭电源。
- 风扇 / 晾衣架等只写选项按瞬时开关读取为关闭，避免因等待不存在的读数造成 HomeKit 无响应。
- 没有转速属性的净化器使用电源状态映射运行状态；声明了转速属性的型号仍等待有效读数。
- HomeKit 部分属性失败时保留逐项状态，包括成功属性的状态；`Vendor/hap-swift` 为同一份共享依赖。
- 设备重试、健康状态、HomeKit 读取失败来源和诊断字段。TV 诊断是独立原生界面，完整实现见 [DIAGNOSTICS.md](DIAGNOSTICS.md)。

## 此次补齐的构建漏项

此前 `prepare.py` 从 `.build/checkouts/MenuBarMijia` 复制源码，并在缓存不存在时尝试解析失效的上游依赖。原生端已在 `4615651` 改为本地维护，但 TV 的准备路径尚未跟进。

现在恢复原生端提交中的完整 `Vendor/MenuBarMijia`（源码、资源、测试、来源说明及 MIT 许可），TV 准备脚本固定读取此目录。原始导入版本仍为 `c6a9db1c84fa30125ed4b642b6745487dec94e89`，49 个核心源码 / 资源文件与旧固定版本逐字节相同；这次更改不改变共享业务逻辑。未来本地核心修复由相同路径进入 TV 构建，清单新增 `coreSource` 标记并继续记录实际 SHA-256。

没有更改现有 Mac `Package.swift`、原生源文件或已有的未提交修复。TV 构建不再通过根项目解析 MijiaCore。

## 保留的平台适配

生成副本与原始共享源码只有以下 4 个文件存在预期差异：

| 文件 | TV 适配 |
| --- | --- |
| `MijiaCore/HADiscovery.swift` | Mac 的 dns-sd / arp 子进程仅在 macOS 编译 |
| `MijiaCore/UpdateChecker.swift` | Mac 的覆盖安装与重启驱动仅在 macOS 编译 |
| `MijiaCore/AssistantConfig.swift` | 不在 TV 上查找 Mac 主目录的环境凭据 |
| `MijiaHomeKitBridge/HomeKitBridgeController.swift` | 不使用 Mac 防睡眠断言；采用独立实验桥名称；保留监听错误并关闭失败的监听器 |

Mac 的菜单栏布局、完整原生控制面板和 Sparkle 更新器不属于 TV 功能。TV 目前有自己的遥控器界面、设备电源控制和诊断详情；已接入独立 TV 版本检查，见 [UPDATES.md](UPDATES.md)。自签版的新版安装仍通过配对 Mac 完成。

## 验证

证据：`build/validation/tvos-native-alignment-20261106/alignment.json`。

- 在无 `.build` 和 `.git` 的独立临时目录执行准备脚本成功；生成的 88 个受管理文件与工作区输出逐字节一致。此项只验证共享源准备不再依赖旧 checkout，未宣称所有其他 SwiftPM 依赖都可无网络首次构建。
- 更新准备脚本后，tvOS App + NE Debug 编译成功，0 警告 / 0 错误。XcodeBuildMCP 日志：`build_sim_2026-11-06T10-22-22-019Z_pid92152_c81139f9.log`。
- 共享 SwiftPM 测试再次执行：7 项通过，1 项需外部模拟器桥的用例跳过。实际加密 HAP / UDP fixture 与诊断采集、脱敏、历史状态边界通过。
- Swift 业务源码与 UI 本次未更改，沿用先前 7 项 XCUIRemote 回归结果；没有重复安装或启动 App，保留浏览器预览状态。

上述是源码、构建和受控运行时验证。Apple TV 真机、真实米家设备及 tvOS NE 后台行为仍未验收。
