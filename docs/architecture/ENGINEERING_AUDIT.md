# InkPaper 工程优化审查

审查日期 2026-11-23。初始代码基线 `89e2728`，应用版本 `1.1.143+10243`。本文基于源码静态审查，覆盖 Flutter 首页、启动、笔记存储、同步、搜索、离线探索、媒体缓存、导入导出和 Android 桥接。每轮执行以当前工作区为准，性能收益待真机校准。

## 交接卡片

新会话先读本节，再按[执行队列](#执行队列)领取任务。本节每轮**整块覆盖**，只描述当下状态；逐轮历史见下文「推进记录」，取舍细节见对应记录条目。

| 项目 | 当前状态 |
| --- | --- |
| 最后更新 | 2026-11-23 · 代码提交 `34c7360`，记录随本笔 · 应用版本 `1.1.143+10243`（未升版本、未推送、未装机） |
| 本轮任务 | OPT-04B（P3 · §4 小组件统计行） |
| 任务状态 | 待验收 |
| 可复查改动 | ① 新增 `lib/models/widget_stat_note.dart`：统计行走它，时间只留 ISO 字符串（日期键取前 10 位、排序直接比串、`createdAt` 惰性解析并缓存）；② `getWidgetStatNotes()` 返回统计行，整库这一趟不再构造任何本地 `DateTime`；③ `RandomReviewSelectorService.selectWidgetCandidatesFrom` 抽出通用核心（自然日 + 回调控件），`Note` 与统计行共用一套兜底；④ `TodoParser.countTodos` 不再构造 `TodoItem`（正则提到类级、无 `[` 早退） |
| 验证结果 | `dart analyze lib test` 无 issue；`dart tool/inkpaper.dart format` 318 文件 0 changed；`flutter test --concurrency=4` 全量 **1099 项全过**（原 1096 + 3）。本机内存库校准（1500 条 / 每条约 20 行）：整库读取 242ms → **14~16ms**，整库构建 284~294ms → **约 53ms**；惰性解析 16 次/构建（原 4500 次）。反向验证两项：改回 `Note.fromMap` → WSR-06 实测 900 次解析变红；日期键改回先解析 `DateTime` → 300 条库解析 308 次变红 |
| 未验证 / 待测 | 无真机（保存/删除后帧时间、冷启动首帧交 OPT-M01）；收益全在本机 JIT 量过，AOT 下 `DateTime` 的时区查询仍要过系统调用但绝对值更小；待办计数维持「每次重算」（1500 条 × 20 行 6~8ms，增量维护要处理编辑/删除/同步全部失效路径，判定不划算） |
| 下一项 | OPT-06C（缩略图索引移出首帧）或 OPT-07A（§7 图片）；OPT-02B / OPT-09B 等各自前置验收，OPT-04C 待评估 |
| 待用户决策 | ① OPT-01 顺带发现的「归档行被剪枝」是 bug 还是设计；② 完整空清单的同步产品规则；③ `OPT-M01` / `OPT-R01` / `OPT-R02` / `OPT-MEMOS` 保持暂缓，等明确启用 |
| 工作区注意事项 | 另有会话在改启动图（`flutter_native_splash.yaml`、`android/app/src/main/res/values*/styles.xml`、`colors.xml`、`lib/main.dart`、`assets/images/splash_inkpaper.png`、`drawable/inkpaper_launch_background.xml`），另有一处未提交的 `docs/README.md` 增加审查文档索引链接，均非本轮产物，勿回退或顺手带上。**`lib/main.dart` 同时被两边改**：OPT-06A 那轮用 `git hash-object` + `update-index` 只提交了自己的 hunk，启动图那笔仍在工作区；发版、推送、装机需单独授权 |

## 执行队列

按表中顺序领取一项`待办`，先重查正文里的证据，再实现该行的最小范围。详情编号用于定位设计与回归要求，任务 ID 用于交接。遇到`待验收`或`阻塞`项先检查它是否影响后续任务，独立项可继续。

| 任务 | 优先级 | 状态 | 详情 | 本轮交付与验收 |
| --- | --- | --- | --- | --- |
| OPT-01 | P1 | 待验收 | §1 Memos 分页 | 有续页令牌的空页继续拉取，重复令牌、失败或达到上限时禁止按缺失 ID 剪枝。覆盖完整清单与部分清单。完整空清单的产品规则另行确认。 |
| OPT-02A | P1 | 待验收 | §2 首页排序 | 统一首批和续页的置顶、四种排序和 ID 并列顺序，切换时丢弃旧查询结果。用跨三页样本验收。 |
| OPT-02B | P1 | 待办 | §2 首页刷新 | 依赖 OPT-02A。同步和导入后刷新已浏览窗口，保留原有的全库读取入口，并覆盖过滤口径、浏览位置和翻页。 |
| OPT-03 | P2 | 待验收 | §3 探索索引 | 先缩小缓存失效范围。验证排序、续页不触发重建，正文、关系或可见性变化能刷新。索引结构及后台查询调整另行评估。 |
| OPT-09A | P2 | 待验收 | §9 短预览缓存 | 缓存键改为「解析上限 + 解析范围内正文的指纹」，按预览文本与样式区间估算预算淘汰。验证编辑、展开和搜索高亮。 |
| OPT-09B | P2 | 待办 | §9 卡片媒体提取 | 依赖 OPT-09A 的取样口径。把卡片分别提取图片与视频合并成一次媒体扫描，保持图片/视频互斥与顺序。 |
| OPT-10 | P2 | 待验收 | §10 笔记引用 | 明确的引用 ID 走批量查询。验证历史正文匹配、反向关系和移除最后一个引用。 |
| OPT-10B | P2 | 待验收 | §10 笔记引用 | `rebuildAllReferences` 只遍历已加载页（见 OPT-10 顺带发现）。改成按库全量重建，验证引用多的老库与分页状态。 |
| OPT-04 | P2 | 待验收 | §4 小组件 | 先缩减一次快照构建中读取的完整笔记范围，核对待办计数、回顾和首屏结果。 |
| OPT-04B | P3 | 待验收 | §4 小组件 | 统计行仍逐条构造 `Note`、待办计数每次重算。评估按行聚合与待办计数增量维护（见 OPT-04 未验证项）。 |
| OPT-04C | P3 | 待评估 | §4 小组件 | `Note.fromMap` 每行解析 3 个本地 `DateTime`（本机约 45µs/次），是分页、搜索、统计共同的读取成本。评估把时间字段改成惰性解析的收益与风险。 |
| OPT-06A | P2 | 待验收 | §6 首屏 | 先调整配置和首屏快照的并行读取，验证主题与语言、离线和空缓存启动。 |
| OPT-06C | P3 | 待办 | §6 首屏 | 缩略图索引仍卡在首帧前（5000 个文件约 37ms，冷缓存更慢）。评估 `lookup` 按需 stat 兜底后把扫描移到首帧后，验证首帧出图与内存。 |
| OPT-07A | P2 | 待办 | §7 图片 | 先约束缩略图像素和查看器预取保留范围，验证长图、方向、透明度和回看。可拆成两轮。 |
| OPT-07B | P2 | 待办 | §7 本地备份 | 优先验证现有 Dart 的流式归档方案。导入暂存与失败清理单独交付。均需覆盖历史备份、附件和失败重试。 |
| OPT-05 | P2 | 待评估 | §5 搜索 | 先用可复现样本判定 SQL 扫描或结果装载的主要成本，再决定分批或全文索引。 |
| OPT-06B | P3 | 待评估 | §6 外部事件 | 根据冷、热启动的通知、分享和深链复现结果决定是否调整事件交付。 |
| OPT-08 | P3 | 待评估 | §8 结构 | 结合前述业务改动逐步提取查询、同步或导入边界。 |
| OPT-M01 | P4 | 暂缓 | 校准测量 | 前面的优化项范围和实施顺序确认、用户明确启用后开始。 |
| OPT-R01 | P4 | 暂缓 | §11 Rust 探索索引 | 优化后的 Dart 仍有可复现瓶颈时，作为可选原型。 |
| OPT-R02 | P4 | 暂缓 | §12 Rust ZIP | Dart 流式方案仍有明确瓶颈或兼容性障碍时，作为可选原型。 |
| OPT-MEMOS | P4 · 最后 | 暂缓 | §13 Memos 功能优化 | 用户确认产品方向后，评估转为单向导入的范围、老用户迁移及同步入口退役条件。 |

### 状态与交接

- `待办`可领取，`待评估`需要先补证据或确认范围，`暂缓`等用户启用。每轮只推进一个可独立验收的改动，范围较大时在原任务下登记子项，保留剩余工作。
- 有可复查的改动和验证结果时标为`待验收`。经独立验收后标为`已验收`。已有实现也按相同标准给出证据。无法继续时标为`阻塞`，写明原因及解除条件。
- 每轮在本节末尾追加一条记录，说明任务 ID、本轮状态、改动或证据、验证命令与结果、未验证事项及下一项。适用时附本地提交号。记录已确认事实，区分功能回归通过和性能收益待测。
- 每轮结束时先整块覆盖文首[交接卡片](#交接卡片)（只留当下状态，不攒历史），再追加记录。两者内容不一致时以新记录为准，并回头修卡片。
- 普通开发轮遵守 [交接文档的版本和提交规则](../HANDOFF.md)。保持用户已有改动，独立验收和部署分别交接。

**推进记录。** 只追加、不删历史；每轮在末尾续一条，最新在最后。卡片与记录冲突时以记录为准。

### 2026-11-23 · OPT-01 · 待验收

- **改动**：`lib/services/memos_api_service_fixed.dart` 的 `getMemos()` v≥22 分支。`isComplete` 初值由 `true` 改为 `false`，只有读到「本页 `nextPageToken` 为空」的终止页才置 `true`，把「完整」变成正向证明；空页仍带令牌时继续拉下一页（原先是 `break`）；新增重复令牌检测，以及可选参数 `maxPages`（默认 1000，安全上限，不是业务参数）——重复令牌或达到上限都按不完整返回。401 与其他非 200 仍抛异常，调用方 `catch` 后同样不剪枝。两条同步路径的剪枝门槛（`app_provider_sync.part.dart:137`、`:357`）与 `allowContentClaim` 未改动。提交 `a681d9a`。
- **测试**：`test/unit/memos_api_service_test.dart` 新增六条（沿用 MockClient + `invalidateVersionCache`）：API-10c 空页续拉至终止页（3 次请求、2 条、完整）、API-10d 令牌重复（2 次请求即停、不完整）、API-10e 达 `maxPages` 上限并与空页交叉（不完整）、API-10f 第 2 页 500 抛错且不是 TokenExpired、API-10g 完整空清单（1 次请求、完整）、API-10h 空页后 401 仍抛 TokenExpiredException。该文件 32 → 38 项。
- **验证**：`dart tool/inkpaper.dart analyze` 无 issue；`dart tool/inkpaper.dart verify` 全量 **1038 项**通过（原 1032 + 新增 6）。功能回归通过；无性能指标可测（本项是正确性修复，收益是避免误删）。
- **行为变化**：页数上限由「最多成功 1001 页」收紧为「最多 1000 页」（`pageCount > 1000` → `pageCount >= maxPages`）。
- **未验证**：真实 Memos 服务端是否会产出「空页 + 非空令牌」无法本地复现，本轮只按协议异常处理；真实 >1000 页大库的剪枝 SQL 绑定参数规模未测。
- **本轮明确不做**：① 同正文副本归并/删除（`app_provider_sync.part.dart:133`、`:350`）不受 `isComplete` 约束——两处只处理未同步行，且先 `saveNotes` 再删副本，丢的是 id 归属不是正文；若在部分清单下也跳过，会留下两条一模一样的笔记，属独立设计。② 三处调用点的 `?? true` 默认值不改 `?? false`：`getMemos` 两条分支都显式返回该键，默认值是死分支，单改一处会造成判定不一致，要收紧应三处一起改并补契约测试。③ 完整空清单的产品规则不动，仍靠 `deleteSyncedNotesNotIn` 的空集合早退兜底。④ 不引入枚举返回结构、不给分页请求加超时、不动剪枝 SQL 规模与 `_primeServerContentIndex`。
- **顺带发现（留独立项，未改动）**：剪枝集合是「可见清单」（`app_provider.dart:1578` 的 `_isVisibleNote` 过滤 ARCHIVED 与待删除），而 `deleteSyncedNotesNotIn` 只排除 `rowStatus='DELETED'`，因此完整清单下服务端已归档的本地已同步行会被物理删除。与分页无关，需先确认是 bug 还是设计。另：修复后病态服务端上单次同步可能跑两轮全量分页（上传前 `_primeServerContentIndex` 预取 + 正式拉取），属预期行为，可作后续优化点。
- **建议下一项**：OPT-02A（首页排序统一）。

### 2026-11-23 · OPT-02A · 待验收

- **改动**：
  - `lib/utils/note_sorting_helper.dart`：新增 `noteOrderBySql(SortOrder)`，固定三级排序 —— `IFNULL(isPinned,0) DESC` → 所选时间字段 → `id`（倒序排序用 `id DESC`，正序用 `id ASC`，让「从旧到新」正好是从新到旧的镜像）。`noteComparator` 补同样的 `id` 兜底，两边逐级对应。删除已无生产调用点的 `inferCurrentSortOrder`：DB 开始按选中字段排序后，从列表内容反推排序不再成立，留着只会误导。
  - `lib/services/database_service.dart`：`getNotesPaged` 的 `String? orderBy` 换成 `SortOrder sortOrder`（默认 `newest`），并补 `DatabaseExecutor? executor` 便于直连测试库；`getNotesByMedia` 的 `orderBy` 同步换成 `SortOrder`。
  - `lib/providers/app_provider.dart`：① `setSortOrder` 改为 async —— 改完排序从第 0 页重查，不再只对已加载的 50 条重排（这是「两年前创建、今天刚编辑」的笔记翻不到底的根因）；② 新增 `_notesQueryEpoch` 代数号，`loadInitialNotes` 与 `loadMoreNotes` 都核对它，切换排序后迟到的首屏/续页结果整份丢弃，也不把新查询的分页状态改成 failed；③ `_getCurrentSortOrder()` 直接返回 `_notesStore.sortOrder`，不再靠内容反推；④ 媒体筛选查询带上 `sortOrder`，await 期间排序又变了就丢弃这次结果。
  - `lib/screens/home_screen.dart`：`_applySorting` 改为 await 新的异步 `setSortOrder`。
  - 未改动：分页仍是 `OFFSET` 取页（游标续页按该项建议留待大库测量后再决定）、`loadNotesFromLocal` 的全量回载路径、`app_provider_sync.part.dart` 同步后的列表更新（均属 OPT-02B 范围）。
- **测试**：新增 `test/unit/notes_paging_sort_test.dart`（9 条，真 SQLite + `sqflite_common_ffi` 内存库 + `executor` 注入）。7 条样本覆盖「老笔记最近编辑」「最老的置顶笔记」「同一 createdAt 并列」。断言：`PGSORT-newest/oldest/updated/updatedOldest` 跨三页（pageSize 3）拼起来必须**逐位等于** `sortedNotesCopy` 的结果且无重复；`PGSORT-deep` 最近编辑第一页就含 2023 年创建的老笔记；`PGSORT-pinned` 四种排序下置顶都在首位；`PGSORT-tie` pageSize=1 让并列项跨页，仍不重不漏；`PGSORT-null` 老行 `isPinned` 为 NULL 时按未置顶排在置顶之后；`PGSORT-media` 「有图片」筛选同样按最近编辑排序。`test/unit/note_sorting_helper_test.dart` 8 → 9 条（删掉 3 条推断函数用例，新增 id 兜底三条 + SQL 子句契约一条）。
- **验证**：`dart tool/inkpaper.dart analyze` 无 issue；`dart tool/inkpaper.dart verify`（格式门禁 + analyze + 全量测试）**1048 项全过**（原 1038，净 +10）。反向验证：把 `getNotesPaged` 的 `orderBy` 临时改回写死的 `createdAt DESC`，新文件 9 条里 8 条立刻失败（`PGSORT-media` 因样本没有其它带图笔记而未被触发），恢复后 9 条全过 —— 说明这批用例真的钉住了本项修复。
- **行为变化**：切换排序会把列表重置为第一页（已加载的深页被丢弃，滚动位置可能被钳制），保留浏览位置与翻页属 OPT-02B；四种排序下**置顶恒在最前**，此前「按编辑时间」排序时置顶笔记虽然仍在前面，但与「最近编辑」混排的样本未被 SQL 覆盖。
- **未验证**：① 无真机验收，滚动观感、切换排序时的重建帧与「列表被重置」的体感未测；② 排序子句现在是三级，`idx_notes_created_at` 只能帮上「创建时间」两种排序的第一段，`ORDER BY` 会走临时排序，大库（万条级）的 SQL 耗时未测 —— 属性能收益待测，交给 OPT-M01 校准；若要加 `(isPinned, updatedAt, id)` 组合索引需升 schema，本轮不动；③ 推理出的一个既有问题本轮未修：`loadNotesFromLocal()` 全量回载后把分页状态重置为初始（`currentPage=0`、`hasMoreData=true`），之后滑到底会按第 1 页再 `addAll` 一次已加载的笔记，理论上产生重复条目，待 OPT-02B 统一刷新入口时一并处理；④ 排序选择仍未持久化（重启回 `newest`），冷启动首屏快照可能来自上次的另一种排序，首帧与真实加载之间有一次顺序差。
- **建议下一项**：OPT-03（§3 探索索引，独立项）。OPT-02B 依赖本项，待本项验收后再领，接手时把上面 ③ 的 `loadNotesFromLocal` 重复追加一并处理。

### 2026-11-23 · OPT-03 · 待验收

- **改动**：
  - 新增 `lib/utils/revisioned_future_cache.dart`：`RevisionedFutureCache<T>` 把「缓存还有没有效」收敛成一次版本号比较。版本未变复用同一个 Future（并发调用共享一次构建）；变了就重建；构建期间又变则丢弃这份结果再建，最多 `maxAttempts` 次（默认 3），避免持续写入时死循环；构建失败不缓存。
  - `lib/services/database_service.dart`：新增 `static int notesRevision` 与 `_bumpNotesRevision()`，在全部 note 行写入处自增 —— `upsertNote`（覆盖 `saveNote`、三条导入链路）、`updateNote`、`deleteNote`、`softDeleteNote`、`restoreDeletedNote`、`purgeDeletedNote`、`purgeAllDeletedNotes`（仅有行被删时）、`clearAllNotes`、`replaceAllNotes`、`mergeNotes`、`deleteSyncedNotesNotIn`（仅有行被删时）、`updateNotesBatch`、`insertNotesBatch`、`setRemoteId`、`markNoteSynced`、`fixInvalidNoteTimestamps`（仅有行被改时）。读路径一律不动，空的服务端清单仍在方法入口提前返回。
  - `lib/providers/app_provider.dart`：`_noteDiscoveryIndex` 由裸 `Future?` 换成带版本号的缓存，版本源抽成可覆盖的 `@protected noteDiscoveryRevision`（生产读数据库写入版本）；`notifyListeners()` 不再置空索引；`updateNoteInMemory()` 同样不再置空（该路径只改内存，引用重建本身会写库）。
  - `docs/BUSINESS_OVERVIEW.md` 4.14 补一句缓存口径。
- **测试**：新增 `test/unit/revisioned_future_cache_test.dart` 7 条（RFC-01 复用不重建、02 版本变化重建、03 构建期间变化丢弃重建、04 达 `maxAttempts` 停止、05 失败不缓存、06 并发共享一次构建、07 `clear` 后重建）；新增 `test/unit/notes_revision_test.dart` 6 条真 SQLite 用例（REV-01 插入/更新各 +1、02 分页与媒体筛选与往年今日与删除列表都不动版本号、03 软删/恢复各 +1、04 彻底删除与批量清空只在有行被删时 +1、05 `mergeNotes` 算语料变化、06 空清单提前返回不动版本号）。改造 `test/unit/related_notes_index_test.dart` 的共用索引用例：原来靠 `notifyListeners()` 触发重建，现在断言「通知不重建」+「版本号变化才重建且结果更新」。
- **验证**：`dart tool/inkpaper.dart format` → 313 个文件 0 changed；`dart tool/inkpaper.dart analyze` → No issues found；`flutter test`（`NO_PROXY` 已设）→ **1061 项全过**（原 1048 + 13）。说明：`verify` 整轮会先跑 `deps`，本轮第三次整轮在该阶段卡住 21 分钟（期间没有 `flutter_tester` 子进程，`flutter test` 单独启动 30 秒内就跑到 194 项），已中止并改成分步执行同一套命令取证；`verify` 前两次已完成 analyze 与测试部分。另有一次 `test/widget_tests/note_editor_draft_image_test.dart` 的「自动恢复后继续写」在全量并发下失败、单跑 9 项全过、重跑全量也过，判环境偶发，与本轮改动无引用关系。功能回归通过；性能收益未测（命中缓存后的进入时延、索引常驻内存交 OPT-M01）。提交 `b79b468`。
- **行为变化**：切排序、首页翻页、切媒体筛选、同步进度通知之后再进随机漫步/相关笔记，直接命中已建的索引；写库（编辑、增删、标签、引用、恢复备份、同步落库）后第一次探索重建一次。索引首次冷建的耗时与结构未变。
- **未验证**：① 无真机验收，命中缓存的体感与内存占用未测；② `deleteNote` 是先标记 `pendingDeleteIds` 再异步软删，落库前有极短窗口索引里仍含该笔记（撤销与恢复都会写库触发重建，实际不可达）；③ 索引结构、轻量语料、后台常驻 isolate 查询未动（本项范围外，见 §3「索引体积与查询开销」）；④ 版本号是进程内计数器，冷启动归零不影响正确性（缓存本来也不跨进程）。
- **建议下一项**：OPT-02B 依赖 OPT-02A，等其验收后再领；独立项下一个是 OPT-09（§9 短预览缓存）。

### 2026-11-23 · OPT-09A · 待验收

- **拆项**：原 OPT-09 在本轮拆成两项。**A**（本轮）= 缓存键与淘汰预算；**B**（待办）= 卡片把图片/视频两次媒体提取合并成一次扫描。B 独立可验收，且不依赖 A 的实现细节，故不出现在本记录里。
- **改动**（`lib/utils/note_preview_builder.dart`）：
  - `NotePreviewCache._key` 不再把整篇正文当键，改为「解析上限 + 解析长度 + 前缀指纹」。指纹用两路 32 位滚动哈希（FNV-1a 与 djb2 变体）在同一趟循环里推进，合起来 64 位；键从「整篇正文」缩到几十字节。
  - 没有按审查建议的「笔记 ID + 随正文改变的版本」实现，理由记录在此：`Note.updatedAt` 不能当正文版本号——Memos 把北京时间当 UTC 存，`createdAt` 可能落在未来，`_clampUpdatedAt`（`note_model.dart:212`）会把编辑时间压回 `createdAt`；而改正文的路径（待办勾选 `NoteCard._toggleTodoItem` 把 `updatedAt` 设为当前时间）正好会被钳住，于是正文改了而 `updatedAt` 不变；另外详情页、历史版本快照这类调用方拿不到笔记 ID，按建议还得再维护一套「合用」的键。改用前缀指纹后所有调用方共用一条规则，失效也不需要额外状态。
  - 键只覆盖前 `parseLimit` 个字符：`buildNotePreview` 第一步就是 `_safePrefix`，超出范围的改动本来就不参与预览，因此不重建是对的。`_safePrefix` 拆出 `_safePrefixLength`，解析与算键共用同一套代理对截断规则，不再为算键复制一份前缀字符串。
  - 淘汰从「固定 400 条」改成「条数 + 估算字符预算」两套：卡片预览 400 条 / 60 万字符，全文预览 4 条 / 120 万字符，两桶各自淘汰（全文超标不会顺手挤掉卡片预览），刚写入的一条不参与淘汰。单条占用按「预览文本字符数 + 样式区间 ×24 + 链接 ×12 + 勾选框 ×12 + 空行偏移 ×2」折算，权重按各结构带的对象/Set 引用估算。
  - 新增 `@visibleForTesting` 的 `entryCount` / `residentChars` / `debugKeys`，供预算与「键里没有正文」的断言使用。
  - 未改动：`resolve` / `resolveAsync` 签名、`defaultPreviewParseLimit`（仍 2400）、`NoteCard` 与 `NotePreviewText` 的调用方式、详情页的 `resolveAsync` 后台解析路径。
- **测试**：`test/unit/note_preview_builder_test.dart` 17 → 23 条：PKEY-01 超出解析范围的尾部改动不重建、PKEY-02 前缀改了就重新解析、PKEY-03 键里不保留正文（10000+ 字的笔记，两个键都短于 64 字节）、PKEY-04 短笔记按 400 条上限淘汰、PKEY-05 300 条 2400 字长卡片被字符预算裁到 200 上下、PKEY-06 全文预览限 4 条且不挤占卡片预览。新增 `test/widget_tests/note_preview_cache_test.dart` 3 条：PCW-01 同一 `updatedAt` 改写正文后卡片显示新内容（钉住「键不能拿 `updatedAt` 当版本」）、PCW-02 命中缓存的预览仍高亮搜索词、PCW-03 展开态沿用同一份预览（`entryCount` 保持 1）。
- **验证**：`dart tool/inkpaper.dart analyze` → No issues found；`flutter test --concurrency=4`（`NO_PROXY` 已设）→ **1070 项全过**（原 1061 + 9）。`verify` 整轮未跑：本轮先按默认并发跑过两次，两次都只有 `note_editor_draft_image_test.dart` 的「编辑已有笔记加图后重开，图片自动回来」失败，失败点是 `addTearDown` 里 `sandbox.deleteSync(recursive: true)` 抛 `PathAccessException: 另一个程序正在使用此文件`（缩略图 worker 还没释放），单跑该文件 9 项全过；改前基线也跑了一次，跑到 786 项时 VM 直接 `Could not start thread DartWorker` 崩掉（`Committed 35.7 / 39.8 GB`），没拿到对照结论。降到 `--concurrency=4` 后一轮全绿，判断是该文件在 Windows 上的清理竞态 + 本机内存吃紧，和预览缓存无关（本项不碰文件 IO、缩略图与草稿）。
- **反向验证**：把 `_key` 临时改回「整篇正文当键」，PKEY-01、PKEY-03 立刻失败（其余 4 条新用例是预算相关，不受影响），恢复后全过。
- **行为变化**：缓存命中从「正文完全相同」放宽到「解析范围内的前缀相同」；超过 2400 字之后的改动不再让卡片预览重建（本来也不参与预览）。长卡片在当前库规模下最多驻留 200 条上下（按 60 万字符预算），短笔记仍是 400 条封顶。全文预览仍是 4 条，另加 120 万字符上限。
- **未验证**：① 无真机，`NotePreviewCache.hitRate` 的实际命中率与滚动帧时间未测，交 OPT-M01；② 两路 32 位哈希理论上可碰撞（400 条规模约 4×10⁻¹⁵），没有额外留原文做二次校验；③ 每次取预览都要对前 ≤2400 字符做一次单趟哈希，卡片重建时的这点开销未单独计时（属于性能收益待测的一部分）。
- **建议下一项**：OPT-09B（§9 卡片媒体提取）。OPT-02B 仍等 OPT-02A 验收。

### 2026-11-23 · OPT-10 · 待验收

- **改动**：
  - `lib/services/database_service.dart`：新增 `getNotesByIds(Iterable<String>, {executor})`——查 `viewActiveNotes`，按 900 个 id 一批（SQLite 变量上限 999），口径与 `getNoteById` 一致（软删行不算存在）。另加两个 `@visibleForTesting` 钩子：`debugOverrideDatabase(Database?)`（引用管理器这类自己持 `DatabaseService()` 的服务没法逐方法注入 `executor`）与 `debugFullTableReadCount`（在 `getNotes()` 里自增，用来证明保存路径还读不读全库）。
  - `lib/services/unified_reference_manager.dart`：
    - `updateReferencesFromContent` 的引用解析改成三段：① 先 `getNotesByIds(newReferences)` 一次批量查（编辑器插入的就是 `[[<id>]]`，见 `note_editor.dart` 的 `[[${referencedNote.id}]]`）；② 只有按 id 查不到的引用才回落到历史兼容路径（`[[正文]]` / `[[正文前缀]]`），那条路才 `getNotes()`；③ 同一引用重复出现只处理一次。原来的三档匹配（id → `content.trim()` 精确 → 去 Markdown 标记后的前缀/前 50 字符包含）抽成 `_resolveLegacyReference` / `_legacyReferenceMatches`，命中多条仍取 `getNotes()`（createdAt DESC）里的第一条，顺序语义不变。
    - `createReference` / `removeReference` / 两个 cleanup 方法不再 `getNotes()`：前者改 `getNoteById` 取源和目标两行。
    - 回调更名并改语义：`onNotesUpdated`（全量笔记）→ `onNotesChanged`（本次受影响的笔记）。以前调用方据此整表替换 `_notesStore.notes`，分页之后那等于把深页状态和排序位置冲掉。
  - `lib/providers/app_provider.dart`：回调改成按 id 就地更新、找不到才追加；删掉「`currentPage == 0` 且条数 ≤ 50 就整表替换」的分支（该分支依赖的 `_pageSize` 仍被同步回载用到，保留）。
  - `docs/development/LESSONS_LEARNED.md` §2.8 补第 2.8 节的第二层：短路只挡住「没有引用」，真有引用时还有 4 次全表读取，以及现在的解析顺序与回调语义。
- **测试**：新增 `test/unit/note_reference_manager_test.dart` 8 条（真 SQLite 内存库 + `debugOverrideDatabase`，样本 4 条现代笔记 + 2 条同前缀老笔记）：REF-01 明确 ID 建双向关系且全表读取 0 次；REF-02 三个 ID 引用仍 0 次（改造前是 4 次：解析 1 + 每个引用 1）；REF-03 `getNotesByIds` 传 1202 个 id 分两批不炸变量上限；REF-04 移除最后一个引用时双向关系一起清掉；REF-05 `[[今天读书笔记]]` 落到 `getNotes()` 顺序的第一条且只读一次全库；REF-06 ID 与历史引用混合，两条都建立关系；REF-07 目标被软删后不建立关系；REF-08 回调只带 `{n-1, n-2, n-3}`，不是整库。
- **验证**：`dart tool/inkpaper.dart analyze` → No issues found；`flutter test --concurrency=4`（`NO_PROXY` 已设）→ **1078 项全过**（原 1070 + 8）。反向验证：把批量解析临时改成空集（强制走全库兼容路径），REF-01 / 02 / 04 / 06 / 08 立刻失败，恢复后 8 条全过。
- **查询行数与耗时校准**：800 条笔记（正文约 190 字）+ 5 轮「保存一条引用三篇笔记的正文」，本机内存库实测现状 **30ms / 0 次全表读取**，改造前等价路径（20 次 `getNotes()`）**2323ms**。这是内存库、无磁盘 IO 的下界，只说明量级关系，不代表真机数字。
- **行为变化**：引用回调只带受影响的笔记；同一条正文里重复出现的 `[[x]]` 只处理一次（以前会重复调用 `createReference`，第二次靠幂等判断早退）；旧式前缀匹配在「精确匹配 vs 前缀匹配」上有极小的判定归并（`cleanContent == cleanRef` 现在两处都算命中），命中结果与顺序不变。
- **未验证**：① 无真机，保存耗时、编辑器关闭帧时间未测，交 OPT-M01；② 旧式 `[[正文前缀]]` 仍是 O(n) 全库扫描，用户若大量依赖它，收益只剩「没引用时零成本」这一条；③ `debugFullTableReadCount` 在 release 里也自增，但没有任何读者，属纯测试钩子；④ `rebuildAllReferences` 未动（见顺带发现）。
- **顺带发现（登记为 OPT-10B）**：`app_provider.dart:4192` 的 `rebuildAllReferences` 遍历的是 `_notesStore.notes`（当前分页缓存），不是全库，接回 UI 前必须改成按库遍历；该方法目前全仓无调用点（`grep` 只剩定义），属死代码。另：`notes_context_builder` 与随机漫步索引仍走 `getNotes()` 全量，那是它们的取样口径，本项不动。
- **建议下一项**：OPT-10B 或 OPT-04（§4 小组件），均为独立项；OPT-02B 等 OPT-02A 验收、OPT-09B 等 OPT-09A 验收。

### 2026-11-23 · OPT-10B · 待验收

- **问题核对**：`AppProvider.rebuildAllReferences` 有两处独立缺陷，都是「分页化之后没人复查」留下的：① 清除与重建都遍历 `_notesStore.notes`——首页 50 条一页的缓存，第 51 条之后的笔记引用关系永远不会被重建；② 中间两次 `loadNotesFromLocal()`，该方法把 `pagingState` 换回 `initialNotesPaginationState()`（`currentPage = 0`、`hasMoreData = true`）却把整库塞进 `notes`，之后 `loadMoreNotes()` 会按第 1 页再 `addAll` 一次，列表出现重复条目。该方法全仓无调用点（`grep` 只剩定义），属维护用死代码，但仍按队列要求修好而不是删掉。
- **改动**：
  - `lib/services/unified_reference_manager.dart`：新增 `rebuildAllFromDatabase()`。整段落在库里：`getNotes()` 全库读一次（重建本就是全库操作）→ 在内存里按正文解析引用（先按 id 命中，再回落到 `_resolveLegacyReference` 的正文/前缀匹配，与保存路径同一套）→ 双向配对（源写 `REFERENCE`、目标写 `REFERENCED_BY`）→ 只把**关系集合真的变了**的行 `updateNotesBatch` 一次写回。`_sameRelationSet` 只比 `type / memoId / relatedMemoId`，所以第二次重建不写库、不自增 `notesRevision`。自引用（`[[自己的 id]]`）不计入，双向关系对同一条笔记没有意义。
  - `lib/providers/app_provider.dart`：`rebuildAllReferences` 收缩成「调管理器 + `loadInitialNotes()`」。重建只改 `relations` 字段，重查首屏即可，分页状态由 `applyInitialPageResult` 按「已加载 / 总数」算，翻页接着第 1 页走。删掉原来的 `Future.delayed(50ms)` 逐条节流（批量写已经不需要）。
  - `docs/development/LESSONS_LEARNED.md` §2.8 补「维护入口」一段：批量维护不要用 `loadNotesFromLocal()` 收尾。
- **测试**：`test/unit/note_reference_manager_test.dart` 8 → 12 条，新增 REF-09 120 条库里最老那条（`bulk-5`，首页缓存里没有）的引用被建起来、REF-10 正文里已删掉的旧关系被清掉（含目标笔记上的反向关系）、REF-11 环形引用重建后双向一致无孤儿、REF-12 幂等（第二次重建 `notesRevision` 不变）。新增 `test/unit/reference_rebuild_paging_test.dart` 2 条（真 SQLite + `AppProvider()` + `debugOverrideDatabase`）：① `loadInitialNotes` 50 条 → `loadMoreNotes` 100 条 → 重建 → 回到 50 条且 `hasMoreData` 仍为真 → 再翻页到 100 条**无重复 id**；② 重建能覆盖首屏之外的最老笔记。
- **验证**：`dart tool/inkpaper.dart format` → 316 个文件 0 changed；`analyze` → No issues found；`flutter test --concurrency=4`（`NO_PROXY` 已设）→ **1084 项全过**（原 1078 + 6）。反向验证两处分别做了：把重建的取样改成 `getNotes().take(50)` → REF-09 与「重建覆盖首屏之外」两条红；把 AppProvider 的收尾改回 `loadNotesFromLocal()` → 「重建后翻下一页不重复」红；恢复后全绿。
- **行为变化**：重建范围从「已加载的首页缓存」变成全库；重建后列表回到首屏（深页被丢弃，与切换排序一致），但不再产生重复条目；重建**不再**触发服务端关系同步（旧实现走 `createReference` 会逐条 `_syncToServerInBackground`）——关系本来由同步合并按正文重建，这里不发请求是有意的，若将来需要远端对齐要单独加。
- **未验证**：① 无真机，重建耗时只在小样本（120 条）上跑过，万条库的一次性重建时长与内存峰值未测，交 OPT-M01；② 重建后不做远端同步，多端场景下服务端关系可能滞后到下一次同步；③ `rebuildAllReferences` 仍无 UI 调用点（设置页若接回需先确认是否要顺带同步）；④ 自引用被忽略这一条没写用例（正文里出现 `[[自己的 id]]` 属病态数据）。
- **建议下一项**：OPT-04（§4 桌面小组件，独立项）；OPT-02B 等 OPT-02A 验收、OPT-09B 等 OPT-09A 验收。

### 2026-11-23 · OPT-04 · 待验收

- **问题核对**：队列里 OPT-02B / OPT-09B 的前置项（02A / 09A）仍待验收，本轮领独立项。先在本机内存库造了 1500 条样本（正文约 300 字、每 5 条带待办、每 3 条带 2 个关系、每 10 条带 1 个附件）量了一次快照构建，两处大头都不是 SQL：
  ① `getNotes()` 整库构造完整 `Note` 302ms，其中每行还要 `jsonDecode` 一次 `relations` 和一次 `resourceList`；
  ② 挑 8 条回顾候选时，`selectWidgetCandidates` 为了「有可见文字」这条规则**先对全库每条**跑 `previewVisibleText`（完整 Markdown 解析 + AST 遍历），单独一圈 544ms，1500 条里最后只留 8 条。
  另外 `_maybePersistFeedSnapshot` 只落最近 20 条，却先把整库构造成完整笔记再 `take(20)`。
- **改动**：
  - `lib/services/random_review_selector_service.dart`：`selectWidgetCandidates` 改成「先按时间范围取候选池 → 洗牌 → 边取边判可见文字，取满 `reviewCount` 就停」。范围池为空时退回全库、池里一条带文字的都没有时退回任意笔记，两条兜底与旧口径一一对应。「洗牌后取前 N 个满足条件的」与「先筛出满足条件的再洗牌取前 N 个」分布相同，所以抽样语义不变。
  - `lib/services/database_service.dart`：新增 `getWidgetStatNotes()`（`id, content, createdAt, updatedAt, displayTime, tags, is_synced, isPinned, resourceList, rowStatus`，不读 relations）与 `getRecentActiveNotes(limit)`（完整行，`createdAt DESC LIMIT n`）。附件列表留在窄列里——回顾/置顶卡片的「这是一条含图片的笔记」靠它判断。
  - `lib/providers/app_provider.dart`：`_scheduleWidgetSnapshotUpdate` 内部改成两批输入——`statNotes` 给统计与回顾，`feedNotes`（≤20，且多取 `pendingDeleteIds.length` 条以免撤销队列把首屏挤到 20 条以下）给首屏快照落盘；读库失败时两批都退回内存里已加载的那一页。
  - `lib/services/widget_snapshot_service.dart`：`debugBuildSnapshot` / `_buildSnapshot` / `_pickReviewNotes` 增加可选 `Random`，让「同一份库、不同读取路径」的快照能逐字段对比。
  - `lib/utils/memos_content_helper.dart`：新增 `@visibleForTesting debugPreviewParseCount`，把「解析了几次」变成可断言的指标。
  - `docs/development/LESSONS_LEARNED.md` §2.11：记「全量口径的统计与抽样：读窄列，抽样别先全筛」。
- **测试**：新增 `test/unit/widget_snapshot_read_scope_test.dart` 5 条（真 SQLite + `debugOverrideDatabase`）：WSR-01 窄列保留统计字段且 relations 为空、已删除行不进来；WSR-02 同一份库用整库完整笔记与窄列笔记各建一次快照（同种子）**逐字段相等**（只剔除 `generatedAt`）；WSR-03 `getRecentActiveNotes(20)` 取最近 20 条且关系/附件都在；WSR-04 300 条库挑 8 条候选，真实解析次数 < 50；WSR-05 全库都是图片型笔记时仍能抽到回顾卡片且预览是「这是一条含图片的笔记」。
- **验证**：`dart tool/inkpaper.dart format` → 206 个文件 0 changed（本轮改动的文件另跑过 `dart format`）；`dart analyze lib test` → No issues found；`flutter test --concurrency=4`（`NO_PROXY` 已设）→ **1089 项全过**（原 1084 + 5）。
- **校准**（本机内存库、非真机）：改造前 `getNotes()` 302ms + 全库可见文字解析 544ms + 其余构建，合计约 850ms 量级；改造后 `getWidgetStatNotes()` 242ms + `getRecentActiveNotes(20)` 5ms + 构建 98~131ms，约 350~380ms。可见文字解析次数 1500 → 8。
- **反向验证**：三项分别单独打回，确认用例真的守得住——① `getWidgetStatNotes` 改回 `SELECT *` → WSR-01 红（relations 非空）；② `getRecentActiveNotes` 改成窄列 → WSR-03 红（关系丢失）；③ `selectWidgetCandidates` 改回「先全筛再洗牌」→ WSR-04 红（解析 300 次）。恢复后全绿。
- **行为变化**：快照内容不变（WSR-02 逐字段对过）。差异只在两点：一是回顾候选在「带文字笔记不足 8 条」时返回顺序不同（集合相同，本来就是随机的）；二是统计用的笔记对象里 `relations` 为空——任何要判双链或要 `toMap` 落盘的路径都必须走 `getRecentActiveNotes`，别再拿统计笔记去 `save`。
- **未验证**：① 无真机，保存/删除后的实际帧时间与冷启动首帧表现未测，交 OPT-M01；② 统计这批仍是逐条构造 `Note`（约 240ms 里大半是 `DateTime.parse` ×3 + 构造），要再降得改成「按行聚合 + 只在选中项上取完整笔记」，已登记 OPT-04B；③ 待办计数仍每次全库重算（1500 条约 5ms，暂不是瓶颈）；④ 只测了 1500 条的合成库，万条或超长正文未覆盖。
- **提交**：`6a75cca`（代码 + 测试）。
- **建议下一项**：OPT-04B（OPT-04 的剩余部分）或 OPT-06A（§6 首屏）；OPT-02B 等 OPT-02A 验收、OPT-09B 等 OPT-09A 验收。

### 2026-11-23 · OPT-06A · 待验收

- **问题核对**：`_initializeApp` 里日期格式、图片缓存、附件缓存、缩略图索引四项先并发发起（这一点早已改过），但**首屏快照与主题/语言配置是在这四项 `await` 完之后才起跑**的，总耗时 = 最慢的四项 + 较慢的这两项。另外 `FeatureFlagService.init()` 在首帧前 `await`，它内部 `_fetchFromRemote` 是一次 HTTP（超时 5 秒）：默认 `FEATURE_FLAG_URL` 为空会早退，一旦构建时配了就是开屏等网络。全仓无任何 `FeatureFlagService().isEnabled` 调用点，这笔等待目前只服务本地缓存。
- **改动**：
  - `lib/utils/startup_essentials.dart`（新增）：`loadStartupEssentials()` 把六项准备连续发起再一次 `Future.wait` 收口，返回 `StartupEssentials(feedSnapshot, appConfig)`。六项都能注入（`StartupTask<T>`），测试可替换。文件头逐项标注「为什么它必须卡在首帧前」。
  - `lib/main.dart`：改为 `final essentials = await essentialsFuture`，`timeago` 注册与图片缓存上限仍在这段等待之间同步设置；`runApp` 之后新增 `unawaited(FeatureFlagService().refreshRemote())`。
  - `lib/services/feature_flag_service.dart`：拆出 `loadLocal()` / `refreshRemote()`，`init()` 保留为两者串联的兼容入口并注明启动路径不要用它。
- **测试**：新增 `test/unit/startup_essentials_test.dart` 7 条——SE-01 六项全部发起后才开始等待（闸门夹具，发起数必须为 6）；SE-02 六个 50ms 任务总耗时 < 150ms（串行是 300ms）；SE-03 缩略图卡住时快照与配置已先好、整体仍未完成；SE-04 空缓存 + 离线（真实默认加载器 + path_provider/安全存储 mock）返回空快照、默认主题、locale 为 null，且 `DateFormat('zh_CN')` 已可用；SE-05 20 条快照回读字段完整；SE-06 功能开关 `loadLocal()` 后 `isEnabled` 立刻反映本地缓存；SE-07 已保存的深色主题与 en_US 通过 `AppProvider(initialConfig:)` 在首帧即生效（系统为浅色）。
- **验证**：`dart analyze lib test` → No issues found；`dart tool/inkpaper.dart format` → 319 文件 0 changed；`flutter test --concurrency=4` → **1096 项全过**（原 1089 + 7）。首跑出现过一次 `test/widget_tests/note_editor_draft_image_test.dart` 的 tearDown 清理竞态失败（该文件单跑 9 项全过，紧接着的全量复跑全绿），与启动代码无关，属既有的并发抖动。
- **反向验证**：把六项改回「前一项 `await` 完再发起下一项」——SE-01 发起数 6 → 1、SE-02 实测 258ms（阈值 150ms）、SE-03「快照已好」变 false；SE-04/05/06/07 仍过（它们不测顺序）。恢复后全绿。
- **量级校准**（本机、内存库/合成数据、**非真机**）：六个 50ms 合成任务并行 50~52ms、串行 258ms；单项实测 `initializeDateFormatting('zh_CN')` 11ms、`loadAppConfig()`（空配置、安全存储走 mock）7ms、20 条快照（13.8KB）回读 5~13ms、`ThumbCache.prepare()` 空目录 9ms / 5000 文件 37ms。按此估算本机合成样本省 10~20ms；真机上配置读取要过 4 次 Keystore、磁盘是冷缓存，实际收益更大，但必须真机校准。
- **行为变化**：快照与配置内容不变；区别只有时序。功能开关的**远程**值现在首帧之后才可能生效——目前没有任何读取点，安全。
- **未验证**：① 无真机，首帧/可交互时间未测（交 OPT-M01）；② 缩略图索引扫描仍在首帧前，冷缓存下的真实耗时未测；③ `StartupCover` 那段启动图改动属另一会话，未参与本轮验证。
- **顺带登记**：OPT-06C——用「`lookup` 未命中索引时按需 stat」把缩略图扫描移到首帧后，代价是每张卡多一次同步 stat。
- **提交**：`54e0242`（代码 + 测试）。`lib/main.dart` 与另一会话的启动图改动同文件，本轮用 `git hash-object -w --path` + `update-index --cacheinfo` 只把自己那 5 个 hunk 写进索引，未把启动图那笔带进提交。
- **建议下一项**：OPT-06C（本轮量出来的剩余项）或 OPT-07A（§7 图片）；OPT-02B / OPT-09B / OPT-04B 仍等各自前置验收。

### 2026-11-23 · OPT-04B · 待验收

- **问题核对**：OPT-04 把小组件读取收窄到窄列后，统计路径仍要 240ms 级。这轮先拆开量：SQL 只有 5~6ms，`Note.fromMap` 1500 行 242~255ms。再往下拆 `fromMap`：3 个 `DateTime.parse` 占 213ms，`jsonDecode` 附件 0~3ms、`split` 标签 0ms。追到根因——**贵的是本地 `DateTime` 的构造**：`DateTime(y,m,d,…)` 每次都要向系统查一次时区偏移，本机 JIT 下 20000 次 890ms（45µs/次），而 `DateTime.utc(...)` 20000 次只要 2ms。手写 ISO 解析器替掉 `DateTime.parse` 只快 5%，方向不对。
- **改动**：
  - `lib/models/widget_stat_note.dart`（新增）：统计行只留 `createdAtIso` / `updatedAtIso` / `displayTimeIso` 三个字符串（按 `Note` 的口径做同一套钳制），`displayDayKey` 取前 10 位、`displaySortKey` 直接比串，`createdAt` / `displayTime` 惰性解析并缓存。`fromRow` 不算时间，`fromNote` 只做 `toIso8601String`（不查时区）。
  - `DatabaseService.getWidgetStatNotes()` 改返回统计行；`lib/providers/app_provider.dart` 的统计/首屏两批输入与兜底路径跟着换，`_excludePendingDeletedNotes` 改成按 id 取值（不绑死 `Note`）。
  - `WidgetSnapshotService._buildSnapshot` 收统计行：排序、今日筛选、周/月格子、`_noteSnapshot` 全部走字符串；`debugBuildSnapshot(List<Note>)` 保留为对照基准，新增 `debugBuildSnapshotFromRows`。
  - `RandomReviewSelectorService`：抽出 `selectWidgetCandidatesFrom<T>`（`displayDayKey` + `contentOf` 两个回调），`Note` 与统计行共用同一套「范围内取 → 取不到回全库 → 全没有文字退任意」的兜底。
  - `TodoParser`：`countTodos` 不再构造 `TodoItem`（单趟扫描），正则提到类级常量（原先**每行** new 一次），正文没有 `[` 直接返回。
- **口径变化（有意）**：「今天」与「N 天范围」从精确时刻改成按自然日比较，窗口最多宽出不到一天。周/月格子本来就按日期分组，这样两者更自洽；`dayCounts` 与 `todayNotes` 以前对「正好 00:00 的笔记」判定不一致，现在一致。
- **测试**：新增 WSR-06（300 条库构建，`Note.debugDateTimeParseCount` < 40 且 `WidgetStatNote.debugLazyParseCount` < 40）、WSR-07（7 天范围按自然日）、TD-16（`countTodos` 与 `parseTodos` 逐例对照 10 组边界正文）。WSR-02 改为「完整笔记 vs 统计行」两条路径逐字段相等，继续锁「内容没变」。
- **验证**：`dart analyze lib test` → No issues found；`dart tool/inkpaper.dart format` → 318 文件 0 changed；`flutter test --concurrency=4` → **1099 项全过**（原 1096 + 3）。
- **校准**（本机内存库、1500 条、每条约 20 行，**非真机**）：整库读取 242ms → 14~16ms；整库构建（含读+建快照）284~294ms → 约 53ms；每次构建的本地时间解析 4500 → 16 次；待办计数 29~48ms → 6~8ms（60 行样本）。
- **反向验证**：① `getWidgetStatNotes` 改回 `Note.fromMap` → WSR-06 实测 900 次解析，红；② `displayDayKey` 改回「先 `DateTime.parse` 再取字段」→ 300 条库 308 次惰性解析，红；③ 待办快路径的正确性由 TD-16 锁住（该用例只锁口径、不锁性能）。
- **未验证**：① 无真机，保存/删除后的帧时间与冷启动首帧未测，交 OPT-M01；② AOT 下时区查询的绝对耗时更小，收益比例会低于本机 JIT 数字；③ 标签排序为了复用 `rankTagsByUsage`，仍对**去重后的标签**解析 `DateTime`（几十次量级），没有改那个共享函数。
- **顺带登记**：OPT-04C——`Note.fromMap` 的 3 次本地时间解析是分页、搜索、统计共同的读取成本，改成惰性解析收益更大但影响面也更大，单独立项评估。
- **提交**：`34c7360`（代码 + 测试）。

## 现有架构

| 层次 | 当前职责 | 与本轮建议的关系 |
| --- | --- | --- |
| 启动与路由 | `main.dart` 准备主题、缓存及首屏快照，构造 `AppProvider` 和 `GoRouter`，接收 Android 通知、分享和深链 | 首屏依赖与外部事件导航可以独立调整 |
| 页面与状态 | `screens/`、`widgets/` 通过 Provider 读取状态。首页使用 `Selector` 订阅信息流，笔记、同步等状态已有 Store 和部分独立 helper | 沿用现有订阅和测试边界，收敛分页、缓存失效和跨服务编排 |
| 存储与领域服务 | SQLite 管理笔记及相关数据，偏好设置、媒体文件和桌面小组件快照有各自的存储路径。随机漫步与相关笔记共用按需创建的本地索引 | 明确全库查询、分页查询和派生索引各自的数据口径 |
| 外部集成 | Memos 处理笔记同步，WebDAV 有单独的备份同步引擎，本地 ZIP 另有导入导出链路。Android 原生通过 MethodChannel 对接 | 同步、备份和外部事件分别验证兼容性和失败恢复 |

入口可从 [应用启动](../../lib/main.dart#L144)、[首页订阅](../../lib/screens/home_screen.dart#L2156)、[SQLite 活跃笔记视图](../../lib/services/database_service.dart#L74)、[Memos 客户端](../../lib/services/memos_api_service_fixed.dart#L497) 和 [Android 通道注册](../../android/app/src/main/kotlin/com/didichou/inkpaper/MainActivity.kt#L53) 交叉查看。

## P1 · 先解决数据与列表正确性

### 1. Memos 分页完整性决定是否允许清理本地笔记

**现状。** Memos 0.22+ 有续页令牌时继续拉取，超出页数上限会返回 `isComplete=false`，HTTP 分页失败会抛错。不过，当某一页为空且仍返回 `nextPageToken` 时，循环会提前结束并保留 `isComplete=true`。首次拉取和手动同步都用该标志决定能否按远端 ID 剪枝。若前页有数据，未读取到的已同步笔记可能被当成服务端已删除。是否有真实服务器产生这种响应，本轮未验证。[分页退出条件](../../lib/services/memos_api_service_fixed.dart#L497) · [首次拉取剪枝](../../lib/providers/app_provider_sync.part.dart#L129) · [手动同步剪枝](../../lib/providers/app_provider_sync.part.dart#L350)

**建议。** 只有读取到正常终止页且清单解析成功时，才允许按缺失 ID 删除。续页令牌仍存在时继续读，重复令牌或达到限额时返回不完整，并明确区分全量、部分成功和失败。两条同步路径共用同一份完整性判定。将部分清单上的同正文副本归并与删除纳入同一检查，依据已有远端 ID、未同步编辑和软删除状态验证数据保留。大库还要检查剪枝 SQL 给每个 ID 绑定一个参数的规模，出现瓶颈时再评估集合表和反连接。[同正文副本处理](../../lib/providers/app_provider_sync.part.dart#L317) · [本地剪枝 SQL](../../lib/services/database_service.dart#L990)

**验收。** 模拟第 2 页失败、空页仍有令牌、令牌重复、分页上限以及完整清单中的真实远端删除。只有完整清单可触发按缺失 ID 剪枝。另测完整空清单，目前数据库层对空 ID 集合直接返回，需要单独决定此时的同步产品规则。

### 2. 首页排序应和 SQLite 分页使用同一规则

**现状。** 首页首批和后续批次默认按 `createdAt DESC` 从 SQLite 每页读 50 条，再对已读列表应用置顶、最早创建、最近编辑等排序。一个创建于两年前但今天刚更新的笔记，切换到最近编辑时可能仍要翻页才能出现。老置顶笔记同理。SQL 使用 `OFFSET` 且创建时间没有第二排序键，分页期间数据增删或多条笔记时间相同时，有重复或漏读的风险。同步后还存在整库载入并把 `hasMoreData` 设为 false 的路径。[数据库分页](../../lib/services/database_service.dart#L723) · [首页初始查询](../../lib/providers/app_provider.dart#L1157) · [续页查询](../../lib/providers/app_provider.dart#L1228) · [置顶及排序比较器](../../lib/utils/note_sorting_helper.dart#L4) · [同步后列表更新](../../lib/providers/app_provider_sync.part.dart#L143)

**建议。** 把置顶优先、所选时间字段、稳定的 ID 并列顺序放进同一查询定义。先修首屏排序，再根据翻页和大库测量决定是否改为基于排序键的游标续页。切换排序、筛选或提交同步结果后刷新查询，并丢弃旧查询的迟到结果。同步成功后的首页也走同一分页入口。保留墓碑排除、归档和待删除过滤、首页静音标签补拉、媒体筛选口径。

**验收。** 用跨三页样本覆盖四种排序、深页置顶、相同时间戳、翻页中新增或删除、切换排序时旧查询仍在执行，以及同步前后的排序一致性。

**常驻内存。** 冷启动读 50 条，`loadNotesFromLocal()` 却会在导入等刷新场景全量回载，随后修复图片路径、重新提取标签。同步也有把全库写回首页状态的路径。收敛到统一分页查询后，刷新当前已浏览窗口，保持排序和滚动位置。把历史路径修复从普通刷新拆开，标签优先随变更笔记更新。测量同步和导入完成后保留的 `Note` 数量、Dart 堆和翻页帧时间，检查只加载首页时其他全库功能仍能读到完整语料。[本地全量刷新](../../lib/providers/app_provider.dart#L1095) · [导入后刷新](../../lib/screens/local_backup_restore_screen.dart#L2053)

## P2 · 降低高频链路的重复工作

### 3. 让离线探索索引只随笔记语料变化失效

**现状。** 随机漫步和相关笔记共用按需构建的 Future，索引构建已经放进 `compute`，首页纯续页也已有专用通知路径。仍有排序切换经通用通知将索引置空。下次探索会重新查全库并把结果转成完整 `Note`，再交给后台 isolate 建索引。排序属于列表视图状态，现有索引读取语料的可见性和正文规则与首页排序无关。[缓存失效](../../lib/providers/app_provider.dart#L339) · [索引构建](../../lib/providers/app_provider.dart#L1538) · [完整模型读取](../../lib/services/database_service.dart#L714)

**建议。** 用语料版本标记正文、标签、关系、可见性和实际参与评分的其他字段。首页排序和普通状态通知只刷新对应界面。若冷建耗时较高，进一步用索引所需字段和媒体存在标志构建轻量记录，点击命中项时再读完整笔记。沿用当前离线评分和跳转理由。

**验收。** 相同语料切换排序、翻页后仍命中原索引。编辑、删除、恢复及同步提交后命中结果及时更新。记录冷建、热命中时延与峰值内存。

**索引体积与查询开销。** 索引会保留每篇笔记的规范化正文、词集合，以及按词组织的倒排词频。相关笔记的候选打分和排序由调用方同步执行。优先比较轻量语料和紧凑词表的效果。当前已只为入选条目提取正文理由，可进一步评估批量读取这些条目的正文，省去索引常驻的正文副本，同时测量增加的查询延迟。若查询仍影响帧时间，可让常驻后台 isolate 持有索引并返回少量结果。[索引结构](../../lib/services/random_walk_index.dart#L29) · [入选条目的理由](../../lib/services/random_walk_index.dart#L247) · [相关笔记调用](../../lib/widgets/note_actions_ui.dart#L543)

### 4. 缩减桌面小组件更新时的全库读取

**现状。** 小组件快照已有延后执行、调度代号去重和失败回退。调度真正开始后仍读取全库、构造完整笔记，并从中生成快照及持久化首屏快照。较大的库可能在保存、删除或启动后产生一轮集中工作，延后只能移动这轮工作的时间。[快照调度与读取](../../lib/providers/app_provider.dart#L215) · [小组件生成与序列化](../../lib/services/widget_snapshot_service.dart#L21)

**建议。** 分别确认首屏快照、小组件统计和回顾各自需要的字段和集合。有限结果用专用查询，整库统计优先读轻量字段。只有状态变化时复用统计数据。待办解析或序列化仍占据 UI isolate 时，再评估迁移纯计算部分。

**验收。** 对连续编辑、批量删除和冷启动记录读取行数及 UI 帧时间。核对小组件待办计数、回顾范围、同步状态和首屏快照的更新结果。

### 5. 先测搜索结果规模，再选择本地索引

**现状。** 首页已有 240ms 防抖和请求序号，旧结果不会覆盖新输入。数据库仍执行正文或标签的前后通配匹配，一次返回全部命中并解码完整笔记。短查询在较大的库里可能同时放大查找和结果装载成本。[首页搜索防抖](../../lib/screens/home_screen.dart#L374) · [SQLite 搜索](../../lib/services/database_service.dart#L1023)

**建议。** 先对真实规模的脱敏样本查看查询计划，分开测 SQL 用时、结果装载和 UI 首批呈现。结果过多时优先分批交付，保留完整结果的浏览能力。只有扫描本身占主导再比较 FTS 与本地字词索引，验证中文短词、正文子串、标签、大小写及 `%`、`_` 等输入的现行或预期语义。保留 SQLite 后备路径以覆盖旧库迁移或重建期间。

### 6. 分开处理启动关键路径和外部事件就绪

**现状。** 日期和媒体缓存的准备已并行发起，但四项 await 结束后才启动首屏快照与配置读取。缩略图准备可能枚举磁盘目录，因此缓存较大时可能拉长首帧前的等待。通知、分享、深链的冷启动载荷在 `runApp` 后异步探测，路由触发仍依赖固定时间等待。[启动等待顺序](../../lib/main.dart#L223) · [缩略图目录扫描](../../lib/utils/thumb_cache.dart#L220) · [冷启动事件处理](../../lib/main.dart#L436)

**建议。** 将首屏快照和主题语言配置读取提前到可并行阶段。逐项标注缓存依赖，只有能保证首次访问安全的准备任务才移到首帧后。提取一个外部事件入口，在路由和目标功能明确就绪时交付待处理事件，验证同一事件从初始载荷与运行回调抵达时只消费一次。

**验收。** 记录普通入口首帧和首屏可交互时间，覆盖冷启动、热启动、空缓存和大缓存。分别测从通知、分享、深链启动及已打开时的导航，检查主题语言无闪变、提醒取消和分享内容交接。

### 7. 控制图片解码和本地备份的峰值内存

**图片缓存。** 常规缩略图路径已有后台编解码，并只取动图首帧。仍会先解码原图再按目标宽度缩放，特别长的竖图可能产生较大的解码缓冲或输出尺寸。先用高像素照片、长截图和多张并发生成复测内存，再考虑宽高或总像素限制，以及系统抽样解码。保持方向、透明度、动图首帧及现有磁盘命中行为。[缩略图编码](../../lib/utils/thumb_cache.dart#L914)

**查看器与内存预算。** Flutter 解码图片缓存配置为 300 MiB 上限。查看器会延迟预取一张相邻图，当前图片组件也会在销毁时驱逐自己的 provider。审查相邻高清预取是否和当前大图使用同一个保留范围，能否在跳离窗口或退出时释放查看器持有的条目。列表和详情继续复用现有缩略图档位。以连续翻图、退出后的内存回落、回看同图时的解码次数一起判断预算是否合理。[全局图片缓存](../../lib/main.dart#L232) · [相邻图片预取](../../lib/screens/image_viewer_screen.dart#L1052) · [当前图片释放](../../lib/screens/image_viewer_screen.dart#L1453)

**备份导出。** 本地 ZIP 逐个把资源读为字节并整包编码，已有单段和累计视频上限。图片规模和压缩输出仍能推高峰值。优先验证当前备份格式能否用流式文件读写完成，并保持历史 ZIP 可恢复。若加密分支仍要求整包字节，单独测它的内存开销和兼容性。[视频大小约束](../../lib/services/backup_archive_service.dart#L144) · [资源读取](../../lib/services/backup_archive_service.dart#L215) · [整包编码](../../lib/services/backup_archive_service.dart#L382)

**备份导入。** 当前解包服务先把资源写入本地，再由页面调用对应的笔记导入。笔记导入失败时，这条路径可能留下未被引用的新文件。建议明确暂存资源和提交笔记的顺序，并使失败清理只接触本次新增资源。成功、重试与中断测试分别核对笔记、附件路径和已有文件。[解包与资源恢复](../../lib/services/backup_archive_service.dart#L536) · [资源写入](../../lib/services/backup_archive_service.dart#L709) · [笔记导入](../../lib/screens/local_backup_restore_screen.dart#L2000)

## P3 · 随下一轮功能改动收敛结构

### 8. 保留现有状态管理，提取可独立验证的动作

**状态和同步。** `app_provider.dart` 约 4900 行，已经使用 Store、分页 helper 和同步 part 拆出部分职责。优先把首页查询状态和同步应用阶段进一步收敛到各自的可测试入口。两条 Memos 拉取入口共享远端清单读取及写库边界，再为各自的上传、冲突和展示策略保留差异。要测试同步中途失败与本地并行编辑，并核对置顶、引用和未同步编辑在重试后仍保留。[应用状态和分页](../../lib/providers/app_provider.dart#L1157) · [同步合并](../../lib/providers/app_provider_sync.part.dart#L285)

**页面与数据。** AI 洞察、首页标签、随机回顾等都有从页面直接读全库的路径，AI 问答已有专用快照入口。先明确每条读取语义，特别是时间区间、归档、待删除及读取失败后是否允许使用部分样本。给复用度高的语料获取建立明确入口，页面负责交互与展示。备份页面后续只在动到导入流程时提取工作流，减少一处页面同时维护多格式导入、资源恢复、历史和错误反馈的成本。[AI 洞察读取](../../lib/screens/ai_insight_screen.dart#L138) · [全库快照](../../lib/providers/app_provider.dart#L1525) · [备份导入分派](../../lib/screens/local_backup_restore_screen.dart#L2084)

**原生桥接。** `MainActivity` 注册通用桥接和单独的缩略图通道。处理第 6 项时可将外部事件的解析、待交付状态和消费逻辑拆到单一组件，沿用现有通道名、事件参数和 Android 生命周期入口。其余原生功能按实际改动再拆。[Android 桥接入口](../../android/app/src/main/kotlin/com/didichou/inkpaper/MainActivity.kt#L23)

## 首页预览与引用保存专项

### 9. 缩短短预览缓存保留的正文

默认预览解析上限为 2400 字符，但缓存键仍使用整篇正文，缓存最多 400 条。长笔记的卡片销毁后，缓存仍可能持有原文。可用笔记 ID、随正文改变的版本和解析模式定位笔记预览，给没有笔记 ID 的调用方保留适用的键策略。再根据预览文本和样式区间的大小控制预算。卡片构建还会分别提取图片与视频，可以合并为一次媒体提取。用长文滚动、编辑后返回列表、全文展开和搜索高亮确认缓存命中率与显示正确性。[解析上限](../../lib/utils/note_preview_builder.dart#L91) · [缓存键和淘汰](../../lib/utils/note_preview_builder.dart#L627) · [卡片媒体提取](../../lib/widgets/note_card.dart#L139)

### 10. 笔记引用优先按 ID 查找

纯文字保存已有跳过引用处理的判断。有引用时，现有更新路径会读取全库，为每个引用分别尝试 ID、正文和正文前缀匹配。让明确的 ID 走批量查询，只对无法按 ID 解析的引用进入历史兼容路径。对照旧笔记测试相同前缀、移除最后一个引用、双向关系和被删除目标。比较单次保存的查询行数、耗时和帧时间。[保存时的引用判断](../../lib/providers/app_provider.dart#L4091) · [引用更新](../../lib/services/unified_reference_manager.dart#L288)

## 下一轮深入审查

| 优先级 | 审查方向 | 要回答的问题与取证方式 |
| --- | --- | --- |
| 高 | **并发任务是否在同一时段争用 CPU、内存和 I/O** | 把启动时的首屏工作、缩略图补齐、小组件刷新、同步和索引构建放到同一张时间线上。复现冷启动后立即滚动、同步时保存、同步后立即探索。记录任务重叠、队列等待及页面离开后仍继续执行的工作，再决定需要合并、延后或降低并发的任务。[缩略图补齐调度](../../lib/main.dart#L493) · [小组件调度](../../lib/providers/app_provider.dart#L215) · [探索索引任务](../../lib/providers/app_provider.dart#L1540) |
| 高 | **大库成本集中在哪里** | 对分页、搜索、标签和同步分别统计 SQL 耗时、查询行数、Dart 模型解码和后续排序。查看真实数据分布下的查询计划，验证同一索引是否覆盖查询与排序。同步另外记录下载、解析、去重、写库和回载的阶段峰值，观察全量清单与本地副本是否同时驻留。[SQLite 分页](../../lib/services/database_service.dart#L723) · [搜索 SQL](../../lib/services/database_service.dart#L1023) · [同步合并](../../lib/providers/app_provider_sync.part.dart#L285) |
| 高 | **媒体页面来回打开后资源是否回落** | 循环进出首页、详情、图册和播放器，再切前后台。分开记录 Flutter 图片缓存、Dart 堆、进程内存和播放控制器等资源，核对预取、监听器、计时器与控制器的释放。若峰值随后回落，继续测解码并发；若每轮稳定值持续抬升，再追踪持有对象和原生资源。[图册预取](../../lib/screens/image_viewer_screen.dart#L1052) · [播放器释放](../../lib/screens/video_player_screen.dart#L93) |
| 按使用场景 | **长内容编辑和 AI 输出是否挤占交互帧** | 对长文带图、连续输入、切后台保存和长时间 AI 输出分别计时，记录草稿序列化次数、输出通知次数、文本布局时间和自动滚动次数。对照纯文字短笔记，定位输入、写盘、渲染或滚动中的主要成本。[草稿落盘](../../lib/widgets/note_editor.dart#L427) · [AI 实时输出](../../lib/widgets/insight_live_output.dart#L14) |

上表是后续取证方向。执行项以文首队列为准，普通代码轮使用对应用例和可复现的本地验证。

## 常规验证入口

优先使用 [分页状态测试](../../test/unit/notes_pagination_helper_test.dart)、[同步合并测试](../../test/unit/sync_merge_helper_test.dart)、[随机漫步测试](../../test/unit/random_walk_index_test.dart) 和 [备份归档测试](../../test/unit/backup_archive_service_test.dart)。按本轮改动选择验证入口，缺少回归覆盖时为关键行为补用例。

## P4 · 暂缓

### OPT-M01 · 校准测量

等前面的优化项确认范围和实施顺序，由用户启用。届时选择可复现的优化前提交和优化后提交，在同一台安卓真机、同一份脱敏样本、同一刷新率和网络条件下对照。当前性能服务的 `_getMemoryUsage()` 固定返回 150 MiB，性能面板读取该服务的报告。使用 DevTools 和 Android 进程统计建立对照基线。[内存指标实现](../../lib/services/performance_monitor_service.dart#L320) · [性能面板](../../lib/screens/performance_dashboard_screen.dart#L30)

1. 使用测试真机运行 `flutter run --profile -d <设备ID>`。在 DevTools **Performance** 录制 UI、Raster 帧耗时和慢帧，在 **Memory** 记录 Dart 堆和 RSS 走势。[Flutter Performance](https://docs.flutter.dev/tools/devtools/performance) · [Flutter Memory](https://docs.flutter.dev/tools/devtools/memory)
2. 在操作前后运行 `adb shell dumpsys meminfo com.didichou.inkpaper`，记录 `TOTAL PSS`。内存取操作前、最高采样值和退出后固定等待时间的稳定值。内存快照只描述取样时刻，操作期间的走势以连续采样为准。[Android dumpsys](https://developer.android.com/tools/dumpsys)
3. 每个场景先重复 5 次，分别记录首次进入和再次进入，用中位数及波动范围描述操作延迟。逐帧数据有足够样本时记录 P95。保留构建提交、样本规模、录制文件和原始记录。

| 场景 | 固定操作 | 重点 |
| --- | --- | --- |
| 同步后翻页 | 同步同一份笔记库，完成后连续翻三页 | Dart 堆、常驻笔记数、慢帧 |
| 连续查看大图 | 按固定顺序查看同一组照片和长截图，退出等 10 秒再打开 | RSS 最高采样值和回落、回看耗时 |
| 首次进入随机漫步 | 重启应用后进入漫步，等候选呈现，退出后再次进入 | 首次与再次查询耗时、索引构建峰值、退出后的常驻内存 |

## P4 · Rust 可选优化

两项均排在现有优化之后。先完成对应的 Dart 优化并取得真机基线，仍有明确瓶颈时再做独立原型。是否纳入正式构建，取决于端到端收益、功能兼容性，以及原生构建和维护成本。

### 11. 随机漫步与相关笔记的 Rust 索引

- **适用条件。** 轻量语料、精确失效和后台查询完成后，大库的索引冷建、打分延迟或常驻内存仍超出目标。
- **原型范围。** 将分词、索引构建和候选打分封装到 Rust 模块，通过同一查询接口与 Dart 实现切换。按批传入轻量语料，查询返回少量结果。测量跨语言传输开销和索引释放，避免两边同时长期持有全库索引。[共享索引入口](../../lib/providers/app_provider.dart#L1540) · [索引与评分](../../lib/services/random_walk_index.dart#L29)
- **验收。** 同一批笔记对比冷建时间、点击至结果的 P95、进程峰值与常驻内存。核对中文匹配、候选排序、跳转理由和已走路径的排除规则。

### 12. 本地 ZIP 备份的 Rust 流式归档

- **适用条件。** 先验证 Dart 流式读写。若现有库难以兼顾旧备份兼容和内存预算，或优化后的归档阶段仍占主要成本，再评估 Rust。
- **原型范围。** 用文件路径作为输入输出，流式处理 ZIP 打包和解包，跨语言边界传递进度及结果。沿用现有备份清单、资源路径映射和导入流程。加密封装的耗时与峰值单独测量。[备份编码](../../lib/services/backup_archive_service.dart#L382) · [备份解包](../../lib/services/backup_archive_service.dart#L536)
- **验收。** 对比同一批文本、长截图和视频的导出及恢复耗时、进程峰值内存。用历史 ZIP、新包往返、加密备份和解包失败场景验证兼容性、附件完整性和暂存清理。

## P4 · 最后 · Memos 功能优化

### 13. 评估从双向同步转为单向导入

任务 `OPT-MEMOS`，状态`暂缓`。目标是评估将 Memos 收敛为导入来源。导入完成后，InkPaper 管理本地笔记、附件和引用。用户确认产品方向、现有账户过渡方式和导入范围后才启动。

#### 现有耦合与受影响的模块

| 模块 | 当前设计 | 导入模式下的评估方向 |
| --- | --- | --- |
| 登录、配置与启动 | 账号状态和凭据决定应用进入本地或在线模式。自动登录会创建 API 和资源服务、切到在线模式并启动自动同步。退出登录支持保留本地数据库，也有清空数据选项。[自动登录](../../lib/providers/app_provider_account.part.dart#L177) · [退出登录](../../lib/providers/app_provider.dart#L2736) | 将服务器地址和凭据收敛到导入或迁移流程。接入 Memos 的动作只建立读取会话，保留本地笔记的读写模式。迁移完成后明确凭据保留与清理行为。 |
| Memos API 与版本适配 | API 服务探测服务器版本，再决定鉴权、笔记接口和分页方式。读、写、删除及附件上传共用同一集成边界。[API 版本探测](../../lib/services/memos_api_service_fixed.dart#L78) · [列表读取](../../lib/services/memos_api_service_fixed.dart#L497) · [附件接口](../../lib/services/memos_resource_service.dart#L30) | 保留导入所需的地址解析、鉴权、分页读取、附件下载和错误提示。远端写入能力的退役等迁移完成后单独决策。 |
| 笔记读写、重试与删除 | 启动和首页刷新可触发远端拉取，定时任务补交本地变更。保存按 `remoteId` 选择创建或更新，删除可提交到远端。同步完整性还影响按远端 ID 清理本地笔记。[首页刷新](../../lib/screens/home_screen.dart#L719) · [上传逻辑](../../lib/providers/app_provider.dart#L1617) · [删除分支](../../lib/providers/app_provider.dart#L3413) · [自动同步](../../lib/providers/app_provider.dart#L3920) · [本地剪枝](../../lib/providers/app_provider_sync.part.dart#L350) | 导入走单独的读取与提交入口，日常新增、编辑、置顶和删除走本地链路。重复导入保留本地编辑，远端清单缺失、删除或顺序变化均不触发本机剪枝。 |
| 本地模型、ID 与引用 | `Note` 和 SQLite 保存远端 ID、同步标记、附件、引用和可见性等信息。同步合并兼容旧版远端 UID 作为本地主键，重映射引用关系，并处理本地待提交编辑。补交操作也持久化在库里。[笔记模型](../../lib/models/note_model.dart#L14) · [库结构与软删除](../../lib/services/database_service.dart#L68) · [ID 与引用映射](../../lib/utils/sync_merge_helper.dart#L8) | 为导入来源建立可重复识别的映射，至少区分来源服务器或账号和远端笔记 ID。先确定本地 ID，再重建导入批次的引用。复用老用户已有映射，保留本地待提交编辑。旧同步字段和队列清理须先核对历史库、WebDAV 和本地功能用途。 |
| 编辑器、图片与视频 | 在线模式下，选图和选视频会触发后台上传。九宫格、图片查看器和播放器有按服务器地址及凭据读取远端资源的分支。现有「附件本地化」会缓存文件，正文仍保留原服务端路径。[编辑器上传](../../lib/widgets/note_editor.dart#L675) · [九宫格资源](../../lib/widgets/note_image_grid.dart#L362) · [视频资源](../../lib/screens/video_player_screen.dart#L140) · [附件本地化](../../lib/services/attachment_maintenance_service.dart#L90) | 迁移时将成功下载的附件保存到应用管理的文件目录，同步更新正文和附件元数据中的路径。复用磁盘已有副本前核对归属和文件完整性。下载失败应报告并允许重试。 |
| 设置、账号入口与分享 | 设置和引导提供账号与多端同步入口。复制 Memos 分享链接需要服务器地址，私有笔记生成公开链接还可能更新远端可见性。[设置入口](../../lib/screens/settings_screen.dart#L99) · [引导说明](../../lib/screens/onboarding_screen.dart#L48) · [链接生成](../../lib/widgets/note_actions_ui.dart#L364) · [公开操作](../../lib/widgets/note_actions_ui.dart#L481) | 增加「从 Memos 导入」入口，盘点账号页、引导、同步提示和公开链接的去留。现有官方服务器用户也纳入过渡范围。保留应用自己的文本、图片或文件分享能力。 |
| 备份、恢复与本地 Markdown | 本地 ZIP 根据可解析的路径打包媒体，缺失资源单独统计。WebDAV 合并使用 `remoteId`、本地 ID 和内容指纹匹配。预览与随机漫步也复用部分 Memos 命名的 Markdown、媒体解析工具。[本地归档](../../lib/services/backup_archive_service.dart#L190) · [WebDAV 合并](../../lib/services/webdav_sync_engine.dart#L414) · [卡片预览](../../lib/utils/note_preview_builder.dart#L111) · [漫步正文处理](../../lib/services/random_walk_index.dart#L123) | 先验证历史备份往返和恢复去重。Markdown、附件识别及本地引用属于现有本地能力，应随行为回归验证。可把通用解析单独提取，避免跟随同步集成一起删除。 |

#### 可独立验收的实施步骤

1. **新增只读导入。** 读取并展示范围，支持分页拉取、来源识别、本地落库和附件下载。明确归档笔记等状态的导入口径。输出新增、跳过和失败清单。用同一来源重复导入、同 ID 的不同来源、分页中断、缺失附件等样本验证。远端变更如何重新导入需先确认产品规则。
2. **提供现有用户迁移。** 从当前库和同步状态盘点尚未上传的笔记、远端独有记录、附件和引用。保留本地待提交编辑，验证能离线打开成功迁移的笔记和附件。迁移前后核对本地 ID、数量、时间、标签、置顶、提醒和引用。用历史 ZIP 与 WebDAV 恢复测试回退。
3. **逐步退役双向同步。** 根据迁移验证结果，由用户决定旧账号入口和远端写入的退役范围。覆盖断网后的编辑、删除、全文搜索、随机漫步和备份。现有同步继续使用期间，`OPT-01` 的分页保护照常推进，`OPT-08` 中的双向同步扩展留待本专项产品决策。
