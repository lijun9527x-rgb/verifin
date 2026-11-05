# 截图目录

根 README「界面预览」引用的三张 Android 模拟器截图（1180×2556，使用 diagnostic flavor 的虚拟账目）：

- `home.jpg` — 首页
- `assets.jpg` — 资产
- `reports.jpg` — 看板

最近一次重拍：2026-10-11（看板改为「日常 / 月统计 / 年统计」三 Tab 之后，深色主题；`reports.jpg` 取「月统计」Tab，能同时看到 Tab 结构与摘要 / 预算 / 排行卡）。

更新界面后记得同步替换：用 diagnostic flavor（`--flavor diagnostic`，覆盖安装不丢演示账目）打开对应页面顶部，
确认模拟器为 1180×2556 / density 480（`adb shell wm size` / `wm density`），
`adb exec-out screencap -p > shot.png`，再转 JPEG 覆盖同名文件（如 `ffmpeg -i shot.png -q:v 3 home.jpg`）。

2026-11-05 新增功能的 Widget 布局验证图（393×852 逻辑尺寸、2 倍导出；合成账户与金额）：

- `monthly-assets-widget.png` — 月度资产表。
- `category-budgets-widget.png` — 首页分类预算组件。

这些图片来自真实页面/组件的 Flutter Widget 测试，不是 Android 真机截图。现有三张 JPEG 仍对应已发布版本；新功能的 Android 验收与整页截图待 CI APK 真机验证后更新。
