# 第三方声明 · Third party notices

本项目的原创代码采用 MIT；下列依赖保留其原有版权和许可证。
Original project code is MIT licensed. Dependencies retain their original copyrights and licenses.

## 直接与间接依赖 / Dependencies

| 组件 / Component | 固定版本 / Revision | 许可证 / License |
| --- | --- | --- |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | `2.10.1` | [Sparkle license (MIT and bundled notices)](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE) |
| [hap-swift](https://github.com/acumen-dev/hap-swift)（内置并修改 / vendored and modified） | `638001bd3590082a8909fd4046ec226ab1349f20` | [Apache-2.0](Vendor/hap-swift/LICENSE.md) |
| [hass-xiaomi-miot](https://github.com/al-one/hass-xiaomi-miot)（转换后的设备映射数据 / converted device mapping data） | `75bc74f67275bde6a8742b6638039819e10eaea5` | [Apache-2.0](Vendor/hass-xiaomi-miot/LICENSE) |
| [homebridge-miot](https://github.com/merdok/homebridge-miot)（移植的 HomeKit 映射规则 / ported HomeKit mapping rules） | `2186f61f2081ec1a51c0388e3072b79741aebb0a` | [MIT](Vendor/homebridge-miot/LICENSE) |
| [mdns-swift](https://github.com/acumen-dev/mdns-swift) | `1.2.0` | [Apache-2.0](https://github.com/acumen-dev/mdns-swift/blob/ef8c8d387a15b762816f88264667d3278042fa78/LICENSE.md) |
| [MenuBarMijia](https://github.com/jryang1997/MenuBarMijia) | `c6a9db1c84fa` | [MIT](https://github.com/jryang1997/MenuBarMijia/blob/c6a9db1c84fa30125ed4b642b6745487dec94e89/LICENSE) |
| [swift-asn1](https://github.com/apple/swift-asn1) | `1.7.3` | [Apache-2.0](https://github.com/apple/swift-asn1/blob/3b6410f7dee09eb33cdd26260c5fd47fda19b0e2/LICENSE.txt) |
| [swift-atomics](https://github.com/apple/swift-atomics) | `1.3.1` | [Apache-2.0 + Swift Runtime Library Exception](https://github.com/apple/swift-atomics/blob/0442cb5a3f98ab802acb777929fdb446bda11a34/LICENSE.txt) |
| [swift-collections](https://github.com/apple/swift-collections) | `1.7.5` | [Apache-2.0 + Swift Runtime Library Exception](https://github.com/apple/swift-collections/blob/f96b909e1a9e469620bc5037c1e24e00153f376f/LICENSE.txt) |
| [swift-crypto](https://github.com/apple/swift-crypto) | `4.5.2` | [Apache-2.0](https://github.com/apple/swift-crypto/blob/da9d28d69ebe3894b18376c8f2395c2f37b8448f/LICENSE.txt) |
| [swift-log](https://github.com/apple/swift-log) | `1.16.2` | [Apache-2.0](https://github.com/apple/swift-log/blob/c9c6bb9d275ec0d95c3ad16391f3f045dc623104/LICENSE.txt) |
| [swift-nio](https://github.com/apple/swift-nio) | `2.104.0` | [Apache-2.0](https://github.com/apple/swift-nio/blob/6db9d9abd92ad7399b8a564cafbb87d3507245fa/LICENSE.txt) |
| [swift-system](https://github.com/apple/swift-system) | `1.8.1` | [Apache-2.0 + Swift Runtime Library Exception](https://github.com/apple/swift-system/blob/869129b7bf4ecc57b97d0193ad29690ca2134750/LICENSE.txt) |

内置 HAP 的修改见 [Vendor/hap-swift/README.md](Vendor/hap-swift/README.md)，被修改的源文件保留原版权并标记了修改。
Local HAP changes are documented in [Vendor/hap-swift/README.md](Vendor/hap-swift/README.md); modified sources retain upstream notices and carry modification notices.

旧 miIO 设备的属性映射表转换自 hass-xiaomi-miot 的 `miio2miot_specs.py`，转换方式和改动见 [Vendor/hass-xiaomi-miot/README.md](Vendor/hass-xiaomi-miot/README.md)。
The legacy miIO property tables are converted from hass-xiaomi-miot's `miio2miot_specs.py`; the conversion and changes are documented in [Vendor/hass-xiaomi-miot/README.md](Vendor/hass-xiaomi-miot/README.md).

加湿器、除湿机、取暖器、空调、窗帘和扫地机的 HomeKit 服务映射参照 homebridge-miot 的类别规则移植，见 [Vendor/homebridge-miot/README.md](Vendor/homebridge-miot/README.md)。
The HomeKit service mapping for humidifiers, dehumidifiers, heaters, air conditioners, curtains and robot vacuums follows homebridge-miot's category rules; see [Vendor/homebridge-miot/README.md](Vendor/homebridge-miot/README.md).

App 构建脚本会将项目及依赖的 LICENSE / NOTICE 等原文复制到 `MijiaLAN.app/Contents/Resources/Licenses`，随二进制一起分发。
The app build script includes original project and dependency LICENSE / NOTICE files in `MijiaLAN.app/Contents/Resources/Licenses` for binary redistribution.

## 应用图标 / Application icon

应用图标沿用 Rust 版的青绿色底色和房屋轮廓；房屋轮廓源自 Lucide 0.468.0（ISC），由 Icon Composer 合成。
The application icon preserves the Rust version's teal background and house outline. The outline derives from Lucide 0.468.0 (ISC), composed with Icon Composer. Copyright Lucide Contributors and Cole Bemis (Feather portions). The original license is retained in [Resources/Licenses/lucide/LICENSE](Resources/Licenses/lucide/LICENSE) and included in the app bundle.

## MijiaCore / MenuBarMijia MIT notice

MijiaCore is used from the pinned MenuBarMijia dependency. Its original MIT notice follows.

```text
MIT License

Copyright (c) 2026 jryang1997 (一群小羊说)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
