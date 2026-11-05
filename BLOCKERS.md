# BLOCKERS

> 记录被阻塞的条目、已尝试方案与具体报错；`ARCH-LAYER-002 / A-09` 要求的许可结论也记在此处。

## VOICE-001 · 本机系统语音识别疑似不可用（未解，2026-11-05）

- **现象**：点首页麦克风进编辑器后立刻显示「正在聆听…」，长时间无任何识别文字，点麦克风 / 点「点击停止」都没反应（修复前）。
- **取证**：
  - `adb shell dumpsys audio` 的 Recording Activity 列表为空 → **麦克风根本没被占用**，不是"在录但识别不出来"
  - 状态栏无麦克风使用指示；等待 30s 也无任何 `onResult`
  - `speech_to_text` 侧 `isListening == true`、`listen()` 正常返回，说明平台"假装"启动成功
- **已修（`290f9d6`，1.1.56）**：平台调用全加超时、防抖标志改时间窗、停止先复位 UI、12s 哑火看门狗、`onError` 全量上报。**「停不掉」已闭环，但"识别起不来"的根因未定位。**
- **待确认**：
  1. 该 HyperOS 设备是否存在可用的 Android `RecognitionService`（`adb shell cmd package query-services -a android.speech.RecognitionService` 或装 debug 包看 `SpeechRecognizer.isRecognitionAvailable`）
  2. 设置里切「讯飞」模式能否正常出字（能出 → 只是本地引擎缺失，考虑首次使用引导）
- **临时结论**：界面不再卡死；引擎不可用时会自己收尾并提示「没有检测到麦克风输入，语音识别可能不可用」。

## ORIENT-001 · App 未做方向锁，行为完全跟随系统（待决策，2026-11-05）

- **现状**：`lib/` 全库无 `SystemChrome.setPreferredOrientations`；`android/app/src/main/AndroidManifest.xml` 无 `android:screenOrientation`；实测设备 `accelerometer_rotation=0`（锁定竖屏）、`user_rotation=0`。
- **含义**：App 会不会旋转只取决于系统「方向锁定」开关，与安装包无关；远程调试期间也可能因系统开关变化而出现"突然能转"的观感。
- **待决策**：是否在 `main()` 里锁 `portraitUp`，仅在图片查看器（`image_viewer_screen.dart`）临时放开横屏。属产品取舍，未动代码。

## PERF-IMG-001 · 多图笔记详情页 / 大图查看器是否仍卡（待复测，2026-11-05）

- **已做**：`fc1b832` 统一解码像素档位（`image_decode_width.dart`）+ 九宫格/大图查看器延后解码；`b567c0f` 修掉首页缩略图同帧解码风暴。
- **未做**：真机前后对比。需要一条 9 图笔记的完整回归：进详情页首屏、连续左右翻大图、Live 图播放，看 `FrameTiming` 或肉眼是否仍有掉帧。
- **风险**：`fc1b832` 的延后解码在低端机上可能表现为"图片出得慢"，需要在真机确认不是以「长时间灰底」换取流畅。

## DOC-001 · 工具链与发布文档的噪音（未解，2026-11-05）

- `_backup/analyze_backup.dart:61` 触发 `require_trailing_commas`（info），导致 `dart tool/inkpaper.dart analyze` / `verify` 退出码为 1，容易被误判为"分析失败"。
- `CHANGELOG.md` 最新条目仍是 `1.1.13`（2026-06-22），落后约 40 个版本；期间变更只记在 `PROGRESS.md`。
- 建议：删掉或纳入 `.gitignore` 的 `_backup/`；CHANGELOG 要么按大版本补齐，要么在文件头声明「内部变更以 PROGRESS.md 为准」。

## ARCH-LAYER-002 · A-09 · 字体许可结论（2026-10-21）

- **对象**：`assets/fonts/` 下 5 个字体文件（`SF-Mono-Regular.ttf`、`SF-Pro-Display-{Regular,Medium,Bold,Light}.ttf`），合计 3.94 MB。
- **结论：不可再分发**。SF Pro / SF Mono 为 Apple 系统字体，Apple 授权仅允许在 Apple 平台/系统内使用，禁止把字体文件本身再分发；随仓库与应用包分发存在许可风险。
- **现状核验**：`pubspec.yaml` 无 `fonts:` 段，`assets:` 只声明 `assets/images/`，因此这 5 个文件**从未进入构建产物**；全库 `Select-String -Pattern 'assets/fonts'` 零命中（代码里 `fontFamily: 'SF Mono'` / `'SF Pro Display'` 均为系统字体名，不是资源引用）。
- **处置**：删除 `assets/fonts/` 整目录（无代码改动）。`preferences_screen` 的字体选项（`AppConfig.FONT_FAMILY_*`）在 `AppTheme.getFontStyle` 中映射为 `sans-serif` / `serif` 等系统字体族，与字体文件无关，保持现状。
- **验收取证**：`(Get-ChildItem assets/fonts -File -ErrorAction SilentlyContinue | Measure-Object).Count` → 0；`assets/` 递归总大小 3.96 MB → 0.02 MB。

## ARCH-LAYER-002 · A-11 · 剩余 1 处 shrinkWrap 在作用域内无法消除（已解除，2026-10-21）

- **解除方式**：采纳选项 a（扩大作用域到 `lib/screens/sidebar_customization_screen.dart`）。该页 `body` 由 `ListView(children:)` 改为 `CustomScrollView` + 3 段 sliver：`SliverList`（其余设置项）+ `SliverToBoxAdapter`（分组标题，抽出 `_buildSectionHeader`）+ `DecoratedSliver(SliverPadding(SliverReorderableList))`（菜单项排序）。拖拽仍由各项内的 `ReorderableDragStartListener` 驱动，`onReorderItem` 语义不变。提交 `84bc599`，全库 `shrinkWrap: true` 9 → 0。

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

## QUAL-CLEAN-003 · 前置未达成（已解除，2026-10-21）

- **原因**：前置条目 `ARCH-LAYER-002` 曾因 A-11 转 blocked，未达 done；按执行合约不得跳过前置开工。
- **解除**：A-11 已用 `84bc599` 完成（设置页改 `CustomScrollView` + `SliverReorderableList`），`ARCH-LAYER-002` 回到 done，本批次已执行 A-12 / A-13 / A-14，剩 A-15 见下。

## QUAL-CLEAN-003 · A-15 · 本地化体量与验收口径（已解除，2026-10-21）

- **解除方式**：重新定义可判定口径——「`lib/screens` + `lib/widgets` 内直接写在 widget 参数里的中文字面量」= 0（排除注释、`_text('zh','en')` / `text('zh','en')` 双语助手、`AppLocalizationsSimple` fallback）。按此口径实测：改前 **82** → 现在 **0**，共 4 批 commit（`0960608`、`21236a4`、`c35259f`、`be5f87a`），覆盖 15 个文件 36 处文案。原先「约 1,300 行」是把 l10n fallback 与日志也算进去的旧口径，已作废。

- **已完成增量**（`0960608`）：`forgot_password_screen.dart` 未接入 l10n 的 UI 文案 10 → 0（新增 `memosNoPasswordResetHint` / `memosNoPasswordResetDetail` / `rememberedPassword` 三个键，中文 fallback 保留），作为「每次一个文件」的参考实现。
- **阻塞原因 1（缺验收）**：条目自述「**缺验收**：无合理『中文归零』终点」。现状指标 `'[^']*[\u4e00-\u9fff]` 会同时统计 l10n fallback 与 `debugPrint`，接入 l10n 后计数**不下降**（`forgot_password_screen.dart` 改后仍为 12），无法作为门禁。
- **阻塞原因 2（体量）**：按「未接 l10n 的 UI 文案」口径（排除 `AppLocalizationsSimple` / `debugPrint` / 注释行）实测余量（Top 10）：`webdav_settings_screen.dart` 148、`preferences_screen.dart` 122、`app_provider.dart` 117、`ai_settings_screen.dart` 109、`user_agreement_screen.dart` 99、`ai_insight_engine.dart` 98、`local_backup_restore_screen.dart` 89、`flomo_import_screen.dart` 75、`server_info_screen.dart` 72；合计约 1,300 行。每个文案还需要新增 zh/en 词条 + getter，单轮无法闭环。
- **建议方案**：
  1. 把 A-15 拆成按文件的 N 条子任务（每条 = 1 个文件 + 1 个 commit），验收改为「该文件按上述口径计数为 0」；
  2. 或先只覆盖「设置类页面」白名单（`webdav_settings_screen` / `ai_settings_screen` / `notion_settings_screen` 等），把 `app_provider.dart`、`ai_insight_engine.dart` 这类日志/内部提示排除在本地化范围外。
- **参考命令**（口径修正后）：
  ```powershell
  (Select-String -Path lib/screens/webdav_settings_screen.dart -Pattern "'[^']*[\u4e00-\u9fff]" |
    Where-Object { $_.Line -notmatch 'AppLocalizationsSimple|debugPrint|^\s*//' } | Measure-Object).Count
  ```
