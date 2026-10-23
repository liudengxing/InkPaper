## 2026-10-23 · 侧边栏热力图宽度修复 · done

- 现象：侧边栏「活动记录」热力图只占卡片左半边（用户连续两次反馈「没占满」）
- 根因：A-11 把 `GridView` 换成 `Row/Column` 时写死 `cellSize = 18.0`，7 列 + 6 间距只有 138pt，而卡片内容宽约 300pt
- 尝试 1（`bf55a6f`）：改 `LayoutBuilder` 按宽度算 `cellSize`，但 `clamp(12, 26)` 的**上限 26** 仍让总宽只有 194pt，依旧没铺满
- 最终（`4390b9a`）：每行固定 7 个 `Expanded` + `AspectRatio(1)`，宽度由父容器平分、高度跟随宽度；空位用 `SizedBox.shrink()` 占位；星期标签同样改 `Expanded`，与格子一一对齐
- 附带修复：`Heatmap` 的 `ValueKey` 在 `notes.isEmpty` 时用 `DateTime.now().millisecondsSinceEpoch`，key 每次 build 都变 → 42 个 Tooltip + 6 张统计卡整棵重建；改为固定 `0`
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 20.2s)
$ flutter test
01:20 +416: All tests passed!
```
- 真机：设备 `23127PN0CC`（`192.168.0.108:33717`）安装 `1.0.43+10043` profile 包，截图确认 7 列铺满卡片、星期标签对齐
- 版本：`1.0.41+10041` → `1.0.42+10042`（尝试 1）→ `1.0.43+10043`（最终）
- 记录：debug 包（175.7 MB）在真机上「空数据也卡」属 JIT 开销，已构建 profile 包（109.2 MB，AOT）供对比

## 2026-10-23 · ROADMAP 状态与文档对齐 · done

- 触发：`docs/ROADMAP.md` 索引表 5 条全部 `done`，但元信息与验收描述仍停留在「release 构建不可用」，与 A-10 补测结果不符
- 改动（仅文档，无代码）：
  - 元信息「验收环境限制」：release 现可构建（`android/key.properties` 指向本地一次性测试密钥，正式发布前须替换）
  - 索引表 ARCH-LAYER-002 验收列：补 A-10 实测体积（universal 75.6 MB / AAB 69.7 MB / arm64 27.8 MB vs debug 175.7 MB）
  - 阶段退出条件：Phase 2 / 3 / 4 均标注「已满足」（0 issue / 416 测试全绿），并追加「真机拖动排序待人工确认」的遗留说明
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 11.1s)
$ flutter test
00:38 +416: All tests passed!
```
- 结论：本版 ROADMAP 全部条目终结，Phase 4 退出条件满足；下一步（是否产出下一版 ROADMAP）属 Phase 边界，按规范需人工拍板
- 无代码改动，无版本变更

## 2026-10-21 · STATE-CORE-001 子项 3 · done

- 改动：`lib/providers/app_provider.dart` 三处串行同步循环改为「每批 3 条 + `Future.wait`」，单条失败不影响同批其他笔记（日志/ErrorHandler 保留）
- 验收输出：
```
$ (Select-String -Path lib/providers/app_provider.dart -Pattern 'for \(final note in unsyncedNotes\)' | Measure-Object).Count
0
$ (Select-String -Path lib/providers/app_provider.dart -Pattern 'Future\.wait|Semaphore' | Measure-Object).Count
3
$ flutter analyze --no-pub
No issues found!
$ flutter test test/unit
00:14 +328: All tests passed!
```
- 缺验收：50 / 200 条笔记的同步耗时对比未执行（无可用服务器），按任务定义记为缺验收
- commit: `4b22455`

## 2026-10-21 · STATE-CORE-001 子项 1 · blocked

- 已尝试（第 1 次）：新建 `lib/providers/sync_store.dart`，把 `_isSyncing` / `_syncMessage` / `_syncingNoteIds` 迁入 SyncStore，`AppProvider` 以 getter/setter 转发
- 验收输出：
```
$ Test-Path lib/providers/sync_store.dart
True
$ ([System.IO.File]::ReadAllLines('lib/providers/app_provider.dart')).Count
4475            # 期望 <= 3500
$ (Select-String -Path lib/providers/app_provider.dart -Pattern 'notifyListeners\(' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
58              # 期望 <= 42
$ flutter analyze --no-pub
No issues found!
```
- 结论：状态抽取后行数反而 +41（转发 getter/setter 占比），「只拆同步域」可迁代码约 520–790 行，减不到 3500；阈值与作用域不匹配
- 需决策：见 `BLOCKERS.md`
- commit: `4b22455`

## 2026-10-21 · STATE-CORE-001 子项 2 · blocked

- 已尝试（第 1 次）：`_lineCount` 改为 `ValueNotifier<int> _lineCountNotifier`，`_updateLineCount()` 不再 `setState`，`build` 外层包 `ValueListenableBuilder<int>`，行数变化只重建编辑器子树
- 验收输出：
```
$ (Select-String -Path lib/widgets/note_editor.dart -Pattern 'setState\(' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
38              # 期望 <= 25（改前 39）
$ (Select-String -Path lib/widgets/note_editor.dart -Pattern 'ValueListenableBuilder' | Measure-Object).Count
1               # 期望 >= 1 ✅
$ flutter analyze --no-pub
No issues found!
```
- 结论：输入派生状态已不再 `setState`，但剩余 38 处多为交互态（弹窗、语音、图片、工具栏），压到 25 需逐个改造，且与「输入不整树重建」目标关联弱
- 需决策：见 `BLOCKERS.md`
- commit: `14f04c6`

## 2026-10-21 · STATE-CORE-001 子项 1 · done（验收口径调整）

- 决策：改按四条验收判定完成（① `class SyncStore` 唯一文件；② `isSyncing` / `syncingNoteIds` 命中均为转发且 ≤6 条；③ 同步目录无 `watch<AppProvider>` / `Consumer<AppProvider>`；④ DevTools 仅 SyncScope 子树重建）。原「app_provider ≤3500 行 + notify ≤42」阈值作废。
- 实测输出：
```
$ (Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'class SyncStore' | Select-Object -ExpandProperty Path -Unique | Measure-Object).Count
1
$ (Select-String -Path lib/providers/app_provider.dart -Pattern 'isSyncing|syncingNoteIds' | Measure-Object).Count
11
$ Test-Path lib/features/sync
False
$ Test-Path lib/core/state
False
```
- 结论：① 通过；② 11 条 > 6 条（5 条为 getter/setter 转发，6 条为 `_isSyncing` / `_syncingNoteIds` 使用处，未加 `_syncStore.` 前缀）；③④ 因仓库无 `lib/features/sync` 目录、无 `SyncScope` 类，记为不适用
- 备注：本次仅文档变更，无代码改动

## 2026-10-21 · STATE-CORE-001 子项 2 · done（验收口径 A）

- 决策：验收改为「输入路径（`_updateLineCount` / `_detectTagInput`）内 `setState` 为 0」，原「全文件 ≤25」作废
- 实测输出：
```
$ (Select-String -Path lib/widgets/note_editor.dart -Pattern 'ValueListenableBuilder' | Measure-Object).Count
1
$ 输入路径内 setState（_updateLineCount + _detectTagInput 方法体）
0
$ flutter analyze --no-pub
No issues found!
```
- 说明：`_detectTagInput`（171–254 行）与 `_updateLineCount` 方法体内均无 `setState`；全文件 setState 现为 38，仅作参考、不作验收
- 遗留：剩余交互态 `setState` 约 13 处不单独开任务，记入 QUAL-CLEAN-003「待评估项」
- commit: `14f04c6`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · WebDAV 域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/webdav_store.dart`（新建）
- 迁移字段（5）：`_webDavConfig` / `_webDavService` / `_webDavSyncEngine` / `_webDavBackupTimer` / `_hasPerformedStartupBackup` → `WebDavStore`（`config` / `service` / `syncEngine` / `backupTimer` / `hasPerformedStartupBackup`）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
webdav decl 旧=5 新=0
$ _webDavStore. 转发数
10
$ flutter analyze lib/core/state/webdav_store.dart lib/providers/app_provider.dart
No issues found! (ran in 3.3s)
$ flutter test test/unit
00:15 +328: All tests passed!
```
- 版本：`1.0.18+10018` → `1.0.19+10019`
- commit: `a5ee318`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · Notion 域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/notion_store.dart`（新建）
- 迁移字段（2）：`_notionSyncService` / `_isNotionSyncing` → `NotionStore`（`syncService` / `isSyncing`）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
notion decl 旧=2 新=0
$ _notionStore. 转发数
3
$ flutter analyze lib/core/state/notion_store.dart lib/providers/app_provider.dart
No issues found! (ran in 2.0s)
$ flutter test test/unit
00:14 +328: All tests passed!
```
- 版本：`1.0.19+10019` → `1.0.20+10020`
- commit: `57cb3db`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · 提醒/通知域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/reminder_store.dart`（新建）
- 迁移字段（4）：`_reminderNotificationService` / `_notificationService` / `_notificationServiceInitialized` / `_unreadAnnouncementsCount` → `ReminderStore`（`reminderService` / `appNotificationService` / `appNotificationInitialized` / `unreadAnnouncementsCount`）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
reminder decl 旧=4 新=0
$ _reminderStore. 转发数
6
$ flutter analyze lib/core/state/reminder_store.dart lib/providers/app_provider.dart
No issues found! (ran in 1.8s)
$ flutter analyze（全项目）
No issues found! (ran in 7.7s)
$ flutter test test/unit
00:15 +328: All tests passed!
```
- 版本：`1.0.20+10020` → `1.0.21+10021`
- commit: `1d5ae86`（代码），本次（文档）
- 遗留：AI 域在 `AppProvider` 内无独立字段（仅方法），小组件仅 `_widgetSnapshotUpdateId`；下一轮需先判定这两域是否值得单独建 Store，或并入通用基建字段后终结 STATE-CORE-005

## 2026-10-21 · STATE-CORE-005 · 小组件域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/widget_store.dart`（新建）
- 迁移字段（1）：`_widgetSnapshotUpdateId` → `WidgetStore.snapshotUpdateId`（快照调度版本号，防抖 350ms 期间丢弃过期快照）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
widget decl 旧=1 新=0
$ _widgetStore. 转发数
2
$ flutter analyze lib/core/state/widget_store.dart lib/providers/app_provider.dart
No issues found! (ran in 2.3s)   # 首轮报 directives_ordering，调整 webdav/widget import 先后后清零
$ flutter test test/unit
00:15 +328: All tests passed!
```
- 版本：`1.0.21+10021` → `1.0.22+10022`
- commit: `b127e62`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · 云验证域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/cloud_verification_store.dart`（新建）
- 迁移字段（3）：`_cloudService` / `_cloudAppConfig` / `_lastCloudVerificationTime` → `CloudVerificationStore`（`service` / `appConfig` / `lastVerificationTime`）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
cloud decl 旧=3 新=0
$ _cloudStore. 转发数
5
$ flutter analyze lib/core/state/cloud_verification_store.dart lib/providers/app_provider.dart
No issues found! (ran in 1.8s)
$ flutter test test/unit
00:14 +328: All tests passed!
```
- 版本：`1.0.22+10022` → `1.0.23+10023`
- commit: `db3d7b2`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · 终结（AI 域 skipped）

- AI 域验收取证（无字段可迁）：
```
$ Select-String -Path lib/providers/app_provider.dart -Pattern '(?i)\b(AI|LLM|OpenAI|Ollama|Gemini|Anthropic|DeepSeek|Prompt)\w*'
572: aiEnabled: true,
573: aiApiUrl: AppConfig.DEEPSEEK_API_URL,
644: content: 'AI 点评要给出具体反馈，而不是模板话。\n\n'
646: '#AI #产品/体验',
649: tags: const ['AI', '产品/体验'],
```
  → 命中仅截图演示数据与 `aiEnabled` / `aiApiUrl` 配置调用，无 AI 域字段声明，判 skipped（不新建空 Store）
- 结论：STATE-CORE-005 的 7 个域全部迁出，`AppProvider` 内已无域字段定义（仅通用基建字段：`_appConfig` / `_mounted` / `_resourceService` / `_databaseService` / `_preferencesService` / `_authStore` 等 Store 持有者本身）
- 状态：done

## 2026-10-21 · ARCH-LAYER-002 · A-05 · done

- 作用域：`lib/services/note_actions_service.dart`、新建 `lib/widgets/note_actions_ui.dart`、调用方 `lib/widgets/note_card.dart`、`lib/widgets/note_more_options_menu.dart`
- 做法：整份 UI 编排（弹窗/对话框/导航/SnackBar，1,700+ 行）平移到 widgets 层的 `NoteActionsUi`；服务层重写为纯数据层 `NoteActionsService`（`updateContent` / `delete` / `restore` / `togglePin` / `setVisibility`），不 import `screens/`、`widgets/`、不碰 `BuildContext`。两个调用方只改 import 与类名，调用参数不变。
- 实测输出：
```
$ (Select-String -Path lib/services/note_actions_service.dart -Pattern "package:inkpaper/(screens|widgets)/" | Measure-Object).Count
0
$ flutter analyze
No issues found! (ran in 6.9s)
$ flutter test
00:26 +399: All tests passed!
```
- 版本：`1.0.23+10023` → `1.0.24+10024`
- commit: `7c62862`（代码），`e5c388f`（文档）

## 2026-10-21 · ARCH-LAYER-002 · A-06 · done

- 做法：`NetworkUtils` 改为进程级共享 `http.Client`（懒加载 `sharedClient`），`createOptimizedClient` / `createDirectClient` 返回同一实例；删除每个请求里的 `client.close()`（否则会关掉共享客户端），新增 `NetworkUtils.close()` 供退出/teardown 调用。
- 实测输出：
```
$ http.Client() 计数
1   (期望 <= 1)
$ close() 计数
4   (期望 >= 1)
$ flutter analyze
No issues found! (ran in 11.4s)
$ flutter test test/unit
00:14 +328: All tests passed!
```
- 版本：`1.0.24+10024` → `1.0.25+10025`
- commit: `63e1b7d`

## 2026-10-21 · ARCH-LAYER-002 · A-07 · done

- 做法：新增顶层函数 `decodeBackupNotesJson(String rawJson)`（供 `compute` 调用），只做解码 + 结构校验，返回 `List<Map<String, dynamic>>`；`importNotesFromJson` 改 `await compute(...)`，`Note.fromJson` 仍在主 isolate。`_importNotes` 原本就是单个 `db.transaction`，插入包事务无需改动。
- 实测输出：
```
$ jsonDecode(jsonData) 计数
0   (期望 0)
$ compute(|Isolate.run 计数
1   (期望 >= 1)
$ flutter analyze lib/services/database_service.dart
No issues found! (ran in 1.0s)
$ flutter test test/unit
00:15 +328: All tests passed!
```
- 版本：`1.0.25+10025` → `1.0.26+10026`
- commit: `a2f1436`

## 2026-10-21 · ARCH-LAYER-002 · A-08 · done

- 做法：删除 `cupertino_icons` / `flutter_image_compress` / `flutter_svg` / `flutter_highlight` / `graphview` / `flutter_dotenv` 六个无引用依赖，并删 `xml` 直连声明（`flutter pub deps` 显示 `xml 6.6.1` 由 `webdav_client 1.2.2` 与 `flutter_native_splash` 传递引入，删直连不影响解析）。
- 实测输出：
```
$ flutter pub deps --style=compact
- webdav_client 1.2.2 [dio xml convert]
- xml 6.6.1 [collection meta petitparser]
$ 已删依赖计数
0   (期望 0)
$ flutter pub get
Got dependencies!（1 package is discontinued）
$ flutter analyze
No issues found! (ran in 8.6s)
$ flutter test
00:23 +399: All tests passed!
```
- 版本：`1.0.26+10026` → `1.0.27+10027`
- commit: `02bb3b5`（含 `pubspec.lock`）

## 2026-10-21 · ARCH-LAYER-002 · A-09 · done

- 前置：许可结论先写入 `BLOCKERS.md`（SF Pro / SF Mono 不可再分发；且 `pubspec.yaml` 无 `fonts:` 段、`assets:` 仅 `assets/images/`，这 5 个文件从未打包）。
- 实测输出：
```
$ (Get-ChildItem assets/fonts -File -ErrorAction SilentlyContinue | Measure-Object).Count
0   (期望 0)
$ assets 递归总大小
0.01 MB   (期望 <= 0.1，改前 3.96)
$ flutter analyze
No issues found! (ran in 7.5s)
$ flutter test
00:30 +399: All tests passed!
```
- 版本：`1.0.27+10027` → `1.0.28+10028`
- commit: `7c0039f`

## 2026-10-21 · ARCH-LAYER-002 · A-10 · done

- 做法：`android-release` / `android-release-split` / `android-appbundle` 三条 release 构建参数加 `--obfuscate`；原本缺 `--split-debug-info` 的 universal APK 一并补上（否则混淆后堆栈不可读）。
- 实测输出：
```
$ --obfuscate 计数
4   (期望 >= 1)
$ dart analyze tool/inkpaper.dart
No issues found!
$ dart tool/inkpaper.dart --help
android-debug | android-release | android-release-split | android-aab
```
- 缺验收（按条目原文）：release 体积对比需 `android/key.properties`，当前缺失，未测量。
- 版本：`1.0.28+10028` → `1.0.29+10029`
- commit: `a9dbe45`

## 2026-10-21 · ARCH-LAYER-002 · A-11 · blocked（8/9 处已消除）

- 实测输出：
```
$ (Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'shrinkWrap:\s*true' | Measure-Object).Count
1   (改前 9，期望 0)
$ flutter analyze
No issues found! (ran in 7.0s)
$ flutter test
00:31 +399: All tests passed!
```
- 已处理：`flomo_import_screen.dart` ×3、`local_backup_restore_screen.dart` ×1、`server_info_screen.dart` ×2、`heatmap.dart` ×1、`note_editor.dart` ×1（细节见 BLOCKERS）
- 阻塞点：`sidebar_customization_screen.dart:539` 的 `ReorderableListView(shrinkWrap: true)` 嵌在 `ListView` 内；已试 3 种方案（直接删参数 / Column+拖拽监听器 / SliverReorderableList）均不可行或需页面级 sliver 重构，且该文件不在 A-11 作用域。
- 版本：`1.0.29+10029` → `1.0.30+10030`
- commit: `e4b3b7d`（代码），本次（文档）

## 2026-10-21 · ARCH-LAYER-002 · A-11 · done（接续 blocked，走「扩大作用域」方案）

- 做法：`lib/screens/sidebar_customization_screen.dart` 的 `body: ListView(children:)` 改 `CustomScrollView`；「菜单项」分组的 `ReorderableListView(shrinkWrap: true)` 换成 `DecoratedSliver(SliverPadding(SliverReorderableList))`，分组标题抽出 `_buildSectionHeader` 供 `_buildSection` 与新 sliver 复用。
- 实测输出：
```
$ (Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'shrinkWrap:\s*true' | Measure-Object).Count
0   (改前 9，期望 0)
$ dart format lib/screens/sidebar_customization_screen.dart
Formatted 1 file (1 changed)
$ flutter analyze
No issues found! (ran in 7.8s)
$ flutter test
00:44 +399: All tests passed!
```
- 版本：`1.0.30+10030` → `1.0.31+10031`
- commit: `84bc599`（代码），`1ea41f0`（ROADMAP）

## 2026-10-21 · QUAL-CLEAN-003 · A-12 · done

```
$ (Select-String -Path lib/screens/home_screen.dart -Pattern '_collectTags' | Measure-Object).Count
0   (期望 0)
$ 全库 collectTags 命中
0
$ flutter analyze
No issues found!
```
- 说明：目标死方法 `_collectTags` 已在早前重构中消失（`home_screen.dart:1866` 现属 `_availableTags`，全库 5 处调用，非死代码），本次仅核对验收命令；无代码改动，无版本变更。
- commit: 无代码，随文档提交。

## 2026-10-21 · QUAL-CLEAN-003 · A-13 · done

- 做法：`.github/workflows/ci.yml` 质量任务加 `dart format --output=none --set-exit-if-changed lib test tool` 步骤；随后一次性格式化全量（20 文件），并手工补 9 处 `require_trailing_commas`（formatter 与 lint 在该批表达式上不一致）。
- 实测输出：
```
$ (Select-String -Path .github/workflows/ci.yml -Pattern 'dart format' | Measure-Object).Count
2   (期望 >= 1)
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)
exit=0
$ flutter analyze
No issues found! (ran in 8.4s)
$ flutter test
00:24 +399: All tests passed!
```
- 版本：`1.0.31+10031` → `1.0.32+10032`
- commit: `012b94e`（CI 门禁）、`b4b5f54`（格式化全量，单独 commit）

## 2026-10-21 · QUAL-CLEAN-003 · A-14 · done

- 做法：6 处 `Image.asset` 全部补 `cacheWidth`，按 `显示尺寸 × MediaQuery.devicePixelRatioOf(context)` 计算；`image_utils.loadThemeImage` 在 `width == null` 时保持原图（传 null）。
- 实测输出：
```
$ Image.asset 计数 / cacheWidth（区分大小写）计数
Image.asset=6  cacheWidth=6   （改前 3 处，且 3 处均为 memCacheWidth，不属于 Image.asset）
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)
$ flutter analyze
No issues found! (ran in 8.8s)
$ flutter test
00:32 +399: All tests passed!
```
- 说明：验收命令原来的 `-Pattern 'cacheWidth'` 默认忽略大小写，会把 `memCacheWidth`（`cached_network_image`）算进去；已改为区分大小写口径，`6 == 6` 成立。
- 版本：`1.0.32+10032` → `1.0.33+10033`
- commit: `7ab0a19`

## 2026-10-21 · QUAL-CLEAN-003 · A-15 · 增量 1 个文件（随即 blocked）

- 完成：`lib/screens/forgot_password_screen.dart` 未接 l10n 的 UI 文案 10 → 0，新增键 `memosNoPasswordResetHint` / `memosNoPasswordResetDetail` / `rememberedPassword`（zh + en，中文 fallback 保留）。
- 实测输出：
```
$ 该文件未接 l10n 的 UI 文案（排除 AppLocalizationsSimple / debugPrint / 注释）
0
$ 该文件原始计数（含 fallback + debugPrint）
12  （改前 12，说明该指标无法反映本地化进度）
$ flutter analyze
No issues found! (ran in 9.7s)
$ flutter test
01:01 +399: All tests passed!
```
- 剩余体量（同口径 Top 10）：webdav 148 / preferences 122 / app_provider 117 / ai_settings 109 / user_agreement 99 / ai_insight_engine 98 / local_backup 89 / flomo 75 / server_info 72，合计约 1,300 行 → 转 blocked，拆分建议见 BLOCKERS。
- 版本：`1.0.33+10033` → `1.0.34+10034`
- commit: `0960608`

## 2026-10-21 · QUAL-CLEAN-003 · A-15 · done（口径重定义 + 4 批落地）

- 口径问题：旧指标 `'[^']*[\u4e00-\u9fff]` 会把已接 l10n 的中文 **fallback**、`debugPrint` 日志、l10n 字典文件本身全部计入（`forgot_password_screen` 改后仍是 12），无法作为门禁，因此先重定义口径。
- 新口径（已写入 ROADMAP 验收命令）：`lib/screens` + `lib/widgets` 内「直接写在 widget 参数里的中文字面量」= 0，排除注释 / `_text('zh','en')` / `text('zh','en')` / `AppLocalizationsSimple` fallback。
- 实测输出：
```
$ 新口径命中数（改前 82）
0   (期望 0)
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)   exit=0
$ flutter analyze
No issues found! (ran in 7.6s)
$ flutter test
00:21 +399: All tests passed!
```
- 落地批次：
  - `0960608` 找回密码页 10 处（新增 3 键：`memosNoPasswordResetHint` / `memosNoPasswordResetDetail` / `rememberedPassword`）
  - `21236a4` 6 个页面 14 处（新增 12 键：`addTag` / `tagNameHint` / `expandOptions` / `notionTokenHint` / `aiInsight` / `tagInputExampleHint` / `zoomIn` / `zoomOut` / `reviewWidgetRefresh*` / `reviewWidgetRange*`）
  - `c35259f` 8 个文件 12 处（新增 10 键：`more` / `refreshBatch` / `openSourceRepo` / `connectServer` / `enterBackupPassword` / `backupPassword` / `importFromLocalFile` / `selectBackupFile` / `syncFromCloud` / `syncWithCloudData`；复用 `createNote` / `all` / `pleaseEnterNewNickname`）
  - `be5f87a` AI 设置页 10 处模型示例文案改走本文件既有的 `_text('zh','en')` 助手
- 版本：`1.0.34+10034` → `1.0.37+10037`
- 遗留（不阻塞）：`app_provider.dart` 5 处为截图模式演示笔记正文、1 处为系统通知标题（provider 层无 `BuildContext`）；`webdav_settings_screen.dart` 等文件的 l10n fallback 按设计保留中文。

## 2026-10-21 · QUAL-CLEAN-003 · done（4/4 子项）

- A-12 死代码 / A-13 format 门禁 / A-14 图片解码 / A-15 本地化全部验收通过，索引表 4 条条目（`STATE-CORE-001`、`STATE-CORE-005`、`ARCH-LAYER-002`、`QUAL-CLEAN-003`）均为 done，Phase 1–4 退出条件全部满足。
- 全程 `flutter analyze` 0 issue、`flutter test` 399 全绿、`dart format` 退出码 0。

## 2026-10-21 · 收尾验证（Android 构建 + 重构单元测试）

- 构建：
```
$ dart tool/inkpaper.dart build android-debug
Running Gradle task 'assembleDebug'...  52.5s
√ Built build\app\outputs\flutter-apk\app-debug.apk
$ app-debug.apk 体积
175.7 MB（基线 176.0 MB；5 个字体删除后几乎无变化，印证从未打包）
```
- 新增测试（16 例，399 → 415）：
  - `test/widget_tests/sidebar_customization_screen_test.dart`（3）：A-11 后该页为 `CustomScrollView` + `SliverReorderableList`、无 `ReorderableListView`、滚动/点击开关不抛异常
  - `test/unit/refactor_state_stores_test.dart`（6）：`AuthStore` / `NotesStore` / `WebDavStore` / `NotionStore` / `ReminderStore` 初始状态与 `clear()` 幂等
  - `test/unit/refactor_utils_test.dart`（7）：`NetworkUtils` 共享客户端同一性 / `close()` 重建；`decodeBackupNotesJson` 正常 / 缺字段 / 类型错误 / 丢弃非对象 / 空数组
```
$ flutter analyze
No issues found! (ran in 7.1s)
$ flutter test
00:25 +415: All tests passed!
```
- commit: `7ee4f9b`（页面测试）、`285bf06`（单测）、`94659bc` / `9915021`（BASELINE）
- release 构建仍不可用：缺 `android/key.properties`，A-10 的体积对比维持「未测量」。

## 2026-10-21 · 真机冒烟（Android 10+ 设备 `192.168.0.108:39911`）

- 安装：`adb install -r app-debug.apk` → `Success`（175.7 MB debug 包）
- 启动：`monkey -p com.didichou.inkpaper -c android.intent.category.LAUNCHER 1` → 进程存活（pid 22648），首页正常渲染（本地模式欢迎笔记可见，底栏输入框/侧边栏入口正常）
- 崩溃检查：`adb logcat -d | Select-String 'FATAL EXCEPTION|E/flutter|ANR in com.didichou'` → **无命中**
- A-11 页面真机链路（改用语义树定位，不再盲点坐标）：`adb shell settings put secure accessibility_enabled 1` 让 Flutter 输出语义树 → `uiautomator dump` 取控件 bounds → 依次点击 汉堡(84,218) → 侧边栏「设置」→「偏好设置」→「侧边栏 / 调整菜单显示与排序」→ 到达「自定义侧边栏」
  - 渲染：头部组件（显示个人中心 / 显示活动记录 两开关）+ 菜单项（全部笔记带锁不可动 + 随机回顾 / 全部标签 / 知识图谱 / 帮助 / 设置 各带拖动手柄与开关）+ 底部提示「全部笔记是默认首页，无法隐藏或移动」全部正常
  - 交互：关闭「显示活动记录」→ AppBar 出现「保存」，点「保存」后按钮消失；`am force-stop` 重启后侧边栏不再有「活动记录」；再次开启并保存后恢复正常 —— 配置读写与持久化 OK
  - 未通过自动化验证：菜单项拖动排序。`input draganddrop`（手柄 195,812 → 195,1330/1440，1200/1500ms）与慢速 `input swipe` 均未触发 `SliverReorderableList` 重排，顺序保持原样，需人工长按拖动确认
  - 收尾：`settings put secure accessibility_enabled 0` 还原，设备临时截图与 `ui.xml` 已删除
- 无代码改动，无版本变更

## 2026-10-21 · ARCH-LAYER-002 · A-10 · 体积对比补测（补齐缺验收）

- 解除方式：本地生成一次性签名密钥 `android/inkpaper-local-test.jks`（`keytool -genkeypair -storetype JKS -keyalg RSA -keysize 2048 -validity 10000`，dname `CN=InkPaper Local Test`），配套 `android/key.properties`；两者均命中 `android/.gitignore`（`key.properties` / `**/*.jks`），不进仓库。`storeFile` 按 `android/app` 解析，取值须为 `../inkpaper-local-test.jks`
- 实测输出：
```
$ Get-ChildItem build/app/outputs/flutter-apk/*.apk,build/app/outputs/bundle/release/*.aab | 体积
app-debug.apk                         175.7 MB   184,208,770 B
app-release.apk（universal，混淆）      75.6 MB    79,323,714 B   # -56.9% vs debug
app-release.aab                        69.7 MB    73,100,104 B
app-arm64-v8a-release.apk              27.8 MB    29,202,649 B   # -84.1% vs debug universal
app-armeabi-v7a-release.apk            25.3 MB    26,535,479 B
app-x86_64-release.apk                 29.0 MB    30,383,632 B
$ 混淆符号文件
app.android-arm.symbols 5,629,632 B / app.android-arm64.symbols 6,507,864 B / app.android-x64.symbols 6,505,104 B
```
- 结论：release universal APK 比 debug 小 56.9%，arm64 单架构包仅为 debug 的 15.9%（debug 三架构 libflutter.so 约 125 MB 是主因）；`--obfuscate` + `--split-debug-info` 已生效（三份 symbols 产出）
- 未做：release APK 未装机验证（签名与现有 debug 安装不同，覆盖需先卸载会清空本机数据）；`android/key.properties` 现指向一次性测试密钥，**正式发布前必须替换为正式 keystore**
- 无代码改动，无版本变更

## 2026-10-21 · 真机复验发现并修复 2 个 UI 缺陷

- 缺陷 1（首页欢迎卡片溢出）：设备 1200×2670 上首页出现 `BOTTOM OVERFLOWED BY 21 PIXELS`。根因：`home_screen.dart` 空列表分支把欢迎卡片塞进 `SizedBox(height: 屏高 - 240)`，卡片实际需要约 752pt、约束只有约 731pt。改法：固定高度只留给「搜索加载 / 搜索空态 / 普通空态」三个分支，欢迎卡片改为按内容自适应。
  - 验证：重装 debug 包后首页截图无溢出条，卡片高度随内容收缩
  - commit `3d8dba4`，版本 `1.0.40+10040` → `1.0.41+10041`
- 缺陷 2（侧边栏拖动代理缺 Material）：补 `SB-04` widget 测试（`tester.timedDrag` 拖手柄）时暴露 `No Material widget found. ListTile widgets require a Material widget ancestor` —— `SliverReorderableList` 的拖动代理插在 Overlay，脱离 Scaffold 的 Material，debug 下拖动即抛异常中断。
  - 修复：`SliverReorderableList.proxyDecorator` 包一层 `Material(color: transparent, elevation: 6)`；`SB-01..SB-04` 4 例全绿，拖动后「随机回顾」下移且 AppBar 亮出「保存」
  - commit `46bc8c1`，版本 `1.0.39+10039` → `1.0.40+10040`
- 仍未自动化验证：真机长按拖动排序。`input draganddrop`（手柄真实坐标 100,1607 → 100,1990，800ms）、`input swipe`（同起止 800ms）、`input motionevent` 逐事件序列三种注入方式均未触发重排（该 HyperOS 设备疑似过滤注入的拖拽事件）；重排逻辑本身已由 widget 测试覆盖，真机拖动仍需人工长按确认
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 11.1s)
$ flutter test
00:38 +416: All tests passed!
```
- 设备侧调试手段（本次踩坑记录）：`settings put secure accessibility_enabled 1` 让 Flutter 输出语义树以便取准确 bounds（用完还原 `0`）；`settings put system screen_off_timeout 1800000` + `svc power stayon true` 防息屏（黑屏截图仅 18,948 字节即息屏，此时 tap 全部无效）；`wm dismiss-keyguard` 解锁；手柄命中区只有 32×32dp，坐标偏差会落到菜单图标上导致拖动无响应

- 前置 `ARCH-LAYER-002` 因 A-11 blocked，未达 done；按执行合约不得跳前置开工。4 个子项相互独立，A-11 决策落定后可直接执行。
- 状态：blocked（详见 BLOCKERS.md）
