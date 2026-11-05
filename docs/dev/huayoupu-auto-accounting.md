# 花有谱页面自动记账：实现与接入评估

核查日期：2026-11-05。对象：[AldenHe/huayoupu-ledger](https://github.com/AldenHe/huayoupu-ledger)，源码版本 [`abb796d`](https://github.com/AldenHe/huayoupu-ledger/tree/abb796d829748403612f09e89909819b974565c7)。本文记录源码事实和接入判断；Veri Fin 当前功能与权限没有因此改变。未安装上游 APK，也未验证真实支付页面。

## 结论

技术上可以借鉴和接入，但它是原生 Android Kotlin 应用，不是可以直接安装到 Flutter 项目的插件。其核心是「无障碍识别支付成功页面 → 截图 → 本地 OCR 和规则解析 → 去重 → 自动入账或待核对」，不是调用微信、支付宝的官方交易接口，也不是依靠通知监听。

完整接入涉及原生权限、后台生命周期、识别队列、去重与账目写入，属于独立功能。相比之下，先把本地规则解析用于现有截图入口，保持确认后保存，范围更小，也符合 Veri Fin 当前规则。

## 上游如何实现

| 环节 | 已核实的实现 |
| --- | --- |
| 页面入口 | 用户启用无障碍服务后，监听窗口状态、窗口变化与内容变化事件；按应用渠道开关和包名白名单过滤。自动检测适配包含微信、支付宝、淘宝，不代表所有银行或支付场景都支持。 |
| 触发判定 | 结合 Activity、可读节点文字、成功状态与唯一正金额判断当前是否为即时支付结果；排除密码、未完成支付和历史账单详情等页面。历史详情另走主动摇一摇或图片导入。 |
| 截图 | 截图前后校验目标窗口、运行状态和识别会话；Android 14 及以上优先按窗口截图，较低版本走显示屏截图并重新核对目标。不是持续录制整段屏幕。 |
| 本地识别 | 图片缩放压缩后，本地 OCR 输出文字与位置；`LocalOcrBillParser` 提取实付金额、方向、商户、时间、交易标识等，区分优惠、余额、退款和未支付信息。无需云端 AI。 |
| 写入与核对 | `CaptureCoordinator` 串行协调，`LedgerStore.ingest` 在 SQLite 事务中处理；可靠、字段完整且无疑似重复的记录进入 `POSTED`，其余可进入 `REVIEW`。明确拒绝的内容可以直接跳过。 |
| 去重 | 既有采集事件防重，也有交易身份、来源、金额、方向等核对；同金额、同商户、相近时间仅是疑似重复，不能据此直接删除真实的第二笔消费。 |

源码依据：[服务与 Manifest](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/AndroidManifest.xml)、[页面检测](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/core/src/main/kotlin/net/ankio/ledger/core/PaymentPageDetector.kt)、[截屏服务](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/net/ankio/ledger/capture/ScreenCaptureService.kt)、[本地识别](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/net/ankio/ledger/ocr/LocalRecognitionClient.kt)、[落账与去重](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/net/ankio/ledger/data/LedgerStore.kt)。

当前 Manifest 没有声明联网、短信或通知监听权限。模型和运行库随包提供；本地处理仍然涉及敏感支付页面，离线并不等于不需要权限管理与数据留存控制。

## 与 Veri Fin 的差异

| 项目 | 花有谱 | Veri Fin 当前实现 |
| --- | --- | --- |
| 技术栈 | Kotlin 原生应用与 Kotlin core | Flutter/Dart，Android 原生桥 |
| 截图来源 | 自动页面识别，也支持主动导入 | 用户分享图片或主动选择截图 |
| 解析 | 本地 OCR + 本地规则 | 本地 ML Kit OCR + 用户配置的 AI 文本解析 |
| 保存 | 可靠结果可自动入账，否则核对 | 全部先生成草稿，由用户确认 |
| 最低系统 | 上游 `minSdk = 30`，即 Android 11 | 当前最低设置至少 API 23，不能因借用组件默认整体提高 |
| 核心数据写入 | 自有原生 SQLite 数据层 | `VeriFinController → LedgerRepository → SQLite` |

Veri Fin 现有边界见 [截图识账与外部意图接口](auto-capture.md)，已有外部工具送入文本的方式见 [自动化入口](../product/automation.md)。Tasker/MacroDroid 可以把文本送入确认页，这条路线仍需要确认，不能等同于完整无感落账。

## 可复用部分与接入代价

### 本地解析：较小范围，但不是复制一个文件即可完成

上游解析器输入是带坐标的 `LocalOcrLine`，还依赖图片宽高、时间、来源和相关辅助规则。Veri Fin 目前的 OCR API 只返回拼接文本，因此若保留现有 ML Kit，需要先保留文字行的位置和图片尺寸，再适配解析器或把规则移植为 Dart。

可行方向是「用户分享截图 → 现有 ML Kit → 本地解析 → 待确认草稿」，识别不确定时保留手动修改或现有 AI 路径。分类名称需要映射到当前账本的 `Category.key` 和真实 ID，不能直接使用上游分类文本作为 ID。效果必须以实际支付截图验证，不能把上游模型下的准确率直接套用到 ML Kit。

上游当前采用 PP-OCRv6 Tiny，包含 ONNX Runtime、OpenCV 等原生运行库。引入整套引擎还会增加安装包、ABI、构建和许可证维护工作；它不是复用解析逻辑的前提。依据：[解析器输入](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/core/src/main/kotlin/net/ankio/ledger/core/LocalOcrBillParser.kt)、[运行库说明](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/third_party/ocr-runtime/README.md)。

### 全自动页面采集：改动较大，当前规则不允许直接启用

需要新增 Android 无障碍服务、授权与渠道设置、窗口检测、截图、识别队列，以及进程重启和重复投递处理。Flutter 还需可靠地接收原生结果；不能假设 UI 或 Dart 引擎始终处于运行状态。

接入时应让原生层负责采集和待处理结果传递，经现有 Controller 完成账目保存；不能照搬上游 `LedgerStore` 另建一套权威账目，也不能绕过 Controller 直接改现有数据库。持久化采集队列与交易身份若被引入，需要单独定义 SQLite 迁移、幂等消费、应用锁、备份及清理语义。

目前 `AGENTS.md` 明确禁止注册无障碍/通知/短信监听，分享与 Intent 只产生待确认草稿。这是现有产品边界，不能仅因技术可行就启用自动采集或自动保存；完整无感模式需要另行明确改变这些规则。

上游还使用了 `com.google.android.accessibility.selecttospeak.SelectToSpeakService` 这一兼容类名，实际继承自己的截图服务，并非 Google 提供的实现。其 README 描述特定微信页面的对照观察，不能据此认为这是稳定接口，也不能保证以后微信版本、系统或设备仍可读取。支付页面改版、无可读节点、安全窗口以及系统权限限制都会影响可用性，应保留手动补记入口。依据：[兼容类](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/com/google/android/accessibility/selecttospeak/SelectToSpeakService.kt)、[上游说明](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/README.md)。

## 对个人需求的适配判断

- **统一扣款账户可以沿用。** 页面来源用于说明「微信/支付宝等渠道」，实际新支出经 Controller 应用指定银行卡活期账户。支付渠道不能直接变成扣款账户，也不能因截图写入再扣第二次。
- **去重必须跨入口。** 同一笔支付可能先被采集，后来又被截图或账单导入；交易号应带支付提供方作用域，保留与本地交易的关联。缺少交易号时只能提示疑似重复，不能只按金额和分钟静默丢弃。
- **资产月度表继续独立。** 日常支出影响指定活期账户，定期、基金、外币资产仍按现有账户和月度快照维护；外币人民币估值继续手动填写，不需要因接入采集增加汇率换算。
- **复杂资金流不宜首批自动处理。** 信用卡还款、余额充值、转账及退款与普通消费口径不同；上游退款逻辑不能直接替换 Veri Fin 已有的关联退款与余额规则。

## 复用边界与核查范围

上游 [NOTICE](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/NOTICE.md) 声明项目代码采用 GPL-3.0-only，OCR 模型、原生库和其他第三方文件另保留各自许可。若复制代码或打包模型/运行库，需要保留对应版权、来源与许可材料，不能只复制功能文件而遗漏通知。

本次结论来自源码阅读，没有把上游测试或 README 的小样本成绩视为本机真机验收。当前适合优先借鉴的是本地解析与保守去重；完整无感模式有技术路径，但需要独立的产品规则调整、原生实现与支付场景验证。本次仅记录评估，没有引入上游依赖、权限或功能。
