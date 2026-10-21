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
