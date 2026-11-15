### 0.4.0 的变化

- 「引导教程」分步完成米家设备导入、家庭设备选择与 Apple「家庭」配对，可在设置中重新打开。
- 桌面版扫码后可选择「记住米家登录」。登录会话加密保存在本机，下次可直接重新导入。会话过期后需重新扫码，也可随时忘记登录。
- Apple「家庭」快速拖动亮度等滑杆时，桥接会先应答，再按设备顺序写入并同步实际状态。米家智能多功能养生壶提供煮茶、果茶、银耳、炖汤、烧水和保温六个独立开关。
- 配对诊断可标记一次尝试、记录 iPhone「家庭」的结果，并导出 Bonjour 发现和配对阶段。可刷新未使用的配对码，或重试启动失败的桥。
- 批量读取局域网属性时保留已成功的读数。桌面版导出诊断时可同时检查离线设备。

直接升级会沿用已有的 Rust 设备与 Apple「家庭」配对。引用旧养生壶控件的场景和自动化可选用新的菜单开关。

### Changes in 0.4.0

- The Setup Guide walks through device import, bridge selection, and Apple Home pairing. Reopen it from Settings.
- After a QR import, desktop users can choose to remember their Xiaomi Home login. The local encrypted session allows re-imports until it expires or is removed in Settings.
- The bridge acknowledges Apple Home slider writes promptly and reports actual device state after applying them in order. The Xiaomi health kettle exposes six individual menu switches.
- Pairing Diagnostics records an attempt and the result shown on iPhone, then exports Bonjour discovery and pairing stages. An unused setup code can be refreshed, and a failed bridge startup can be retried.
- LAN property reads keep successful values when part of a batch fails. Desktop diagnostics can also check offline devices.

Existing Rust devices and pairings carry over on upgrade. Scenes or automations using the old kettle controls can be updated to use the new menu switches.
