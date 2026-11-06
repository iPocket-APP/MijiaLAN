# Apple TV 原生页面预览

这个本地工具显示 tvOS 模拟器的真实画面，并提供页面导航和遥控按钮。它不把电视当作触屏；视频上的鼠标点击不会转发为 iPhone 触摸事件。全部导航只在 Debug `--design-preview` 示例模式处理，不用于真实设备控制或 NE 后台验收。

需要 Node 22+，以及已编译、安装到 Apple TV 模拟器的实验 App。先为同一台模拟器启动镜像，再启动本目录服务：

```sh
npx --yes serve-sim@0.1.49 17F26DCA-8995-4C1E-AB4A-3740301FD679 --port 3200
```

另一个终端，从仓库根目录运行：

```sh
node Experiments/AppleTV/Preview/server.mjs
```

打开 `http://localhost:3202/`。点「打开应用」可重新启动纯示例预览；点「应用设置」进入 App 自己的设置页。下方的方向、确认和返回按钮发送遥控器按键。键盘的方向键、回车和 Esc 也可用；回车在网页按钮获得焦点时正常触发那个按钮。

点「诊断」进入原生诊断页，用下方「确认」生成示例报告。之后「下载诊断报告」可下载 `MijiaLAN-TV-Diagnostics.json`，并显示最近文件的来源和采集时间。点设备可查看健康、属性、错误码及 HomeKit 失败详情。下载只读取已经生成的固定文件，不会触发设备通信；新数据须在 TV App 内重新生成。纯示例预览始终标为示例数据，完整说明见 [../DIAGNOSTICS.md](../DIAGNOSTICS.md)。

点「软件更新」可体验原生检查更新页面，再用下方「确认」生成示例更新结果。纯预览不会访问真实更新接口；实际网络检查和服务端实现见 [../UPDATES.md](../UPDATES.md)。

全新模拟器首次打开预览导航链接时，系统可能显示「Open in MijiaLAN 实验?」。用下方「确认」选择 Open。本机完成首次确认后，随后设备、桥接和设置导航未再次弹出。示例预览在总览按返回也留在 App 内；真实运行模式保留 tvOS 的正常返回主屏行为。

服务仅绑定本机 127.0.0.1。可选环境变量：`MIJIALAN_TV_SIMULATOR` 指定模拟器 UDID、`MIJIALAN_TV_STREAM` 指定本机 serve-sim 地址、`MIJIALAN_TV_PREVIEW_PORT` 指定页面端口，默认分别为本机验收设备、`http://127.0.0.1:3200`、3202。无局域网公开地址、通用命令执行接口或任意 bundle 输入。

结束预览时停止本服务，并停止这个终端拥有的镜像。不要结束其他项目的模拟器或镜像；如果镜像异常退出，仅清理当前 UDID：

```sh
npx --yes serve-sim@0.1.49 --kill 17F26DCA-8995-4C1E-AB4A-3740301FD679
```

## 应用图标

`tvOS/Assets.xcassets/AppIcon.brandassets` 使用 tvOS 的分层图标及 Top Shelf 格式。前景复用仓库 `Resources/AppIcon.icon/Assets/House.svg` 的白色房屋标记，背景复用现有绿色。源矢量不修改，导出的 PNG 无圆角预裁切。

重新导出：

```sh
swift Experiments/AppleTV/render-tv-assets.swift
```

UI 测试会安装单独的 `MijiaLANTVUITests-Runner`。这个入口由 XCTest 启动，不是用户可打开的产品；完成测试后，手动预览前可卸载它，避免与实验 App 混淆。
