# 原生 0.1.2 HomeKit 状态同步调查

调查日期：2026-11-05。基线：`v0.1.2`（`ab24c0333ce65aed5a45c8b997b1c0eb9350524f`）。

用户反馈为“桥接到家庭后设备状态获取不到”，已知版本为原生 0.1.2；设备型号、固件、整座桥还是个别设备不可用尚不明确。下面区分代码中已复现的问题与尚待用户现场验证的原因。本次没有发布新版本。

## 结论

当前“后台采集 → 缓存 → HomeKit 读取/事件”的方向可保留。应先保证已读取的数据及时发布、可用性恢复有序送达，再考虑调整采集频率。

已复现并修正两点：

1. **旧错误通知可能晚于恢复通知到达。** 原先每次事件独立启动 `Task`，上一次发送一旦挂起，后一次发送就可能先完成。缓存已经恢复为成功，但最后送达的是旧的 `-70402`，可能让“家庭”保留不可用状态。数值未变化时，之后的增量抑制也不保证有新的纠正事件。
2. **正常轮询等待所有在线设备读完才发布。** 快设备的新值已进入原始快照，HomeKit 缓存与可观察版本却仍等待慢设备，造成额外延迟。

这两点是可独立复现的缺陷；目前没有现场证据证明它们就是该用户设备的全部原因。

## 其他项目如何处理

| 项目 | 已核对的处理方式 | 对 MijiaLAN 的启示 |
| --- | --- | --- |
| homebridge-miot | 默认 15 秒；轮询定时器属于各 `MiotDevice`。连续四次失败后安排重连/重启轮询；识别到 `user ack timeout` 时调大内部轮询间隔参数。写入获得有效响应后更新本地属性并发出事件。 | 各设备采集/发布需要隔离；更密集的请求未必更可靠。控制后的状态反馈不必等待普通轮询。 |
| Home Assistant | `DataUpdateCoordinator` 集中同一数据源的采集，实体读取缓存；支持错误、可用性、合并刷新和不变数据抑制。官方文档特别提醒首次刷新必须初始化实体缓存，命令后可以请求合并刷新。HomeKit Bridge 初始化已有状态，再监听状态事件，并单独维护可用性。 | 缓存读取合理，但初始值、错误恢复、命令确认和增量抑制需要一起设计。不能只比较业务数值。 |
| 小米官方 Xiaomi Home | 云端/中枢以 MQTT 订阅为主，初始同步后接收属性事件。源码会切换订阅来源，并在重连时刷新设备信息。直接 LAN 的 `miIO.sub` 为可选路径，检查 `MSUB`/`PUB` 及通配订阅能力后接收 `properties_changed`；`enable_subscribe` 构造默认值为 false。 | 推送可以作为支持设备的后续优化，但旧 miIO 设备、MIoT LAN 设备与官方中枢不是同一种能力，当前不能统一改成纯推送。 |

还有与“状态不更新”直接相关的设备差异：homebridge-miot 的更新记录修正过新风机 `zhimi.airfresh.ua1` 在低温下返回异常进风温度，导致轮询超时并最终停止的问题。应检查单属性错误、数据类型和固件行为，不能把所有状态问题归结为间隔太长。

资料来源（查阅当前上游源码，并记录固定提交）：

- [homebridge-miot README：默认轮询 15 秒](https://github.com/merdok/homebridge-miot/blob/2186f61f2081ec1a51c0388e3072b79741aebb0a/README.md#L226-L227)
- [MiotDevice：轮询、重试和重连](https://github.com/merdok/homebridge-miot/blob/2186f61f2081ec1a51c0388e3072b79741aebb0a/lib/protocol/MiotDevice.js#L747-L841)
- [MiotDevice：有效写入响应后发布属性](https://github.com/merdok/homebridge-miot/blob/2186f61f2081ec1a51c0388e3072b79741aebb0a/lib/protocol/MiotDevice.js#L1488-L1505)
- [homebridge-miot 异常温度导致轮询失败的修复记录](https://github.com/merdok/homebridge-miot/blob/2186f61f2081ec1a51c0388e3072b79741aebb0a/CHANGELOG.md#L33)
- [Home Assistant：数据采集、首次初始化、缓存和合并刷新](https://contributors.home-assistant.io/core/integrations/fetching-data/)
- [Home Assistant HomeKit Bridge：初始化、状态事件与可用性](https://github.com/home-assistant/core/blob/db50c01e164020f0179e679c9923138bf4172e9c/homeassistant/components/homekit/accessories.py#L603-L702)
- [HAP-python：通过事件循环发送通知](https://github.com/ikalchev/HAP-python/blob/master/pyhap/accessory_driver.py#L548-L603)
- [小米官方：云端与本地架构](https://github.com/XiaoMi/ha_xiaomi_home/blob/75b3acb6325a3a8d295688b13904737d6738a6a5/README.md#L108-L134)
- [小米官方：订阅来源切换及重新订阅](https://github.com/XiaoMi/ha_xiaomi_home/blob/75b3acb6325a3a8d295688b13904737d6738a6a5/custom_components/xiaomi_home/miot/miot_client.py#L996-L1029)
- [小米官方：miIO.sub](https://github.com/XiaoMi/ha_xiaomi_home/blob/75b3acb6325a3a8d295688b13904737d6738a6a5/custom_components/xiaomi_home/miot/miot_lan.py#L262-L281) / [能力检查](https://github.com/XiaoMi/ha_xiaomi_home/blob/75b3acb6325a3a8d295688b13904737d6738a6a5/custom_components/xiaomi_home/miot/miot_lan.py#L1244-L1261)

## 0.1.2 现有链路

- `DeviceController.events()` 启动一个后台循环。面板可见时，每轮完成后等 3 秒；隐藏时等 5 秒。因此实际周期是“该轮耗时 + 3/5 秒”，并非固定频率。滤芯、功耗统计等慢属性一般每 60 秒读取；开关等普通状态不走这个慢周期。
- 每台设备合并重叠读请求，设备命令经各自执行器串行化。`LANMiotAPI` 使用每次尝试 5 秒的超时和一次重试；多个属性分包和排队可能进一步拉长一轮。
- 一次网络失败可使相关属性读数不可用，即使设备健康状态尚未变为离线；连续两次传输失败通常标记离线。属性级拒绝不会被混同为整个网络离线。
- 无效读数保留上一次值供诊断，但保留错误状态，HomeKit 不会把它当作新鲜成功值。HomeKit `GET /characteristics` 读缓存及状态，不直接请求米家设备。
- HomeKit 映射为有效值或 `-70402`。恢复时即使数值相同，也强制发送成功值；0.1.2 已有此恢复逻辑，但独立通知任务仍会打乱交付顺序。
- 正常发布只比较语义变化，时间戳变化不会重建布局或反复推送。成功控制后执行回读确认并发布；扫地机动作另有状态确认流程。
- 离线设备采用带抖动的指数重试，约从 20 秒递增至 24 小时；手动重试可以提前。5 分钟重新发现可更新地址，并为已发现设备安排提前重试。因此“设备重新上电”也不保证下一次 5 秒轮询立即恢复。
- 桥运行时默认持有防自动闲置睡眠断言。系统主动睡眠、断网、主机不可达与单个属性错误需要分别定位。

## 本次修改

### 有序通知

`Vendor/hap-swift/Sources/HAPTransport/HAPBridge.swift` 增加 FIFO 通知任务链，普通变更与新订阅的初始快照都经过同一入口。每个事件等待前一事件的发送处理完成，缓存读写不等待网络发送。

这与 0.1.2 的加密帧顺序修复不同：加密帧计数器正确，只说明 TCP 密文不会因计数器乱序而认证失败；仍需保证交给加密层的业务状态本身按顺序到达。

### 已完成设备及时发布

`DeviceController.refreshNow()` 逐个消费读任务的完成结果，通过 25 毫秒的小批次合并发布。整轮完成后仍立即发布最终快照并取消待发布任务；关闭时也取消该任务。相近完成的设备不会各自重复构建 Home，而已经完成的设备无需等其他设备超时。

本次保留 3/5 秒间隔和既有退避策略。全局下一轮启动仍受当前一轮结束时间影响；彻底改成各设备独立采集调度是另一项更大改动，需要结合设备数量、设备负载和现场日志评估。

## 验证

测试及日志位于 `build/validation/state-sync-20261105/`。

- 修复前，`notificationRecoveryOrder` 的两种情况均失败：已有订阅、离线时新订阅。刻意挂起错误通知发送，最终捕获顺序为成功值在前、旧错误在后。日志：`notification-before.log`。
- 修复后两种情况均通过，最终事件为成功值，桥缓存也为成功。日志：`notification-after.log` 与完整测试日志。
- 修复前，`independentPollPublication` 已等到快设备原始值更新，但发布版本仍未推进，在慢设备保持阻塞时超时。日志：`publication-before.log`。
- 修复后，在慢设备仍阻塞时，发布版本与合成 Home 中的风扇状态均已更新。
- `swift test -c release --force-resolved-versions` 全部通过：LAN 79 项/18 套件，App 9 项/2 套件，Bridge 67 项/16 套件，共 155 项/36 套件。包括八组真实 miIO UDP + 加密 HAP TCP 参数化回归、128 个并发加密写入者、无变化轮询抑制、同值恢复及配对身份保留。日志：`full-release-tests.log`。

这些是模拟设备与本机真实 socket 测试；没有该用户设备或其家庭中枢的实机验收，也没有发布 0.1.3。

## 现场定位的下一步

若 App 内状态也无法读取，先看设备型号、能力映射、属性返回值/错误码、IP/Token 和传输失败；若 App 内已经更新而“家庭”仍不可用，优先核对对应 HomeKit 特征的读状态、订阅与恢复事件；若整座桥同时无响应，再看 Mac 可达性、睡眠及 HAP 连接。补充设备型号、错误提示或一段发生期间日志，才能将现场反馈对应到具体环节。
