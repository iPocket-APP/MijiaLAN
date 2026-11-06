# Sideloadly 重签适配 · 2026-11-06

## 资料核对

- [Sideloadly 官方](https://sideloadly.io/)：支持 tvOS，允许修改 Bundle ID，也可删除 PlugIns。实验必须保留扩展。
- [Sideloadly 更新记录](https://sideloadly.io/changelog)：0.42 加入 TV；0.55 修复多扩展安装；0.60 的自定义 entitlements 有账号和订阅条件；0.70 重写签名引擎。未将“工具支持侧载”当作“能授予 NE 权限”的证据。
- [SideStore/SideSign](https://github.com/SideStore/SideSign)：分别处理嵌入扩展、Profile、App Groups 与 Keychain，区分可用的免费 / 付费权限。仅参考结构，没有引入该库或复制代码。
- [fastlane 重签脚本](https://github.com/fastlane/fastlane/blob/master/sigh/lib/assets/resign.sh)：App ID prefix 与 Team ID 不一定相同，共享 Keychain 不能盲目拼 Team ID。
- [ProxyTunnel](https://github.com/kylosonic/ProxyTunnel)：明确区分构建、签名安装、NE 授权和真实运行，作者没有把免费账号安装预期当作 NE 成功证据。
- [Apple 签名格式实现](https://github.com/apple-oss-distributions/Security/blob/main/OSX/utilities/der_plist.c)：核对 XML / DER 和当前 version-1 DER 包装格式。实现为独立、受限的只读解析器，不调用移动平台私有 SecTask API，也不注入 hook。

## 修复

旧包完全没有签名，重签工具无法从代码签名发现权限要求；运行时又直接使用构建时写入 Info.plist 的组名和前缀。两者都不适用于更换签名身份。

1. 分发副本为 App / NE 各加入证书无关的临时签名，XML 与 DER 均携带 NE 和共享权限模板，前缀 `UNSIGNED00`。仍须用户重签，模板不包含任何 Apple 授权或个人材料。
2. `SignedEntitlements.swift` 只读解析本次安装的 Mach-O 签名，支持 arm64 / arm64e 及 FAT、XML、旧版 DER 字典和新版 DER。严格限制长度、条数、嵌套层数并拒绝 XML / DER 不一致。
3. `SigningIdentity.swift` 从最终 App / NE 签名的交集中选择共享组。已授权的旧组优先；组被改名则选唯一共同组；多义情况报错，不猜测另一个钥匙串。Keychain 使用实际签名值，支持 App ID prefix 不等于 Team ID。
4. Provider ID 来自实际 `PlugIns/*.appex` 的 Packet Tunnel 声明；不再硬拼 `.Tunnel`。扩展被剥离、多于一个、团队不同或身份不匹配均明确失败。
5. App 在保存 VPN 配置前验证双方 NE 权限，把已验证的共享组选择放入 `providerConfiguration`。NE 进程重新检查其自身签名是否授权这些组，避免依赖其沙箱读取宿主二进制。已有配置在下次启动时补齐绑定。
6. `verify_sideload.py` 检查分发模板或重签导出包，分别报告模板签名与真实设备 Profile，不把 `codesign -s -` 当作 Apple 的设备分发授权。验证阶段不安装、登录、创建或撤销证书，也不请求全局网络放行。

模拟器仍显式使用原有前台测试路径，不能用于证明真机签名授权或 NE 激活。真实设备不会静默退回本地文件或私有 Keychain。

## 当前验收边界

签名测试使用 Apple `codesign` 生成两份独立的真实代码签名，包括不同 App ID prefix、扩展改名、旧 Info 值失效、DER-only、扩展丢失、多扩展、共享组歧义和权限删除。证书无关的测试签名没有被安装到设备，也不代表 Apple 已授权测试身份。

tvOS arm64 Release Archive 与模拟器 App / NE 均构建成功。共享运行时测试共 20 项，18 项执行通过，2 项需额外输入的集成用例跳过；其中签名专项 7 项全部通过。另有 5 项实际 IPA 变异检查通过，覆盖剥离扩展、删除 NE / Keychain 权限、不同共享组，以及模板不能冒充设备授权。模拟器的前台桥接控制、配置取消、实际诊断三项回归通过。

实体 iPhone 使用现有 Apple Development 证书与已授权描述文件完成安装和新 NE 启动，App 写入的 Keychain 配置由另一个 NE 进程成功读取，NE 运行记录由 App 从共享容器读取。短时切到系统设置再返回，同一会话的后台成功读数增加 5 次，零传输失败。本次使用内存模拟设备，没有把轮询成功当作外部 HomeKit 控制或真实家电验收。个人描述文件、证书与私有诊断文件仅保留在忽略的本地 `build/`，不随包发布。

另将设备测试副本中 App / NE 的 `PrototypeAppGroup` 和 `PrototypeKeychainGroup` 故意改为无效旧值，用原有已授权身份重新签名后安装。新 NE 会话仍达到 `providerReady`，共享配置读取与桥启动成功，证明运行路径已不依赖这两个旧 Info.plist 值。此对照没有改变 Bundle ID、描述文件或开发者后台能力。

Sideloadly 0.72 已实际载入 tvOS 候选 IPA，未输入账号、请求生成描述文件或修改开发者证书。此结果只说明文件能载入工具，没有产生可供验证的 Sideloadly 重签导出包。

没有 Apple TV 真机，因此不能声明 Apple TV 上的 Sideloadly 安装、系统 NE 启动和后台持续性已通过。iPhone 上的共用代码验证也不能替代这些步骤。
