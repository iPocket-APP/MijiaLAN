# MijiaLAN Linux

## Debian 12 和 Ubuntu 24.04 桌面

下载 x86_64 `.deb` 和 `SHA256SUMS.txt`，核对安装包对应的 SHA-256，然后安装。

```sh
sha256sum MijiaLAN-rs-0.1.0-b1-linux-x86_64.deb
sudo apt install ./MijiaLAN-rs-0.1.0-b1-linux-x86_64.deb
```

从应用菜单打开 **MijiaLAN**。托盘可用时，关闭窗口可收起到房屋图标。托盘菜单可重新打开、查看设置和退出。也可以通过应用菜单唤起正在运行的窗口。没有托盘时，使用最小化保持桥运行，关闭窗口会退出。GNOME 可通过 AppIndicator 扩展显示托盘。

GPUI 需要 Vulkan 驱动。虚拟机可尝试安装 `mesa-vulkan-drivers`，并分别核对 X11 或 Wayland 会话中的实际画面。扫码导入使用桌面会话的 Secret Service。系统提示凭据不可用时，启动并解锁 GNOME Keyring，或启用并解锁 KeePassXC 的 Secret Service，然后重试。

升级时直接用 `apt install` 安装新版 `.deb`。设备和配对保存在当前用户的配置目录与 Secret Service。便携包解压后运行 `./mijialan-rust`，需要同样的图形和凭据运行环境。可用 `--demo` 查看演示数据。

## 群晖 DS920+

1. 打开 **Container Manager → 项目 → 新增**，选择独立的项目目录并导入 `compose.yaml`。把 `MIJIALAN_LAN_IP` 改成群晖在设备所在局域网中的 IPv4。镜像使用固定摘要。验收候选则先在「镜像」中导入 `mijialan-bridge-amd64.tar.gz`，再使用候选包内的 Compose。
2. 启动项目。在同一可信局域网用浏览器打开 `http://<群晖 IPv4>:17890`，从容器日志复制一次性设置码。向导 20 分钟后关闭。该端口用于局域网首次设置。
3. 选择米家区域，使用「米家」App 扫码并确认。设备导入后勾选要加入 Apple「家庭」的设备，点「启用家庭桥」。在 iPhone「家庭 → 添加配件」扫描页面上的第二个二维码，配对后点「完成并关闭向导」。

容器使用主机网络，HAP 默认监听选定地址的 TCP 51826，mDNS 通过该局域网接口发布。端口占用时可分别修改 `MIJIALAN_HAP_PORT` 和 `MIJIALAN_SETUP_PORT`。如需再次导入，设置 `MIJIALAN_SETUP` 为 `"true"` 并重建容器，完成维护后改回 `"false"`。已配对的桥在维护窗口期间继续运行。

同一项目的 `data` 与 `keys` 持久卷分别保存加密数据和主密钥。备份时先停止桥，再保存两个卷。升级时使用同一项目和两个卷，更换 Compose 中的镜像摘要后重建容器。回退时恢复原摘要及对应卷备份。若报告主密钥、加密凭据或桥接身份缺失，应恢复原备份后再启动。

## 群晖 SPK 和飞牛 FPK 测试包

- **群晖**。Geminilake x86_64（如 DS920+）使用 `*-synology-geminilake-test.spk`，在 DSM「套件中心 → 手动安装」上传。测试包将最低版本声明为 DSM 7.2.2。
- **飞牛**。x86_64 使用同次 Actions 的 `MijiaLAN-NAS-x86_64-b<构建号>-test` 中的 `*-fnos-x86_64-test.fpk`，从应用中心手动安装用于本地验收。正式上架走飞牛应用中心提交流程。

安装时填 NAS 在米家设备所在网络的 IPv4、HomeKit TCP 端口和一个临时设置码。默认 HomeKit 端口为 51826，和容器版并行测试时请选其他未占用端口。启动后用同一局域网内的浏览器打开 `http://<NAS IPv4>:17890`，输入安装时设置的码，再扫码导入和配对。设置码只能使用一次，设置窗口最多开放 20 分钟。飞牛可停止应用后在应用配置中设新码，再启动进入维护。

套件用专用用户运行，`data` 和 `keys` 存在套件的私有数据目录。DSM 使用 `SYNOPKG_PKGVAR`，飞牛使用 `TRIM_PKGVAR`。覆盖升级沿用原配置和密钥。备份、迁移或卸载前先停止旧桥，配对身份和加密设备数据需要与主密钥一起保存。套件启动失败时，从同一数据目录的 `bridge.log` 查看原因。

测试包在 Linux 容器中检查静态依赖、套件内的启停脚本、设置码和密钥保留。DSM / fnOS 应用中心安装、NAS 重启后恢复以及手机的家庭配对仍需对应系统验收。

## 候选包与发布

GitHub Actions 的 **Linux Build and Release** 使用固定的 Debian 12 基础镜像。候选包含桌面安装包、便携包、可导入的 amd64 镜像、Compose 和 SHA-256 清单。`build-info.json` 记录源提交、构建号、测试结果和镜像 ID。

桌面需验收 Debian X11 和 Ubuntu Wayland 的安装、托盘与无托盘场景、旧包升级、扫码和真实设备读写。群晖需验收 iPhone 发现与配对、设备写入读回、重启及重建后的配对恢复。验收完成后，从 `MijiaLAN-rs` 分支手动运行同一工作流，提供已验收的 `verified_run_id`，复用该次产物发布 `rs-linux-vVERSION-bBUILD`。首次推送 GHCR 时，在包设置中将 `mijialan-bridge` 设为公开，再重跑发布任务。任务会核对公开镜像配置摘要和 Release 附件。
