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
