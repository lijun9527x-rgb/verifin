# 花有谱页面自动记账：实现与接入评估

核查日期：2026-11-05。对象：[AldenHe/huayoupu-ledger](https://github.com/AldenHe/huayoupu-ledger)，源码版本 [`abb796d`](https://github.com/AldenHe/huayoupu-ledger/tree/abb796d829748403612f09e89909819b974565c7)。本文记录源码事实和接入判断；Veri Fin 当前功能与权限没有因此改变。未安装上游 APK，也未验证真实支付页面。上游结论按 `core`、`app` 与 Manifest 逐文件核对得出，非依据 README。

## 结论

技术上可以借鉴和接入，但它是原生 Android Kotlin 应用，不是可以直接安装到 Flutter 项目的插件。其核心是「无障碍识别支付成功页面 → 截图 → 本地 OCR 和规则解析 → 去重 → 自动入账或待核对」，不是调用微信、支付宝的官方交易接口，也不是依靠通知监听。

完整接入涉及原生权限、后台生命周期、识别队列、去重与账目写入，属于独立功能。本定制分支的需求允许使用无障碍采集及可靠结果自动落账；不再沿用上游「零监听」作为接入限制。建议继续扩展当前 Veri Fin fork，选择性复用花有谱模块，而非更换整个记账应用。

## 上游如何实现

上游是「无障碍读节点树判定 → 通过后才申请像素 → 本地 OCR 取坐标 → 规则解析 → 单事务落账」的闭环，**判定全部发生在截图之前**。

| 环节 | 已核实的实现 |
| --- | --- |
| 服务入口 | `app/src/main/java/com/google/android/accessibility/selecttospeak/SelectToSpeakService.kt` 是**伪装的类名**（谷歌的包名里放自己的类），实际继承 `capture/ScreenCaptureService : AccessibilityService`。`res/xml/accessibility_service.xml` 监听 `typeWindowStateChanged｜typeWindowsChanged｜typeWindowContentChanged`，flags 为 `flagRetrieveInteractiveWindows｜flagIncludeNotImportantViews`，`canRetrieveWindowContent` 与 `canTakeScreenshot` 均为 true，`isAccessibilityTool="false"`。`onAccessibilityEvent` 维护 `windowId → packageName` 映射（上限 64，超出清空）。 |
| 触发判定 | **两级闸门，都在申请像素之前。** ①`CapturePrivacy.sensitive`：节点可编辑、Activity 名匹配 `password/passwd/pwd/verification/biometric/fingerprint/faceid`、或文案含「密码/验证码/身份验证/指纹支付/刷脸支付/确认支付/立即付款」→ 直接放弃。②`PaymentPageDetector.detect`：Activity 白名单（微信仅认 `UIPageFragmentActivity` 等几个 result activity 及 `.wallet./.remittance./.wxpay.` 前缀；支付宝 `com.alipay.` 前缀）→ 排除历史账单 Activity（`detail\|orderinfo\|billhistory\|transactionrecord`）与「全部账单/账单详情/交易详情」文案 → 必须命中成功文案（`支付成功/付款成功/交易成功/转账成功/对方已收钱`…）且不含禁止文案（`请输入支付密码/确认支付/支付失败/交易关闭/已退还/退款中/待支付`…）→ 金额优先取「实付款/实付金额/支付金额」标签，剔除优惠券、红包、积分、立减类，**必须唯一且大于 0，否则 fail closed**。淘宝要求「已付总额唯一」或「有交易号且有支付时间」。 |
| 事件去重 | `PaymentGate` 内存 claimed 集合（上限 256）按 `eventIdentity` 只 claim 一次，失败可 `release`。**它只是事件闸门，不是账目去重**。有交易号时身份取 `packageName\|transaction:交易号` 的 SHA-256；无交易号时取「包名+窗口+Activity+金额」。 |
| 截图 | API 34 及以上走 `takeScreenshotOfWindow(windowId, …)`；较低版本走 `takeScreenshot(Display.DEFAULT_DISPLAY, …)` 并复核目标窗口。截图前后校验目标窗口、运行状态与识别会话。`ERROR_TAKE_SCREENSHOT_SECURE_WINDOW` 会中止该次采集并提示改用账单截图导入。**不是持续录制整段屏幕。** |
| 识别队列 | `PaymentRecognitionQueue`：图片落盘，内存 `Map<taskId, Entry>`，`MAX_PENDING = 8`，`Semaphore(1)` 保证同时只有一次模型调用；每个任务带 **epoch 校验**（渠道开关世代 + 识别会话世代），授权一关就取消任务；启动或服务连上后 `resume()` 从 `tasks` 表捞 `QUEUED` 重放，`cancelAutomatic` / `cancelShake` 分别取消。 |
| 任务持久化 | 表 `tasks(id, source, origin, created_at, status, message, image, record_id, diagnostic)`，状态机 `CAPTURING → QUEUED → RECOGNIZING → SUCCEEDED / REVIEW / FAILED / CANCELLED / SKIPPED / DUPLICATE`；图片本体存文件系统、表内列置空，处理完清理。 |
| 本地识别 | 随包 PP-OCRv6 Tiny + ONNX Runtime 1.21.1 reduced + OpenCV 4.12.0 minimal（`third_party/ocr-runtime/*.aar`），输出**带坐标**的 `LocalOcrLine`；`core/LocalOcrBillParser` 靠坐标定位顶部大字金额与商户布局，产出 `ParsedBill(amountCents, direction, merchant, category, occurredAt, transactionId, reliable, reason, timeExplicit, refund)`。无需云端 AI，不打包 ML Kit。 |
| 写入与核对 | `data/CaptureCoordinator` 用 `Mutex` 串行化，`LedgerStore.ingest` 在**单个 SQLite 事务**内完成：`capture_events` 按 `event_key` 主键拦截事件重放（保留 7 天）→ `record_identities(scope,value)` 精确身份匹配 → 自动付款补全 → 重复付款 → 退款关联 → 近邻候选（±120 s，**必须 transactionId 或 timeExplicit 明确**，否则不参与）→ 判 `Exact`/`Possible` → 插入并持久化身份。可靠且字段完整且无疑似重复 → `POSTED`，否则 `REVIEW`；`REVIEW` 记录后续可被可靠识别**提升**为 `POSTED`。 |
| 去重 | 既有采集事件防重，也有交易身份、来源、金额、方向等核对；同金额、同商户、相近时间仅是疑似重复，不能据此直接删除真实的第二笔消费。`record_deletions` 保留删除墓碑，避免重看页面被记回。 |

身份命名空间属于**签发方**而非商户名，形如 `alipay` / `wechat` / `app:com.taobao.taobao`（`data/TransactionIdentity.kt`），同一 scope 只允许一个值，冲突时判为歧义而非取首项。

源码依据：[服务与 Manifest](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/AndroidManifest.xml)、[无障碍配置](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/res/xml/accessibility_service.xml)、[页面检测](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/core/src/main/kotlin/net/ankio/ledger/core/PaymentPageDetector.kt)、[隐私过滤](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/core/src/main/kotlin/net/ankio/ledger/core/CapturePrivacy.kt)、[截屏服务](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/net/ankio/ledger/capture/ScreenCaptureService.kt)、[识别队列](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/net/ankio/ledger/capture/PaymentRecognitionQueue.kt)、[本地识别](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/net/ankio/ledger/ocr/LocalRecognitionClient.kt)、[规则解析](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/core/src/main/kotlin/net/ankio/ledger/core/LocalOcrBillParser.kt)、[落账与去重](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/net/ankio/ledger/data/LedgerStore.kt)。

当前 Manifest 只有 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 一个敏感权限，`allowBackup="false"`，未声明联网、短信或通知监听权限。模型和运行库随包提供；本地处理仍然涉及敏感支付页面，离线并不等于不需要权限管理与数据留存控制。

## 与 Veri Fin 的差异

| 项目 | 花有谱 | Veri Fin 当前实现 |
| --- | --- | --- |
| 技术栈 | Kotlin 原生应用与 Kotlin core | Flutter/Dart，`platform_bridge.dart` 单一 MethodChannel（`verifin/app`） |
| 截图来源 | 无障碍自动识别，也支持摇一摇与主动导入 | 用户分享图片（`ShareReceiverActivity`）或相册选图 |
| 解析 | 本地 OCR 输出坐标 + `LocalOcrBillParser` 坐标规则 | 本地 ML Kit **仅返回拼接文本**（`result.text`）+ 用户配置的 AI 文本解析 |
| 保存 | 可靠结果自动入账，否则进入待核对 | 全部先生成 `EntryDetailPage` 草稿，由用户确认 |
| 待处理队列 | `tasks` 表 + 内存队列 + epoch 取消 + 崩溃重放 | 无持久化队列；`consumeCaptureImage` / `consumeCaptureText` 是「取走即清」的内存消息 |
| 后台运行时 | 原生组件在应用进程中常驻 | **没有 Application 子类**；引擎由 `MainActivity.configureFlutterEngine` 创建，Activity 销毁即无 Dart 运行时 |
| 最低系统 | `minSdk = 30`（Android 11），`targetSdk = 36` | `minSdk = max(flutter.minSdkVersion, 23)`，不能因借用组件默认整体提高 |
| 核心数据写入 | 自有原生 SQLite `LedgerStore` 即权威账本 | `VeriFinController → LedgerRepository → SQLite`，Controller 另持内存集合、行快照与写队列 |
| 许可证 | `GPL-3.0-only`（NOTICE 已声明）；OCR 模型与 AAR 各有许可 | `GPL-3.0-or-later` |

Veri Fin 现有边界见 [截图识账与外部意图接口](auto-capture.md)，已有外部工具送入文本的方式见 [自动化入口](../product/automation.md)。Tasker/MacroDroid 可以把文本送入确认页，这条路线仍需要确认，不能等同于完整无感落账。

## 可复用部分与接入代价

### 本地解析：较小范围，但不是复制一个文件即可完成

上游解析器输入是带坐标的 `LocalOcrLine`，还依赖图片宽高、时间、来源和相关辅助规则。Veri Fin 目前的 OCR API 只返回拼接文本，因此若保留现有 ML Kit，需要先保留文字行的位置和图片尺寸，再适配解析器或把规则移植为 Dart。

可行方向是「用户分享截图 → 现有 ML Kit → 本地解析 → 待确认草稿」，识别不确定时保留手动修改或现有 AI 路径。分类名称需要映射到当前账本的 `Category.key` 和真实 ID，不能直接使用上游分类文本作为 ID。效果必须以实际支付截图验证，不能把上游模型下的准确率直接套用到 ML Kit。

上游当前采用 PP-OCRv6 Tiny，包含 ONNX Runtime、OpenCV 等原生运行库。引入整套引擎还会增加安装包、ABI、构建和许可证维护工作；它不是复用解析逻辑的前提。依据：[解析器输入](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/core/src/main/kotlin/net/ankio/ledger/core/LocalOcrBillParser.kt)、[运行库说明](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/third_party/ocr-runtime/README.md)。

### 全自动页面采集：定制需求允许，尚未实现

需要新增 Android 无障碍服务、授权与渠道设置、窗口检测、截图、识别队列，以及进程重启和重复投递处理。Flutter 还需可靠地接收原生结果；不能假设 UI 或 Dart 引擎始终处于运行状态。

接入时应让原生层负责采集和待处理结果传递，经现有 Controller 完成账目保存；不能照搬上游 `LedgerStore` 另建一套权威账目，也不能绕过 Controller 直接改现有数据库。持久化采集队列与交易身份若被引入，需要单独定义 SQLite 迁移、幂等消费、应用锁、备份及清理语义。

源码与现有 `AGENTS.md` 仍描述原有「不监听、确认后保存」行为。定制需求已允许无障碍和自动记账，后续实现时需同步这些规则与产品文档，区分新自动采集入口、原有手动入口及 AI 查询工具；这不意味着给只读 AI 查询工具增加写账能力。

上游还使用了 `com.google.android.accessibility.selecttospeak.SelectToSpeakService` 这一兼容类名，实际继承自己的截图服务，并非 Google 提供的实现。README 描述的是特定微信页面的对照观察，不能据此认为这是稳定接口，也不能保证以后微信版本、系统或设备仍可读取。支付页面改版、无可读节点、安全窗口以及系统权限限制都会影响可用性，应保留手动补记入口。依据：[兼容类](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/app/src/main/java/com/google/android/accessibility/selecttospeak/SelectToSpeakService.kt)、[上游说明](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/README.md)。

### 与 Veri Fin 当前代码的具体落差

结论都来自本地源码核对，随相关代码改动可能失效：

| 落差 | 现状 | 影响 |
| --- | --- | --- |
| 后台 Dart 运行时 | `android/app/src/main/kotlin/top/talyra42/verifin/` 下**没有 Application 子类**；Manifest 用 `${applicationName}` 默认值；通道在 `MainActivity.configureFlutterEngine` 注册 | Activity 销毁即无 Dart 运行时，原生采集到的结果没有落点；要做真后台必须先加应用级 `FlutterEngine` 缓存与 Application 生命周期 |
| 原生队列语义 | `consumeCaptureImage` / `consumeCaptureText` 是内存字段 + 取走即清 | 不能当可靠后台队列；进程被杀即丢，也无法区分「已落账」与「只是取走了」 |
| OCR 坐标 | `lib/app/screenshot_recognizer_io.dart` 只返回 `result.text` | 上游 `LocalOcrBillParser` 依赖 `LocalOcrLine` 坐标与图片宽高，**不能整文件搬运**；需先取 ML Kit 的 block/line bounding box，或改写为不依赖位置的规则 |
| 账目写入 | 权威是 `VeriFinController`（内存集合 + 行快照 + 写队列），`LedgerRepository` 的整表保存语义是「落库后该表等于传入集合」 | 原生服务若直连 SQLite 会绕过 Controller，导致内存/磁盘不一致、预算与界面不刷新；采集必须回到 Dart 层落账 |
| minSdk | Veri Fin 为 23，上游为 30 | 无障碍截图 API 需按 `Build.VERSION.SDK_INT` 能力探测（窗口截图要求 API 34），低版本禁用该功能，不抬 minSdk |

## 对个人需求的适配判断

- **统一扣款账户可以沿用。** 页面来源用于说明「微信/支付宝等渠道」，实际新支出经 Controller 应用指定银行卡活期账户。支付渠道不能直接变成扣款账户，也不能因截图写入再扣第二次。
- **去重必须跨入口。** 同一笔支付可能先被采集，后来又被截图或账单导入；交易号应带支付提供方作用域，保留与本地交易的关联。缺少交易号时只能提示疑似重复，不能只按金额和分钟静默丢弃。
- **资产月度表继续独立。** 日常支出影响指定活期账户，定期、基金、外币资产仍按现有账户和月度快照维护；外币人民币估值继续手动填写，不需要因接入采集增加汇率换算。
- **复杂资金流不宜首批自动处理。** 信用卡还款、余额充值、转账及退款与普通消费口径不同；上游退款逻辑不能直接替换 Veri Fin 已有的关联退款与余额规则。

## 复用边界与核查范围

上游 [NOTICE](https://github.com/AldenHe/huayoupu-ledger/blob/abb796d829748403612f09e89909819b974565c7/NOTICE.md) 声明项目代码采用 GPL-3.0-only，OCR 模型、原生库和其他第三方文件另保留各自许可。若复制代码或打包模型/运行库，需要保留对应版权、来源与许可材料，不能只复制功能文件而遗漏通知。

本次结论来自源码阅读，没有把上游测试或 README 的小样本成绩视为本机真机验收。本次仅记录评估和接入设计，没有引入上游依赖、权限或功能。

## 未决事项

以下问题会直接决定实现结构，需在动工前定稿；本页不预设答案：

- **首批做到哪一步**：只做真机探针（见「分批与验收前置」第 0 批），还是直接做「后台采集、打开后补记」，或一次性做到应用级常驻引擎的完整后台自动记账。
- **识别与规则解析放哪一层**：在 Dart 侧扩展现有 ML Kit（拿坐标、把规则改写为 Dart，不增包体积但与引擎绑定），或按上游在 Kotlin 侧引入独立识别运行库（后台可独立识别，但要引入 ONNX/OpenCV 的包体积、ABI 与许可维护）。

## 定制接入设计

本节是建议的实现设计，尚不是已发布能力。目标设备为小米 14，覆盖微信、支付宝；实际 Android / HyperOS 版本需实机核对，不根据机型推断当前系统版本。

### 仓库选择

| 选择 | 可以保留 | 主要代价 | 判断 |
| --- | --- | --- | --- |
| 在当前 Veri Fin fork 增加采集模块 | 已有资产月度表、分类预算、统一支出账户、历史账目和界面 | Android 采集与 Flutter 后台写入衔接 | 推荐；在独立功能分支开发 |
| 另 fork 花有谱作为主应用 | 已有原生采集和本地识别链路 | 重新适配资产、预算、账户口径、备份及数据迁移 | 适合以花有谱为主要产品的情况，当前需求不占优势 |
| 花有谱改成独立采集助手，向 Veri Fin 送数据 | 两边代码相对分离 | 两个 APK、跨应用接口、权限和消息确认；现有 Intent 仍会拉起确认页 | 不作为首选 |

当前仓库本身已是自有 fork，不必再创建同源的新 GitHub 仓库。可用 `feature/auto-accounting` 分支隔离开发，继续由现有 CI 生成后续版本；已推送的历史标签不移动，也不包含本节设想的功能。

### 分批与验收前置

功能较大，按批次推进，每批单独可验证；**后一批不通过不进入下一批**。

| 批次 | 交付 | 通过标准 |
| --- | --- | --- |
| 0 真机探针 | 最小无障碍服务，只记录微信/支付宝支付结果页能否读到节点树、成功文案与金额，以及能否截到图 | 小米 14 上两种渠道各一笔真实付款都能拿到节点树；能确认截图 API 可用或给出明确的不可用原因。**这批不过，后面都不做** |
| 1 前台闭环 | 采集任务交 Dart（引擎在时），ML Kit 取坐标 + 规则解析，产出草稿或待核对 | 不落账也能看到解析结果；支付页、非支付页、密码页分类正确 |
| 2 后台运行时 | 应用级常驻引擎，真正自动入账 | 「应用未打开时完成扣款与预算更新」验证通过 |
| 3 待核对与设置 | 待核对列表、暂停采集、失败状态、应用锁交互 | 可用、可更正、可删除、可暂停 |

探针阶段先验证节点树与截图这两个外部前提，再决定解析规则要不要照搬上游坐标算法；在未验证的前提下写完整解析器，返工风险最高。

### 使用效果与范围

- 设置中选择采集账本、微信/支付宝渠道、统一扣款活期账户；启用系统无障碍权限。自动采集账本固定保存，不随前台临时切换账本而变化。
- 明确的人民币普通支出自动记账，不必每次打开应用或点确认；默认不调用 AI，也不上传截图。记录包含商户、金额、支付时间和来源，分类按商户规则匹配，未匹配时使用明确的「待分类」项。
- 疑似重复、金额冲突、外币或账户不可用时进入待核对列表，不靠猜测落账。首批转账、充值、还款、退款不自动入账，后续分别衔接既有资金流规则。
- 收到记账结果后可查看、更正或删除；提供暂停采集和失败状态。应用锁继续保护查看账目，是否允许锁定期间后台记账应由独立设置明确控制，不能靠 `BuildContext` 是否存在来判断授权。
- 首批不同时增加通知监听、短信监听、商户图标裁剪或整套 OCR 引擎替换，先完成两种支付渠道的闭环。

### 模块与数据流

```text
微信 / 支付宝支付结果页
  → Kotlin 无障碍服务：隐私过滤 + 渠道过滤 + 成功判定（全部在申请像素之前）
  → 截图 + 持久化采集任务：稳定任务 ID、渠道、交易标识、目标账本、处理状态
  → Dart 侧：ML Kit 取带坐标的文字行 + 规则解析（保留可靠性判断与拒绝原因）
  → 自动记账协调器：可靠性判断、分类匹配、重复核对
  → 唯一账目 Controller → Repository 事务
  → 交易 + 采集回执同时提交 → 更新预算、账户及界面
```

原生侧只负责**采集与待处理证据传递**，识别与落账都在 Dart；这条分工是与上游最大的结构差别，因为 Veri Fin 的权威账目在 Controller 而不在原生数据层。

可选择性移植上游的页面检测、隐私过滤、金额解析和重复判定；需保留其辅助规则及测试样例来源。`ScreenCaptureService` 依赖上游应用对象、运行状态、队列和数据层，不能整文件复制后直接运行。第一版保留 Veri Fin 已有 ML Kit，只有真实截图暴露识别瓶颈时才评估 PP-OCR；两种 OCR 的效果不能直接等同。

### 后台写入的关键设计

当前平台通道由 `MainActivity.configureFlutterEngine` 注册，分享入口为内存中的「取走即清」消息；它们不适合作为后台采集任务的可靠队列。Controller 和 Repository 又分别维护内存账目、行快照和写队列，因此新建第二个后台 Controller 并发写同一账库，并不能仅靠 SQLite 事务保证应用状态一致；恢复、删除和整表替换尤其需要协调。

推荐先验证「进程内唯一账目运行时」：Android 应用级组件管理缓存 FlutterEngine，使账目 Controller 的生命周期独立于 Activity；主界面重新进入时连接同一运行时。无障碍服务只提交采集任务，不能直接写核心交易表。平台通道拆为应用级采集/持久化通道和依赖 Activity 的界面能力；无界面启动不得弹授权、导航、解锁页或执行需要 Activity 的插件调用。还要避免启动重试、界面销毁时误释放后台 Controller，以及重复执行周期规则、备份和小组件回调。

Flutter 官方支持引擎独立于 Activity 运行，但这不是后台永不被系统终止的保证。引擎未就绪或进程被终止时，任务保留，恢复后继续；只有「采集到交易，应用未打开时也完成扣款与预算更新」验证通过，才可宣称完整后台自动记账。如果仅在下次打开应用时消费任务，应明确称为「后台采集、打开后补记」。依据：[Flutter 缓存引擎与后台执行](https://docs.flutter.dev/add-to-app/android/add-flutter-screen)。

### 持久化与去重

- 采集队列保存 `captureId`、渠道、来源包、交易标识、金额最小单位、原文时间及其是否明确、接收时间、商户、目标账本、状态和错误。金额不能使用浮点文本直接计算。采集库只存待处理证据，不成为第二套账本。
- 同一采集任务重复投递使用稳定 `captureId`；跨页面、截图与导入使用带支付提供方作用域的交易身份。相同交易号出现不同金额属于冲突，不能把金额拼入主键后作为新消费再记一次。
- 正式交易与采集回执在同一账库事务提交，并对身份建立合适的唯一约束；提交成功后才确认队列。即使在提交后、确认前崩溃，重放也只返回既有交易。缺少交易号时保留疑似判断，不只按金额和分钟强行合并。
- 删除已自动记账交易需保留必要的忽略标记，避免重看页面后又被记回。补采历史页面不得修改已冻结的月度资产快照。
- 任务绑定目标账本、指定账户等配置版本；处理前重新校验账户是否删除、隐藏或币种不符，不能回退为首账户。队列设置容量与过期清理，已确认去重身份随备份恢复保留，避免恢复后重复记账；原始截图处理完默认清理。

### 适配和验证边界

无障碍截屏能力要求 Android API 30 及以上；按窗口截屏要求 API 34 及以上（上游即按此分支：34+ 用 `takeScreenshotOfWindow`，更低版本用显示屏截图再复核目标窗口）。保留应用原最低版本（23），在不支持的系统上禁用此功能；安全窗口截图失败则停止该次采集，不能保证每个支付界面都可读取。依据：[Android AccessibilityService API](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService)。

小米 14 真机优先核对：微信/支付宝各一笔付款、连续同金额两笔、重复打开页面、切后台与恢复、关闭服务、应用锁、指定账户扣款和一次重复导入。自动采集涉及原生服务与系统生命周期，不能只用 Dart 单测代替；后续实现采用这些关键检查及相关解析/幂等测试，不因调研运行全量测试。系统自启动和电池设置按实机 HyperOS 版本定位，不预写未经核实的菜单路径。
