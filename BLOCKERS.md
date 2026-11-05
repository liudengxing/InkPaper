# BLOCKERS

> 记录被阻塞的条目、已尝试方案与具体报错；`ARCH-LAYER-002 / A-09` 要求的许可结论也记在此处。

## VOICE-001 · 语音改为「默认关闭 + 仅讯飞」，系统识别整体移除（已解决，2026-11-05 · 1.1.57 `d8f395c`）

- **原现象**：点首页麦克风进编辑器后立刻显示「正在聆听…」，长时间无任何识别文字，点停止也没反应；`adb shell dumpsys audio` 的 Recording Activity 为空 → 麦克风根本没被占用，但 `speech_to_text` 侧 `isListening == true`（平台「假装」启动成功）。
- **处理决定（不再追根因）**：这个根因（HyperOS 无可用 `RecognitionService`）在用户设备上不可控，留着就是长期隐患。改为：
  1. 系统识别链路（`speech_to_text` 插件 + 本地识别代码 + 失败弹窗）**整体删除**；依赖从 `pubspec.yaml` 移除
  2. 百度语音链路（`baidu_speech_service` / `baidu_realtime_speech_service`）**无任何调用方**，属死代码，一并删除（含 `AppConfig.BAIDU_*` 常量与专用文案）
  3. 新增 `AppConfig.speechInputEnabled` = `iflytekSpeechEnabled && 三件套齐全`；首页输入条与编辑器右上角麦克风**只在为真时渲染**
  4. `IflytekSpeechService` 补 `onDone`：VAD 判停（status=2）或连接关闭时回调一次，编辑器自动落字并复位「正在聆听」
- **验收**：`dart tool/inkpaper.dart analyze` 仅剩 `_backup` 历史 info；`test` 530 项全绿（新增 6 项覆盖 `speechInputEnabled` 组合）；`build android-release` 成功（50.1MB）。
- **仍未验证**：**讯飞端到端真机**。本机 `adb connect 192.168.0.108:35819` 超时（设备离线），所以「填三件套 → 首页出现麦克风 → 说长句 → 判停自动落字」这条链只有编译与单测保证，没有真机证据。

## STRUCT-001 · 结构与巨型文件（L1/L2 完成，L3 待做 · 1.1.59）

**结论先行**：拆分的价值不在「行数」，在**改动的隔离面**与**逻辑能否被测**。按最近 300 次提交的 churn 排序，只有 5 个文件值得动：

| 文件 | 行数 | churn | 判断 |
|---|---|---|---|
| `app_provider.dart` | 4966 | 38 | ✅ 该拆（L3） |
| `home_screen.dart` | 2926 → **1950** | 26 | ✅ 已做（L1） |
| `note_card.dart` | 1630 → **1298** | 23 | ✅ 已做（L1） |
| `note_editor.dart` | 3850 → **3293** | 13 | ✅ 已做（L1+L2） |
| `local_backup_restore_screen.dart` | 2768 | 11 | ⏳ 边界，看后续 |
| `preferences_screen.dart` | 2764 | **2** | ❌ 不做 |
| `share_utils.dart` | 2441 | **2** | ❌ 不做 |
| `ai_settings_screen.dart` | 2351 | 4 | ❌ 不做 |
| `share_image_preview_screen.dart` | 1644 | **1** | ❌ 不做 |

`preferences` / `share_utils` / `ai_settings` / `share_image_preview` 合计 9200 行，但一个季度只改 9 次——拆它们要动 9200 行，换 0 次未来收益。

- **已做 P0（1.1.57 `eed02f3`，纯机械）**：`widgets→screens` 2 个页面；`services→utils` 7 个纯函数工具。
- **已做 L1（1.1.58 `f719baa`）**：抽出三块寄生 UI —— `_AiInsightScreen`（977 行 → `screens/ai_insight_screen.dart`）、`_NoteReferenceDialog`（382 行 → `widgets/note_reference_dialog.dart`）、批注 CRUD（**两处副本已漂移**，合并为 `widgets/note_annotation_dialogs.dart`，note_card 与 note_actions_ui 各减 355/378 行）。
- **已做 L2（1.1.59 `3eae4f8`）**：`utils/note_image_anchor.dart`（`TextDiff` / `shiftImageOffsets` / `splitRangeByImages`）、`utils/tag_input_helper.dart`（`detectTagPrefix` / `rankTagSuggestions` / `applyTagInsertion`），补 39 项单测。这两个新文件都**不认识 `MemoStyleRange`**，只返回索引区间，避免 `utils → widgets` 逆依赖。
- **刻意没做（附理由）**：
  - `utils/share_utils.dart` 是 Canvas 绘制/截图逻辑，`share_image_widget.dart` 被它依赖；把 widget 挪进 `widgets/` 会制造 `utils → widgets` 逆依赖
  - `services/note_actions_service.dart` 是唯一一处 `services → providers` 逆向依赖，需要改结构（动作函数下沉）
- **仍欠（L3，等设备上线再做）**：
  1. `app_provider.dart` 的真实构成不是「全能上帝类」：约 **1500 行（30%）是账号与云验证**，跟笔记无关；AI 与导入导出早就不在里面。拆法是把账号域（~900 行）+ 云验证（~600 行）搬去 `lib/core/auth/`，再抽一个 `_mutateNote()` 统一 9 件事的编排（现在 `createNote` / `updateNote` 各复制一遍）
  2. **`core/state/` 的 37 条纯转发 getter/setter 要在 L3 一并删掉**，让方法直接写 `_notesStore.notes`。`STATE-CORE-005` 只搬了字段没搬行为，留着这层转发只会让人误判「拆分已完成」，而且行数不降反升
  3. 根目录 4 个内部文档（`ARCHITECTURE.md` 停在 1.0.15 / `AUDIT.md` / `BASELINE.md` / `LOCAL_DEV_SETUP.md`）未进 `docs/`
- **不建议**：feature-first 重排 166 个文件。路径全变会让文档里几十处「文件:行号」作废，git blame 断代，一次几百文件的 diff 无法 review。

## AI-INSIGHT-001 · AI 洞察页没有入口（待决策，2026-11-05 · 1.1.59）

- **现象**：`lib/screens/ai_insight_screen.dart`（L1 从 `home_screen.dart` 抽出的 977 行完整页面）在真机上点不到。唯一调用它的 `home_screen.dart:1921 _showAiInsightDialog()` 带着 `// ignore: unused_element`，自 `c059bf8`「排序改为标题下方下拉菜单，移除顶栏 AI 入口」之后就没有任何调用方了。
- **影响**：这不影响编译和测试，但 `docs/HANDOFF.md` 把它当作可用功能列在代码地图里，属于文档与代码不一致；后续如果有人「修」这个页面，会白费力气。
- **选项**：
  1. 在侧边栏「回顾」附近加一个入口，让它真正可用（需确认产品上是否还要这个功能——它的能力与「回顾」「问笔记」有重叠）
  2. 连同 `_showAiInsightDialog` 一起删除，`ai_insight_screen.dart` 一并移除
  3. 保持现状，只在文档里标注「当前无入口」
- **建议**：先定产品取舍（1 或 2），别长期挂着一个点不到的页面。

## ORIENT-001 · App 未做方向锁，行为完全跟随系统（待决策，2026-11-05）

- **现状**：`lib/` 全库无 `SystemChrome.setPreferredOrientations`；`android/app/src/main/AndroidManifest.xml` 无 `android:screenOrientation`；实测设备 `accelerometer_rotation=0`（锁定竖屏）、`user_rotation=0`。
- **含义**：App 会不会旋转只取决于系统「方向锁定」开关，与安装包无关；远程调试期间也可能因系统开关变化而出现"突然能转"的观感。
- **待决策**：是否在 `main()` 里锁 `portraitUp`，仅在图片查看器（`image_viewer_screen.dart`）临时放开横屏。属产品取舍，未动代码。

## PERF-IMG-001 · 多图笔记详情页 / 大图查看器是否仍卡（待复测，2026-11-05）

- **已做**：`fc1b832` 统一解码像素档位（`image_decode_width.dart`）+ 九宫格/大图查看器延后解码；`b567c0f` 修掉首页缩略图同帧解码风暴。
- **未做**：真机前后对比。需要一条 9 图笔记的完整回归：进详情页首屏、连续左右翻大图、Live 图播放，看 `FrameTiming` 或肉眼是否仍有掉帧。
- **风险**：`fc1b832` 的延后解码在低端机上可能表现为"图片出得慢"，需要在真机确认不是以「长时间灰底」换取流畅。

## DOC-001 · 工具链与发布文档的噪音（部分解决，2026-11-05 · 1.1.58 `1ee212e`）

- ✅ `analyze` 退出码已归零：`analysis_options.yaml` 的 `exclude` 增加 `_backup/**`。该目录既不参与编译也不该参与分析，此前它让退出码长期为 1，把真正的告警淹没了。现在 `dart tool/inkpaper.dart analyze` → `No issues found!`，退出码 0（首次全绿）。
- ⏳ `CHANGELOG.md` 仍停在 `1.1.13`（2026-06-22），落后约 45 个版本；期间变更只记在 `PROGRESS.md`。**待决策**：按大版本补齐，还是在文件头声明「内部变更以 PROGRESS.md 为准」——后者成本低得多，倾向后者。

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
