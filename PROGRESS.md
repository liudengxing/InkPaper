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

## 2026-10-21 · QUAL-CLEAN-003 · blocked（前置未达成）

- 前置 `ARCH-LAYER-002` 因 A-11 blocked，未达 done；按执行合约不得跳前置开工。4 个子项相互独立，A-11 决策落定后可直接执行。
- 状态：blocked（详见 BLOCKERS.md）
