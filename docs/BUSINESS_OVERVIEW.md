# 业务框架与流程 / 参数手册

> 配套 `docs/HANDOFF.md`：**HANDOFF 讲「怎么开工」，本文讲「这个 App 是怎么运转的」**。
> 最后更新：2026-11-09 · 版本 `1.1.64+10160`
> 所有结论都带文件行号依据，行号为主分支 `main` 当时快照，重构后可能漂移，按方法名检索即可。

---

## 1. 产品一句话

**InkPaper（墨鸣笔记）**：本地优先的笔记应用。核心是「纯文本 + Markdown + 本地图片」的快速记录，可选连自己的 Memos 服务器做多端同步；AI 侧提供「问笔记」（拿全库笔记当资料对话）与「周/月回顾」（AI 总结近期笔记）。

- 平台范围：只做 Android（仓库已删除 iOS / macOS / Windows / Linux / Web 工程），全部迭代在真机
- 数据主权：默认不登录也能用，全部数据在本机 `notes.db`；登录 Memos 后才双向同步
- 无自建后端：新账号/同步都指向用户自己填的 Memos 服务器；只有公告/反馈走 `https://api.didichou.site`

---

## 2. 分层与目录职责

```
lib/
  main.dart              启动、路由挂载、图片缓存、分享/通知冷启动入口
  config/                AppConfig（常量中心）、AppIdentity（包名/品牌）、环境开关
  core/state/            跨页面共享状态（7 个文件，含编辑器/选择态等）
  routes/app_router.dart go_router 路由表（唯一的页面入口清单）
  models/                数据模型（note / app_config / annotation / resource / draft …）
  providers/             AppProvider（全局状态 + 业务编排）、app_provider_sync.part.dart（同步）、app_provider_account.part.dart（账号/云验证）、settings
  services/              39 个服务：数据库、Memos API、AI、语音、通知、小组件、导入导出…
  screens/               37 个页面
  widgets/               25 个可复用组件（note_card / note_image_grid / note_editor / 批注对话框…）
  utils/                 34 个纯函数工具（标签、排序、分页、同步合并、图片锚点、Markdown、解码宽度、草稿…）
  themes/ l10n/          主题与中英文案（自建 AppLocalizationsSimple，不走 gen-l10n）
```

依赖方向：`screens/widgets → providers → services → models/utils`，**services 之间不做互相调用**。纯函数工具（`note_sorting_helper` / `sync_merge_helper` / `weread_parser` / `notes_context_builder` 等）已在 1.1.57 从 `services/` 归位到 `utils/`——它们没有 IO 和生命周期，放 services 容易误导。

1.1.59 起 `utils/` 里新增的两个编辑器工具（`note_image_anchor` / `tag_input_helper`）**刻意不认识 `MemoStyleRange`**：只返回 `({int start, int end})` 索引区间，由调用方套回样式类型。原因见 §4.13。

### 页面清单（按用途分组）

| 分组 | 页面（`lib/screens`） |
| --- | --- |
| 主流程 | `home_screen`（首页列表+底部输入胶囊）、`note_detail_screen`、`note_chat_screen`（问笔记）、`random_review_screen`、`periodic_review_screen`（周/月回顾）、`tags_screen` / `tag_notes_screen`、`notifications_screen`、`draft_box_screen`、`recently_deleted_screen` |
| 账号/服务器 | `login_screen`、`register_screen`、`forgot_password_screen`、`server_info_screen`、`webdav_settings_screen`、`account_info_screen`、`account_deletion_screen` |
| 设置 | `settings_screen`、`preferences_screen`、`user_preferences_screen`、`ai_settings_screen`、`sidebar_customization_screen`、`notion_settings_screen`、`data_cleanup_screen` |
| 导入/导出 | `import_export_main_screen`、`local_backup_restore_screen`、`flomo_import_screen`、`weread_import_screen` |
| 其他 | `onboarding_screen`、`help_screen`、`feedback_screen`、`about_screen`、`laboratory_screen`、`performance_dashboard_screen`、`knowledge_graph_screen_custom` |

### 路由（`lib/routes/app_router.dart`）

`/`（shell，含 sidebar 抽屉）下挂：`note/:id`、`edit`、`draft-box`、`recently-deleted`、`notifications`、`preferences`、`ai-settings`、`sidebar-customization`、`webdav-settings`、`server-info`、`account-info`、`data-cleanup`、`import-export`（`local-backup-restore` / `flomo-import` / `weread-import` / `notion-settings`）、`login` / `register` / `forgot-password`、`/tags`、`/random-review`、`/note-chat`、`/periodic-review`、`/knowledge-graph`、`/settings`、`/help`、`/feedback`、`/laboratory`、`/performance-dashboard`、`/onboarding`、`/welcome`、`/account-deletion`。
深链 scheme：`inkpaper://`（分享回传用 `inkpaper://share`）。

---

## 3. 数据模型（核心表）

`notes.db`（`AppConfig.databaseName`），schema 版本 **12**（`AppConfig.databaseVersion`）。

```sql
notes(
  id TEXT PK, content TEXT, createdAt TEXT, updatedAt TEXT, displayTime TEXT,
  tags TEXT,                 -- 逗号串，如 ",工作/项目,读书,"
  creator TEXT,
  is_synced INTEGER,         -- 0 = 有本地改动待推
  isPinned INTEGER,
  visibility TEXT,           -- PRIVATE / PUBLIC…
  rowStatus TEXT,            -- NORMAL / ARCHIVED / DELETED（软删）
  resourceList TEXT,         -- JSON（Memos 附件）
  relations TEXT,            -- JSON（笔记引用）
  annotations TEXT,          -- JSON（批注/待办）
  reminder_time TEXT, last_sync_time TEXT, deleted_at TEXT, remote_id TEXT
)
reminder_notifications(id, note_id, note_title, note_content, reminder_time, triggered_at, is_read, is_clicked)
pending_note_operations(note_id, operation, created_at, attempts, last_error)  -- 待推送的远端操作队列
VIEW active_notes AS SELECT * FROM notes WHERE IFNULL(rowStatus,'NORMAL') <> 'DELETED'
```

**三条铁律**：

1. 列表/分页/搜索/统计一律查 `active_notes` 视图，别直接查 `notes`，否则软删笔记会漏出来（`database_service.dart:96-102`）。
2. 写入走 `upsertNote`（先 UPDATE 非软删行、再 INSERT ignore），避免 `REPLACE` 把软删行"复活"（`database_service.dart:338-354`）。
3. 三种时间别混：
   - `createdAt`：**创建时间**，首页卡片、详情页、热度图、默认排序都用它
   - `updatedAt`：最后编辑（批注、待办勾选、同步都会改）
   - `displayTime`：**业务时间线**，缺省 = `clamp(updatedAt)`，被随机回顾 / 周月回顾 / AI 上下文 / 小组件使用；同步时按「保留本地时间线」规则处理（`sync_merge_helper.dart:169-173`）

---

## 4. 业务流程

### 4.1 新建笔记（本地优先）

`home_screen.dart:1657` 「+」→ `_showAddNoteForm` → `NoteEditor`（`showGeneralDialog` + 高斯模糊背景）→ 保存 `note_editor.dart:985 _saveNote` → `app_provider.createNote`（`app_provider.dart:2702`）→ `extractTags` → `saveNote` 落库 → **不阻塞 UI**，登录态下 `unawaited(syncNotesWithServer())` 后台推。本地新建的行 `rowStatus='NORMAL'`、`is_synced=0`。

### 4.2 编辑与草稿

- 输入防抖 **800ms** 自动暂存（`note_editor.dart:417`）
- 存 `SharedPreferences` 的 `note_editor_drafts_v2`，新笔记共用槽位 `__new__`，保留 **7 天**（`draft_service.dart:50-57`）
- 恢复策略：新建笔记直接回填；编辑已有笔记只在顶部提示「有草稿」，用户点「恢复」才覆盖（避免误盖）
- 切后台 / `dispose` 各兜底落盘一次；保存成功后 `_clearDraft()`
- 草稿箱：`draft_box_screen.dart` → 复用 `NoteEditor`

### 4.3 详情页 / 删除 / 置顶

- 卡片点击 `note_card.dart:957` → `/note/:id`；详情页复用同一个 `NoteEditor` **类**但每次新实例（不是共享实例）
- 删除：菜单 → `NoteActionsUi.deleteNote` → 软删（`rowStatus='DELETED'`）→ 有撤销窗口 → 超时才提交远端删除
- 置顶：`app_provider.togglePinStatus`（本地 `isPinned`，同步时本地优先）
- **归档无 UI 入口**：只有服务端 `rowStatus=ARCHIVED` 与 l10n 文案，`_isVisibleNote` 会把它过滤掉

### 4.4 Memos 同步（双向，冲突有明确优先级）

- 触发：下拉刷新、启动后台、登录后、全量上传
- 鉴权：token 存 `flutter_secure_storage`（key `auth_token`），请求头 `Authorization: Bearer $token`（`api_service_factory.dart:120`）
- 拉取：`pageSize=1000` + `pageToken` 循环，直到 `isComplete`；**不足一页时跳过本地删除清理**，避免把尚未拉到的远端笔记误删（`app_provider_sync.part.dart:136`）
- 合并（`sync_merge_helper.dart:125-188`）优先级：
  1. 本地 `is_synced=0` → **整条保留本地**
  2. 正文比较前先归一化（忽略附件 uid 差异）
  3. 本地创建时间早于服务端 → 保留本地时间线（`displayTime`）
  4. `isPinned / annotations / relations / reminderTime` **一律取本地**
  5. 冲突只用于计数提示，不做三方合并
- 失败重试：`pending_note_operations` 队列 + `attempts/last_error`

### 4.5 系统分享导入（不落库，先预填）

- Android：`AndroidManifest.xml:72-111`（`SEND` text/image/\*、`SEND_MULTIPLE`、`PROCESS_TEXT`）→ `MainActivity.handleIntent` → MethodChannel `onSharedPayload` → `shared_payload_utils.dart` 归一化 → 路由 `extra: {'sharedContent': …}` → **打开编辑器预填**，用户点保存才 `createNote`
- 类型分支：纯文本原文 / 单图 `![图片](file://…)` / 多图多行 / 文件 `📎 文件名 + 路径`
- 没有「链接/书签」专有处理，URL 当文本

### 4.6 导入 / 导出

- Flomo HTML 导入：解析 → 逐条 `saveNote` → 重复检测（`_detectDuplicates`）→ 图片校验
- 本地备份：JSON（可选加密，后缀 `.enc`）或 Markdown+图片 ZIP（含 `resource_manifest.json`），文件名 `momingbiji_backup_<ts>`
- 导出 Markdown 带 front matter：`id / createdAt / updatedAt / displayTime / tags / rowStatus / annotations / reminderTime`，便于回导还原本地字段
- 微信读书导入：`weread_parser.dart` + `weread_import_screen`
- Notion / WebDAV：`notion_sync_service`、`webdav_sync_engine`（44KB，本次未展开）

### 4.7 标签体系

- 解析正则：`(?<![\w:/])(?!##)#([^\s\[\],，、;；:：！!？?\n#]+)`（`tag_utils.dart:11`），逐行剔除 URL 内的 `#`
- 多层级用 `/`：`normalizeTagPath` 归一 + `tagPathMatches` 前缀匹配
- 存储是逗号串，SQL 用「前后补逗号整词匹配」（`database_service.dart:180`），避免 `LIKE '%tag%'` 命中同前缀标签
- 点卡片正文里的 `#标签` → `/tags?tag=<path>`
- **重命名/删除标签未实现**（只有置顶/复制）

### 4.8 排序 / 搜索 / 随机回顾

- 排序枚举 `newest / oldest / updated / updatedOldest`，**先按 `isPinned` 再按枚举**（`note_sorting_helper.dart:4`）
- 搜索：输入防抖 **240ms** → `AppProvider.searchNotes` → SQL；分页 `_pageSize = 50`
- 随机回顾：按 `displayTime` 距今 `reviewDays` 过滤 → 标签 all-match → 不足则回落全集 → shuffle 取 N（`random_review_selector_service.dart:10-52`）；同屏「那年今日」来自 `loadNotesOnThisDay()`

### 4.9 提醒（Android 走原生闹钟，不是 Timer）

- 菜单设提醒 → 先调度成功才写 `reminder_time`（避免"显示有提醒其实没排上"）
- Android：MethodChannel `com.didichou.inkpaper/native_alarm` → `MainActivity` `setExactAndAllowWhileIdle(RTC_WAKEUP)`；**12+ 无精确闹钟权限时降级普通闹钟**
- 触达：`AlarmReceiver` 建/修渠道 `note_reminders_v2`，发高优先级锁屏可见通知，点击带 `noteId` 回 `MainActivity`，并落 `reminder_notifications`
- 已知：Android 不强制精确闹钟权限，只上报状态

### 4.10 桌面小组件

- Dart 侧：`widget_snapshot_service` 在增删改/加载完成/同步状态变化时触发，**350ms 防抖**，JSON 未变则跳过下发
- 通道：`com.didichou.inkpaper/native_alarm`，原生写 `SharedPreferences("inkpaper_widget")`
- 快照字段：`schemaVersion / generatedAt / today{notes,words,tags,pendingTodos} / sync{mode,status,message,unsyncedCount} / quickTags(≤5) / reviewConfig{refreshIntervalMinutes,rangeDays} / reviewNotes(≤8)`
- 只把 `rowStatus` 为 NORMAL/空 的笔记放进快照；**原生侧不展示日期**，不存在"首页改 createdAt 而小组件还是 updatedAt"的不一致

### 4.11 AI：问笔记 + 周/月回顾

- 通用：OpenAI 兼容 `POST {aiBaseUrl}/chat/completions`，`Authorization: Bearer <aiApiKey>`（key 由用户自填，默认模型 `deepseek-chat`）
- **问笔记**（`notes_qa_service.dart`）：先把问题做关键词检索（IDF 权重 + 标签提权），再用最近笔记填剩余预算 → 拼上下文 → `temperature 0.5 / max_tokens 1600`
- **周/月回顾**（`periodic_review_service` + `ai_review_service`）：按 `displayTime` 窗口取近 7/30 天 → 生成提示词（可在 AI 设置里改）→ `temperature 0.45 / max_tokens 520`；提示词改动会让旧总结失效
- **上下文预算**（`notes_context_builder.dart:56-63`）：总字符 **28000**、最多 **200** 条笔记、其中相关命中最多 **80** 条、单条截断 **400** 字符
- 全局兜底：`AppConfig.aiRequestTimeoutSeconds = 30`，`aiMaxTokens = 2000`

- **自定义提示词**（1.1.61 / 1.1.62 整理后共三块）：点评 `customReviewPrompt`（`ai_review_service:79`）、续写 `customContinuationPrompt`、回顾 `customPeriodicReviewPrompt`（`periodic_review_service:406`）。三者由同一个开关 `useCustomPrompt` 统一放行
- 开关语义（1.1.62 起）：**开着但某块留空 = 该功能用默认提示词**，不是「没启用」。两个消费者本来就是按字段判空再回退，保存时不再把开关改回 `false`（旧逻辑会让开关静默弹回，用户以为没保存成功）
- 1.1.61 已删除没有入口的「AI 洞察」页与它的两块提示词（洞察 / 标签洞察）；1.1.63 又删掉同为零消费者的「标签推荐提示词」（`customTagRecommendationPrompt`）与配套孤儿文案，详见 `BLOCKERS.md` TAG-REC-001

### 4.12 语音输入（1.1.57 起：默认关闭，仅讯飞）

- **只有一条链路**：设置为「语音输入」开关打开 + 讯飞 APPID/APIKey/APISecret 填全 → `AppConfig.speechInputEnabled == true`。系统识别（`speech_to_text`）与百度识别已整体移除（见 `BLOCKERS.md` `VOICE-001`）
- **入口显隐跟着开关走**：首页底部输入条右侧麦克风、编辑器右上角麦克风都只在 `speechInputEnabled` 为真时渲染；默认配置下应用内没有任何语音入口
- 识别实现：`speech_service.dart`（门面 + 权限）→ `iflytek_speech_service.dart`（`wss://iat-api.xfyun.cn/v2/iat`，`record` 采 PCM16/16kHz，VAD `vad_eos=3000`）
- 收尾语义：讯飞判停（status=2）或连接关闭时回调一次 `onDone` → 编辑器落字并复位「正在聆听」；用户主动停止则先复位 UI 再释放麦克风
- 编辑器兜底（`note_editor.dart`）：3s 防抖窗口、**12s 无声音无结果自动收尾**（看门狗）、错误走 SnackBar
- 设置入口：AI 设置 → 语音输入（开关 + 三件套 + 连接测试 + 对接教程）

### 4.13 图片管线

- 导入：编辑器粘贴/选择 → 复制进应用私有目录（`_saveImageLocally`），Markdown 里写 `file://` 路径
- 解码：统一走 `image_decode_width.dart` 的档位 `160/240/320/480/720/1080`；网格缩略图收敛到 **480/720**，让列表与详情命中同一份 `ImageCache`
- 缓存：`ImageCache.maximumSize = 300` 条、`maximumSizeBytes = 300MB`（`main.dart:168-169`）
- 首屏优化：卡片缩略图 `90ms + index×30ms` 错峰挂载；进详情前 `precacheImage` 预取；大图查看器同样延后解码
- Live 图：导入时识别 Motion Photo / 配对 MOV，抽视频到私有目录，查看器用 `video_player` 播放；失败降级为静态图
- **编辑区的图片锚点换算**（1.1.59 抽到 `utils/note_image_anchor.dart`）：编辑框里显示的是去掉 `![]()` 之后的纯文本，图片以卡片插在视觉位置。两道换算都在这个文件里：
  - 打字时：`shiftImageOffsets` 用公共前后缀求出差异区间，把每个图片的 `offset` 平移过去（`null` 表示该图已删除，保留占位）
  - 保存时：`splitRangeByImages` 把加粗/斜体等样式区间**在图片位置断开**再平移，避免 `![]()` 被样式包进去
  - 它只返回 `({int start, int end})`，不认识 `MemoStyleRange`——因为后者定义在 `widgets/memo_editing_controller.dart`，让 utils 反过来依赖 widgets 会破坏分层

---

## 5. 关键参数速查

### 5.1 应用与构建

| 项 | 值 |
| --- | --- |
| 包名 / applicationId | `com.didichou.inkpaper` |
| 展示名 | `InkPaper` / 全称 `InkPaper-墨鸣笔记` |
| 深链 | `inkpaper://`（分享回传 `inkpaper://share`） |
| 数据库 | `notes.db`，schema v12，视图 `active_notes` |
| 默认 WebDAV 路径 | `/InkPaper/` |
| MethodChannel | `com.didichou.inkpaper/native_alarm` |
| 通知渠道 | `note_reminders_v2`（「笔记提醒」） |
| 官方站点 / 反馈 | `https://inkpaper.cn/`、`https://api.didichou.site/feedback` |
| 构建注入 | `--dart-define=SENTRY_DSN=…`（可选）；`ENVIRONMENT` 默认 `development` |
| 版本真源 | `pubspec.yaml` 的 `version: x.y.z+N`（`PackageInfo` 读取） |

### 5.2 缓存 / 性能

| 项 | 值 |
| --- | --- |
| ImageCache | 300 条 / 300 MB |
| 解码档位 | 160 / 240 / 320 / 480 / 720 / 1080；网格 480 或 720 |
| 卡片缩略图延迟 | 90ms 起，按序号 +30ms 错峰 |
| 详情页九宫格延迟 | 90ms（`note_image_grid.dart`） |
| 搜索防抖 | 240ms |
| 草稿防抖 | 800ms |
| 小组件快照防抖 | 350ms |
| 本地分页 | 50 条 / 页 |
| 远端拉取分页 | 1000 条 / 页 |

### 5.3 AI

| 项 | 值 |
| --- | --- |
| 协议 | OpenAI 兼容 `/chat/completions` |
| 默认模型 | `deepseek-chat` |
| 超时 | 30s，重试 3 次 |
| 问笔记 | temperature 0.5 / max_tokens 1600 |
| 周月回顾 | temperature 0.45 / max_tokens 520 |
| 摘要类工具 | temperature 0.3 |
| 默认上限 | max_tokens 2000 |
| 上下文 | 28000 字符 / 200 条 / 相关 80 条 / 单条 400 字符 |

### 5.4 同步与提醒

| 项 | 值 |
| --- | --- |
| 同步间隔 | 默认 300s，范围 60s ~ 3600s |
| 鉴权存储 | `flutter_secure_storage`，key `auth_token` / `refresh_token` |
| SharedPreferences | 主配置文件 `FlutterSharedPreferences`；小组件 `inkpaper_widget`；草稿 `note_editor_drafts_v2` |
| 提醒调度 | Android `setExactAndAllowWhileIdle`（无权限时降级普通闹钟） |

---

## 6. 真机调试参数（本机环境）

| 项 | 值 / 做法 |
| --- | --- |
| 设备连接 | `adb connect 192.168.0.108:35819`（小米 HyperOS，`23127PN0CC`） |
| 设备别名 | 命令里用 `-s 192.168.0.108:35819` 显式指定（同机还会以 mDNS 形式重复出现） |
| 安装 | `adb -s … install -r build/app/outputs/flutter-apk/app-release.apk` |
| 启动 / 停止 | `am start -n com.didichou.inkpaper/.MainActivity`、`am force-stop com.didichou.inkpaper` |
| 截图 | `adb shell screencap -p /sdcard/x.png` → `adb pull`（**不要** `exec-out > file`，PowerShell 会把二进制改坏） |
| 点击/滑动 | `adb shell input tap X Y` / `input swipe X1 Y1 X2 Y2 时长ms`（坐标 = 截图像素，屏幕 1200×2670） |
| 日志 | **本机 logcat 读不到内容**（系统缓冲区不可用），排查靠 `dumpsys` + 截图 |
| 数据库 | debug 包：`adb shell run-as com.didichou.inkpaper ls databases`；release 包不可 `run-as` |
| 偏好设置 | `shared_prefs/FlutterSharedPreferences.xml`（同样需要 debug 包） |
| 录音/音频排查 | `adb shell dumpsys audio`（看 Recording Activity 是否为空） |
| 方向 | `settings get system accelerometer_rotation`（0 = 锁定）、`user_rotation`（0 = 竖屏） |
| 构建耗时 | release 全量 ≈ 115s；debug 增量 ≈ 40s；debug APK ≈ 176–221MB（三套 ABI） |
| 签名 | release 需要 `android/key.properties`（缺失则 Gradle 直接失败） |

---

## 7. 已知边界（写代码前先确认不是"设计如此"）

1. 标签重命名 / 删除、归档 / 取消归档：**没有 UI**，只有文案与数据字段。
2. `AppConfig.isFeatureEnabled('speech_to_text')` 是历史功能开关表里的死键（`false`），**不参与任何逻辑**；语音真正的开关是 `AppConfig.iflytekSpeechEnabled`（配合三件套，见 §4.12）。
3. `notification_service.dart` 里仍有 `_activeTimers` 残留字段与「使用 Timer」的旧注释，实际调度走系统闹钟。
4. WebDAV / Notion 两条同步链路未纳入本文梳理，改它们前单独读 `webdav_sync_engine.dart`、`notion_sync_service.dart`。
5. `_backup/` 目录里的旧脚本会污染 `flutter analyze`（见 `BLOCKERS.md` `DOC-001`）。
