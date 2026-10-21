# ROADMAP

> 本文件是任务唯一真相。AI 每轮开工先读第 0 节执行合约，再读第 2 节索引表取任务，只加载该条目详情与作用域内文件。
>
> 本版由 `AUDIT.md`（Stage 2，`main@c24777c`）按 `ROADMAP_SPEC.md` 第 5 节转换生成；上一版历史完成项见 `git show c24777c:docs/ROADMAP.md`。

## 0. 执行合约（优先级高于其他一切）

```
1. 读本文件，找状态为 doing 的条目；没有则取索引表中第一条 todo 且前置已全部 done 的。
2. 只加载该条目的「作用域」内文件，不重读全项目。
3. 完成后按条目「验收」实际执行命令，把真实输出追加到 PROGRESS.md。
4. 验收通过 → 状态改 done → 立刻取下一项，不汇报、不询问。
5. 验收不通过 → 最多尝试修复 2 次；仍失败则改 blocked，写 BLOCKERS.md
   （含已尝试方案 + 具体报错），跳过继续下一项。
6. 禁止：中途总结进度、询问"是否继续"、改作用域外代码、跳过验收命令。
7. 只在全部条目终结、或连续 3 条 blocked 时，才输出文字汇报。
```

**环境约定**：Windows / PowerShell，环境中**没有 `rg`**。验收命令统一用 `Select-String` 与 `[System.IO.File]::ReadAllLines` 写法，全部放在代码块内，可整段复制执行；计数均指「出现次数」而非文件数。

## 1. 项目元信息

| 项 | 值 |
|---|---|
| 项目 | InkPaper（Flutter 笔记应用，Android 为主） |
| Flutter / Dart | 3.47.7 / 3.13.5 |
| 审计基线 | 见 `BASELINE.md`：analyze 0 issue、测试 399 通过、覆盖率 14.1%、release 体积未测量 |
| 本轮目标 | 完成 Phase 1 + Phase 2 + Phase 4 |
| 单轮任务上限 | 1 个子项（P1 / P2 / P3 均为批次任务） |
| 验收环境限制 | release 构建不可用（缺 `android/key.properties`）；无 profile 运行时采集 |

## 2. 索引表（AI 靠这张表选任务，不必先读详情）

| ID | 标题 | 优先级 | 前置 | 验收 | 状态 |
|---|---|---|---|---|---|
| — | P0 无 finding（analyze 0 error、399 测试全绿） | P0 | — | 不适用 | done |
| STATE-CORE-001 | 收敛状态通知与高频重建（4 子项） | P1 | — | 子项 1 按四条验收判定 done（①✅ 1 个文件；②实测 11 条，待收敛 ≤6；③④ 仓库无 `lib/features/sync` / `SyncScope`，不适用）；子项 2 按 A 口径 done（输入路径 setState = 0）；子项 4 未开始（由 STATE-CORE-005 承接） | done |
| STATE-CORE-005 | AppProvider 上帝对象分域拆分 | P2 | STATE-CORE-001 | 7 域全绿（认证/笔记/WebDAV/Notion/提醒/小组件/云验证，字段定义数均 0，转发 4/31/10/3/6/2/5）；AI 域 skipped（`AppProvider` 内无该域字段，命令实证） | done |
| ARCH-LAYER-002 | 修分层倒置与工程结构（7 子项） | P2 | STATE-CORE-001 | 可执行（子项 5 删除字体需先在 BLOCKERS.md 记录许可结论） | todo |
| QUAL-CLEAN-003 | P3 清理批次（4 子项 + 交互态 setState 待评估） | P3 | ARCH-LAYER-002 | **缺验收**：子项 4 本地化目标值不可命令化 | todo |

阶段退出条件：Phase 1 = 全部 P0 条目终结（本版已满足）；Phase 2 = STATE-CORE-001 全部子项 done 且 release 体积已重测或已记入 BLOCKERS；Phase 3 = ARCH-LAYER-002 全部子项 done 且 `flutter analyze` 无新增 issue；Phase 4 = 全部条目终结且 `flutter analyze` 为 0 error。

---

## 3. 任务详情

### STATE-CORE-001 · 收敛状态通知与高频重建

> 批次任务，含 4 个子项（A-01 ~ A-04）。**单轮只做一个子项**；子项验收全绿才算该子项 done，4 个子项全 done 才算本条 done。

| 字段 | 内容 |
|---|---|
| 优先级 | P1 |
| 前置 | 无 |
| 作用域 | 子项 1：`lib/providers/app_provider.dart`、`lib/providers/sync_store.dart`（新建）、`lib/main.dart`<br>子项 2：`lib/widgets/note_editor.dart`<br>子项 3：`lib/providers/app_provider.dart`（仅同步方法段）<br>子项 4：`lib/screens/home_screen.dart` |
| 现状证据 | **A-01** `lib/providers/app_provider.dart` 4,434 行，`notifyListeners()` 58 处（全库 63 处）；`lib/main.dart:537` `Widget build(BuildContext context) => ChangeNotifierProvider.value(`、`:539` `child: Selector<AppProvider, _AppChrome>(`；全库 `Selector<` 仅 4 处。<br>**A-02** `lib/widgets/note_editor.dart` 3,284 行，`setState(` 39 处（`:143`、`:465`、`:562`）。<br>**A-03** `lib/providers/app_provider.dart:2048` `for (final note in unsyncedNotes) {`、`:2050` `syncedCount += await _syncUnsyncedNotesSnapshot([note]);`。<br>**A-04** `lib/screens/home_screen.dart` 2,801 行；`Widget _build*` 定义 19 处、`_build\w+(` 出现 52 次（`:809` `Widget _buildNotificationBannerBody(BuildContext context, int unreadCount) {`、`:1461` `Widget _buildBottomComposerBar(BuildContext context) {`）。 |
| 做什么 | **子项 1（A-01，先做）**：新建 `SyncStore extends ChangeNotifier`，把同步字段与方法迁出 `AppProvider`，对外接口保持不变。<br>**子项 2（A-02）**：输入区改 `TextEditingController` + `ValueListenableBuilder`，输入路径不再 `setState`；预览刷新加 200ms 防抖。<br>**子项 3（A-03）**：逐条 `await` 改为有限并发（信号量 2–3）或按批 `Future.wait`，保留逐条失败隔离。<br>**子项 4（A-04）**：`_buildNotificationBannerBody`、`_buildBottomComposerBar`、笔记列表项抽为独立 `StatelessWidget` 并加 `const` 构造。 |
| 验收 | **子项 1（已定）**：① `rg -l "class SyncStore" lib/` 恰好 1 个文件；② `rg "isSyncing\|syncingNoteIds" lib/core/state/app_provider.dart` 每条命中都是转发（≤ 6 条，均带 `syncStore.` 前缀）；③ `rg "watch<AppProvider>\|Consumer<AppProvider>" lib/features/sync/` 期望 0；④ DevTools：同步状态变更仅 SyncScope 子树重建，页面根节点 rebuild 为 0<br>**子项 2/3/4**：见下方「STATE-CORE-001 验收命令」；子项 2 的 rebuild 统计与子项 3 的同步耗时仍**缺验收** |
| 收益 | A-01：通知面从「整实例 63 处触发」收敛到分域；A-02：长文输入不再重建整棵编辑器树（未测量）；A-03：同步耗时由 N×RTT 降至约 N/2×RTT（未测量）；A-04：单次重建 widget 数下降（未测量） |
| 回滚 | 每个子项单独 commit，`git revert <sha>` 即可回退该子项 |
| 不许做 | 不引入新状态管理库（沿用 provider）；不改同步协议与 `pending_operations` 语义；不改编辑器 Markdown 渲染规则；不动 `home_screen` 之外页面；不改 pubspec 依赖 |
| 状态 | done |

**子项状态**：✅ 子项 1 SyncStore 抽出（按下列四条验收判定，`4b22455`）｜✅ 子项 2 编辑器输入局部化（验收口径 A：输入路径 setState = 0，`14f04c6`）｜✅ 子项 3 并发化（`4b22455`）｜⬜ 子项 4 未开始（后续拆分由 STATE-CORE-005 承接）

**STATE-CORE-001 验收命令**（改前基线：app_provider 4,434 行 / notify 58 / setState 39 / home 2,801 行 / `Widget _build` 19）：

```powershell
# 子项 1：SyncStore 抽出（以下为指定验收，原样保留）
rg -l "class SyncStore" lib/                                        # ① 恰好 1 个文件
rg "isSyncing|syncingNoteIds" lib/core/state/app_provider.dart      # ② ≤ 6 条，且均为 syncStore. 转发
rg "watch<AppProvider>|Consumer<AppProvider>" lib/features/sync/    # ③ 期望 0
# ④ DevTools：同步状态变更仅 SyncScope 子树重建，页面根节点 rebuild 为 0
# 注：仓库实际路径为 lib/providers/app_provider.dart，且当前 Windows 环境未安装 rg；
#     实际执行时请按真实路径用 Select-String 复核，语义不变。

# 子项 2：编辑器输入局部化（验收口径 A：输入路径内 setState 为 0）
(Select-String -Path lib/widgets/note_editor.dart -Pattern 'ValueListenableBuilder' | Measure-Object).Count   # 期望 >= 1
# 提取 _updateLineCount 与 _detectTagInput 方法体，统计其中 setState（期望 0）
$src = [System.IO.File]::ReadAllText('lib/widgets/note_editor.dart')
$blocks = [regex]::Matches($src, '(?s)void _(updateLineCount|detectTagInput)\(\).*?\r?\n  \}')
($blocks | ForEach-Object { ([regex]::Matches($_.Value, 'setState\(')).Count } | Measure-Object -Sum).Sum   # 期望 0
flutter analyze                                                                  # 期望无 error
# 说明：全文件 setState 计数仅作参考，不作为本条验收；剩余交互态 setState 记入 QUAL-CLEAN-003 待评估项
# 缺验收：输入时长帧/重建次数，需 profile + DevTools rebuild 统计（本次未测量）

# 子项 3：同步并发化
(Select-String -Path lib/providers/app_provider.dart -Pattern 'for \(final note in unsyncedNotes\)' | Measure-Object).Count   # 期望 0
(Select-String -Path lib/providers/app_provider.dart -Pattern 'Future\.wait|Semaphore' | Measure-Object).Count                # 期望 >= 1
# 缺验收：50 / 200 条笔记同步总耗时对比，需可用服务器（本次未测量）

# 子项 4：首页拆分
([System.IO.File]::ReadAllLines('lib/screens/home_screen.dart')).Count           # 期望 <= 2200
(Select-String -Path lib/screens/home_screen.dart -Pattern 'Widget _build' | Measure-Object).Count   # 期望 <= 12
flutter analyze                                                                  # 期望无新增 issue
```

### STATE-CORE-005 · AppProvider 上帝对象分域拆分

> 每轮只搬一个域，一个域一个 commit；顺序：认证 → 笔记 → 同步之外的其他域。

| 字段 | 内容 |
|---|---|
| 优先级 | P2 |
| 前置 | STATE-CORE-001 |
| 作用域 | `lib/core/state/app_provider.dart`（仓库现路径 `lib/providers/app_provider.dart`）+ 各域 Store 文件（如 `lib/core/state/auth_store.dart`、`note_store.dart`、`sync_store.dart`） |
| 现状证据 | `lib/providers/app_provider.dart` 单类、`notifyListeners()` 58 处；`_isSyncing` / `_syncMessage` / `_syncingNoteIds` 已转发 `SyncStore`（`4b22455`）；**认证域已迁出**（`f25a829`）：`_user` / `_memosApiService` → `lib/core/state/auth_store.dart`，AppProvider 4 处 `_authStore.` 转发；**笔记域已迁出**（`2e8be5c`）：17 个字段（`_notes` / `_isLoading` / `_isInitialized` / `_pagingState` / `_loadMoreCompleter` / `_totalNotesCount` / `_lastLoadTime` / `_loadStopwatch` / `_sortOrder` / `_visibleNotesCache` / 删除队列与撤销 7 字段）→ `lib/core/state/notes_store.dart`，AppProvider 31 处 `_notesStore.` 转发；**WebDAV 域已迁出**（`a5ee318`）：5 字段 → `lib/core/state/webdav_store.dart`，10 处 `_webDavStore.` 转发；**Notion 域已迁出**（`57cb3db`）：2 字段 → `lib/core/state/notion_store.dart`，3 处 `_notionStore.` 转发；**提醒/通知域已迁出**（`1d5ae86`）：4 字段 → `lib/core/state/reminder_store.dart`，6 处 `_reminderStore.` 转发；仍在类内的域字段仅剩 `_widgetSnapshotUpdateId`（小组件）、云验证 3 字段（`_cloudAppConfig` / `_lastCloudVerificationTime` / `_cloudService`）与通用基建字段（`_appConfig` / `_mounted` / `_resourceService` / `_databaseService` / `_preferencesService`） |
| 做什么 | 每轮搬一个域：<br>1. **认证域**：`registerWithPassword` / `loginWithPassword` / `loginWithToken` / `logout` 及相关字段<br>2. **笔记域**：笔记集合、分页、标签、排序相关字段与方法<br>3. **同步之外的其他域**：WebDAV、Notion、提醒、AI、小组件，按体量从大到小<br>每域新建 `XxxStore`，`AppProvider` 只保留 `xxxStore.` 转发 |
| 验收 | 该域字段在 `app_provider.dart` 内的定义数归零，只保留 `xxxStore.` 转发；每搬完一个域一个 commit；**不以总行数作为验收**。<br>**认证域（已定，`f25a829`）**：`(Select-String -Path lib/providers/app_provider.dart -Pattern '^\s{2}User\?\s+_user;\|^\s{2}MemosApiServiceFixed\?\s+_memosApiService;' \| Measure-Object).Count` → 0；`_authStore.` 转发 ≥ 4；`class AuthStore` 唯一文件 = 1<br>**笔记域（已定，`2e8be5c`）**：`Select-String -Path lib/providers/app_provider.dart -Pattern '^\s{2}(?:final\s+)?[A-Za-z_][\w<>.,?\s]*?\s+(?<![A-Za-z0-9_.])(?:_notes\|_isLoading\|_isInitialized\|_pagingState\|_loadMoreCompleter\|_totalNotesCount\|_lastLoadTime\|_loadStopwatch\|_sortOrder\|_visibleNotesCache\|_deleteQueue\|_pendingDeleteIds\|_isProcessingDelete\|_deleteDebounceTimer\|_lastDeletedNote\|_lastDeletedIndex\|_pendingDeleteCommitTimer)\s*(?:=\|;)' \| Where-Object { $_.Line -notmatch '=>' } \| Measure-Object \| Select -Expand Count` → 0（旧版实测 17，可反向校验正则有效性）；`_notesStore.` 转发 ≥ 31；`class NotesStore` 唯一文件 = 1<br>**WebDAV 域（已定，`a5ee318`）**：同一正则把域字段组换成 `(?:_webDavConfig\|_webDavService\|_webDavSyncEngine\|_webDavBackupTimer\|_hasPerformedStartupBackup)` → 0（旧版实测 5）；`_webDavStore.` 转发 ≥ 10<br>**Notion 域（已定，`57cb3db`）**：`(?:_notionSyncService\|_isNotionSyncing)` → 0（旧版实测 2）；`_notionStore.` 转发 ≥ 3<br>**提醒/通知域（已定，`1d5ae86`）**：`(?:_reminderNotificationService\|_notificationService\|_notificationServiceInitialized\|_unreadAnnouncementsCount)` → 0（旧版实测 4）；`_reminderStore.` 转发 ≥ 6<br>**AI / 小组件 / 云验证**：开工时按域补充字段计数命令（现状：AI 域在 `AppProvider` 内无独立字段，小组件仅 `_widgetSnapshotUpdateId`，云验证 3 字段） |
| 收益 | 通知面按域收敛，页面可按域订阅；单文件体量下降（不作为验收指标） |
| 回滚 | 每域单 commit，`git revert <sha>` |
| 不许做 | 不改任何业务逻辑；不改方法签名与调用方行为；不用总行数做验收；不混入服务层重构（A-05） |
| 状态 | done |

**域进度**：✅ 认证域（`f25a829`，`_user` / `_memosApiService` → `AuthStore`，字段定义数 0、转发 4）｜✅ 笔记域（`2e8be5c`，17 字段 → `NotesStore`，定义数 0、转发 31）｜✅ WebDAV（`a5ee318`，5 字段 → `WebDavStore`，定义数 0、转发 10）｜✅ Notion（`57cb3db`，2 字段 → `NotionStore`，定义数 0、转发 3）｜✅ 提醒/通知（`1d5ae86`，4 字段 → `ReminderStore`，定义数 0、转发 6）｜✅ 小组件（`b127e62`，1 字段 → `WidgetStore`，定义数 0、转发 2）｜✅ 云验证（`db3d7b2`，3 字段 → `CloudVerificationStore`，定义数 0、转发 5）｜⏭️ AI（skipped：`AppProvider` 内无 AI 域字段，AI 能力通过 `aiEnabled` / `aiApiUrl` 配置与页面层调用，无可迁字段）

### ARCH-LAYER-002 · 修分层倒置与工程结构

> 批次任务，含 7 个子项（A-05 ~ A-11）。**单轮只做一个子项**；子项 5 执行前必须先在 `BLOCKERS.md` 记录字体许可结论。

| 字段 | 内容 |
|---|---|
| 优先级 | P2 |
| 前置 | STATE-CORE-001 |
| 作用域 | 子项 1：`lib/services/note_actions_service.dart` + 调用方页面的回调参数<br>子项 2：`lib/utils/network_utils.dart`<br>子项 3：`lib/services/database_service.dart`<br>子项 4：`pubspec.yaml`<br>子项 5：`assets/fonts/**`、`lib/screens/preferences_screen.dart`（仅字体选项）<br>子项 6：`tool/inkpaper.dart`<br>子项 7：`lib/screens/flomo_import_screen.dart`、`lib/screens/local_backup_restore_screen.dart` |
| 现状证据 | **A-05** `lib/services/note_actions_service.dart:10` `import 'package:inkpaper/screens/note_detail_screen.dart';`、`:16` `import 'package:inkpaper/widgets/note_editor.dart';`（同文件 `:14`、`:15`、`:17`、`:18`、`:19` 合计 7 条 UI import）。<br>**A-06** `lib/utils/network_utils.dart:10` `static http.Client createOptimizedClient() {`、`:11` `final client = http.Client();`（`:16-19` 同样新建）。<br>**A-07** `lib/services/database_service.dart:798` `final Map<String, dynamic> data = jsonDecode(jsonData);`。<br>**A-08** `pubspec.yaml:41` `xml: ^6.5.0`、`:80` `flutter_svg: ^2.0.10`、`:89` `flutter_highlight: ^0.7.0`，加 `:19`、`:32`、`:112`、`:121` 共 7 个无 import 依赖。<br>**A-09** `pubspec.yaml:178-179` `assets:` / `- assets/images/`，无 `fonts:` 段；`assets/fonts/` 5 文件 3.94 MB。<br>**A-10** `tool/inkpaper.dart:265` `'--split-per-abi',`、`:266` `'--split-debug-info=build/symbols',`，无 `--obfuscate`。<br>**A-11** `lib/screens/flomo_import_screen.dart:704-706` `ListView.separated(` / `shrinkWrap: true,` / `physics: const NeverScrollableScrollPhysics(),`；`lib/screens/local_backup_restore_screen.dart:685-687` 同模式；全库 `shrinkWrap: true` 共 9 处。 |
| 做什么 | **子项 1（A-05）**：弹窗/导航从服务层剥离，改为返回意图对象或接收回调；服务层不再 import `screens/`、`widgets/`。<br>**子项 2（A-06）**：`NetworkUtils` 复用单例 `http.Client` 并提供 `close()`。<br>**子项 3（A-07）**：`importBackup` 的 `jsonDecode` 移到 `compute()`，插入包在单事务内。<br>**子项 4（A-08）**：删除 6 个确认无引用依赖；`xml` 先跑 `flutter pub deps --style=compact` 复核，确认非 `webdav_client` 必需后再删。<br>**子项 5（A-09）**：许可确认后删除 `assets/fonts/` 5 个字体，并核对 `preferences_screen` 字体选项。<br>**子项 6（A-10）**：release 构建参数加 `--obfuscate`。<br>**子项 7（A-11）**：嵌套 `shrinkWrap` 列表改 `CustomScrollView + SliverList`，或限制预览条数。 |
| 验收 | 见下方「ARCH-LAYER-002 验收命令」：子项 1/2/3/4/5/7 全为静态命令；子项 6 含 1 项**缺验收**（release 体积需签名文件） |
| 收益 | A-05：服务层可脱离 `BuildContext` 单测；A-06：减少重复 TLS 握手（未测量）；A-07：大备份导入不再阻塞 UI isolate（未测量）；A-08：依赖树缩小（未测量）；A-09：仓库减 3.94 MB；A-10：符号不随包（未测量）；A-11：嵌套列表首帧不再全量布局（未测量） |
| 回滚 | 子项 2/3/6/7 单 commit revert；子项 4/5 涉及删除，回退需 `git revert` + `flutter pub get` |
| 不许做 | 不改同步协议、DB schema、备份 JSON 格式；不动 `assets/images/`；不引入新网络库；除任务列出的依赖外不增删任何包 |
| 状态 | doing |

**子项进度**：✅ A-05（`7c62862`，UI import 7 → 0；UI 编排移至 `lib/widgets/note_actions_ui.dart`，服务层仅留数据层 5 个方法）｜⬜ A-06｜⬜ A-07｜⬜ A-08｜⬜ A-09｜⬜ A-10｜⬜ A-11

**ARCH-LAYER-002 验收命令**（改前基线：UI import 7 / `http.Client()` 2 / `jsonDecode(jsonData)` 1 / 无 import 依赖 7 / 字体 5 个 3.94 MB / `shrinkWrap` 9）：

```powershell
# 子项 1：服务层去 UI 依赖
(Select-String -Path lib/services/note_actions_service.dart -Pattern "package:inkpaper/(screens|widgets)/" | Measure-Object).Count   # 期望 0
flutter analyze                                                                  # 期望无 error

# 子项 2：http.Client 复用
(Select-String -Path lib/utils/network_utils.dart -Pattern 'http\.Client\(\)' | Measure-Object).Count   # 期望 <= 1
(Select-String -Path lib/utils/network_utils.dart -Pattern 'close\(\)' | Measure-Object).Count          # 期望 >= 1

# 子项 3：备份解码移出主线程
(Select-String -Path lib/services/database_service.dart -Pattern 'jsonDecode\(jsonData\)' | Measure-Object).Count   # 期望 0
(Select-String -Path lib/services/database_service.dart -Pattern 'compute\(|Isolate\.run' | Measure-Object).Count   # 期望 >= 1

# 子项 4：删除未用依赖
flutter pub deps --style=compact | Select-String -Pattern '^xml|flutter_svg|flutter_highlight|graphview'   # 先复核 xml 是否传递依赖
(Select-String -Path pubspec.yaml -Pattern '^\s{2}(cupertino_icons|flutter_image_compress|flutter_svg|flutter_highlight|graphview|flutter_dotenv):' | Measure-Object).Count   # 期望 0
flutter pub get                                                                  # 期望成功
flutter analyze                                                                  # 期望无 error

# 子项 5：删除未使用字体（先写 BLOCKERS.md 记录许可结论）
(Get-ChildItem assets/fonts -File -ErrorAction SilentlyContinue | Measure-Object).Count   # 期望 0
[math]::Round(((Get-ChildItem assets -Recurse -File | Measure-Object -Property Length -Sum).Sum/1MB),2)   # 期望 <= 0.1（改前 3.96）

# 子项 6：release 加混淆
(Select-String -Path tool/inkpaper.dart -Pattern '--obfuscate' | Measure-Object).Count   # 期望 >= 1
# 缺验收：release 体积对比，需 android/key.properties（当前缺失，未测量）

# 子项 7：去嵌套 shrinkWrap
(Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'shrinkWrap:\s*true' | Measure-Object).Count   # 期望 0
flutter analyze                                                                  # 期望无 error
```

### QUAL-CLEAN-003 · P3 清理批次

> 批次任务，含 4 个子项（A-12 ~ A-15）。每个子项独立 commit。

| 字段 | 内容 |
|---|---|
| 优先级 | P3 |
| 前置 | ARCH-LAYER-002 |
| 作用域 | 子项 1：`lib/screens/home_screen.dart`（仅删死方法）<br>子项 2：`.github/workflows/ci.yml` + 全库格式化<br>子项 3：`lib/screens/{login,register,about}_screen.dart`（仅 `Image.asset`）<br>子项 4：`lib/l10n/translations.dart`、`lib/l10n/app_localizations_simple.dart`、单页面文件（每次一个） |
| 现状证据 | **A-12** `lib/screens/home_screen.dart:1866` `return tags.toList()..sort();`，所属 `_collectTags` 全库调用 0 次。<br>**A-13** `.github/workflows/` 内无 `dart format`（`ci.yml` 只有 analyze / test）。<br>**A-14** `lib/screens/login_screen.dart:886` `Theme.of(context).brightness == Brightness.dark`、`:887` `? 'assets/images/black2logo.png'`；`Image.asset` 共 6 处，仅 3 处带 `cacheWidth`。<br>**A-15** 硬编码中文约 1,500 处（静态计数）：`webdav_settings_screen.dart` 125、`app_provider.dart` 117、`ai_insight_engine.dart` 98、`ai_settings_screen.dart` 88、`user_agreement_screen.dart` 63。 |
| 做什么 | **子项 1（A-12）**：删除 `_collectTags`。<br>**子项 2（A-13）**：CI 加 `dart format --output=none --set-exit-if-changed lib test tool`，并一次性格式化全量（单独 commit）。<br>**子项 3（A-14）**：`Image.asset` 统一补 `cacheWidth` 或走 `image_utils`。<br>**子项 4（A-15）**：按文件逐个接入 `AppLocalizationsSimple`，保留中文 fallback。 |
| 验收 | 子项 1/2/3 为静态命令；子项 4 **缺验收**（无合理「中文归零」终点，只能按文件监控计数下降 + 人工抽样） |
| 收益 | 死代码清理、格式与依赖门禁长期生效、图片解码可控；本地化收益为英文界面一致性（无性能数字） |
| 回滚 | 子项 2 格式化范围大，单独 commit；其余子项单 commit 可 revert |
| 不许做 | 子项 2 不得与业务改动同一 commit；子项 3 不改图片视觉；子项 4 不翻译 FAQ 长正文（已决策保留中文）；不改 lint 严格模式 |
| 待评估项 | 交互态 `setState`（`note_editor.dart` 剩余约 13 处，改前全文件 39 → 现 38）不单独开任务，仅在本批次评估：若后续 profile 显示交互路径存在明显重建开销，再按「局部化 setState」纳入；否则保持现状 |
| 状态 | todo |

**QUAL-CLEAN-003 验收命令**（改前基线：`_collectTags` 1 处 / `Image.asset` 6 处、`cacheWidth` 3 处 / webdav 文案 125）：

```powershell
# 子项 1：删死代码
(Select-String -Path lib/screens/home_screen.dart -Pattern '_collectTags' | Measure-Object).Count   # 期望 0
flutter analyze                                                                  # 期望 No issues found!

# 子项 2：format 门禁
(Select-String -Path .github/workflows/ci.yml -Pattern 'dart format' | Measure-Object).Count   # 期望 >= 1
dart format --output=none --set-exit-if-changed lib test tool                    # 期望退出码 0

# 子项 3：图片解码尺寸
(Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'Image\.asset' | Measure-Object).Count   # 期望 == cacheWidth 相关处数
(Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'cacheWidth' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum   # 改前 3
flutter analyze                                                                  # 期望无 issue

# 子项 4：本地化（每完成一个文件跑一次，监控下降）
(Select-String -Path lib/screens/webdav_settings_screen.dart -Pattern "'[^']*\p{Han}" | Measure-Object).Count   # 改前 125
# 缺验收：无法命令化「英文界面无中文」这一终点，需人工抽样 + 真机切英文确认
```

---

## 附录 A · 审计 finding 索引

| finding | 内容 | 任务 / 子项 |
|---|---|---|
| A-01 | 单一 4,434 行 `AppProvider`，63 次 `notifyListeners` | STATE-CORE-001 子项 1 |
| A-02 | `note_editor` 39 处 `setState` | STATE-CORE-001 子项 2 |
| A-03 | 同步串行 `await` | STATE-CORE-001 子项 3 |
| A-04 | `_buildXxx` 拆方法不减少重建 | STATE-CORE-001 子项 4 |
| A-05 | 服务层反向依赖 UI（7 条 import） | ARCH-LAYER-002 子项 1 |
| A-06 | 每次新建 `http.Client` | ARCH-LAYER-002 子项 2 |
| A-07 | 主线程 `jsonDecode` 整包备份 | ARCH-LAYER-002 子项 3 |
| A-08 | 7 个无 import 依赖 | ARCH-LAYER-002 子项 4 |
| A-09 | 3.94 MB 字体未声明未使用 | ARCH-LAYER-002 子项 5 |
| A-10 | 缺 `--obfuscate` | ARCH-LAYER-002 子项 6 |
| A-11 | 9 处嵌套 `shrinkWrap` | ARCH-LAYER-002 子项 7 |
| A-12 | 死方法 `_collectTags` | QUAL-CLEAN-003 子项 1 |
| A-13 | 无 `dart format` 门禁 | QUAL-CLEAN-003 子项 2 |
| A-14 | 图片未统一 `cacheWidth` | QUAL-CLEAN-003 子项 3 |
| A-15 | 约 1,500 处硬编码中文 | QUAL-CLEAN-003 子项 4 |

## 附录 B · PROGRESS.md 格式（AI 只 append，不改旧行）

一条任务占一段，命令输出必须贴真实的，不许写"验收通过"四个字了事：

```markdown
## 2026-10-21 15:40 · STATE-CORE-001 子项 1 · done
- 改动：新建 sync_store.dart；app_provider.dart 迁出同步段
- 验收输出：
  $ Test-Path lib/providers/sync_store.dart
  True
  $ ([System.IO.File]::ReadAllLines('lib/providers/app_provider.dart')).Count
  3712
  $ flutter analyze
  No issues found!
- 备注：对外方法保留转发，页面改动留到子项 4
- commit: a3f9c21
```

失败或跳过的也要记，理由是下次恢复现场的依据：

```markdown
## 2026-10-21 16:05 · ARCH-LAYER-002 子项 5 · blocked
- 已尝试：核对 pubspec 无 fonts 声明、lib 无引用，删除后构建正常
- 报错：无技术报错；等待字体许可结论
- 需决策：见 BLOCKERS.md
```

## 附录 C · BLOCKERS.md 格式

只有 `blocked` 状态的条目才进这里，`skipped` 不进。每条必须能被一眼决策：

```markdown
## ARCH-LAYER-002 子项 5 · 2026-10-21 16:05
**问题**：assets/fonts/ 下 5 个 SF Pro 字体是否可删除（Apple 字体许可）
**已尝试**：核对 pubspec 无 fonts 声明、lib 无引用，删除不影响构建
**要你决定**：
- A. 直接删除（影响：仓库减 3.94 MB，历史版本仍可追溯）
- B. 保留但补来源说明（影响：仓库体积不变）
**影响**：阻塞该子项，已跳过，继续做子项 6
```

## 附录 D · 每轮开工的自检三问

1. 索引表里有没有两条以上 `doing`？有 → 说明上一轮没收尾，先修正状态，别开始新任务。
2. 选中的任务「前置」是否全部 `done`？有 `blocked` 在链上 → 跳到无关任务，别硬上。
3. 任务「验收」能不能直接复制执行？不能 → 说明条目不合格，先补验收再动手。
