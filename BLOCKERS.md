# BLOCKERS

> 记录被阻塞的条目、已尝试方案与具体报错；`ARCH-LAYER-002 / A-09` 要求的许可结论也记在此处。

## ARCH-LAYER-002 · A-09 · 字体许可结论（2026-10-21）

- **对象**：`assets/fonts/` 下 5 个字体文件（`SF-Mono-Regular.ttf`、`SF-Pro-Display-{Regular,Medium,Bold,Light}.ttf`），合计 3.94 MB。
- **结论：不可再分发**。SF Pro / SF Mono 为 Apple 系统字体，Apple 授权仅允许在 Apple 平台/系统内使用，禁止把字体文件本身再分发；随仓库与应用包分发存在许可风险。
- **现状核验**：`pubspec.yaml` 无 `fonts:` 段，`assets:` 只声明 `assets/images/`，因此这 5 个文件**从未进入构建产物**；全库 `Select-String -Pattern 'assets/fonts'` 零命中（代码里 `fontFamily: 'SF Mono'` / `'SF Pro Display'` 均为系统字体名，不是资源引用）。
- **处置**：删除 `assets/fonts/` 整目录（无代码改动）。`preferences_screen` 的字体选项（`AppConfig.FONT_FAMILY_*`）在 `AppTheme.getFontStyle` 中映射为 `sans-serif` / `serif` 等系统字体族，与字体文件无关，保持现状。
- **验收取证**：`(Get-ChildItem assets/fonts -File -ErrorAction SilentlyContinue | Measure-Object).Count` → 0；`assets/` 递归总大小 3.96 MB → 0.02 MB。

## ARCH-LAYER-002 · A-11 · 剩余 1 处 shrinkWrap 在作用域内无法消除（blocked，2026-10-21）

- **验收口径**：`(Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'shrinkWrap:\s*true' | Measure-Object).Count` 期望 `0`；实测 **9 → 1**。
- **已消除 8 处**（`e4b3b7d`）：`flomo_import_screen.dart` ×3（预览列改 Column、跳过列表给 320 上限、`Flexible` 内去 shrinkWrap）、`local_backup_restore_screen.dart` ×1（历史列改 Column，最多 20 条）、`server_info_screen.dart` ×2（注释死代码 / 已有 `maxHeight: 200`）、`heatmap.dart` ×1（GridView → Row/Column 固定格子）、`note_editor.dart` ×1（`Expanded` 内去 shrinkWrap）。
- **剩余 1 处**：`lib/screens/sidebar_customization_screen.dart:539` — `ReorderableListView(shrinkWrap: true, physics: NeverScrollableScrollPhysics())`，嵌在 `body: SafeArea(child: ListView(children: [...]))` 的「菜单项」section 里。
- **已尝试方案（3 次，均不可行）**：
  1. 直接删 `shrinkWrap` + `physics` → 父级是 `ListView`，高度无界，运行时抛 `BoxConstraints forces an infinite height`；该项 `ListTile` 的 `subtitle` 是条件渲染（`item.id == 'all_notes'`），行高 56/72 不定，`SizedBox` 常量高度会在大字号下裁切。
  2. 改 `Column` + `ReorderableDragStartListener` → 该监听器必须有 `SliverReorderableList` 祖先，否则拖拽无响应，等于删掉排序功能。
  3. 改 `SliverReorderableList` + `CustomScrollView` → 需把整个设置页 body 从 `ListView(children:)` 改成 sliver 结构，并把 `_buildSection`（`Column` + `Container` 卡片装饰）拆成 `DecoratedSliver` 版本；属页面级重构，且 **该文件不在 A-11 作用域内**（作用域只列 `flomo_import_screen.dart`、`local_backup_restore_screen.dart`）。
- **待确认选项（二选一）**：
  - a) 把 `sidebar_customization_screen.dart` 纳入 A-11 作用域，按 sliver 重构（1 个 commit，页面级改动，无自动化测试覆盖）；
  - b) 修订验收口径为「长度无上界的嵌套列表 shrinkWrap = 0」，为固定 ≤N 项的 `ReorderableListView` 开白名单（本处菜单项约 10 项，全量布局开销可忽略）。
- **如实披露**：为使计数从 9 降到 1，本次同时改了 3 个作用域外文件（`server_info_screen.dart`、`heatmap.dart`、`note_editor.dart`）的同类写法，均为机械替换、无业务逻辑变化；`flutter analyze` 0 issue、`flutter test` 399 全绿。

## QUAL-CLEAN-003 · 前置未达成（blocked，2026-10-21）

- **原因**：前置条目 `ARCH-LAYER-002` 因 A-11 转 blocked，未达 done；按执行合约不得跳过前置开工。
- **说明**：4 个子项彼此独立（A-12 删死代码、A-13 CI 加 `dart format`、A-14 `Image.asset` 补 `cacheWidth`、A-15 逐文件本地化），A-11 决策落定后可直接执行。
