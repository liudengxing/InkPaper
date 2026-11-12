# 交接文档（HANDOFF）

> 面向「接着改代码的人 / 新开的 AI 窗口」。目标：读完这一篇就能开工，不用翻聊天记录。
> 最后更新：2026-11-09 · 版本 `1.1.64+10160`
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
- 支持的构建目标：只有 Android（APK / AAB）；iOS、macOS、Windows、Linux、Web 工程已于 2026-11-12 删除

---

## 2. 怎么跑（别手写零散 flutter 命令）

```powershell
cd "f:\VibeCoding Project\InkPaper"
dart tool/inkpaper.dart doctor            # 环境检查
dart tool/inkpaper.dart deps              # flutter pub get
dart tool/inkpaper.dart analyze           # 静态分析
dart tool/inkpaper.dart test              # 全量单测（当前 579 项）
dart tool/inkpaper.dart verify            # deps + analyze + test
dart tool/inkpaper.dart build android-debug
dart tool/inkpaper.dart build android-release
dart tool/inkpaper.dart release vX.Y.Z    # 打 tag 触发 CI
```

真机（小米 14 / HyperOS，`23127PN0CC`，1200×2670，density 480）：

```bash
# 端口不固定：每次关开「无线调试」都会重新分配，配对端口和主端口也不同。
# 手机 开发者选项 → 无线调试：顶部「IP 地址和端口」= 主端口；
# 「使用配对码配对设备」弹窗里的 IP:端口 + 6 位码 = 配对用。
adb pair 192.168.0.108:<配对端口> <6位配对码>
adb connect 192.168.0.108:<主端口>

export MSYS_NO_PATHCONV=1        # Git Bash 必需，否则 /sdcard/x.png 被改写成 Windows 路径
D="-s 192.168.0.108:<主端口>"
adb $D install -r build/app/outputs/flutter-apk/app-release.apk
adb $D shell am force-stop com.didichou.inkpaper
adb $D shell am start -n com.didichou.inkpaper/.MainActivity
adb $D shell screencap -p /sdcard/s.png   # 再 pull 回来，别用 exec-out 直接重定向（会破坏二进制）
```

**环境坑（2026-11-05 实测）**：

1. **adb server 在每条命令结束时会被回收**（本机沙箱行为），下一条命令重新拉起 daemon 就丢了连接——**每条 adb 命令前都要重新 `adb connect`**，或把 connect 和操作写进同一条命令。
2. **Git Bash 会改写路径**：`/sdcard/x.png` 被换成 `F:/.../sdcard/x.png`，`screencap` 直接失败。必须 `export MSYS_NO_PATHCONV=1`。
3. **默认输入法是微信输入法的插件服务**（`com.tencent.wetype/.plugin.hld.WxHldService`）时 `input text` 完全不生效（文字被吞成剪贴板建议）。临时切搜狗 `adb shell ime set com.sohu.inputmethod.sogou.xiaomi/.SogouIME`，验完切回。
4. **截图写 `/sdcard/` 会进系统相册**（小米「安全访问」图片选择器里能看到全部截图），验完必须 `rm`。
5. **HyperOS 息屏省电**时 ping 从 1ms 涨到 80~150ms 且抖动，属正常，别误判成「不在同一局域网」。
6. **坐标别靠肉眼换算**：`uiautomator dump` 能取到 Flutter 工具栏按钮的精确 `bounds`。按「截图 480px 宽 → 实际 1200px，比例 2.5」手算会偏 10~170px，用 dump 出来的 center 最稳。

实测耗时：release 全量 ~115s，debug 增量 ~40s。release 需要 `android/key.properties`，缺失时 Gradle 直接报错。

**这台设备上 `logcat` 读不到内容**（系统侧日志缓冲区不可用），排查只能靠 `dumpsys` + 截图；release 包也不可 `run-as`，要读 `shared_prefs` / `databases` 得先装 debug 包。

---

## 3. 代码地图（改之前先认路）

> 业务怎么跑、每个流程落在哪些方法、有哪些数值参数（AI 预算、解码档位、防抖、分页、同步间隔…），见 `docs/BUSINESS_OVERVIEW.md`。本节只做「快速定位」。

| 关注点 | 位置 |
| --- | --- |
| 入口、`ImageCache` 容量配置 | `lib/main.dart` |
| 全局状态、分页加载、笔记增删改（统一收尾 `_commitNoteChange`） | `lib/providers/app_provider.dart`（4460 行） |
| 账号信息、登录信息存取、API 服务初始化、Token 过期、头像预加载 | `lib/providers/app_provider_account.part.dart`（`AppProvider` 的 part，extension） |
| 服务端拉取与合并 | `lib/providers/app_provider_sync.part.dart`（同上） |
| SQLite（`notes.db`）、分页排序 | `lib/services/database_service.dart`（`getNotesPaged` 按 `createdAt DESC`） |
| 笔记模型（`createdAt` / `updatedAt` / `displayTime`） | `lib/models/note_model.dart` |
| 首页卡片（图片栅格、展开判定、时间） | `lib/widgets/note_card.dart` |
| 详情页九宫格（延后解码的**样板实现**） | `lib/widgets/note_image_grid.dart` |
| 大图 / Live 图查看器 | `lib/screens/image_viewer_screen.dart` |
| 编辑器（语音状态机、草稿、标签） | `lib/widgets/note_editor.dart` |
| 编辑器里的图片锚点偏移换算 | `lib/utils/note_image_anchor.dart`（`shiftImageOffsets` / `splitRangeByImages`） |
| `#` 标签补全（前缀识别、候选排序、插入） | `lib/utils/tag_input_helper.dart` |
| 批注（侧边栏 + 三个对话框 + 写操作） | `lib/widgets/note_annotation_dialogs.dart` |
| 「引用笔记」选择框 | `lib/widgets/note_reference_dialog.dart` |
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
| `1ee212e` | 清理：iOS 语音权限 + analyze 归零 | 删 `NSSpeechRecognitionUsageDescription`；`analysis_options.yaml` exclude 加 `_backup/**`，`analyze` 退出码首次为 0 |
| `f719baa` | L1 抽出三块寄生 UI | `_AiInsightScreen`(977) → `screens/ai_insight_screen.dart`；`_NoteReferenceDialog`(382) → `widgets/note_reference_dialog.dart`；批注 CRUD **两处漂移副本合并**为 `widgets/note_annotation_dialogs.dart`。home 2926→1950、note_card 1630→1298、note_actions_ui 1791→1413 |
| `3eae4f8` | L2 抽纯函数 + 39 项单测 | `utils/note_image_anchor.dart`、`utils/tag_input_helper.dart`；note_editor 3850→3293；新文件不认识 `MemoStyleRange`，只返回索引，避免 `utils → widgets` 逆依赖 |
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
| ~~VOICE-001~~ | **已解决（1.1.57 `d8f395c`）**：不再赌设备有没有系统识别引擎 | 根因不再追：系统识别在部分国产 ROM 上「静默假启动」，留着就是隐患。改为「默认关闭 + 仅讯飞」，两个麦克风入口都由 `speechInputEnabled` 控制显隐；百度死链路一并删除。结论与验证见 `BLOCKERS.md` | 语音入口显隐已在 1.1.59 真机确认（首页/编辑器均无麦克风）；**讯飞端到端仍未验**——设备没配密钥 |
| ORIENT-001 | **App 没有方向锁** | `lib/` 内无 `SystemChrome.setPreferredOrientations`，`AndroidManifest.xml` 无 `android:screenOrientation`；设备当前 `accelerometer_rotation=0`（锁定竖屏）、`user_rotation=0`。即：转不转完全由系统开关决定 | 若希望 App 行为确定，可在 `main()` 锁竖屏，仅在图片查看器放开横屏；需产品确认 |
| PERF-IMG-001 | **多图笔记详情页 / 大图查看器是否还卡** | `fc1b832` 已统一解码档位并延后解码，但**没有做过真机前后对比**，是否彻底解决未知 | 用 9 图笔记复测：进详情页、连续翻图、Live 图播放，看是否还有掉帧 |
| ~~DOC-001~~ | **已解决（1.1.58 `1ee212e` + 2026-11-09 文档整理）**：工具链噪音清理完毕 | `_backup/` 进 `analysis_options.yaml` 的 exclude，`analyze` 退出码归 0；`CHANGELOG.md` 按「以 PROGRESS.md 为准」结项，文件头声明历史断档原因，并补齐 `1.1.57`–`1.1.62` | 无需后续动作 |
| SHARE-001 | **系统分享进来没弹预填编辑器**（2026-11-06 新发现） | 用 adb 合成 `ACTION_SEND text/plain` 打进 1.1.62 release 包，冷启动与后台两种情形都停在首页。原生载荷键名与 Dart 解析对得上，release 包 `ReleaseLog` 静默，logcat 无线索 | 先在微信里长按转发一次确认真伪；真坏了换 debug 包抓 `已通知Flutter处理分享内容` 定位。「微信 → 笔记」目前只靠这条手动通道 |
| ~~TAG-REC-001~~ | **已解决（1.1.63）**：「标签推荐提示词」死配置已删除 | 溯源确认它是原「相关标签推荐」（`tag_ai_service.dart`，TF-IDF + LLM 合并）的提示词，而该服务在 v1.0.0 基线 `ca0ed14` 导入时就零调用，`33c9647` 清理死代码时整文件删除。已删设置页输入框 + `AppConfig` 字段 + 6 个孤儿文案键，帮助页能力说明同步更正 | 无需后续动作；新增设置项时务必同时确认有真实读者 |

---

## 6. 后续计划

**P0（接着做）**

1. 讯飞语音端到端真机验证（1.1.57 已改为唯一链路）：填好三件套 → 首页出现麦克风 → 长句/断句/连续聆听 → 看 VAD 判停后是否自动落字。**1.1.59 已真机确认「关闭时无麦克风」，开启态与识别链路仍未验（设备没配讯飞密钥）**。
2. 图片性能复测：9 图笔记详情页滑动、大图查看器左右翻、Live 图播放，确认 `fc1b832` 的收益并决定是否继续压（例如更小的解码档位、只在静止时解码）。
3. 分享导入复验（SHARE-001）：微信长按消息 → 转发到 InkPaper，确认分享面板里有入口且编辑器预填；同时复验浏览器与阅读器的分享。

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

1. **改代码就升版本**：`pubspec.yaml` 的 `version: x.y.z+N`，patch +1、`N` 同步 +1（例：`1.1.62+10158` → `1.1.63+10159`），否则真机 `install -r` 会报 `INSTALL_FAILED_VERSION_DOWNGRADE`。
2. **构建/测试只走 `dart tool/inkpaper.dart`**，不要手写零散 `flutter build`。
3. **提交粒度**：一个连贯改动一个 commit；不相关模块（CI / 业务代码 / 文档）拆开提交；只 `git add` 本次涉及的文件（仓库长期有大量未提交改动）；信息用 Conventional Commits + 中文，如 `fix(voice): ...`。
4. **不动 git config**，不用 `--amend` / `--force`，除非用户明确要求。
5. **不要删 `.codebuddy/`**；不要提交 `_backup/`、`build/`、临时截图。
6. 交付前至少跑 `dart tool/inkpaper.dart verify`（= `deps` → 格式门禁 → `analyze` → `test`，与 CI 完全同一条命令；**analyze 必须 0 issue、退出码 0**，`_backup/` 已 exclude）。改动涉及 UI / 原生能力时，装到真机点一遍再汇报。
7. 回答用中文，先给结论再给证据；性能和视觉类改动要说明「怎么验证的」。
8. **行尾与格式**：仓库有 `.gitattributes`（`* text=auto eol=lf`），索引与检出都按 LF，Windows 上不要手动转 CRLF、也不要把编辑器改成 CRLF 保存，否则 diff 会变成整文件重写。格式问题用 `dart tool/inkpaper.dart format` 检查、`format --fix` 就地重排；**必须先 `deps` 再检查**，否则 `dart format` 读不到 pubspec 的语言版本、会退回 tall style 造成满屏假差异。CI 的 Flutter 版本已固定为 `3.47.7`（两个 workflow 的 `FLUTTER_VERSION`），升级时两处一起改。

---

## 8. 新窗口开场 Prompt（直接复制）

> 用法：整段粘贴，只改 `【本次任务】`。一次只放一件事；任务多就拆成多次对话，上下文一长模型容易开始「顺手重构」。

```text
你在 InkPaper 仓库继续开发：F:\VibeCoding Project\InkPaper
（Flutter 笔记应用，包名 com.didichou.inkpaper，深链 inkpaper://，当前版本见 pubspec.yaml，写作时 1.1.64+10160）

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
- 改任何代码后，pubspec.yaml 的 version patch +1、versionCode +1（1.1.62+10158 → 1.1.63+10159），否则真机覆盖安装会报 VERSION_DOWNGRADE。
- 构建/测试只用 dart tool/inkpaper.dart（analyze / test / build android-debug / build android-release），不要手写零散 flutter 命令。
- 最小改动：不顺手重构无关文件、不动公开 API、不引入新依赖（确实需要先说明理由）。
- 不改数据契约：notes 表字段、rowStatus 语义、displayTime 的三种时间口径都别擅自动（见 BUSINESS_OVERVIEW §3）。
- 提交：一个连贯改动一个 commit，Conventional Commits + 中文（如 fix(voice): ...）；只 add 本次涉及的文件；不碰 git config，不用 --amend/--force。
- 不要删 .codebuddy/、_backup/、build/。

【真机参数（Android）】
- 设备：小米 14 / HyperOS 23127PN0CC，1200×2670。**无线调试端口每次关开都会变**，先 `adb pair IP:配对端口 6位码` 再 `adb connect IP:主端口`；命令里显式 -s。
- 装机：adb -s … install -r build/app/outputs/flutter-apk/app-release.apk（release 需要 android/key.properties）。
- 启停：adb -s … shell am force-stop com.didichou.inkpaper / am start -n com.didichou.inkpaper/.MainActivity。
- 操作：adb -s … shell input tap X Y / input swipe X1 Y1 X2 Y2 120（坐标=设备像素）；精确坐标用 `uiautomator dump` 取 bounds，别拿截图手算。
- 截图：adb -s … shell screencap -p /sdcard/x.png → adb -s … pull /sdcard/x.png 本地路径；不要用 exec-out 重定向（会破坏二进制）。Git Bash 必须先 `export MSYS_NO_PATHCONV=1`；**截图存 /sdcard/ 会进相册，验完删掉**。
- 每个 Bash 调用结束 adb server 会被回收，**每条命令都要重新 connect**；默认输入法是微信输入法插件服务时 `input text` 无效，需临时切搜狗。
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
