# InkPaper 工程优化审查

审查日期 2026-11-23。初始代码基线 `89e2728`，应用版本 `1.1.143+10243`。本文基于源码静态审查，覆盖 Flutter 首页、启动、笔记存储、同步、搜索、离线探索、媒体缓存、导入导出和 Android 桥接。每轮执行以当前工作区为准，性能收益待真机校准。

## 交接卡片

新会话先读本节，再按[执行队列](#执行队列)领取任务。本节每轮**整块覆盖**，只描述当下状态；逐轮历史见下文「推进记录」，取舍细节见对应记录条目。

| 项目 | 当前状态 |
| --- | --- |
| 最后更新 | 2026-11-24 · 本项代码 `42d6139`（用例加固 `37d9729`），记录随本笔 · 应用版本 `1.1.143+10243`（未升版本、未推送、未装机） |
| 本轮任务 | OPT-07B-3（P3 · §7 本地备份：加解密不再连续占住 UI isolate） |
| 任务状态 | 待复验 |
| 可复查改动 | ① KDF 挪到后台 isolate（顶层 `_pbkdf2KeyBytes`，闭包只捕获密码、salt 与迭代次数，不拖 `Random.secure()`）；② `encryptToBytes` / `decrypt` 变 `Future`，页面加 `await`；③ AES 与 MAC 分块推进时**按时间**让出事件循环（16ms 一帧），不按字节硬切；④ 解密侧新增 `_streamCbcDecrypt`：`CBCBlockCipher` + 手写去 PKCS7 换掉只能整段算的 `PaddedBlockCipherImpl.process`，输出写进预分配缓冲；⑤ `looksEncrypted` 改前缀探测（512 字节），认不出但确实含该键时退回整段解析；⑥ 顺带 `37d9729`：查看器用例 `tearDown` 容忍临时目录被占用 |
| 验证结果 | `analyze`（lib+test）→ No issues found；`format` 327 文件 0 changed；`flutter test --concurrency=4` 全量 **1172 项全过**（原 1169 + 3），修复清理竞态后全量连跑两次全绿（4:04 / 4:01，widget 目录另跑两次 2:08 / 1:37）。主 isolate 最长不可用时长（本机 JIT，自驱异步转轮，40MB 明文）：加密 **2393ms → 73~80ms**，解密 **1972ms → 371~400ms**；耗时只多约 7%（加密 3379 → 3615ms）。KDF 单独量：100000 次 848ms，占满期间 50ms 定时器 **0 次**触发，挪进 isolate 后 **16 次**；`Isolate.run` 每次约 2ms，连开三次峰值内存无增长。解密峰值（独立进程）**+187MB**（上轮 +185MB，同量级）。输出仍逐字节相同。反向验证三项：KDF 改回同步 → ENC-10/11 `Actual: <0>`；永不让出 → 最长停顿回到 2393ms / 1972ms（探针）；去掉整段回退 → ENC-12 红 |
| 未验证 / 待测 | 解密仍有一次**整段信封解码**：`utf8.decode`（56MB 字符串）+ `jsonDecode` + `base64Decode`，40MB 包实测约 0.4s 停顿与 +187MB 峰值，登记 OPT-07B-4；真机未测（AOT 下 PBKDF2 与 AES 吞吐、isolate 启动开销都可能与桌面不同）；交付仍需一份 `Uint8List`；页面编排（FilePicker → 解密 → 解包）仍无 widget 测试；`iterations` 取自文件且没有上限，畸形包可让后台 isolate 长期占用（非真实威胁模型，未加） |
| 下一项 | OPT-07B-4（信封整段解码：按字节扫描 / 分块 base64 / 二进制信封 v3）；OPT-02B / OPT-10B 等各自前置复验 |
| 待用户决策 | ① OPT-01B 的远端归档、本地同内容副本与完整空清单处理规则；② `OPT-M01` / `OPT-R01` / `OPT-R02` / `OPT-MEMOS` 保持暂缓 |
| 工作区注意事项 | 另有未提交的 `docs/README.md` 索引链接、`dist/`、`.model-desk/`，均非本轮产物，勿回退或顺手带上。发版、推送、装机需单独授权 |

## 执行队列

按表中顺序领取一项`待办`，先重查正文里的证据，再实现该行的最小范围。详情编号用于定位设计与回归要求，任务 ID 用于交接。遇到`待验收`或`阻塞`项先检查它是否影响后续任务，独立项可继续。

| 任务 | 优先级 | 状态 | 详情 | 本轮交付与验收 |
| --- | --- | --- | --- | --- |
| OPT-01 | P1 | 已验收 | §1 Memos 分页 | 空页续拉、重复令牌、失败和页数上限的处理通过。同步合并与剪枝的剩余边界转 OPT-01B。 |
| OPT-01B | P1 | 待评估 | §1 同步清单与本地身份 | 核对不完整清单下的同正文合并、归档行保护与完整空清单规则，验证本地 ID、引用和待提交编辑的保留。 |
| OPT-02A | P1 | 待验收 | §2 首页排序 | 返修完成（`022b36c`）：SQL 与 Dart 共用墙钟时间键，混合来源顺序一致。待复验混合样本、并列档、续页途中切换。 |
| OPT-02B | P1 | 待办 | §2 首页刷新 | 依赖 OPT-02A。同步和导入后刷新已浏览窗口，保留原有的全库读取入口，并覆盖过滤口径、浏览位置和翻页。 |
| OPT-03 | P2 | 已验收 | §3 探索索引 | 按写库版本复用，排序和续页复用同一语料索引。索引结构及后台查询调整另行评估。 |
| OPT-09A | P2 | 已验收 | §9 短预览缓存 | 解析前缀指纹、长短预览隔离与字符预算通过，OPT-09B 前置条件满足。 |
| OPT-09B | P2 | 待验收 | §9 卡片媒体提取 | 完成（`3196ab4`）：`extractNoteMediaPaths` 一次扫出图片与视频，卡片/详情页改用合并入口。待复验分类独立性、去重口径与扫描次数。 |
| OPT-10 | P2 | 待验收 | §10 笔记引用 | 返修完成（`6a068bb`）：回调只替换已加载 ID、续页按 id 去重、面板按 id 查库补标题。待复验深页样本、续页不重复与面板补查。 |
| OPT-10B | P2 | 待办 | §10 笔记引用 | 返修。依赖 OPT-10 复验。保留只存在于关系数据中的有效引用，批量更新只写关系字段并验证并发编辑场景。 |
| OPT-04 | P2 | 已验收 | §4 小组件 | 窄列读取、回顾按需判定、首屏快照限量读取通过。 |
| OPT-04B | P3 | 待验收 | §4 小组件 | 返修完成（`4b0699c`）：回顾范围恢复精确时刻，统计/置顶按挂钟键，坏时间串降级。待复验跨日边界、混存样本与坏数据。 |
| OPT-04C | P3 | 待评估 | §4 小组件 | `Note.fromMap` 每行解析 3 个本地 `DateTime`（本机约 45µs/次），是分页、搜索、统计共同的读取成本。评估把时间字段改成惰性解析的收益与风险。 |
| OPT-06A | P2 | 已验收 | §6 首屏 | 启动配置和首屏快照并发读取，首页无需等待远程功能开关。真实帧边界未保证。 |
| OPT-06C | P3 | 待验收 | §6 首屏 | 返修完成（`9c7baa7`）：扫描收尾与索引可信拆成两个状态，失败时保留 stat 兜底；补齐与磁盘记账按可信度分支。待复验半途失败样本、`clear()` 复位与首帧不等扫描。 |
| OPT-07A | P2 | 待验收 | §7 图片 | 缩略图解码规模已做（`9c4091b`）：>8MP 走引擎采样解码、输出高度上限 4096、两条路径共用尺寸口径。待复验大图内存、方向/透明度与长图边界。 |
| OPT-07A-2 | P2 | 待验收 | §7 图片 | 保留窗口已做（`b106ce5`）：当前页左右各留一张，窗口外与退出时 evict，预取按「窗口里谁没解」选边。待复验回看命中、窗口上限与退出释放。 |
| OPT-07B | P2 | 待验收 | §7 本地备份 | 导出已改流式落盘（`ca596f9`）：视频按 1MB 块 STORE 写入，组装阶段不再攒媒体与整包缓冲；失败删半成品。待复验峰值、历史包与重试。 |
| OPT-07B-2 | P2 | 待验收 | §7 本地备份 | 导出侧已做（`72f6c2f`）：加密改流式，40MB 明文峰值 +656MB → +40MB，输出与旧实现逐字节相同。待复验峰值回落、老包兼容与 200MB 外推；**剩余**：解密侧仍 3.3 份（要换二进制信封或流式 base64 解码）。 |
| OPT-07B-3 | P3 | 待验收 | §7 本地备份 | 已做（`42d6139`）：KDF 进后台 isolate、AES/MAC 按时间让出事件循环，40MB 包最长停顿 2393ms → 80ms（加密）/ 1972ms → 400ms（解密）。待复验真机卡顿、老包兼容与解密封信剩余部分。 |
| OPT-07B-4 | P2 | 待办 | §7 本地备份 | 信封解码仍整段：`decrypt` 对 53MB 信封做一次 `utf8.decode`（56MB 字符串）+ `jsonDecode` + `base64Decode`，40MB 包实测约 0.4s 瞬时停顿、+187MB 峰值，是整个加解密链路最后一块。评估按字节扫描 + 4 字符对齐分块 base64 解码，或二进制信封 v3（必须保持老包可解，靠 `ENC-01` 黄金样本咬住）。 |
| OPT-07C | P2 | 待验收 | §7 本地备份 | 导入回滚已做（`de6a0ad`）：解包记录本次新建的资源，导入失败或 0 条时只删这批，同毫秒重复导入不再覆盖。待复验失败/重试/中断三条路径与既有文件保护。 |
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
- **验证**：`dart analyze lib test` → No issues found；`dart tool/inkpaper.dart format` → 320 文件 0 changed；`flutter test --concurrency=4` → **1099 项全过**（原 1096 + 3）。
- **校准**（本机内存库、1500 条、每条约 20 行，**非真机**）：整库读取 242ms → 14~16ms；整库构建（含读+建快照）284~294ms → 约 53ms；每次构建的本地时间解析 4500 → 16 次；待办计数 29~48ms → 6~8ms（60 行样本）。
- **反向验证**：① `getWidgetStatNotes` 改回 `Note.fromMap` → WSR-06 实测 900 次解析，红；② `displayDayKey` 改回「先 `DateTime.parse` 再取字段」→ 300 条库 308 次惰性解析，红；③ 待办快路径的正确性由 TD-16 锁住（该用例只锁口径、不锁性能）。
- **未验证**：① 无真机，保存/删除后的帧时间与冷启动首帧未测，交 OPT-M01；② AOT 下时区查询的绝对耗时更小，收益比例会低于本机 JIT 数字；③ 标签排序为了复用 `rankTagsByUsage`，仍对**去重后的标签**解析 `DateTime`（几十次量级），没有改那个共享函数。
- **顺带登记**：OPT-04C——`Note.fromMap` 的 3 次本地时间解析是分页、搜索、统计共同的读取成本，改成惰性解析收益更大但影响面也更大，单独立项评估。
- **提交**：`34c7360`（代码 + 测试）。

### 2026-11-23 · OPT-06C · 待验收

- **问题核对**：OPT-06A 量出来的「缩略图索引仍在首帧前（5000 个文件 37ms，冷缓存更慢）」是本轮剩下的最后一项首帧等待。翻 `lib/utils/thumb_cache.dart`：`prepare()` 里真正必要的只有「拿到 cacheDir 并把目录建好」——写缩略图要用；扫目录只是把已有缩略图的名字读进 `_known`，作用是让 `lookup` 对未命中的名字不必 stat。也就是说这一项的代价不是「首帧出图正确性」，而是「省掉每次 lookup 的一次系统调用」：只要扫描窗口内 `lookup` 自己补一次 stat，正确性就能保住，扫描本身可以挪到首帧后。
- **改动**：
  - `lib/utils/thumb_cache.dart`：
    - `prepare()` / `_prepare()`：只等目录可用（`getTemporaryDirectory` + `create`，毫秒级），置好 `_dirPath` 后 `_startDiskIndex()` 发起扫描并立即返回；扫描体抽成 `_scanDisk()`，失败也只打日志（退化成「每张卡片 stat 一次」而不是没有缩略图）。
    - 新增 `_indexComplete` / `_indexFuture` / `indexReady`：`indexReady` 给「必须看到完整清单」的后台任务等，`lookup` 不依赖它。
    - `lookup()`：把「`_known` 里有 → stat 确认文件还在」扩成「`_known` 里没有但扫描未完成 → 也 stat 一次」，命中就补进 `_known`，之后走原来的快速路径；扫描完成后 `_indexComplete == true`，行为与改前完全一致（未知名字不 stat）。
    - `ensure()`：新增「扫描未完成且盘上已有同名缩略图 → 直接复用」分支，否则这一窗口里每个 `ensure` 都会把已有缩略图重新解码一遍。
    - `_pendingSources()`：补队列前 `await indexReady`。否则索引不完整时会把已经生成过的图全部排进队列（`ensure` 的 stat 兜底能防重编码，但白扫一遍目录）。
    - `_runDiskMaintenance()`：记账前 `await indexReady`。`_diskBytes` 按 `_known` 逐条 stat，索引没扫完就算漏，淘汰会算错。
    - `_clear()`：删目录前 `await indexReady`，否则正在跑的扫描会把刚删掉的名字又加回 `_known`；清完把 `_indexComplete` 置 true（空目录就是完整索引）。
    - `_prepare()`：`imagesDir` 被注入时跳过 `getApplicationDocumentsDirectory()`（测试不必再 mock path_provider，生产路径不变）。
    - 测试钩子：`debugSeed` 增加 `indexScanned`（模拟「扫描还没跑完」的首帧窗口），新增 `debugIndexComplete`。
  - `lib/utils/startup_essentials.dart`：只改注释——这一项现在等的是「目录可用」，索引扫描已经在首帧后，并说明靠 stat 兜底保住首帧出图。
  - 未改动：`_known` 的数据结构（内存占用与改前一致，同一个 `Set<String>`，只是晚几十毫秒填满）、两档宽度与编码路径、原生解码、`_giveUp`、补齐节奏（3 秒延迟 + 张间让路 + 低优先级槽）、`prepare()` 的对外签名与「已就绪时直接返回」的幂等语义。
- **测试**：`test/unit/thumb_cache_test.dart` 24 → 29 条。TC-22 `prepare` 后 `debugIndexComplete` 必须还是 false、此时 `lookup` 仍能命中已有缩略图、`await indexReady` 后索引补齐（`knownCount == 1`）；TC-23 窗口内兜底命中会补进索引、没有文件的名字不入索引（用 `lookupHits`/`lookupMisses` 增量断言）；TC-24 窗口内 `ensure` 复用盘上文件，编码次数 0；TC-25 索引完成后对未知名字**不再** stat 兜底（漏掉这个闸门就会每次 miss 白付一次系统调用）；TC-26 `prepare` 后立刻 `startBackfill`，只补缺的那张、不重编码已有缩略图。
- **验证**：`dart tool/inkpaper.dart analyze` → No issues found；`dart tool/inkpaper.dart format` → 320 文件 0 changed；`flutter test --concurrency=4` → **1104 项全过**（原 1099 + 5）。
- **反向验证**：① 把 `lookup` 的兜底闸门改回 `if (indexed)` → TC-22、TC-23 变红（TC-24 仍过，说明 `ensure` 那条兜底是独立生效的第二道门）；② 把 `prepare` 改回 `await _scanDisk(...)` → TC-22 的「扫描还在后台」断言变红，其余 4 条照过。恢复后全绿。
- **量级校准**（本机、临时目录、**非真机**、热页缓存，两轮取值）：5000 个缩略图时 `prepare` **6.5ms / 4.0ms**（改前等于这两项之和再等完扫描），扫描本身 **58ms / 55ms** → 首帧前少等约 55ms；扫描窗口内命中一次 `lookup` **55.7~71.1µs**（多一次 stat + 一次 Set 插入），索引完成后 **36.6~42.2µs**。按首屏可见十几张图估算，窗口期额外成本 0.2~0.5ms。冷缓存下扫描更慢（OPT-06A 记录的 37ms 是同一套合成脚本的另一组取值），收益更大。
- **行为变化**：首帧前不再等目录扫描；`knownCount` 在扫描完成前偏小（仅诊断用，当前无生产读取点）；扫描完成后一切与改前一致。扫描窗口内若某张缩略图在盘上但不在索引里，会多一次 stat 并收进索引——这是有意的。
- **未验证**：① 无真机，首帧/可交互时间、冷缓存扫描耗时、滚动帧时间均未测，交 OPT-M01；② 真机 cacheDir 在 `/data/user/0/com.didichou.inkpaper/cache`，stat 走系统调用、比本机热页缓存慢，窗口内成本需实机确认；③ 索引内存与改前一致，但「扫描推迟到首帧后」意味着它与首屏解码有几十毫秒的重叠，是否会争 I/O 未测（扫描是顺序 list，量级远小于图片解码）。
- **建议下一项**：OPT-07A（§7 图片，约束缩略图像素与查看器预取范围）。OPT-02B / OPT-09B / OPT-04B 等各自前置验收；OPT-04C / OPT-05 / OPT-06B / OPT-08 待评估。

### 2026-11-23 · 独立复验 · 5 项通过、5 项返修

审查基线 `9a81e8a`，覆盖 `89e2728` 之后登记为待验收的 10 个代码提交。独立通过项目测试入口 `dart tool/inkpaper.dart test` 运行工作区的完整测试套件，结果 **1104 项通过**。工作区原有启动页改动保留。本轮未开展真机或真实服务端验证。

| 已验收 | 提交 | 验收范围与剩余边界 |
| --- | --- | --- |
| OPT-01 | `a681d9a` | API 会在带令牌的空页继续拉取，重复令牌、页数上限及 HTTP 失败不能触发按缺失 ID 剪枝。两处同步仍可能对部分清单执行同正文副本删除，完整清单也可能把被过滤掉的归档行视为远端缺失。既有合并规则和完整空清单规则转 OPT-01B。[分页终止条件](../../lib/services/memos_api_service_fixed.dart#L547) · [部分清单下副本删除](../../lib/providers/app_provider_sync.part.dart#L349) · [本地剪枝](../../lib/services/database_service.dart#L1130) |
| OPT-03 | `b79b468` | 列表排序、续页和筛选无需作废索引，写库版本变化会构建新索引。当前按写库统一递增，精确到字段的失效可作为后续优化。[索引加载](../../lib/providers/app_provider.dart#L1613) · [版本缓存](../../lib/utils/revisioned_future_cache.dart#L31) |
| OPT-09A | `aa1772a` | 缓存键按安全截取的正文前缀计算指纹，长短预览隔离，驻留预算生效。卡片媒体提取进入 OPT-09B。[缓存键](../../lib/utils/note_preview_builder.dart#L733) |
| OPT-04 | `6a75cca` | 窄列读取、回顾抽样后才判定可见文字、首屏快照限量读取均可验收。后续 OPT-04B 引入的时间规则单独返修。[窄列与首屏查询](../../lib/services/database_service.dart#L784) |
| OPT-06A | `54e0242` | 快照、配置和各项准备并行，远程功能开关已从首页等待路径移出。`runApp` 后立即调用 `refreshRemote()`，尚无 Flutter 首帧回调约束，历史记录中的「首帧之后」应理解为首页不等待网络。真实时序和收益待 OPT-M01。[并行任务](../../lib/utils/startup_essentials.dart#L52) · [远端刷新调用](../../lib/main.dart#L514) |

| 返修项 | 提交 | 代码发现与复验条件 |
| --- | --- | --- |
| OPT-02A | `3dabf69` | **跨页排序口径仍不一致。** SQL 按时间字符串排序，Dart 按 `DateTime` 时间点排序。中国标准时间下独立复现：本地 `09:00` 与同日远端 `02:00Z` 同为未置顶，SQLite 把本地排前，Dart 把远端排前。两个来源分别由本地时钟和 Memos ISO 时间写入。用统一的时间比较键修复四种排序，补真实分页样本和快速切换测试。[双端排序规则](../../lib/utils/note_sorting_helper.dart#L13) · [写库时间格式](../../lib/models/note_model.dart#L410) |
| OPT-10 | `0f29b49` | **深页引用目标会重复出现。** 引用回调将尚未加载的目标直接追加到首页列表，下一次 SQL 续页仍会返回它。用首批 50 条引用第 51 条的样本验证续页，加载窗口只替换已存在的 ID，关系查询按数据库读取深页目标。[引用回调](../../lib/providers/app_provider.dart#L739) · [续页追加](../../lib/providers/app_provider.dart#L1295) |
| OPT-10B | `6cb4a2d` | **全库重建会重写无关字段和旧关系。** 批量提交把扫描时的整条笔记写回，期间的正文等更新可能被旧快照覆盖。由正文产生的关系集合还会清除只存在于同步关系数据里的有效关系，并把受影响行中仍存在的关系重新标为未同步。当前未找到生产调用点。接回入口前，按关系字段更新并先明确关系来源和保留规则。验证并发编辑、远端独有关系和已有同步标记。[重建及写回](../../lib/services/unified_reference_manager.dart#L465) · [整行更新](../../lib/services/database_service.dart#L1527) |
| OPT-04B | `34c7360` | **回顾范围由精确时间变成日期比较。** 在当天 18:00 请求最近 7 天时，7 天前 09:00 原本在范围外，现在会入选。字符串比较也无法在 UTC / 本地混存时等价替代原时间点排序和区间判断。用跨日、混合时间及旧数据样本核对统计和回顾，保持已确认的产品口径。[日期筛选](../../lib/services/random_review_selector_service.dart#L155) · [统计排序](../../lib/services/widget_snapshot_service.dart#L149) |
| OPT-06C | `0d2b531` | **扫描失败仍关闭未索引文件的磁盘兜底。** `_scanDisk` 捕获错误后在 `finally` 置 `_indexComplete=true`，未扫描到的已缓存缩略图随后会被当作未命中。区分扫描流程结束与索引完整，加入半途出错的回归用例。当前扫描在 `prepare()` 内即发起，验证时应记录「首帧无需等待扫描」这一实际保证。[扫描收尾](../../lib/utils/thumb_cache.dart#L267) · [查询兜底条件](../../lib/utils/thumb_cache.dart#L323) |

继续从 OPT-02A 开始返修。OPT-02B 与 OPT-10B 分别等待自己的前置项复验。OPT-09B 可独立领取。

### 2026-11-24 · OPT-02A 返修 · 待复验

- **问题核对**（复验给出的现象先复现再改）：库里时间有两种来源。本地新建写 `createdAt.toString()` → `2026-11-23T09:00:00.000`（本地时间、无后缀）；Memos 同步写服务端 ISO → `2026-11-23T02:00:00.000Z`（把北京时间当 UTC 存）。原来的 SQL 直接拿这一列比字符串，Dart 直接拿 `DateTime` 比绝对时刻：
  - SQL：`"…T09:00…" > "…T02:00…Z"` → 本地 09:00 在前；
  - Dart：`DateTime(2026,11,23,9)` = `01:00Z` < `DateTime.utc(...,2)` → 远端 02:00 在前。

  同两条笔记，首批（SQL）与切换排序后（内存重排）顺序相反。项目既有的显示口径是「字段值就是墙上时钟、一律不做时区换算」（`lib/utils/timestamp/note_timestamp_format.dart`），排序必须跟着这条口径走，否则与用户看到的时刻打架。
- **改动**（`lib/utils/note_sorting_helper.dart`）：
  - 新增 `noteTimeKeySql(column)` → `substr(replace($column, ' ', 'T'), 1, 23)`。三层含义都写在注释里：`substr(...,1,23)` 取到毫秒，`Z` 后缀不参与比较（它只是来源标记，不代表要换算时区）；微秒被截掉，因为 Dart 侧同样不比到微秒，否则同一瞬间两种精度的行会在两边排出不同顺序；`replace` 把老库里可能存在的 `DateTime.toString()` 空格写法归一成 `T`——空格是 0x20、`T` 是 0x54，同一时刻的两种写法在 SQL 里本来会排出先后。
  - 四种排序（`newest` / `oldest` / `updated` / `updatedOldest`）的时间级全部换成该表达式，置顶与 `id` 兜底两级不动。
  - 新增 `compareNoteWallClock(a, b)`：逐个比 `year / month / day / hour / minute / second / millisecond`，**不**比 `isUtc`、**不**换算时区；`noteComparator` 的时间级改用它。这样 `DateTime` 的绝对时刻差异不再影响结果，两个来源落在同一条坐标轴上。
  - 未改动：置顶恒在最前、并列时 `id` 兜底（倒序排序 `id DESC`、正序排序 `id ASC` 的镜像关系）、`sortedNotesCopy`、查询代数 `_notesQueryEpoch` 保护、仍用 `OFFSET` 取页（游标续页留待大库测量）。
  - 顺带覆盖到：`noteOrderBySql` 还被 `getNotesByMedia`（媒体筛选）用，媒体列表的排序口径与首页自动一致。
- **测试**：总数 1104 → **1117**（+13）。
  - `test/unit/notes_paging_sort_test.dart` 新增 `OPT-02A 返修 · 混合时间戳` 组 7 条：`SORT-MIX-01` 墙钟比较（本地 09:00 晚于同日远端 02:00、墙钟相同则相等）、四种排序各一条 `PGSORT-mixed-*`（pageSize 2 取满 8 条，跨页拼接必须逐位等于 `sortedNotesCopy`）、`PGSORT-mixed-order` 固定期望序列、`PGSORT-mixed-updated` 编辑时间混存（远端 `08:00Z` vs 本地 `10:00`，按绝对时刻会反过来）。样本里塞了一组「墙钟并列、来源不同、且 `id` 顺序与字符串里带不带 `Z` 相反」的 `mx-tie-a` / `mx-tie-b`——裸列比较会把带 `Z` 的排前面，墙钟键比较必须按 `id` 倒序让 `mx-tie-b` 在前；漏掉 `id` 兜底这组就会露馅。
  - `test/unit/note_sorting_helper_test.dart`：`SORT-09` 改成断言表达式形式，新增 `SORT-10`（时间键截到毫秒、空格归一、`compareNoteWallClock` 对 UTC/本地同墙钟返回 0、微秒不参与）。
  - `test/unit/home_sort_switch_test.dart`（新增）5 条，走真实 `AppProvider` + 内存库：`HSW-01` 首批混合来源顺序、`HSW-02` 不 await 第一次就连续切两次（先发起的那次整份丢弃）、`HSW-03` 连切四种、`HSW-04` 切到 `oldest` 后翻完三页与整库墙钟排序逐位一致、`HSW-05` 续页飞行途中切排序（旧偏移那页不能追加到新首屏后面）。
- **验证**：`dart tool/inkpaper.dart analyze` → No issues found；`dart tool/inkpaper.dart format` → 321 文件 0 changed；`flutter test --concurrency=4` → **1117 项全过**（复验基线 1104 + 13）。
- **反向验证**：① 把 `noteOrderBySql` 里的表达式换回裸列 → `PGSORT-mixed-*` 四条与 `PGSORT-mixed-order` 变红（Dart 侧不动，正好证明「两端不一致」就是原缺陷）；② 把 `noteComparator` 的时间级换回 `a.createdAt.compareTo(b.createdAt)` 这类绝对时刻比较 → `PGSORT-mixed-*` 与 `HSW-01` 变红。两次恢复后全绿，说明两组断言各自咬住一端。
- **行为变化**：混合来源下「排序顺序」与「界面显示的时刻」重新对齐（此前远端笔记在 `oldest` 排序里可能出现在比它显示更晚的位置）；纯本地库或纯 Memos 库的顺序不变（同一来源内两种比较等价）。`ORDER BY` 从裸列变成表达式，SQLite 无法用 `idx_notes_created_at` 走有序扫描，改走临时排序——这是本轮换来的代价，量级待 OPT-M01。
- **未验证**：① 无真机，切换排序的重建帧与滚动观感未测；② 大库（万条级）下临时排序的 SQL 耗时未测，要加 `(isPinned, createdAt, id)` / `(isPinned, updatedAt, id)` 组合索引需升 schema，按「不擅自动数据契约」留给校准后决定；③ 伪 UTC 的绝对时刻仍比真实时刻早 8 小时，只有排序/区间比较被本项拉回墙钟口径，`_parseTimestamp` 与 WebDAV 冲突判断没动；④ `loadNotesFromLocal()` 全量回载后把分页状态归零、滑到底会重复追加同页的既有问题仍未处理，属 OPT-02B。
- **建议下一项**：OPT-02B（本项复验通过后领取，接手时把上面 ④ 一并处理），或独立项 OPT-09B / OPT-10 返修；OPT-04B、OPT-06C 返修与本项无耦合。

### 2026-11-24 · OPT-09B · 待验收

- **问题核对**：`NoteCard` 每次 build 都要同时知道「图片有哪些」和「视频有哪些」（两者互斥，视频优先）。原来的做法是连调两次 `extractNoteImagePaths` / `extractNoteVideoPaths`，而这两个方法各自把 `note.content` 交给 `markdownMediaRegex` 跑一遍全量 `allMatches`，再各自过一遍 `resourceList`。同一篇正文的媒体正则因此被扫两遍——长笔记（几千字、二三十张图）在滚动时每帧都要付两次。详情页 `_renderImagePaths` / `_renderVideoPaths` 是同一形状。`OPT-09A` 已经把预览正文的重复解析收掉了，这一项是同一方向上剩下的最后一处。
- **改动**：
  - `lib/utils/memos_content_helper.dart`：
    - 新增 `extractNoteMediaPaths(Note) → NoteMediaPaths`：`resourceList` 单趟遍历，按 `isVideoResource` 分流进 images / videos；正文单趟 `markdownMediaRegex.allMatches`，按 `MediaPaths.isVideoMarkdown` 分流。结果顺序与旧实现逐项一致（先资源、后正文）。
    - 抽出 `resourcePathOf(resource)`：externalLink → `attachments/<name>/<filename>` → `/o/r/<uid>` 三级拼装，原来在 `_resourcePaths` 里写了一份，合并实现不能照抄第二份。
    - `_resourcePaths(resources, video:)` 改为「过滤 + 调 `resourcePathOf`」，行为不变。
    - 新增 `NoteMediaPaths`（`@immutable`，含 `empty` / `isEmpty` / `isNotEmpty`），放在同文件底部。
    - 图片与视频**各自**一个 `Set` 做去重，不共用：两者的「是不是同一个东西」是两套独立判断——一条资源声明为图片、正文却写成 `![视频](/o/r/x)` 时，图片列表和视频列表各保留一次，卡片据此走视频分支。共用集合会把它从视频列表里悄悄抹掉。
    - `extractNoteImagePaths` / `extractNoteVideoPaths` 保留，改为转发到合并入口（公开 API 不变，其余调用点无需改）。
    - 新增 `@visibleForTesting static int debugMarkdownMediaScanCount`：只靠耗时观察「合并了没有」太脆弱，计数能让断言直接咬住「一遍 vs 两遍」。
  - `lib/widgets/note_card.dart`：`imagePaths` / `videoPaths` 改为从一次 `extractNoteMediaPaths` 取。
  - `lib/screens/note_detail_screen.dart`：`_renderImagePaths` / `_renderVideoPaths` 同上。
  - 未改动：图片/视频互斥的渲染优先级（视频在前）、`NoteImageGrid` 的延后解码、`extractResourceImagePaths` / `extractMarkdownImagePaths` 等按单一类型取路径的公开方法（小组件快照与备份仍在用）。
- **测试**：1117 → **1123**（+6）。
  - `test/unit/media_paths_test.dart` 新增 `MC-04`（同一篇笔记带资源图、资源视频、正文图、正文视频，外加只在资源里出现的图：断言 images/videos 的具体顺序，且两个旧入口的返回值与合并结果逐项相同）、`MC-05`（资源说图片、正文按视频写 → 两个列表各保留一次，专咬「共用去重集合」这个回退）、`MC-06`（一次合并 = 扫描计数 1，两个旧入口各调一次 = 3）。
  - `test/widget_tests/note_card_media_test.dart`（新增）3 条，走真实 `NoteCard`：`NCM-01` 正文有视频 + 资源有图片时只出现 `NoteVideoCard`、不出现九宫格（合并不能把优先级弄反）、`NCM-02` 视频只来自 `resourceList` 时同样走视频分支（资源分类仍按 type/filename 判）、`NCM-03` 纯图片笔记不出现视频卡片。
- **验证**：`dart tool/inkpaper.dart analyze` → No issues found；`dart tool/inkpaper.dart format` → 322 文件 0 changed；`flutter test --concurrency=4` → **1123 项全过**。
- **反向验证**：① 把 `seenVideos` 指向 `seenImages`（两套分类共用去重集合）→ `MC-05` 变红；② 把正文改成「先调 `extractMarkdownImagePaths` 再调 `extractMarkdownVideoPaths`」两趟 → `MC-06` 变红（计数 3 而非 1）。两次恢复后全绿。
- **量级校准**（本机、临时脚本、单轮取值）：4359 字正文、31 张图、2 段视频。合并 **31.88µs**，分开两次 **61.55µs**，只取图片 **31.83µs**。即合并的代价等于「只扫一遍」，省掉的正是第二遍；首屏可见十几张卡片时按每张 30µs 估算省 0.3~0.5ms，滚动时每帧同理。
- **行为变化**：对外结果不变（顺序、去重、互斥优先级都保持）。唯一可观察差异是 `debugMarkdownMediaScanCount` 的推进次数。`NoteMediaPaths.images/videos` 与旧返回值一样是可变 `List`，没有改成不可变，避免给调用方制造 breaking change。
- **未验证**：① 无真机，卡片滚动的帧时间与重建次数未测，交 OPT-M01；② 校准只取了一轮，未做多轮统计；③ 正文正则本身没有优化（仍是全量 `allMatches`），只是从两遍降到一遍——若后续要再快，得换增量扫描或缓存 `matchCount`，属新项。
- **建议下一项**：OPT-02B（仍等 OPT-02A 复验）；可独立领取的是 OPT-04B / OPT-06C 返修、OPT-07A，或 OPT-10 返修。

### 2026-11-24 · OPT-10 返修 · 待复验

- **问题核对**（先复现再改）：`initializeApp()` 里注册的 `onNotesChanged` 对每条受影响的笔记做 `indexWhere`，找不到就 `_notesStore.notes.add(note)`。注释写的是「被引用的目标可能还没出现在当前这一页里」——动机合理（引用面板要显示对端标题），但代价被低估了：`notes` 是**分页窗口**，续页按 `OFFSET` 取，下一条 SQL 照样会返回这条，`addAll` 之后同一个 id 在列表里出现两次。复现样本是 120 条库里「首屏 50 条引用第 51 条」：回调后 `notes.length` 从 50 变 51，翻一页后 `r-69` 出现两次。
- **为什么不能靠「翻页前先查重」了事**：真正的问题不是重复本身，而是**把分页窗口当成缓存用**。窗口的第 i 个位置对应 SQL 的 OFFSET i，往中间或末尾插一条，后面所有位置都对不上——`hasMoreData` 的判定、`totalNotesCount` 的比较、乃至滚动位置都建立在「窗口 = 库的一个前缀」这个前提上。
- **改动**：
  - `lib/providers/app_provider.dart`：
    - 回调体抽成 `applyReferenceNoteChanges(List<Note>)`（生产注册直接用这个方法），改为**只按 id 就地替换**；不在窗口的只打一行 debug 日志，等翻页时从库里读到最新行。索引 `indexById` 一次建好，不再对每条改动各扫一遍列表（原实现是 O(m·n)）。
    - 新增 `getNotesByIds(List<String>)` 转发（服务层已按 900 一批处理 SQLite 变量上限），给面板按 id 取深页目标。
    - 续页 `addAll` 之前经 `filterUnloadedNotes` 过滤：万一有别的路径把某条提前插进窗口，这里也不会变成两张卡片，并打日志说明丢弃了几条。
  - `lib/utils/notes_pagination_helper.dart`：新增 `filterUnloadedNotes<T>(loaded, page, idOf)`——纯函数、泛型，便于直接单测，不必先造一个分页窗口。
  - `lib/widgets/references_sidebar.dart`：
    - 新增 `_deepTargets`（id → Note?，null 表示查过但没有）与 `_resolvingTargets`；`_targetIdOf` 统一「正向取 relatedMemoId、反向取 memoId」。
    - `_scheduleResolveTargets` 在 build 里收集窗口外的对端 id，用 `addPostFrameCallback` 推迟到本帧画完后调 `getNotesByIds`，回来 `setState` 换真实标题。同一批 id 只查一次。
    - `_buildReferenceCard` 的 `notes.firstWhere(..., orElse: 笔记未找到)` 换成 `_targetNote`：先查窗口、再查 `_deepTargets`，都没有时若仍在查就显示 `…`，查完确实没有才显示「笔记未找到」。
    - `didUpdateWidget` 里换笔记就清缓存，避免看上一条笔记的标题。
  - `lib/utils/thumb_cache.dart` + `test/widget_tests/note_editor_draft_image_test.dart`（独立提交 `79b38a9`）：新增 `debugSettle()`（等目录扫描、inflight 编码与磁盘维护），4 处 `addTearDown` 先等它再删临时目录。**理由是上一轮 OPT-06C 把扫描改成 fire-and-forget 后，后台 worker 更容易和 tearDown 抢文件**，全量跑时 `note_editor_draft_image_test` 偶发 `PathAccessException`（单跑必过）。这不是功能缺陷，是清理顺序问题，顺手修掉以免每轮全量都有红灯干扰判断。
  - 未改动：`UnifiedReferenceManager` 的关系写入逻辑（OPT-10B 的范围）、引用面板的筛选与布局、`rebuildAllReferences` 的「重建后只重查首屏」。
- **测试**：1123 → **1128**（+5）。
  - `test/unit/reference_deep_target_paging_test.dart`（新增）3 条：`OPT-10 引用深页目标不插进首屏，续页也不会出现同 id 两条`（120 条样本、首屏 50 条、目标是第 51 条 `r-69`；回调后仍是 50 条；翻页后 100 条且 `r-69` 只出现一次）、`窗口内的引用更新仍然就地生效`（不能因为去掉 `add` 把功能也去掉）、`深页目标可以按 id 取到`（面板补查的依据）。
  - `test/unit/notes_pagination_helper_test.dart` 新增 `PAGE-07`：重叠 / 不重叠 / 整页重叠三种输入下 `filterUnloadedNotes` 的返回。
  - `test/widget_tests/references_sidebar_test.dart`（新增）`RSB-01`：真实 `AppProvider` + 内存库 + 真 `ReferencesSidebar`，对端在深页时面板要显示「批量笔记 69」而不是「笔记未找到」，且窗口长度仍是 50。真库 IO 在 `testWidgets` 的 FakeAsync 里不推进，准备与等待都用 `tester.runAsync` 包住（第一次写成直接 `await` + `pumpAndSettle` 会卡死到被 SIGTERM）。
- **验证**：`dart tool/inkpaper.dart analyze` → No issues found；`dart tool/inkpaper.dart format` → 324 文件 0 changed；`flutter test --concurrency=4` → **1128 项全过**。第一轮全量曾红在 `note_editor_draft_image_test`（`PathAccessException`），单跑 9 条全过，加固清理顺序后连跑两次 + 全量均绿。
- **反向验证**：① 回调改回 `_notesStore.notes.add(note)` → 深页用例变红（`Expected: <50> / Actual: <51>`）；② 面板把 `_scheduleResolveTargets` 关掉 → `RSB-01` 变红（找不到「批量笔记 69」）；③ `PAGE-07` 直接覆盖去重函数，改动它的保留策略会立刻红。
- **行为变化**：引用涉及的深页目标不再出现在首页列表里（它本来就不该出现在窗口的中间位置）；面板首次打开时对端标题可能短暂显示 `…`，补查回来即换成真实标题；续页在极端情况下（有别的路径提前插入了某条）会少追加重复项并打日志。
- **未验证**：① 无真机，面板补查的延迟与占位观感未测；② 引用条数很多（跨页几十条）时面板的查询次数与耗时未测，交 OPT-M01；③ `_deepTargets` 没有容量上限——面板是弹出层，关闭即释放，常驻场景未评估；④ 只在 `newest` 排序下验证，其他三种排序的深页样本未单独跑（分页样本本身与排序无关，但没跑就是没跑）。
- **建议下一项**：OPT-10B（本项复验通过后领取，按关系字段更新并保留远端独有关系）；或独立项 OPT-04B / OPT-06C 返修、OPT-07A。

### 2026-11-24 · OPT-04B 返修 · 待复验

- **问题核对**（先复现再改）：`_withinDays` 把「最近 N 天」实现成「按 `yyyy-MM-dd` 比」。18:00 请求「最近 7 天」时下界本应是 7 天前 18:00，实际变成了 7 天前 00:00 —— 当天 09:00 的笔记被一起收进来，窗口宽出将近一整天。当时这么写是为了避开「1500 行各解析一个本地 `DateTime`（约 45µs/次）」，但代价是产品口径错了。
- **关键判断**：不必在「精确时刻」和「不解析 DateTime」之间二选一。库里存的就是 ISO 串，截前 23 位得到一个字符串键，字典序就是挂钟时间序——和 OPT-02A 已经在用的 `noteTimeKeySql` / `compareNoteWallClock` 是同一套口径。于是区间判断可以既精确到毫秒、又零解析。
- **改动**：
  - `lib/utils/note_sorting_helper.dart`：新增 `noteWallClockKey(DateTime)` → `toIso8601String()` 截 23 位。注释点明它和 `noteTimeKeySql` 严格对应（毫秒精度、`Z` 不参与），以及「库里本来就是 ISO 串的行直接取前 23 位，不必调它」。
  - `lib/services/random_review_selector_service.dart`：
    - `selectWidgetCandidatesFrom` 的参数 `displayDayKey` → `displayTimeKey`（语义从「日」变成「时刻」）；`_withinDays` 的 cutoff 也换成 `noteWallClockKey(now - N 天)`，比较用 `>=`。
    - 新增可选 `now` 参数（`selectWidgetCandidates` 与 `selectWidgetCandidatesFrom` 都有），只给测试固定边界用；生产不传，行为与 `DateTime.now()` 一致。
    - 删掉不再使用的 `_dayKey(DateTime)`。
  - `lib/models/widget_stat_note.dart`：新增 `displayTimeKey`（`displayTimeIso` 前 23 位），`displaySortKey` 改为复用它。**这是一个顺带的对齐**：排序键原来用完整 ISO 串（可到微秒），而 SQL 侧排到毫秒，同一毫秒内两种精度的行在内存重排和库查询里可能给出不同顺序。
  - `lib/services/widget_snapshot_service.dart`：
    - 回顾候选传给 `displayTimeKey`。
    - **坏时间串降级**：`_noteSnapshot` 里 `formatWidgetTime(note.createdAt)` / `formatReviewAgeLabel(note.createdAt)` 会 `DateTime.parse`，库里的空串或非 ISO 值直接抛 `FormatException`，整份快照构建失败 → 小组件不更新。改为 `DateTime.tryParse(note.createdAtIso)`，解析不出来时这两个文案给空串。
    - `_rankQuickTags` 同理：`DateTime.parse` 改 `DateTime.tryParse` 并跳过坏行。仍然只对「去重后的标签」解析，没有把成本摊回每行。
  - `lib/utils/thumb_cache.dart`（独立提交 `b8e82b4`）：上一轮把 `debugSettle` 插到了 `debugSeed` 的文档注释与 `@visibleForTesting` 之间，导致注解落在错误的方法上。只搬位置，无行为变化。
  - 未改动：`todayNotes` 仍按自然日判定（「今天」本身就是自然日概念）；`dayCounts` 仍按 `displayDayKey`；月格子的 `DateTime(y, m, d)` 逐格构造留给 OPT-04C。
- **测试**：1128 → **1137**（+9）。
  - `test/unit/random_review_selector_service_test.dart` 新增 `RRS-01~06`：固定 `now = 2026-11-24 18:00`。RRS-01 界内 19:00 / 界外 09:00（同一自然日）→ 只收界内；RRS-02 正落在下界那一毫秒仍算界内；RRS-03 跨日但不足 168 小时（前一天 23:30）仍算界内；RRS-04 混存样本，其中 `remote-split`（伪 UTC 墙钟 14:00，绝对时刻为 22:00）是真正的分叉点——按挂钟排除，按绝对时刻就会纳入；RRS-05 统计行只靠串比较，`debugLazyParseCount == 0`；RRS-06 空时间串的坏行被排除且不抛。
  - `test/unit/widget_snapshot_stats_test.dart` 新增 `WS-S08~10`：伪 UTC `23:30Z` 与本地 `09:00` 归到同一格（按绝对时刻会把前者挪到次日）；两条置顶取挂钟更晚的那条（`pinned-local` 09:00 而非 `pinned-remote` 02:00Z）；空时间串的坏行不让整份快照失败。
  - `test/unit/widget_snapshot_read_scope_test.dart`：两处调用点跟着参数改名。
- **验证**：`dart tool/inkpaper.dart analyze` → No issues found；`dart tool/inkpaper.dart format` → 324 文件 0 changed；`flutter test --concurrency=4` → **1137 项全过**。
- **反向验证**：① 区间退回按日期比较（`substring(0, 10)`）→ `RRS-01`（`before` 被收进来）、`RRS-04`、`RRS-05` 变红；② 区间改成 UTC 绝对时刻（两端都 `toUtc()`）→ `RRS-04` 变红，多出 `remote-split`；③ 快照排序改成按 `DateTime.toUtc()` 比较 → `WS-S09` 变红（选中 `pinned-remote`）。三次恢复后全绿。
- **行为变化**：回顾窗口变回精确 N×24 小时（`reviewDays = 7` 时最多比原来窄一天）；`displaySortKey` 的精度从微秒降到毫秒（与 SQL 对齐，同一毫秒内的并列交给原顺序）；坏时间串的笔记不再拖垮整个小组件快照，只是时间标签留空。
- **未验证**：① 无真机，小组件回顾的实际取数、跨时区旅行（设备时区变化）下的表现未测；② 统计月格子仍逐格 `DateTime(y, m, d)`（31 次/构建，约 1.4ms），属 OPT-04C 范围；③ `reviewRangeDays` 的其他取值（1 / 30）只做了逻辑推演，没有单独设样本。
- **建议下一项**：OPT-06C 返修（与本项无耦合）或 OPT-07A（§7 图片，可拆两轮）；OPT-02B / OPT-10B 仍等各自前置复验。

### 2026-11-24 · OPT-06C 返修 · 待复验

- **问题核对**（先复现再改）：`_scanDisk` 把「扫描结束」和「索引可信」写进同一个 `_indexComplete`，并由 `finally` 无条件置 `true`。于是目录扫描半途 IO 失败时，`_known` 只是**部分清单**却被当成完整索引，`lookup` 的兜底闸门（`indexed || !_indexComplete`）随之关掉：盘上确实存在的缩略图被判未命中，退回原图并重新编码，`ensure` 也不再复用盘上文件。这正是「缓存做了却用不上」的最坏形态——失败一次就要长时间承受。
- **改动**（`lib/utils/thumb_cache.dart`）：
  - 状态拆成两个维度：`_indexSettled`（扫描流程收尾，成功失败都算）与 `_indexComplete`（索引可信）。`_scanDisk` 用局部 `complete` 记录成功，`finally` 里 `_indexComplete = complete; _indexSettled = true;`——收尾照常放行 `indexReady`，可信度如实反映。`indexReady` 的 doc 一并改为「扫描收尾（或扫描失败也照样收尾）的 Future」。
  - `_prepare` 的 `_startDiskIndex` 两个标志都复位；`_clear()` 清空目录后置 `_indexComplete = true; _indexSettled = true;`（空目录就是完整索引，不能让一次失败把 `clear()` 之后也拖成每张 stat）。
  - `_pendingSources`：`await indexReady` 之后若索引不可信直接返回空。索引不完整时没有「缺哪些」的判断依据，硬排只会把已有缩略图全刷进队列（`ensure` 的 stat 兜底能防重编码，但白扫一遍源目录）。
  - `_runDiskMaintenance`：记账循环照跑（`_known` 里的条目仍然有效），但只在 `_indexComplete` 为真时才置 `_diskIndexed`，让 `lookup` 兜底补进来的条目下次维护还能记账，预算不至于长期偏小。
  - 新增 `debugSetDiskLister`（替换目录枚举）、`debugIndexSettled` / `debugIndexStarted`；`debugSeed` 一并复位 `_indexSettled` 与注入的枚举器，避免跨用例串状态。
  - 未改动：两档宽度与编码路径、原生解码、`_giveUp`、补齐节奏、`prepare()` 的对外签名与幂等语义、`lookup` 的同步 stat 形态（仍是 build 里唯一允许的 IO）。
- **测试**：1137 → **1140**（+3），`test/unit/thumb_cache_test.dart` 29 → 32 条。
  - `TC-27` 扫描半途失败：注入的枚举先交出一条名字再抛 `FileSystemException`。断言 `debugIndexSettled == true`（否则补齐/整理永远在等）、`debugIndexComplete == false`（部分清单不是完整索引）、`knownCount == 1`（已扫到的仍有效）；关键是没扫到的那张 `lookup` 仍要命中盘上缩略图，并把名字补进索引（`knownCount` → 2）。同时断言 `prepare` 返回时 `debugIndexStarted == true` 且 `debugIndexComplete == false`——复验要求的「首帧无需等待扫描」这条保证在失败路径上同样成立。
  - `TC-28` 扫描失败后补齐不白排：源目录两张图、盘上一张缩略图、索引部分已知。`startBackfill` 后 `encodes == 0`（不排已有缩略图），`lookup` 兜底仍命中，缺的那张由 `ensure` 按需编码 1 次。
  - `TC-29` `clear()` 之后索引回到可信完整：失败态下 `debugIndexComplete == false`，清空后应为 `true` 且 `debugIndexSettled == true`，避免把失败状态粘到清理之后。
- **验证**：`dart analyze lib test` → No issues found；`dart tool/inkpaper.dart format` → 324 文件 0 changed；`flutter test --concurrency=4` → **1140 项全过**。
- **反向验证**：① 把 `finally` 改回无条件 `_indexComplete = true`（复验给出的原缺陷）→ `TC-27`（`Expected: false / Actual: <true>`）、`TC-28`（`encodes` 0→1）、`TC-29` 三条同时变红；② 只去掉 `_pendingSources` 的 `_indexComplete` 闸门 → `TC-28` 变红，`TC-27/29` 仍过，说明三条各自咬住不同路径。两次恢复后全绿。
- **行为变化**：扫描失败的进程内，`lookup` 对未收录名字一直补 stat（命中即入索引，渐进恢复），不再误判未命中退回原图；主动补齐这一轮直接跳过，缺图仍由渲染路径按需生成；磁盘记账在不可信期间偏小，淘汰会少做（不会误删）。成功路径与改前完全一致。
- **未验证**：① 无真机，扫描 IO 失败后的 stat 成本与首屏观感未测；② 失败后不自动重扫（`_indexFuture` 已完成，无重试入口），要重建完整索引得重启——是否值得加一次有界重试，等真机确认失败概率再定；③ 只注入 `FileSystemException` 一种失败，权限/路径被删/部分可读等形态未覆盖；④ `_diskIndexed` 在不可信期间保持 false，若失败后从不触发维护（`_diskBytes` 未超限），记账会一直不全，这属于「少做」方向，未单独验证。
- **提交**：`9c7baa7`（代码 + 测试）。
- **建议下一项**：OPT-07A（§7 图片，约束缩略图像素与查看器预取范围，可拆两轮）；OPT-02B / OPT-10B 仍等各自前置复验。

### 2026-11-24 · OPT-07A 第一轮 · 待复验

- **问题核对**（先量再改）：`_encodeThumbTask` 一直用 `img.decodeImage(bytes, frame: 0)` 全量解码，再 `copyResize` 到目标宽度。这条路对一张 4000×3000 的手机照片就是 48MB 位图，而本机能耗更高的一档完全没设防——本机内存库/合成样本实测：
  | 样本 | 现状 | 走引擎采样 |
  | --- | --- | --- |
  | 24MP（6000×4000） | 1467ms、RSS **+393MB** | 31ms、RSS +1MB |
  | 32MP 长截图（1080×30000） | 2582ms、RSS **+463MB** | 293ms、+24MB（按高度解 47ms、+3MB） |
  | 8.64MP 走完整 `ensure` | — | 175ms、+6MB |
  手机 50MP 模式按这个比例要 800MB 一张，而编码槽允许两路并发——这在真机上是「点开一张照片就被系统杀掉」的量级，不是掉帧问题。§7 原本的建议是「先用高像素照片复测，再考虑宽高/总像素限制以及系统抽样解码」，本轮把复测和限制一起做。
- **改动**（`lib/utils/thumb_cache.dart`）：
  - 新增 `ThumbCache.thumbSize(srcW, srcH, targetWidth)`：先把宽度收到目标档位，再受 `_maxThumbHeight = 4096` 约束（长图按高度收，宽度随之变窄）。**两条解码路径共用它**，输出尺寸与方向才不会因为走了不同分支而不同。
  - 新增 `_readImageSize(bytes)`：`img.findDecoderForData` + `startDecode` 只解析头部拿宽高，不解像素。**注意 `findDecoderForData` 自己也会抛**：几个 `isValidFile` 直接按下标读魔数，一两个字节的坏文件能把 `RangeError` 抛到外面（`TC-17` 的 `broken.jpg` 当场复现），所以整段包在 `try` 里。
  - `_encode` 分流：头部尺寸超过 `_maxComputeDecodePixels = 8000000` 时走 `_encodeSampled`，否则保持原 `compute` 全解。阈值取 8MP 是有意的——12MP 手机照、32MP 长截图都换到采样路径，而普通截图（1080×2400 ≈ 2.6MP）留在后台 isolate 全解，行为面最小。
  - `_encodeSampled`：`ui.instantiateImageCodec` 在解码阶段就按目标尺寸采样（JPEG 走 DCT 缩放、PNG 走降采样），不产生整张位图。它只能在根 isolate 用，所以这条路径不走 `compute`；产物已经很小，`toByteData` + `encodeJpg` 占主 isolate 的时间是几毫秒，真正贵的解码在引擎 IO 线程上。
  - **只给一个目标维度**：`targetWidth` 与 `targetHeight` 同时给等于指定输出尺寸，而 header 里的宽高是 EXIF 方向应用之前的——竖拍照片会被拉伸。长度限制改为「先按宽度采样，出来发现还超 4096 再按高度重解一次」，两次都等比。实测竖拍 3600×2400（orientation 6）两条路径都输出 480×720。
  - **必须用 `rawStraightRgba`**：`toByteData()` 的默认格式 `rawRgba` 是预乘 alpha，image 包按非预乘解读，半透明图会发黑（反向验证实测 200 被压成 100）。
  - 未改动：编码槽与优先级、`_giveUp`、磁盘记账与淘汰、HEIC/视频的原生解码分流、`compute` 路径的 `Interpolation.average`、`fileNameFor` 的命名规则。
- **测试**：1140 → **1145**（+5），`test/unit/thumb_cache_test.dart` 32 → 37 条。
  - `TC-30` 8.64MP 竖拍（orientation 6）走采样：采样计数 1，输出 480×720，并与 `debugEncode` 全解路径逐字段同尺寸（方向一致）。
  - `TC-31` 阈值以下（400×300）不触发采样、不放大。
  - `TC-32` 半透明红（2900×2900 PNG，刚好过阈值）走采样：alpha 128 保留、r > 150（预乘会掉到 100）。
  - `TC-33` 采样路径长图（700×12500）：输出高度 ≤ 4096 且宽度 < 480。
  - `TC-34` 全解路径长图（300×9000，2.7MP 走 compute）：输出 4096 高、宽度收窄。
- **验证**：`dart analyze lib test` → No issues found；`dart tool/inkpaper.dart format` → 324 文件 0 changed；`flutter test --concurrency=4` → **1145 项全过**。
- **反向验证**：① `rawStraightRgba` 改回 `rawRgba` → `TC-32` 红（`Expected: a value greater than <150> / Actual: <100>`）；② 阈值抬到 100MP（等于关闭分流）→ `TC-30/32/33` 红（采样计数 0），`TC-31/34` 仍过；③ 高度上限抬到 100000 → `TC-33`（8571）、`TC-34`（9000）红。三次恢复后全绿。
- **量级校准**（本机、JIT、合成样本、**非真机**）：见上表。注意 175ms 是含读文件、写盘与完整 `ensure` 的数字，31ms 只含引擎解码 + PNG 编码；AOT 下两边都会缩短，但内存差距是结构性的（一块整图 vs 一块缩略图）。
- **行为变化**：>8MP 的图改由主 isolate 发起引擎解码（解码本身在引擎线程），缩略图输出尺寸与全解路径一致（±1% 采样粒度）；长截图不再生成上万像素高的缩略图；透明图颜色不再变暗（这条对两条路径都成立，采样路径之前根本不存在）。
- **未验证**：① 无真机，AOT 下的耗时、连续补齐几十张大图时主 isolate 与引擎线程的争用未测，交 OPT-M01；② 磁盘上已存在的旧长图缩略图仍是旧尺寸——文件名按宽度档位命名、键里没有高度，新规则只对新生成的生效，要等「清理缓存」或自然淘汰；若要把旧文件一次换掉，得给文件名加版本戳（等于全库重编码一次），没在本轮做；③ 只注入了 JPEG/PNG，HEIC/视频仍走原生解码（未改），WebP/GIF 的大图样本未单测（逻辑同 PNG/JPEG 分支）；④ `thumbSize` 对「宽度不超目标但高度超上限」的窄长图会缩到很小（300×9000 → 137×4096），视觉上是否可接受未在真机确认。
- **提交**：`9c4091b`（代码 + 测试）。
- **建议下一项**：OPT-07A-2（查看器预取与保留范围，本轮拆出来的另一半）；OPT-02B / OPT-10B 仍等各自前置复验。

### 2026-11-24 · OPT-07A-2 · 待复验

- **问题核对**（先量再改）：查看器的高清图 evict 写在 `_PhotoPageState.dispose` 里，而预取（`_precacheAround`）走的是全局 `imageCache`。两处口径不一致，量出来的行为是（4 张 1200×900 PNG，`ImageCache.containsKey` 采样，`o`=在缓存）：
  | 阶段 | 修前 | 修后 |
  | --- | --- | --- |
  | 打开 @0 | `[o,o,x,x]` | `[o,o,x,x]` |
  | 翻到 1 | `[x,o,o,x]` ← 0 被清 | `[o,o,o,x]` |
  | 翻到 2 | `[x,x,o,o]` ← 1 又被清 | `[x,o,o,o]` |
  | 回看到 1 | `[x,o,x,o]` ← 1 重新解码 | `[x,o,o,x]` |
  | 退出 | `[x,x,x,o]` ← 预取的 3 还在 | `[x,x,x,x]` |
  两个方向的错：**该留的没留**（翻走就清，回看必重解 150~300ms），**该清的没清**（预取但从未显示的邻居没人替它收尾，退出后还占一块纹理）。
- **改动**（`lib/screens/image_viewer_screen.dart`）：
  - 新增 `_retainAround(index)`：窗口 = `[index-1, index+1]`（`_retainRadius = 1`，夹在合法范围）。窗口外的 `_retainedProviders` 条目立刻 `evict`，窗口内的重新登记。
  - 查看器 `dispose` 把 `_retainedProviders` 全量 evict 后清空；`_PhotoPageState.dispose` 只留 `_detachPreview()`，不再碰高清图。
  - 新增 `_viewerProvider(index)`：`getImageProvider(path, context, maxWidth: viewerDecodeWidth(context))`。页面、预取、保留窗口三处共用它出键，键一致才谈得上「共用同一保留范围」。
  - `_prefetchNeighbour` 取代原来的单点预取：候选按「下一张 → 上一张」排，先 `obtainKey` 再看 `imageCache.containsKey`，已在缓存（含正在解码）就跳过，最多解一张。原来的实现只认「下一张」，回看方向永远没有预热。
  - 未改动：320ms 入场后的原图延迟解码、缩略图占位、手势仲裁、Live 图自动播放时机、`viewerDecodeWidth` 的档位算法。
- **测试**：1145 → **1150**（+5），新增 `test/widget_tests/image_viewer_retention_test.dart`。断言口径是「键还在 `ImageCache` 里 ⇔ `resolve` 命中不重解码」，用固定 800×600@3x 的 surface 保证解码宽度稳定为 1600。
  - `IVR-01` 打开后当前页与下一张已解码、第三张不解码（同时证明页面与窗口的键一致）。
  - `IVR-02` 翻一页后三张都在（刚离开的那张不被清）。
  - `IVR-03` 连续翻两张后只剩窗口内三张（0 号被释放、4 号不提前解），再翻一张窗口整体右移。
  - `IVR-04` 1→2→1 回看命中（1 号全程没离开窗口；同时 3 号被释放、0 号由预取补上）。
  - `IVR-05` 退出后全部释放，含预取但从未显示的那张。
- **验证**：`dart analyze lib test` → No issues found；`dart tool/inkpaper.dart format` → 325 文件 0 changed；`flutter test --concurrency=4` → **1150 项全过**。
- **反向验证**：① 恢复 `_PhotoPageState.dispose` 里的 `provider.evict()` → `IVR-02/03/04` 红；② 去掉 `dispose` 里的全量 evict → `IVR-05` 红（`[false,false,false,true]`，正是修前那行）；③ `_handlePageChanged` 不调 `_retainAround` → `IVR-03/04` 红（0 号永远不释放）；④ 预取只看下一张 → 仅 `IVR-04` 红。四次恢复后全绿。
- **行为变化**：滑过第 N 张后，第 N-2 张的高清图被释放（腾出纹理，全局缓存压力变小）；回看相邻一张零解码；退出查看器后缓存里不再残留查看器尺寸的图。
- **未验证**：① 无真机，窗口 3 张纹理的峰值未实测（1600 宽竖拍约 13.6MB/张，长图受 4096 高上限约 26MB/张，全局上限 300MB），滑动时的纹理上传开销也未量；② `resource:` 资源图与网络图的键可能被别处共用，退出时 evict 会让那些页面重取一次（体积都小，未单独豁免）；③ Live 图视频解码器不计入窗口，它的释放仍走 `_disposeLiveController`；④ 只测了 4 张图的小样本，几十张的滑动序列没做长跑（逻辑与窗口大小无关，靠 `IVR-03` 覆盖）；⑤ 复跑 `image_viewer_actions_test` 时曾见 `IVA-01` 失败一次（两文件并发、本机内存紧张），单独跑 3 次与全量 1150 项均通过，未定位到与本项相关的因果，先记为可疑抖动。
- **提交**：`b106ce5`（代码 + 测试）。
- **建议下一项**：OPT-07B（§7 本地备份，优先验证流式归档）；OPT-02B / OPT-10B 仍等各自前置复验。

### 2026-11-24 · OPT-07B 第一轮 · 待复验

- **问题核对**（先量再改）：`buildArchive` 把每个附件 `readAsBytes()` 塞进 `Archive`，再 `ZipEncoder().encode(archive)` 出一整包，最后 `Uint8List.fromList(encoded)` 再拷一份。单段 150MB 的视频在结构上要占：源字节 + `Archive` 引用（同一份）+ deflate 输出 + 整包缓冲 + 拷贝 —— 而 §7 的原始担心正是这条路径的峰值。用 `ProcessInfo.maxRss` 量到的基线（本机 JIT、临时目录、合成样本）：
  | 样本 | 修前 | 修后 |
  | --- | --- | --- |
  | 5×8MB 压不动的图片（合计 40MB） | 2569ms、峰值 **+131MB** | 2585ms、**+49MB** |
  | 单个 60MB 视频 | 3726ms、**+92MB** | 1157ms、**+49MB** |
  修前的视频数字用等价的「整块读 + `Deflate` + `Uint8List.fromList`」量的，真实 `buildArchive` 在它之上还要再留一份 `Archive` 期间的媒体引用。
- **改动**（`lib/services/backup_archive_service.dart`）：
  - 新增 `buildArchiveToFile({required File target, ...})`：用 `ZipFileEncoder` 直接往文件写，条目按「先来的先写」顺序落盘（与原来的 `Archive` 顺序一致）。
  - 视频条目 `_addFileEntry`：`ArchiveFile.stream(name, size, InputFileStream(path))..compress = false`。**必须 STORE** —— `ZipEncoder.addFile` 的压缩分支会 `content.toUint8List()` 再 `Deflate`，等于把整个视频再读进堆一次；STORE 分支走 `writeInputStream`，`OutputFileStream` 按 1MB 缓冲直写，内存与文件大小无关。CRC 也是分块算的（先扫一遍再写一遍，代价是两次读盘）。
  - 图片保持原样（`readAsBytes` + deflate）：动图要从字节里切片段，本来就得整张读；单张的额外拷贝只在处理它那一瞬间存在，不随总量累积。
  - `buildArchive` 变成「落盘 + 读一次字节」，对外签名与 `BackupArchiveBuildResult` 不变，调用点（`local_backup_restore_screen`）无需改。
  - 临时目录用可注入的 `tempDirectoryProvider`（默认 `getTemporaryDirectory()`）。**不用 `Directory.systemTemp`**：它在 Android 上可能落在授权范围外，写出来的包再分享会被 FileProvider 拒（`apk_install_service` 里有同类踩坑注释）。
  - 失败清理由 `buildArchiveToFile` 自己负责：`create` 之后的任何异常都会先 `close()` 放掉句柄再删掉半成品，然后把原异常抛出去；`buildArchive` 的 `finally` 再清临时目录。重试就是再调一次。
  - 未改动：视频体积上限（单段 150MB / 合计 200MB）、正文与清单的 deflate、资源命名规则、`decodeArchive` 的读端。
- **测试**：1150 → **1154**（+4），`test/unit/backup_archive_service_test.dart` 19 → 23 条。原有 19 条全部在新实现下通过（它们本身就做「打包 → 解包 → 比正文与媒体」的往返）。
  - `BAK-S01` 视频条目 `compress == false`（STORE）、图片条目与 `notes.json` 仍 `compress == true`，且 `notes.json` 确实被压小。
  - `BAK-S02` 6MB 视频（跨 6 个 1MB 块）还原后逐字节相同 —— 分块读写不能在块边界截断或错位。
  - `BAK-S03` 用旧路径（`ZipEncoder().encode(Archive)`，媒体也 deflate）造的历史包仍能还原，正文里的图片路径被重写为 `file://`。
  - `BAK-S04` 打包中途失败（取图片目录的 provider 抛错，此时第一条媒体已写进 zip）→ 抛原异常且目标文件不存在；随后用正常 service 重试同一路径成功。测试里注入 `tempDirectoryProvider: () async => Directory.systemTemp`，因为单测没有 path_provider 通道。
- **验证**：`dart analyze lib test` → No issues found；`dart tool/inkpaper.dart format` → 325 文件 0 changed；`flutter test --concurrency=4` → **1154 项全过**。
- **反向验证**：① 视频退回 `readAsBytes` + 普通 `ArchiveFile` → `BAK-S01` 红（`compress` 为 true）；② 去掉失败时的 `_deleteQuietly(target)` → `BAK-S04` 红（半成品仍在）。两次恢复后全绿。
- **行为变化**：视频进包不再压缩（体积几乎不变，视频本来就压不动）；整个打包不再占用「媒体总量 + 整包」的堆，只留交付那一份；失败不再留下能被当成有效备份的半成品。压缩包结构（条目名、清单字段、manifest 版本 2.0）完全不变，旧包照常可解。
- **未验证**：① 无真机，AOT 与手机闪存下的吞吐未测（`OutputFileStream` 每次 `flush` 1MB，低端机 IO 可能更慢）；② 交付阶段仍要一份整包字节（系统选择器与加密接口只收 `Uint8List`），200MB 包最终仍需 200MB 堆 —— 要继续降只能走路径交付（分享 `XFile(path)`、应用目录 `copy`），本轮没动 UI 流程；③ 加密分支在整包之上再叠 AES 密文 + base64 + JSON 字符串 + UTF-8，约 4~5 份包体，单独登记 **OPT-07B-2**；④ 图片仍整张读入，单张超大 PNG 没有上限（动图必须切片段，暂时无法流式）；⑤ 只测了本地文件源，`content://` / 服务端资源本来就返回 null（不进包），未受影响。
- **提交**：`ca596f9`（代码 + 测试）。
- **建议下一项**：OPT-07C（导入暂存与失败清理，队列里本来就写着「单独交付」）；OPT-07B-2 待评估；OPT-02B / OPT-10B 仍等各自前置复验。

### 2026-11-24 · OPT-07C · 待验收

- **问题核对**（读完写盘与导入两条路）：`decodeArchive` 先 `_restoreResources` 把 `resources/*` 写进 `documents/images`，再由页面 `_importDecodedArchive` 导入笔记，两段之间没有事务。会漏的三条路径：
  1. 导入抛异常（HTML 包、`importNotesFromJson` 包装后的写库失败）→ 新文件无人引用，也没有记录能认出它们；
  2. 包里 `entries` 为空时的报错发生在写盘**之后**，同样漏；
  3. 文件名是 `backup_image_<毫秒>_<本次已还原数>`：同一个包连导两次，时间戳容易落在同一毫秒、序号又都从 0 开始，第二次会**覆盖**第一次还原的图 —— 第一次的笔记就指向了别的内容（比留垃圾更严重）。
- **改动**（`lib/services/backup_archive_service.dart`、`lib/screens/local_backup_restore_screen.dart`）：
  - `DecodedBackupArchive` 增加 `restoredLocalPaths`：本次解包真正新建的文件绝对路径，是回滚的唯一依据。
  - 新增 `_allocateRestoredFile(dir, kind, ext)`：写之前循环试 `backup_<kind>_<毫秒>`、`_1`、`_2`… 直到不存在。保证「清单里的一定是本次新建」，回滚才不会误删；同时修掉同毫秒覆盖。时间源做成可注入的 `now`，测试能固定到同一毫秒。
  - `_restoreResources` 把静图/视频与 Live 侧车都记进清单（侧车写失败仍只吞掉那一条）。
  - `decodeArchive` 在 `entries.isEmpty` 报错前先 `_discardPaths(createdPaths)`。
  - 新增 `discardRestoredResources(decoded)`（无条件回滚，导入异常时用）与 `finalizeRestore(decoded, importedCount:)`（0 条时整批清、有笔记则保留），两者都只删清单内文件、单个删除失败只记日志，不覆盖调用方的原始异常。
  - 页面：ZIP 分支用 try 包住 `_importDecodedArchive`，异常时先回滚再 `rethrow`；导入 0 条时改走 `finalizeRestore` 清理，并把「同时恢复了 N 张图片」换成「已清理本次还原的 N 个文件」；0 条不再弹「成功导入 0 条」。
  - 未改动：manifest 与包结构、`_rewriteImagePaths`、资源目录本身、加密分支、WebDAV 备份链路。
- **测试**：1154 → **1160**（+6），`test/unit/backup_archive_service_test.dart` 23 → 29 条。新增 `导入回滚` 组：
  - `R01` 解包记下清单（1 个文件）、正文确实指向这份副本（JSON 转义后仍能还原成同一路径）、`discardRestoredResources` 只删它，导入前就在目录里的文件不动。
  - `R02` 手工造「有资源、无正文」的包：抛错的同时孤儿文件被清掉，既有文件不动。
  - `R03` 固定时间源后连解两次：第二次路径带 `_1` 后缀、第一次的图不被覆盖。
  - `R04` 第一次 `finalizeRestore(importedCount: 1)` 保留、第二次 `importedCount: 0` 只清本次新增，第一次的图仍在。
  - `R05` 模拟中断（解包但不收尾）后再解一次并回滚：中断留下的文件不在本次清单里，不被越界删除。
  - `R06` Live 图包的清单含静图与 `<图>.live.mp4` 侧车，回滚两个一起删。
- **验证**：`dart analyze lib test` → No issues found；`dart format --set-exit-if-changed lib test` → 325 文件 0 changed；`flutter test --concurrency=4`（`NO_PROXY` 已设）→ **1160 项全过**，连跑两次均全绿。
- **反向验证**（四次，每次恢复后复跑全绿）：① `_allocateRestoredFile` 不查重 → `R03` 红（两次路径完全相同）；② 去掉 `entries.isEmpty` 前的回滚 → `R02` 红（`Expected: empty`，目录里多出 `backup_image_*`）；③ `_discardPaths` 改成删整个图片目录 → `R01/R02/R04/R05/R06` 全红（R01 的「既有文件不动」、R05 的「中断残留不动」直接咬住）；④ `finalizeRestore` 恒返回 0（等于永不清理）→ `R04` 红（`Expected: <1> / Actual: <0>`）。
- **顺带修复（`abffcee`，本轮范围外）**：全量并发两次分别挂在 `IVR-02` 与 `IVR-03`（查看器保留窗口），单跑该文件三次全过。原因是用例用「12 轮 × 30ms 真实 + 60ms 假时钟」的固定预算等解码，并发负载下不够。改成 `_waitFor(tester, 条件)`：推进真实 IO 与假时钟直到期望的缓存状态成立，150 轮（约 4.5s）超预算才放弃、断言照旧失败；`_settle` 退化为「只推进动画与定时器」的薄封装。加固后全量两次全绿。
- **行为变化**：导入失败不再在图片目录留下未被引用的文件；同毫秒重复导入不再互相覆盖；导入 0 条时不再提示「成功导入 0 条」，改为「没有笔记被导入」+「已清理本次还原的 N 个文件」。包结构与可导入性完全不变。
- **未验证**：① 页面编排（FilePicker 选择 → 解包 → 导入 → 回滚）没有 widget 测试，只测到服务边界；`_importDecodedArchive` 的 HTML 分支与写库异常在页面上共用同一个 catch，逻辑上已覆盖，但没有端到端用例；② 进程被杀/闪退的中断无法跨会话清理 —— 只保证「不覆盖已有文件」与「不参与后续批次的回滚清单」；要真正清理得在解包前落一份待提交清单并在启动时核对，属另一项工作；③ 回滚后 `ThumbCache` 里可能留有源文件已删的派生缩略图（键含 size/mtime，源文件不在时 `lookup` 会 miss 并重编码，不会用错图，但会占一点磁盘）；④ 同一包重复导入、且每次都有笔记落库时仍会各写一份副本（旧副本无人引用）；内容寻址去重没做；⑤ 加密包（`.enc`）走的是解密后再解包，回滚逻辑同路径但未单独测；⑥ 无真机，手机闪存上的删除与写入耗时未测。
- **提交**：`de6a0ad`（代码 + 测试）、`abffcee`（查看器用例加固）。
- **建议下一项**：OPT-07B-2 —— 加密分支的峰值需要先量（`_encryptBytes` 在整包之上再叠 AES 密文、base64、JSON 字符串与 UTF-8 字节），量完再决定是入口限流、流式加密还是最终降级提示；OPT-02B / OPT-10B 仍等各自前置复验。

### 2026-11-24 · OPT-07B-2 · 待验收

- **先量基线**（本机 JIT，`ProcessInfo.maxRss`，40MB 明文）：加密 3381ms、峰值 **+656MB**，即约 15.6 份包体 —— 比登记时估的「4~5 份」高得多。按这比例，200MB 包要 3GB 以上，Android 上必 OOM。拆开看，最大的一份不在队列里写的那些：
  - `_backupMacPayload` 用 `Uint8List.fromList([...header, ...salt, ...iv, ...cipherText])`，spread 一个 `Uint8List` 会先展开成 growable `List<int>`（每个元素 8 字节），40MB 密文光这一步就是 320MB，再拷进 `Uint8List` 又 40MB；
  - 密文 `base64Encode` 成 String（1.33 份）、`jsonEncode` 整个信封又一份 String（1.33 份）、`utf8.encode`（1.33）、`Uint8List.fromList`（1.33）。
- **改动**：
  - 新增 `lib/services/backup_encryption_service.dart`（纯 Dart，不 import Flutter）：`encryptToBytes` / `looksEncrypted` / `decrypt`，v2 信封与 v1 老包两条解密路径都搬过来。页面的 218 行私有实现（`_encryptBytes`、`_deriveBackupKeys`、`_aesCbcCrypt`、`_backupMacPayload`、`_secureRandomBytes`、`_constantTimeStringEquals`、`_BackupKeyMaterial`）删掉，`_askBackupPassword` 留在页面。
  - 加密改流式：明文按 64KB 块（16 字节对齐）走 `CBCBlockCipher` + 手写 PKCS7，比 `PaddedBlockCipherImpl.process` 更适合分块；每块同时喂 HMAC 的 chunked sink 与 `_Base64StreamWriter`（攒 3 字节就编一段，`=` 填充只在最后一块），结果直接写进 `BytesBuilder`。
  - 信封不再 `jsonEncode`：手拼头 + 分块 base64 + 手拼尾，**字段顺序与原来完全一致**（`marker/version/algorithm/kdf/iterations/originalFormat/salt/iv/ciphertext/mac/timestamp`）。
  - MAC 改成 `Hmac(sha256, key).startChunkedConversion(_DigestSink())` 逐段 `add`，加密与校验两侧都改，spread 与整份 payload 都没了。
  - 页面导出改成 `fileBytes = _encryptionService.encryptToBytes(...)`，不再 `utf8.encode` + `Uint8List.fromList` 各拷一份。
  - 未改动：信封字段与语义、迭代次数（100000）与下限（10000）、v1 兼容规则、错误文案、页面上的密码输入与「加密备份」开关。
- **兼容性证据**：改造前用固定 `salt` / `iv` / 迭代 10000 / `timestamp` 产出一个 744 字节信封，硬编码为 `ENC-01` 的黄金样本；新实现必须逐字节相同。它同时钉住字段顺序、base64 分块边界、PKCS7 补齐与 MAC 覆盖范围 —— 老版本解新包等价于能解这段字节。
- **测试**：1160 → **1169**（+9），新增 `test/unit/backup_encryption_service_test.dart`。之前这条路径**零测试覆盖**。
  - `ENC-01` 黄金样本逐字节一致；`ENC-02` 往返拿回原文与 `originalFormat`；`ENC-03` 密码错报固定文案；`ENC-04` 密文改一个字节 → MAC 校验失败；`ENC-05` 迭代次数 1000 → 「加密备份参数不安全」；`ENC-06` v1 老包（`content` + `signature`）仍能解；`ENC-07` `looksEncrypted` 认标记、拒明文 zip、拒 `marker:false`、拒空字节；`ENC-08` 200KB（跨 4 个 64KB 块、总长非 3 的倍数）往返一致；`ENC-09` 0/1/15/16/17/63/64/65 字节的 PKCS7 边界。
- **验证**：`dart analyze lib test` → No issues found；`dart format lib test tool` → 325 文件 0 changed；`flutter test --concurrency=4`（`NO_PROXY` 已设）→ **1169 项全过**。
- **反向验证**（三次，每次恢复后复跑全绿）：① `_Base64StreamWriter.close()` 不写余数 → `ENC-01/02/09` 红（`ENC-08` 因长度是 3 的倍数没触发，属预期）；② PKCS7 改成永远补整块 → 同上三条红；③ MAC 少喂 `iv` 与密文 → `ENC-02/08/09` 全红（往返解不出原文）。
- **峰值实测**（本机 JIT、合成样本、`ProcessInfo.maxRss`、单次独立进程）：

  | 场景 | 修前 | 修后 |
  | --- | --- | --- |
  | 加密 40MB 明文（输出 55.9MB） | 3381ms / **+656MB** | 2878ms / **+40MB** |
  | 加密 80MB 明文（输出 111.8MB） | 未测（按比例约 +1.3GB） | 5653ms / **+129MB** |
  | 解密 40MB 包（明文 40MB） | 未改 | 3164ms / **+185MB** |

  加密侧现在只剩「输出那 1.1~1.3 份」；耗时没变多少，因为 100000 次 PBKDF2 占了大头（下面这条）。
- **顺带发现（登记 OPT-07B-3）**：`_deriveKeys` 是 100000 次 HMAC-SHA256，同步跑在 UI isolate，本机约 2.4s，手机只会更慢；导出加密与导入解密都会整段卡住界面且没有进度提示。移到后台 isolate 要处理「不可发送的 `Random.secure()` 与闭包」，得单独一轮。
- **行为变化**：加密导出的包内容与以前**完全一致**（旧版本可解，新版本可解旧包）；导出时不再有「整包 → base64 String → JSON String → UTF-8」的三次全量拷贝。界面上看不到变化。
- **未验证**：① 解密侧仍是整块路径：`jsonDecode` 出一份 1.33 份的 String + Map，`base64Decode` 一份密文，AES 解出一份明文，实测 3.3 份；200MB 加密包导入约 660MB，要继续降得换二进制信封 v3（不再 base64/JSON）或手写流式 base64 解码，属本项剩余；② 交付阶段仍需一份 `Uint8List`（`FilePicker.saveFile(bytes:)` 与 `share_plus` 只收字节），要做路径交付得改 UI 流程；③ 无真机，手机上的 AES/内存峰值与 200MB 包的实际表现未测；④ 未做「加密包体积上限 / 入口限流」的产品决策 —— 现在能流式导出，但交付那一份仍随包体线性增长，需要用户定规则。
- **提交**：`72f6c2f`（代码 + 测试）。
- **建议下一项**：OPT-07B-3（KDF 移出 UI isolate，先量真实卡顿时长）；OPT-07B-2 剩余（解密侧）待用户决定是否值得换容器格式；OPT-02B / OPT-10B 仍等各自前置复验。

### 2026-11-24 · OPT-07B-3 · 待验收

- **先量，结果推翻了队列里的前提**：队列写的是「KDF 本机约 2.4s，占住界面」，实测 100000 次 PBKDF2 是 **848ms**（`crypto` 包的 `Hmac` 比 pointycastle 的 `PBKDF2KeyDerivator` 快：668ms vs 955ms，所以没换实现）。拆开 40MB 加密包的解密各阶段：`jsonDecode` 146ms / `base64Decode` 210ms / KDF 856ms / MAC 536ms / AES 1296ms —— KDF 只占 28%，**只搬 KDF 修不好卡死**。
- **改动**（`lib/services/backup_encryption_service.dart`、`lib/screens/local_backup_restore_screen.dart`）：
  - KDF 进后台 isolate：顶层 `_pbkdf2KeyBytes(password, salt, iterations)`，`Isolate.run` 的闭包只捕获这三样。**必须是顶层/静态函数** —— 实例方法会捕获 `this`，而服务里握着 `Random.secure()`，跨 isolate 发送会直接失败。
  - `encryptToBytes` / `decrypt` 变 `Future`；页面两处调用加 `await`。
  - 加密的 64KB 块循环、MAC 的 256KB 块循环、解密的新块循环，统一按「攒够 16ms 就让出」而不是按字节切：按 64KB 一刀切时 40MB 加密从 2878ms 涨到 3436ms（一次让出约 1~3ms，640 次白付），按时间攒只多 7%。
  - 解密新增 `_streamCbcDecrypt`：`CBCBlockCipher`（`processBlock` 逐块、CBC 链接自然延续）+ 手写 PKCS7 去尾，输出写进按密文长度预分配的缓冲、最后 `sublistView` 截掉补齐。换掉原 `PaddedBlockCipherImpl.process`（它只能整段一次算完，40MB 要连占主线程 1.3s）。
  - `looksEncrypted` 改前缀探测：先看开头 512 字节是否以 `{"InkPaperEncryptedBackup":true` 开头；认不出但开头确实出现这个键（外部工具重排过字段、值被截断）时退回整段解析，保证判定与整段解析一致。原来它对 53MB 信封做一次 `utf8.decode` + `jsonDecode`（约 150ms、多出 56MB 字符串和一张 Map），而 `decrypt` 紧接着还要再解一次。
  - 未改动：信封格式与字段顺序、迭代次数与下限、v1 老包路径、错误文案、页面密码框与开关。
- **验证方法**：写了个「自驱异步转轮」探针（`await Future.delayed(Duration.zero)` 自循环，记录相邻两轮的 `DateTime` 差）量主 isolate 的最长不可用时长。**先用 `_busy(500)` 自检**（报 504ms）再量，否则计量本身不可信 —— 一开始用 `Timer.periodic(5ms)`，被零时长定时器饿死，数字完全不可读。
- **测试**：1169 → **1172**（+3）。
  - `ENC-10` 加密期间 3ms 定时器照常触发（300 字节明文，只有 KDF 在 isolate 里跑，所以 tick 只能来自它）；`ENC-11` 解密同理。把 KDF 改回同步后两条都是 `Expected: a value greater than <0> / Actual: <0>`。
  - `ENC-12` 1MB 包跨 4 个 256KB 解密块往返一致（此前只测到 200KB，单块），外加前缀探测与整段解析在「字段重排 / 多一个空白 / 值不是 true」下结论一致。
- **验证**：`dart analyze lib test` → No issues found；`dart tool/inkpaper.dart format` → 327 文件 0 changed；`flutter test --concurrency=4` → **1172 项全过**，修复清理竞态后连跑两次全绿。
- **反向验证**（三次）：① `_deriveKeys` 改回同步 → `ENC-10`/`ENC-11` 红（`Actual: <0>`）；② `_yieldSliceMs` 设成 `1 << 30`（永不让出）→ 探针量到最长停顿回到 **2393ms / 1972ms**（这条是测量而非用例，阈值型断言在并发负载下会抖，见 §2.23 的教训）；③ 去掉 `looksEncrypted` 的整段回退 → `ENC-12` 红（`Expected: true / Actual: <false>`）。
- **实测**（本机 JIT，40MB 明文，同一个探针前后各跑两次）：

  | 场景 | 永不让出 | 16ms 让出 |
  | --- | --- | --- |
  | 加密最长停顿 | 2393ms | **73 / 80ms** |
  | 解密最长停顿 | 1972ms | **371 / 400ms** |
  | 加密总耗时 | 3379 / 3286ms | 3615 / 3316 / 3297ms |
  | 解密总耗时 | 3447ms | 3237 / 3329ms |

  KDF 单独看：100000 次 848ms，占满期间 50ms 定时器 **0 次**触发；`Isolate.run` 后 **16 次**。`Isolate.run` 每次约 2ms（5 次 10ms），连开三次 `maxRss` 无增长。解密峰值（独立进程读 53MB 信封）**+187MB**，与上轮 +185MB 同量级。
- **行为变化**：输出逐字节不变（`ENC-01` 黄金样本仍过），老包（v1 与 v2）都能解；界面上的进度指示器现在真的在转，返回手势可用。`encryptToBytes` / `decrypt` 从同步变异步，调用方必须 `await`。
- **未验证**：① 解密仍有一次**整段信封解码**（`utf8.decode` + `jsonDecode` + `base64Decode`），40MB 包实测 0.4s 停顿、峰值 187MB 基本由它决定，登记 **OPT-07B-4**；② 无真机 —— AOT 下 PBKDF2/AES 吞吐与 isolate 启动开销都可能与桌面不同（手机 PBKDF2 通常更慢，isolate 启动可能 10~30ms）；③ 交付仍需一份 `Uint8List`；④ 页面编排仍无 widget 测试；⑤ `iterations` 从文件读取且没有上限，畸形包可让后台 isolate 跑很久（不是真实威胁模型，未加）。
- **顺带修复（`37d9729`，范围外）**：全量并发连续两次各挂一条 `IVR-01` / `IVR-03`，报的是 `tearDown` 删 `viewer-retention*` 临时目录 `PathAccessException(errno 32)` —— 树上还挂着没读完的 `FileImage.load`，Windows 锁着文件。清理改成最多试三次、失败就放弃（临时目录残留不影响断言）。
- **提交**：`42d6139`（代码 + 测试）、`37d9729`（查看器用例加固）。
- **建议下一项**：OPT-07B-4 —— 把信封解码也拆开（按字节扫描字段 + 4 字符对齐分块 base64），这是加解密链路最后一块 0.4s / 187MB；或先做 OPT-02B / OPT-10B（等各自前置复验）。

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
