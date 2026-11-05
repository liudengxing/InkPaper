# 交接文档（HANDOFF）

> 面向「接着改代码的人 / 新开的 AI 窗口」。目标：读完这一篇就能开工，不用翻聊天记录。
> 最后更新：2026-11-05 · 版本 `1.1.57+10153`
>
> 配套文档：
> - **`docs/BUSINESS_OVERVIEW.md`** — 业务框架、13 条业务流程、参数速查、真机调试参数（改具体功能前必读）
> - `PROGRESS.md` — 逐条工作记录（最新在最前）
> - `BLOCKERS.md` — 未解决 / 待决策条目
> - `CHANGELOG.md` — 对外发布日志（**目前落后，只到 1.1.13**）

---

## 1. 一句话现状

Android 单端优先的笔记应用（Flutter），本地 SQLite + Memos 服务器同步，AI 侧有「问笔记」聊天、周/月回顾两套能力；最近一轮主要在收**图标视觉、首页滚动掉帧、卡片时间口径、语音识别卡死**四件事。

- 包名：`com.didichou.inkpaper`，深链 `inkpaper://`
- 支持的构建目标：Android（主力）/ iOS / macOS / Windows / Linux（桌面端未长期验证）

---

## 2. 怎么跑（别手写零散 flutter 命令）

```powershell
cd "f:\VibeCoding Project\InkPaper"
dart tool/inkpaper.dart doctor            # 环境检查
dart tool/inkpaper.dart deps              # flutter pub get
dart tool/inkpaper.dart analyze           # 静态分析
dart tool/inkpaper.dart test              # 全量单测（当前 530 项）
dart tool/inkpaper.dart verify            # deps + analyze + test
dart tool/inkpaper.dart build android-debug
dart tool/inkpaper.dart build android-release
dart tool/inkpaper.dart release vX.Y.Z    # 打 tag 触发 CI
```

真机（小米 HyperOS，USB 或 `adb connect 192.168.0.108:35819`）：

```powershell
adb -s 192.168.0.108:35819 install -r build/app/outputs/flutter-apk/app-release.apk
adb -s 192.168.0.108:35819 shell am force-stop com.didichou.inkpaper
adb -s 192.168.0.108:35819 shell am start -n com.didichou.inkpaper/.MainActivity
adb -s 192.168.0.108:35819 shell screencap -p /sdcard/s.png   # 再 pull 回来，别用 exec-out 直接重定向（会破坏二进制）
```

实测耗时：release 全量 ~115s，debug 增量 ~40s。release 需要 `android/key.properties`，缺失时 Gradle 直接报错。

**这台设备上 `logcat` 读不到内容**（系统侧日志缓冲区不可用），排查只能靠 `dumpsys` + 截图；release 包也不可 `run-as`，要读 `shared_prefs` / `databases` 得先装 debug 包。

---

## 3. 代码地图（改之前先认路）

> 业务怎么跑、每个流程落在哪些方法、有哪些数值参数（AI 预算、解码档位、防抖、分页、同步间隔…），见 `docs/BUSINESS_OVERVIEW.md`。本节只做「快速定位」。

| 关注点 | 位置 |
| --- | --- |
| 入口、`ImageCache` 容量配置 | `lib/main.dart` |
| 全局状态、分页加载、AI 设置 | `lib/providers/app_provider.dart` |
| SQLite（`notes.db`）、分页排序 | `lib/services/database_service.dart`（`getNotesPaged` 按 `createdAt DESC`） |
| 笔记模型（`createdAt` / `updatedAt` / `displayTime`） | `lib/models/note_model.dart` |
| 首页卡片（图片栅格、展开判定、时间） | `lib/widgets/note_card.dart` |
| 详情页九宫格（延后解码的**样板实现**） | `lib/widgets/note_image_grid.dart` |
| 大图 / Live 图查看器 | `lib/screens/image_viewer_screen.dart` |
| 编辑器（语音状态机、草稿、标签） | `lib/widgets/note_editor.dart` |
| 语音服务（仅讯飞，默认关闭） | `lib/services/speech_service.dart`、`lib/services/iflytek_speech_service.dart` |
| 周/月回顾 | `lib/services/periodic_review_service.dart`、`ai_review_service.dart`、`lib/screens/periodic_review_screen.dart` |
| 「问笔记」上下文预算 | `lib/utils/notes_context_builder.dart` |
| 图片解码像素档位 | `lib/utils/image_decode_width.dart` |
| Markdown 解析与缓存 | `lib/utils/memos_content_helper.dart` |
| DeepSeek 鲸鱼图标（矢量剪影） | `lib/widgets/deepseek_whale.dart` |
| 桌面小组件快照 / 原生渲染 | `lib/services/widget_snapshot_service.dart`、`android/app/src/main/kotlin/com/didichou/inkpaper/InkPaperWidgetProvider.kt` |

---

## 4. 最近一轮改动（2026-10-29 ~ 11-05）

| commit | 内容 | 关键实现 |
| --- | --- | --- |
| `d8f395c` | 语音默认关闭 + 只留讯飞；系统识别、百度识别全删 | `AppConfig.speechInputEnabled`（开关 && 三件套齐全）决定首页/编辑器麦克风显隐；`speech_service.dart` 892 → 135 行；移除 `speech_to_text` 依赖；`IflytekSpeechService` 补 `onDone`（VAD 判停后自动落字） |
| `c75fa13` / `eed02f3` | 结构归位（纯机械） | `widgets→screens` 2 个页面（`image_viewer_screen`、`share_image_preview_screen`）；`services→utils` 7 个纯函数工具（排序/标签/分页/同步合并/同步状态/微信读书解析/上下文预算）；逻辑零改动 |
| `8cedbe7` → `67d7339` → `bf209ca` | AI 图标统一为 DeepSeek 鲸鱼，最终定为**透明底蓝色** | `deepseek_whale.dart` 用 27×20 坐标系的三次贝塞尔路径 + `PathFillType.evenOdd` 挖空嘴/眼；按用户给的 27×20 位图逐像素拟合（IoU 0.87，剩余差异全是 1px 抗锯齿）。对外 API 只有 `size` / `color` |
| `b567c0f` | 首页含图笔记下滑卡顿 | `note_card.dart` 新增 `_DeferredThumbnail`：缩略图先铺静态灰底，按 `90ms + index×30ms` 错峰挂载 `Image`，避免九图同帧解码；补 `gaplessPlayback` + `filterQuality.low`；`MemosContentHelper.cachedExpansionText` 缓存「展开」判定用的 Markdown 解析结果（上限 300 条） |
| `6d0e4ad` | 首页卡片时间与详情页不一致 | `NoteCard.timestamp` 由 `updatedAt` 改为 `createdAt`，与详情页、与默认排序口径统一 |
| `290f9d6` | 语音「正在聆听」停不掉 | 平台调用全部加超时（`initialize`/`listen` 8s，`locales`/`hasPermission`/`stop`/`cancel` 3s）；防抖标志由 `bool` 改成 3 秒时间窗；停止改为**先复位 UI 再释放麦克风**；新增 12 秒「哑火」看门狗；`onError` 全量上报并弹提示 |

更早、但仍在生效的几个大件（当时属于「待优化清单」，现已落地）：

- `a45fa64` 卡片正文里的 `#标签` 可点击跳转标签页
- `eea1cf9` 相似笔记打分重构（内容主导，去掉时间偏置与 >100% 评分）
- `fdec40c` + `99dd120` 周/月回顾（AI 总结 + 提示词可在设置里改 + 改动自动失效旧总结）
- `d350fb0` Live 图（导入抽取内嵌视频、查看器播放）
- `fc1b832` 缩略图解码档位统一 + 延后解码（覆盖详情页九宫格与大图查看器）

---

## 5. 未解决的问题 / 待决策

详见 `BLOCKERS.md`，这里给出摘要与优先级：

| ID | 问题 | 现状与证据 | 建议 |
| --- | --- | --- | --- |
| ~~VOICE-001~~ | **已解决（1.1.57 `d8f395c`）**：不再赌设备有没有系统识别引擎 | 根因不再追：系统识别在部分国产 ROM 上「静默假启动」，留着就是隐患。改为「默认关闭 + 仅讯飞」，两个麦克风入口都由 `speechInputEnabled` 控制显隐；百度死链路一并删除。结论与验证见 `BLOCKERS.md` | 待办只剩一次讯飞端到端真机验证（本机 adb 目前连不上） |
| ORIENT-001 | **App 没有方向锁** | `lib/` 内无 `SystemChrome.setPreferredOrientations`，`AndroidManifest.xml` 无 `android:screenOrientation`；设备当前 `accelerometer_rotation=0`（锁定竖屏）、`user_rotation=0`。即：转不转完全由系统开关决定 | 若希望 App 行为确定，可在 `main()` 锁竖屏，仅在图片查看器放开横屏；需产品确认 |
| PERF-IMG-001 | **多图笔记详情页 / 大图查看器是否还卡** | `fc1b832` 已统一解码档位并延后解码，但**没有做过真机前后对比**，是否彻底解决未知 | 用 9 图笔记复测：进详情页、连续翻图、Live 图播放，看是否还有掉帧 |
| DOC-001 | **工具链噪音** | `_backup/analyze_backup.dart` 触发一条 `require_trailing_commas` info，导致 `dart tool/inkpaper.dart analyze` 退出码为 1；`CHANGELOG.md` 停在 `1.1.13`，落后约 40 个版本 | 删/忽略 `_backup/`；CHANGELOG 要么按阶段补齐，要么声明「以 PROGRESS.md 为准」 |

---

## 6. 后续计划

**P0（接着做）**

1. 讯飞语音端到端真机验证（1.1.57 已改为唯一链路）：填好三件套 → 首页出现麦克风 → 长句/断句/连续聆听 → 看 VAD 判停后是否自动落字。设备当前 `adb connect` 超时，**尚未真机验证**。
2. 图片性能复测：9 图笔记详情页滑动、大图查看器左右翻、Live 图播放，确认 `fc1b832` 的收益并决定是否继续压（例如更小的解码档位、只在静止时解码）。

**P1（下一步功能）**

3. 周/月回顾调优：提示词默认值、输出长度、无笔记/跨月边界的空态、总结导出 Markdown。
4. Live 图增强：编辑器内预览与删除、分享/备份导出时是否保留动态片段、失败降级为静态图。
5. 「问笔记」上下文预算：`notes_context_builder` 的检索命中率与 token 上限再调一轮，补「只载入了 N 条」的显式提示（已有雏形）。

**P2（有空再做）**

6. 相似笔记权重微调（基于真实使用体感，而不是单测分数）。
7. 桌面小组件与提醒的真机回归（精确闹钟权限、厂商自启动白名单、13+ POST_NOTIFICATIONS）。
8. 文档收尾：`CHANGELOG.md` 补齐或归档、`_backup/` 清理、`docs/README.md` 索引同步。

---

## 7. 硬性约定（新窗口必读）

1. **改代码就升版本**：`pubspec.yaml` 的 `version: x.y.z+N`，patch +1、`N` 同步 +1（例：`1.1.57+10153` → `1.1.58+10154`），否则真机 `install -r` 会报 `INSTALL_FAILED_VERSION_DOWNGRADE`。
2. **构建/测试只走 `dart tool/inkpaper.dart`**，不要手写零散 `flutter build`。
3. **提交粒度**：一个连贯改动一个 commit；不相关模块（CI / 业务代码 / 文档）拆开提交；只 `git add` 本次涉及的文件（仓库长期有大量未提交改动）；信息用 Conventional Commits + 中文，如 `fix(voice): ...`。
4. **不动 git config**，不用 `--amend` / `--force`，除非用户明确要求。
5. **不要删 `.codebuddy/`**；不要提交 `_backup/`、`build/`、临时截图。
6. 交付前至少跑：`dart tool/inkpaper.dart analyze`（只剩 `_backup` 那条历史 info 可忽略）+ 相关单测；改动涉及 UI / 原生能力时，装到真机点一遍再汇报。
7. 回答用中文，先给结论再给证据；性能和视觉类改动要说明「怎么验证的」。

---

## 8. 新窗口开场 Prompt（直接复制）

> 用法：整段粘贴，只改 `【本次任务】`。一次只放一件事；任务多就拆成多次对话，上下文一长模型容易开始「顺手重构」。

```text
你在 InkPaper 仓库继续开发：F:\VibeCoding Project\InkPaper
（Flutter 笔记应用，包名 com.didichou.inkpaper，深链 inkpaper://，当前版本见 pubspec.yaml，写作时 1.1.57+10153）

【这是个什么项目】
本地优先的笔记应用：纯文本/Markdown + 本地图片，数据全在本机 notes.db（schema v12，查询一律走 active_notes 视图）；
可选登录用户自建的 Memos 服务器做双向同步；AI 侧有「问笔记」（全库笔记当资料对话）和「周/月回顾」；
另有语音输入（系统/讯飞/百度三种模式）、定时提醒（Android 原生精确闹钟）、桌面小组件、Flomo/微信读书导入、JSON/ZIP 备份。

【先读，再动手】
1. docs/HANDOFF.md —— 现状、代码地图、未解决问题、硬性约定
2. docs/BUSINESS_OVERVIEW.md —— 业务框架、13 条业务流程、参数速查（AI 预算/解码档位/防抖/分页）、真机调试参数
3. PROGRESS.md 顶部 3 条记录 —— 最近做了什么
4. BLOCKERS.md 的 VOICE-001 / ORIENT-001 / PERF-IMG-001 / DOC-001
读完先用 3~5 行汇报：你理解的当前状态 + 你打算动哪几个文件 + 验收标准，等我确认后再写代码。

【本次任务】
<要改什么 / 期望行为 / 验收标准；bug 附复现步骤与设备型号>

【硬性约束】
- 改任何代码后，pubspec.yaml 的 version patch +1、versionCode +1（1.1.57+10153 → 1.1.58+10154），否则真机覆盖安装会报 VERSION_DOWNGRADE。
- 构建/测试只用 dart tool/inkpaper.dart（analyze / test / build android-debug / build android-release），不要手写零散 flutter 命令。
- 最小改动：不顺手重构无关文件、不动公开 API、不引入新依赖（确实需要先说明理由）。
- 不改数据契约：notes 表字段、rowStatus 语义、displayTime 的三种时间口径都别擅自动（见 BUSINESS_OVERVIEW §3）。
- 提交：一个连贯改动一个 commit，Conventional Commits + 中文（如 fix(voice): ...）；只 add 本次涉及的文件；不碰 git config，不用 --amend/--force。
- 不要删 .codebuddy/、_backup/、build/。

【真机参数（Android）】
- 设备：adb connect 192.168.0.108:35819（小米 HyperOS 23127PN0CC，1200×2670）；命令里显式 -s 192.168.0.108:35819。
- 装机：adb -s … install -r build/app/outputs/flutter-apk/app-release.apk（release 需要 android/key.properties）。
- 启停：adb -s … shell am force-stop com.didichou.inkpaper / am start -n com.didichou.inkpaper/.MainActivity。
- 操作：adb -s … shell input tap X Y / input swipe X1 Y1 X2 Y2 120（坐标=截图像素）。
- 截图：adb -s … shell screencap -p /sdcard/x.png → adb -s … pull /sdcard/x.png 本地路径；不要用 exec-out 重定向（会破坏二进制）。
- 没有设备就明说「未真机验证」，不要假装验证过。

【环境坑】
- 这台设备 logcat 读不到内容（系统缓冲区不可用），排查只能用 dumpsys + 截图。
- release 包不可 run-as；要读 databases/ shared_prefs/ 必须先装 debug 包。
- 常见排查命令：dumpsys audio（录音活动是否为空）、dumpsys package <pkg>（versionName）、settings get system accelerometer_rotation（方向锁）。
- release 全量构建约 115s，别中途打断；debug 增量约 40s。

【交付要求】
- 分四段汇报：改了什么（文件路径 + 关键行号）、为什么这么改、怎么验证的（命令 + 真机现象）、还剩什么风险/未验证点。
- 性能与视觉改动必须给出可复现的验证方式，不要只说「应该会变好」。
- 如果发现文档与实际代码不一致，先指出来，再改代码。
```
