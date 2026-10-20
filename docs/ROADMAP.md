# 优化路线图 / Roadmap

本文件记录代码优化中已落地的改动、待处理问题与验收标准，用于指导后续迭代。
每条问题都标了代码位置（以符号名为准，行号可能随重构变化）。

- 最后一次更新：2026-10-20
- 当前数据库 schema：**11**
- 静态检查基线：`dart analyze lib tool test` 4 条既有 warning（`unawaited_return_in_try_block`）、0 error
- 测试基线：`flutter test` **392** 项全通过
- 代码规模：`lib/` 146 个 Dart 文件 / 88,287 行；`test/` 38 个文件
- 当前版本：`1.0.7+10007`

---

## 一、已完成

| 提交 | 范围 | 说明 |
| --- | --- | --- |
| `74cc6b5` | M0 死代码清理 | 删除 8 个零引用服务与 6 个零引用 Widget，共 -4,522 行；移除 `AppProvider._apiService` 残留 |
| `bbfcd2a` | M1 数据层 | schema 9：`notes` 增加 `idx_notes_created_at` / `idx_notes_is_synced`；`getNotesByTag` 改为逗号边界整词匹配；修正 v7 迁移位置 |
| `0b423b2` | 软删除基础 | schema 10：新增 `deleted_at` 列与 `active_notes` 视图；列表/分页/搜索/标签/总数/未同步查询统一切到视图 |
| `857233e` | 删除链路 | `deleteNote` / `deleteNoteLocal` / 后台删除队列改软删；撤销改为解除软删标记 |
| `f6b5051` | 回收站 | 新增「最近删除」页面、`/recently-deleted` 路由、数据清理页入口 |
| `257b9bf` | 同步正确性 | 本地 id 判定收敛到 `Note.isLocalId`（只认 `local_` 前缀），修掉 UUID 笔记更新/删除被静默跳过 |
| `e411a69` | 删除重试 | schema 11：`pending_note_operations` 表；远端删除入队，同步前后补交，失败累加 `attempts` |
| `111cd1c` | 同步收敛 | 下拉刷新复用 `fetchNotesFromServer`；删除 `IncrementalSyncService` 与 `AppConfig.prefKeyLastSyncTime` |
| `0e9dd00` | 合并保护 | 拉取合并新增 `keepLocalPendingChanges`，本地待上传改动不再被服务端旧内容覆盖 |
| `aa7dca6` | 卡片渲染降维 | 新增 `utils/note_preview_builder.dart` + `widgets/note_preview_text.dart`：Markdown AST → 纯文本 + 样式区间，整卡只产出一个 `Text.rich`；`NotePreviewCache` LRU 400 条。同时删除 `_visibleItemsCount` 分帧递增、骨架屏、`scrollCacheExtent: 1000` |
| `864e6fa` | 根节点重建收窄 | 根级 `Consumer` → `Selector<AppProvider, _AppChrome>` |
| `2a3e837` | 引用解析索引化 | `SimpleMemoContent` 的 `indexWhere` 全表扫描改为 id→Note 索引缓存 |
| `8490e1a` | Android 拆包构建 | `tool/inkpaper.dart` 新增 `android-release-split`（`--split-per-abi` + `--split-debug-info`），发布用 universal 包不变 |
| `5b1cccc` | P0-1 同步修复 | `updateMemo` 遇 404 回退 `createMemo`，恢复的笔记不再永久上传失败 |
| `2ab768f` | P-5 缩略图解码 | 卡片图片按格子实际像素宽度解码，`memCacheWidth` 不再固定 720 |
| `4b54c01` | P-2 字体 | Android 上思源黑体/宋体走系统字体族，去掉 google_fonts 运行时下载 |
| `0c8ec83` | P-1 状态通知分家 | 新增 `notifyUiStateChanged()`；主页 `Selector<_FeedSnapshot>`、未读条 `Selector<int>` |
| `2419d4e` | P-6 基线采集 | `BUILD_AND_DEVICE_TESTING.md` §3.1 写入采集步骤与目标值 |
| `11f46f5` | 卡片按压动画 | `AnimatedBuilder` 接上 `child`，缩放不再整卡重建；修掉恒定居中缩小 3% 的曲线错误；`DateFormat` 与预览正则静态化 |
| `91eb1ab` | P1-1 计数修复 | 删除与撤销删除后重新取 `viewActiveNotes` 的 COUNT |
| `bd89ba4` | P0-5 重复笔记 | `utils/note_dedupe.dart`：同内容未同步副本合并增强数据后物理删除，两条同步路径都接上 |
| `a25bd7e` | P0-2 上传退避 | `operation='upsert'` 记录失败次数，连续 3 次后暂停重试，编辑后清零 |
| `252def0` | P0-2 提示保留 | 同步结束清状态时保留「已暂停重试」文案 |

### 1.1 已落地的设计约束（改动时不要破坏）

1. **写库不能用 `ConflictAlgorithm.replace`**：REPLACE 会删行重插，冲掉 `deleted_at`。统一走 `DatabaseService.upsertNote`（先 UPDATE 后 INSERT，且 UPDATE 跳过软删行）。
2. **删除状态是黏性的**：只有 `restoreDeletedNote` 能解除，任何保存/导入/sync 回写都不能把 `DELETED` 改回 `NORMAL`。
3. **读笔记统一查 `active_notes` 视图**：新增查询必须走 `DatabaseService.viewActiveNotes`，避免软删笔记泄漏。
4. **同步剪枝要跳过软删行**：`deleteSyncedNotesNotIn` 已带 `rowStatus <> 'DELETED'` 条件。
5. **列表卡片不得走 `MemosMarkdownRenderer`**：`flutter_markdown` 的 `MarkdownBody` 会为每个 `p/strong/em/li` 建 widget 节点，且需 `TextPainter` 预测量行数。卡片统一走 `NotePreviewText`（单 `Text.rich`），详情页 / 编辑器才用完整渲染。新增卡片样式请扩展 `note_preview_builder.dart` 的 `PreviewInlineStyle`，不要引入 widget 级 span。

---

## 二、验收清单（发布前至少跑一遍）

- [ ] **全新安装**：建库 v11，回收站入口存在且为空。
- [ ] **旧库升级**：用真实 v8/v9 用户库升级，启动不崩、索引/视图/队列表均创建、历史笔记完整。
- [ ] **删除 → 回收站**：列表立即消失；回收站出现该条；显示删除时间。
- [ ] **回收站恢复**：恢复到列表，总数与分页正确。
- [ ] **离线编辑 → 联网同步**：本地内容不被服务端旧版本覆盖（`0e9dd00` 的行为）。
- [ ] **下拉刷新**：已删笔记不会重新出现。
- [ ] **回收站恢复「服务端已删」的笔记**：验证 P0-1 是否触发上传永久失败。
- [ ] **主页滚动**：profile 模式下连续滚动 30 秒，无掉帧、无白块；长笔记（数千字）卡片展开/收起正常。
- [ ] **卡片预览还原度**：粗体、斜体、行内代码、删除线、`<u>` 下划线、`☑/☐` 待办、引用块灰字都显示；待办点按能改回笔记。
- [ ] **拆包产物**：`build android-release-split` 出的三个 APK 可分别安装（arm64 真机 + 模拟器），`build/symbols` 有产物。

---

## 三、P0：正确性 / 数据风险

| # | 问题 | 位置 | 影响 | 建议方案 |
| --- | --- | --- | --- | --- |
| ~~P0-1~~ ✅ | 从回收站恢复时若远端已删除，上传会永久失败 | ~~`MemosApiServiceFixed.updateMemo`（非 200 一律 throw，含 404）~~ | 已修复：404 回退 `createMemo`，上层 `_syncUnsyncedNoteToMemos` 已有的 id 变更处理会自动重写引用并物理删除旧记录。待真机验证（见「七」） | — |
| ~~P0-2~~ ✅ | 上传失败无退避、无上限、无提示 | ~~`AppProvider.syncWithServer` 的上传循环~~ | 已修复（`a25bd7e` / `252def0`）：复用 `pending_note_operations` 的 `operation='upsert'` + 已有 `attempts`/`last_error`，连续失败 3 次后暂停重试，提示在同步结束后保留；用户编辑笔记时清零。仍缺的是**指数退避**与**设置页可查看失败清单** | 后续可加：失败清单 UI、退避间隔 |
| P0-3 | 冲突静默 LWW | `SyncStats.conflicts` 从未赋值；`mergeServerNoteWithLocalState` 以时间戳为准 | 双端同时编辑，一侧修改无声丢失 | 同 id 且双方内容与时间戳都变化时记录冲突，至少在设置页/回收站可见并允许重试 |
| P0-4 | 备份与回收站语义未对齐 | `local_backup_restore_screen.dart` 导出取 `getNotes()`（仅未删）；`Note.toJson` 有 `rowStatus` 但无 `deletedAt`；`replaceAllNotes` 物理清表 | 换机恢复后回收站为空；若导出 DELETED 行则 `deleted_at` 丢失、GC 失效 | 明确「备份不含回收站」并在导出时跳过 `DELETED`；`toJson` 补 `deletedAt` 以备将来 |
| ~~P0-5~~ ✅ | 远端"删除后重建"产生重复笔记 | ~~`deleteSyncedNotesNotIn` 仅按 id 剪枝~~ | 已修复（`bd89ba4`）：新增 `utils/note_dedupe.dart`，`fetchNotesFromServer` / `syncWithServer` 会把同内容的未同步副本的本地增强数据并到服务端那条，再物理删除旧副本。注意这条风险随 P0-1 的自愈加重 —— 现在 404 会自动重建并换新 id | — |

---

## 四、P1：一致性与体验

| # | 问题 | 位置 | 建议方案 |
| --- | --- | --- | --- |
| ~~P1-1~~ ✅ | 删除/撤销删除后 `totalNotesCount` 不更新 | ~~`AppProvider._totalNotesCount` 仅在加载路径赋值~~ | 已在删除与撤销两处改为库操作后重新取 COUNT（`91eb1ab`）。回收站恢复走 `loadNotesFromLocal`，本来就会重算 |
| P1-2 | 回收站页面文案硬编码中文 | `lib/screens/recently_deleted_screen.dart` | 并入 i18n 收敛（P2-1） |
| P1-3 | 回收站 GC 仅在进入页面时触发 | `_RecentlyDeletedScreenState._load` | 也可挂到启动幂等任务或数据清理页 |
| P1-4 | 缺少删除链路的组件/集成测试 | `test/` 目前以 unit 为主 | 补「删除 → 回收站出现 → 恢复 → 列表中有」的 widget 测试 |
| P1-5 | `AppProvider` 过大 | `providers/app_provider.dart` **3,781 行 / 约 104 方法 / 61 处 `notifyListeners`**，根级单 Provider 包住 `MaterialApp.router` | 按 `PrefsStore → SyncStore → AuthStore → NoteStore` 顺序拆分，最后换 `MultiProvider` + `Selector`。`PrefsStore` 风险最低，建议先做。根节点 `Selector` 已落地（只隔离了 MaterialApp 外壳），真正的重建根因见 **P-1** |

### 4.1 性能专项（Android 为主战场）

目标是「中端安卓机（骁龙 7 系 / 天玑 8000 档）主页滚动不掉帧、冷启动 ≤1.5s」。性能问题是实现层面的，**不建议为此重写为纯 Kotlin**（理由见 4.3）。

已完成：

| 项 | 做法 |
| --- | --- |
| 卡片渲染降维 | `NotePreviewText` + `NotePreviewCache`，整卡一个 `Text.rich`，去掉逐卡 `MarkdownBody` 与 `TextPainter` 测量 |
| 列表分帧机制 | 删除 `_visibleItemsCount` 递增、骨架屏占位、`scrollCacheExtent: 1000`，交回 `ListView.builder` |
| 引用解析 | `SimpleMemoContent` 用 id→Note 索引缓存替代逐条 `indexWhere` |
| 根节点重建 | `main.dart` 根级 `Consumer` → `Selector<AppProvider, _AppChrome>` |
| **P-1** | 新增 `notifyUiStateChanged()`：同步进度、加载指示、未读数变化不清 `notes` 缓存。主页 body → `Selector<_FeedSnapshot>`，未读通知条 → `Selector<int>` |
| **P-2** | Android 上思源黑体/宋体改走 `sans-serif` / `serif` 系统族，去掉 google_fonts 运行时下载（装饰字体保留） |
| **P-5** | 卡片缩略图按格子实际像素宽度解码（`memCacheWidth` 不再固定 720） |
| **P-6** | 基线采集方法与目标值写入 `BUILD_AND_DEVICE_TESTING.md` §3.1，数值待真机采集 |
| 拆包构建 | `android-release-split`（`--split-per-abi` + `--split-debug-info`） |
| 卡片按压动画 | `AnimatedBuilder` 接上 `child` 复用静态子树，每帧只重建 `Transform`；顺带修掉 `Tween(1→0.98)` 导致卡片恒定居中缩小 3% 的问题 |
| 格式与正则 | 卡片时间 `DateFormat`、预览解析用的 `RegExp` / `InlineSyntax` 全部提到静态，不再每条笔记重新编译 |

待办：

| # | 项 | 位置 | 预期收益 | 成本 |
| --- | --- | --- | --- | --- |
| P-3 | `AppProvider` 拆分（同 P1-5） | `providers/app_provider.dart` | 消除全局重建根因，也是 P2-3 大文件拆分的主战场 | 高 |
| P-4 | SQLite 结果 → `Note` 反序列化在主 isolate | `services/database_service.dart` / `AppProvider.loadNotesFromLocal` | 千条笔记首屏 -100~300ms；全项目仅 5 处 `compute()` | 中 |

执行顺序：先真机采一轮基线（P-6 的方法），再动 P-3；P-4 随手做。

并行约束：P-3 与「三、P0」剩余项都动 `app_provider.dart`，**不要同时开两个会话**，遵守 P2-7。

### 4.2 性能验收标准

- 主页连续滚动 30 秒，`frame_build` 99 分位 < 16ms，无超过 2 帧的卡顿尖峰。
- 1000 条笔记冷启动到首屏可交互 ≤ 1.5s（中端机，profile 模式）。
- 同一台机器 `note_preview_builder` 的 LRU 命中率 > 90%（`NotePreviewCache.hitRate`）。
- `flutter build apk --release --split-per-abi` 的 `arm64-v8a` 包 < 25MB。

### 4.3 已否决的方案

- **重写为纯 Kotlin/Compose 原生工程**：`lib/services` 的 15,137 行（WebDAV 同步引擎、Memos API、Notion 同步、三种语音识别、AI 洞察、导入导出、FTS 搜索、小组件快照）与 UI 框架无关，重写需 3-6 人月且必然重踩已修好的坑（通知冷启动、分享载荷兼容等）。原生收益仅冷启动 -200~400ms、包体 -10~15MB，不足以抵消成本。
- **`--obfuscate`**：项目在用 Sentry 上报异常，混淆后堆栈不可读；对 AOT 产物仅 3-5% 体积收益，不划算。保留 `--split-debug-info` 以便后续需要时启用。
- **`scrollCacheExtent: 1000`**：不是缓存命中率参数，而是「预构建多少像素外的 item」。调大会让首屏多构建数屏卡片、内存上升，已回退到框架默认值。

---

## 五、P2：技术债与工程化

| # | 问题 | 现状 | 建议 |
| --- | --- | --- | --- |
| P2-1 | i18n 两套实现 | `l10n/app_localizations_simple.dart`（2,802 行）+ `l10n/translations.dart`（2,801 行） | 收敛到 ARB 生成式 |
| P2-2 | 重复实现 | 日志、typography 各有多套；Markdown 渲染已分成「卡片轻量预览」与「详情页完整渲染」两条路径，属于有意为之，不要再合并 | 日志与 typography 各收敛为一套 |
| P2-3 | 巨型 UI 文件 | `note_editor`（3,006）、`preferences_screen`（2,617）、`ai_settings_screen`（2,180）、`home_screen`（2,559） | 按区块抽子 Widget。注意 `home_screen` 与 P-1 同文件，排在一起改 |
| P2-4 | 数据库明文 | `notes.db` 无加密 | 评估 SQLCipher，并同步隐私政策文案 |
| P2-5 | 死配置残留 | `AppConfig.canaryStages` / `canaryPercentage` / `isFeatureEnabled` 零引用；`screens/user_agreement_screen.dart` 零引用但有未提交改动 | 确认后删除 |
| P2-6 | CI 门禁 | Actions 已收敛为仅 Android APK（`46c3648`）；analyze 仍有 4 条既有 warning；`android-release-split` 尚未接入 CI（仅本地可用） | 清理 warning 后再考虑把 info/warning 纳入失败条件；若要把拆包纳入发布，需同步改 `release.yml` 的证书校验与产物命名 |
| P2-7 | 并行改动的提交流程 | 曾出现多个会话共用工作区、暂存互相覆盖 | 大改动期间只保留一个会话执行提交 |

---

## 六、待拍板的决策

1. **备份是否包含回收站**：建议不包含（导出时跳过 `DELETED`），回收站属于本地临时态。
2. **撤销档位**：当前是 3.2 秒内存窗口 + 30 天回收站；是否需要"永久撤销 toast"或调整回收站保留期。
3. **数据库加密**：是否引入 SQLCipher（影响启动耗时与备份兼容性）。
4. **冲突处理策略**：保留 `SyncStats.conflicts` 仅做统计，还是提供"冲突副本"式人工合并。
5. **卡片预览的交互边界**：当前预览里的标签/链接/引用不可点（块级结构已拍平，没有点击区域），点卡片进详情页。是否需要给链接单独挂 `TapGestureRecognizer`。参见 4.3。

---

## 七、尚未验证的部分

- 未运行 `dart tool/inkpaper.dart verify`（仅跑了 `dart analyze` 与 `flutter test`）。
- 未在真机/模拟器验证 UI 链路（删除刷新、分页、回收站、下拉刷新）。
- **P0-1 只有代码修复，没有集成验证**：需要构造「设备 A 删除 → 设备 B 从回收站恢复 → 同步」的真实链路，确认重建后本地 id 收敛、引用关系不断裂、旧记录不残留。
- **P0-1 + P0-5 的联合场景未验证**：设备 A 删除 → 设备 B（旧 id 有未上传改动）同步 → 上传 404 重建 → 再同步。要确认最终只剩一条、置顶/批注/引用都还在。`findDuplicateLocalCopies` 只有纯函数单测，没有跑过真实同步链路。
- **P0-2 的暂停重试未验证**：需要构造一条必定失败的笔记（例如让服务端返回 413/422，或断网后重试），确认第 4 次同步被跳过、提示保留、编辑后重新入队。`pending_note_operations` 的新方法还没有 DB 层单测（sqflite 测试基础设施尚未搭）。
- 未在真机上采集性能基线（见 §4.1 P-6）：滚动帧耗时、冷启动、`NotePreviewCache.hitRate` 均无实测数据。
- 未执行 `build android-release-split` 验证拆包产物与 `--split-debug-info` 输出路径。
- 迁移测试使用手工构造的 schema，未覆盖真实用户库中的脏数据（例如 `rowStatus` 为 NULL、`createdAt` 非 ISO 格式）。
- `docs/architecture/ARCHITECTURE_OVERVIEW.md` 是 v1.1.13 时期的历史快照（记为 102,042 行 / `AppProvider` 4,613 行），与当前 88,287 行 / 3,781 行不符，引用数据时以本文件为准。
