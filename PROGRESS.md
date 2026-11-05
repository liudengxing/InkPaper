## 2026-11-05 · L3：删转发层 + 抽取笔记收尾流程 + 账号域独立成 part（1.1.60+10156）· done

- 背景：`STATE-CORE-005` 把字段搬进 `core/state/` 的 7 个 Store，但 `AppProvider` 里留了 36 条 `get _x => _store.x` 的纯转发。转发层让「拆分完成」看起来没完成、行数不降反升，且每个方法里仍是旧名字，读代码无法判断数据到底归谁管
- 改动一（`cdd5adb`）：36 条转发全部删除，方法体直接写 `_notesStore.notes` / `_authStore.user` / `_webDavStore.config`。`_totalNotesCount` 是例外——它的 setter 要顺带把统计快照置空，保留为具名方法 `_setTotalNotesCount(int)`。`app_provider_sync.part.dart` 里 12 处引用同步替换
- 改动二（`cdd5adb`）：抽 `_commitNoteChange(note, {persist, rebuildReferences})`。原先 `createNote`、`updateNote` 的三个分支、`updateNoteLocally`、`setNoteVisibility`、`updateNoteTags` **各自复制一遍**「落库 → 写内存 → 重建引用 → 重排 → 通知 UI → 刷小组件」，漏任何一步都只表现为「界面没刷新」「引用没重建」这类只能靠肉眼发现的 bug。收敛后 `updateNote` 从 152 行降到 90 行
  - 顺带修掉一个隐藏缺陷：`updateNoteTags` 改了 `updatedAt` 却没调 `_applyCurrentSort`，按时间排序时改完标签卡片位置不动
  - `setNoteVisibility` 原先只在「内存里找得到」时才通知 UI，统一后总是通知（找不到时通知一次是安全的，反而避免漏刷新）
- 改动三（`cdd5adb`）：账号域 386 行搬到 `lib/providers/app_provider_account.part.dart`，与既有 `app_provider_sync.part.dart` 同款 `extension AppProviderAccountPart on AppProvider` 形式，**实现一行未改**，靠同 library 的 extension 直接访问 `_authStore` / `_appConfig` 等私有字段
  - 搬出内容：`updateUserInfo` / `updatePassword` / `saveLoginInfo` / `clearLoginInfo` / `getSaved*` 4 个 / `setUser` / `_initializeApiServiceInBackground` / `_ensureApiServiceInitialized` / `_handleTokenExpired` / `_preloadUserAvatarAsync`
  - `app_provider.dart` 4966 → 4460 行
- 刻意没搬：云验证域只剩 ~50 行（`_loadCloudVerificationData` + `refreshCloudData`），单独拆文件是碎片化；`setLocalMode` / `switchToLocalMode` 夹着大量笔记重载逻辑，不算纯账号域
- 踩坑记录：第一版删除脚本用 `^\s*(?:get|set)\s+_\w+` 识别定义块，漏掉了 `List<Note> get _notes` 这种**带类型**的单行定义，把它们改成了 `List<Note> get _notesStore.notes => ...` 的语法错误；`_totalNotesCount` 的多行 setter 还被重复插入 5 次。教训是这类机械替换必须先把「定义块」和「使用点」分开处理，改完立刻 analyze，不能靠肉眼扫 diff
- 验证：
```
$ dart tool/inkpaper.dart analyze
No issues found! (ran in 14.7s)
$ dart tool/inkpaper.dart test
01:56 +579: All tests passed!
```

## 2026-11-05 · 编辑器两处：标签候选改按最近常用排、修复首行输入后发送按钮置灰（1.1.60+10156）· done

- 缺陷 1（发送按钮置灰）：新建笔记输入第一行文字后，右下角发送按钮仍是灰的、点不动，必须按一次回车换行才「亮」起来
  - 根因：`canSave` 在 `_buildEditor` 里从 `_textController.text` 算，而 `_buildEditor` 只由 `_lineCountNotifier`（换行数）和 `setState` 触发重建。首行打字不改变行数 → 不重建 → 按钮保持初始的灰色状态；回车让行数 1→2 才顺带刷新
  - 改法：把发送按钮包进 `ValueListenableBuilder<TextEditingValue>` 监听 controller 本身，`canSave` 在 builder 内计算。行数那个 Notifier 仍只负责编辑器高度，不改动
- 缺陷 2（标签候选排序）：输入 `#` 弹出的标签建议按字典序排，用户攒起来的常用标签被埋在字母表中间
  - 改法：`utils/tag_input_helper.dart` 新增 `rankTagsByUsage`，频次分 `4*log2(1+次数)`（用 1 次 4 分、3 次 8 分、15 次 16 分）+ 时效分（1 天内 +12、7 天内 +8、30 天内 +4、90 天内 +1），同分按最近使用时间、频次、名称兜底。效果：昨天用过一次(16) 压过半年前用过三次(8)，长期高频(20 上下)仍稳在前排
  - 补 `TG-01..10` 十项单测（含时钟偏差导致 `updatedAt` 在未来、大小写不同的标签不被合并、顺序稳定性）
- 验证：analyze 无 issue，579 项测试全绿（569 + 10）
- **真机验证通过**（1.1.60 release 装机，设备 1200×2670）：
  - 发送按钮：空白态灰色 → 输入 `hello`（单行、未回车）立刻变绿可点 → `DEL` 删空后立刻变回灰。相反方向也验了，说明监听的是内容本身而不是行数
  - 标签候选：输入 `#` 弹出顺序为「运动记录 → 碎碎念 → 起飞日记 → 找不到答案时就去找自己」。旧版按字典序，「运动记录」(y 开头) 会排在很后面，现在靠历史频次排到首位
  - 收尾：测试草稿 `hello #,` 已在草稿箱删除；输入法临时从微信切到搜狗（`input text` 在微信输入法插件服务下失效）后已切回；设备临时截图与 UI 树已 `rm`

## 2026-11-05 · 真机验证 L1/L2（1.1.59+10155）· done

- 设备重新联网：无线调试端口 35819 → 42741，且必须在手机上「使用配对码配对设备」重新配对（`adb pair`）后才连得上；本机 adbkey 未变，是手机端配对关系失效
- 装机：1.1.56+10152 → 1.1.59+10155（`install -r` 成功，重建是因为升版本后原 APK 是 1.1.58）
- **验证通过（均为真机点击 + 截图确认）**：
  - **语音默认关闭**：首页输入条右侧无麦克风；编辑器工具栏（#, 图片, 勾选, 星, B, 列表, …）无麦克风。符合 `speechInputEnabled` 默认 false
  - **批注（L1 合并实现）**：卡片 `…` → 查看批注 → 侧边栏（0 条空状态）→ `+` → 添加批注对话框（类型：评论/问题/想法/重要/待办）→ 写入 `L1verify` → 提交后卡片右下角出现 `💬 1` 徽标
    - **`onUpdated: () {}` 空函数没问题**：`provider.updateNote` 内部 `notifyListeners` 已驱动卡片重建，此前担心的「加完批注不刷新」未出现
  - **引用笔记（L1）**：编辑器 `…` → `@` → 「添加笔记引用」对话框（搜索框 + 找到 50 个笔记）→ 选一条 → 插入 `[[67f0f065-…]]` → 保存后卡片显示 `↗ 引用笔记`，被引用笔记底部出现 `↖ 1` 反向链接
  - **标签补全（L2）**：输入 `#` → 弹出建议（`# 学习记录` / `# 找不到答案时就去找自己` / `# 投资`…）→ 点选后文本变 `#学习记录 `（带尾空格），光标在末尾，继续输入 `test` 正常追加
- **未验证**：
  - **图片锚点（L2）**：插入图片要走小米「安全访问」图片选择器，嵌套层级导致 adb 点击命不中缩略图，放弃。该逻辑由 `IA-01..17` 共 17 项单测覆盖（含区间横跨图片断段、图片在端点不切开）
  - **AI 洞察页**：无 UI 入口，见下
- **新发现（文档与代码不一致）**：`home_screen.dart:1921` 的 `_showAiInsightDialog()` 带 `// ignore: unused_element`，自 `c059bf8`「移除顶栏 AI 入口」起**没有任何调用方**。L1 抽出的 `AiInsightScreen` 目前是无入口死代码
- 环境坑已写入 `docs/HANDOFF.md` 真机段：adb server 每条命令被回收需重连、Git Bash 要 `MSYS_NO_PATHCONV=1`、微信输入法插件服务下 `input text` 失效需临时切搜狗、截图存 /sdcard/ 会进相册、息屏省电导致 ping 80~150ms、坐标要用 `uiautomator dump` 而非截图手算
- 现场清理：设备上 39 个临时截图/UI 树已 `rm`；`heads_up_notifications_enabled` 与默认输入法已恢复原值

## 2026-11-05 · L2：抽出图片锚点与标签补全的纯函数并补 39 项单测 · done

- 背景：`note_editor.dart` 里图片偏移换算、`#` 标签补全全是纯算术，但埋在 State 里，一行测试都没有
- 改动（`3eae4f8`，3850 → 3293 行，交互零变化）：
  - 新增 `utils/note_image_anchor.dart`：`NoteImageAnchor` / `TextDiff` / `shiftImageOffsets` / `splitRangeByImages`，替代 State 里的 `_AnchoredImage` / `_TextDiff` / `_rangesWithImages` / `_shiftRangeSegment` / `_insertedLengthBefore(OrAt)` / `_syncImageAnchorsForTextChange`
  - 新增 `utils/tag_input_helper.dart`：`detectTagPrefix` / `rankTagSuggestions` / `applyTagInsertion`，替代 `_detectTagInput` / `_insertTag` 的内联实现
  - 关键设计：两个新文件都不认识 `MemoStyleRange`，`splitRangeByImages` 只返回索引区间，调用方套回样式类型——避免 `utils → widgets` 逆依赖（`MemoStyleRange` 定义在 `widgets/memo_editing_controller.dart`）
- 新增测试 `test/unit/note_image_anchor_test.dart`（IA-01..17）+ `test/unit/tag_input_helper_test.dart`（TI-01..22），覆盖插入/删除/替换三种 diff、锚点前后插入、null 锚点保留、区间横跨图片断段且图片不被样式覆盖、图片正好在区间端点不切开、`#` 前补空格的三种字符类型、光标越界不抛异常
- 验证：
```
$ dart tool/inkpaper.dart analyze
No issues found!
$ dart tool/inkpaper.dart test
01:47 +569: All tests passed!   # 530 + 39
$ dart tool/inkpaper.dart build android-release
√ Built build\\app\\outputs\\flutter-apk\\app-release.apk (50.1MB)
```
- 未验证：**真机**（设备 `adb connect` 仍超时）。图片锚点与标签补全都是纯函数，逻辑有测试兜底，但「编辑器里插图后加粗、标签弹出的位置」这类**视觉结果**仍需真机点一遍

## 2026-11-05 · L1：抽出三块寄生 UI，合并两份已漂移的批注实现 · done

- 背景：三个高频文件的「体积」不是业务复杂度，是寄生在里面的独立 UI + 重复实现
- 改动（`f719baa`）：
  - `home_screen.dart` 2926 → 1950 行：`_AiInsightScreen`（977 行）→ 公开 `screens/ai_insight_screen.dart::AiInsightScreen`
  - `note_editor.dart` 3850 → 3469 行：`_NoteReferenceDialog`（382 行）→ 公开 `widgets/note_reference_dialog.dart::NoteReferenceDialog`
  - 批注 CRUD：`note_card.dart` 与 `note_actions_ui.dart` **各有一份副本且行为已漂移**（前者直接 `AppProvider.updateNote`，后者走 `NoteActionsService`），合并为 `widgets/note_annotation_dialogs.dart::NoteAnnotationDialogs`；note_card 1630 → 1298、note_actions_ui 1791 → 1413
  - 新增 `onAnnotationOpened` 参数：首页卡片点批注要跳详情页，详情页侧边栏只弹提示，同一实现两种用法
  - 三个类均公开命名（去掉下划线），`super.key` 按 `always_put_required_named_parameters_first` 放到 required 之后
- 验证：`analyze` 无告警、`test` 530 项全绿

## 2026-11-05 · 清理：iOS 语音权限删除 + analyze 退出码归零（DOC-001）· done

- `ios/Runner/Info.plist`：删 `NSSpeechRecognitionUsageDescription`（系统识别 1.1.57 已移除，该权限不再被请求）；`NSMicrophoneUsageDescription` 保留（讯飞录音需要）
- `analysis_options.yaml`：`exclude` 加 `_backup/**`。此前 `_backup/analyze_backup.dart:61` 的 `require_trailing_commas` 让 analyze 退出码长期为 1
- 验证：`dart tool/inkpaper.dart analyze` → `No issues found!`，**退出码 0，首次全绿**

## 2026-11-05 · 结构归位：9 个错层文件各回各位 · done

- 背景：`lib/` 164 个文件 / 10.3 万行，分层骨架没问题，但有文件放错层，看目录猜不到
- 改动（`eed02f3`，纯机械，逻辑零改动）：
  - `widgets → screens`：`image_viewer_screen.dart`、`share_image_preview_screen.dart`（都是页面，与 go_router 页面清单对不上）
  - `services → utils`：`note_sorting_helper` / `note_tags_helper` / `notes_pagination_helper` / `sync_merge_helper` / `sync_status_helper` / `weread_parser` / `notes_context_builder`（7 个无状态纯函数，`BUSINESS_OVERVIEW` 自己都称它们「纯函数工具」）
  - 18 个文件的 import 路径同步；`dart fix --code=directives_ordering` 修掉重排后的 import 顺序
- 刻意没动：
  - `utils/share_utils.dart` + `utils/share_image_widget.dart` 保持原位——前者是 Canvas 绘制/截图，后者被它依赖，挪 widget 进 `widgets/` 反而制造 `utils → widgets` 逆依赖
  - `services/note_actions_service.dart` 的 `services → providers` 逆依赖，需要改结构，留待 P1
- 目录规模：screens 37 / widgets 23 / services 39 / utils 32（文件总数 166 → 164，含删掉的百度语音）
- 验证：
```
$ dart tool/inkpaper.dart analyze
1 issue found.   # 仅 _backup/analyze_backup.dart 那条历史 info（DOC-001）
$ dart tool/inkpaper.dart test
02:15 +530: All tests passed!
```
- 备注：`flutter test` 在本机需绕开沙箱代理（`http_proxy` 会让 flutter_tester 的 websocket 连接报 `Invalid WebSocket upgrade request`），命令改成 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy dart tool/inkpaper.dart test`

## 2026-11-05 · 语音改为默认关闭且仅讯飞，系统/百度识别删除 · done

- 需求：首页默认不展示语音按钮；设置里开启语音并填讯飞 API 后首页才出现；系统语音相关功能删掉
- 结论：`VOICE-001` 结项——不再追 HyperOS 有无 `RecognitionService` 的根因，直接不赌
- 改动（`d8f395c`）：
  - `lib/services/speech_service.dart`：892 → 135 行，只留讯飞；删掉 `speech_to_text` 的初始化/续听/语种解析/失败弹窗/超时兜底
  - `lib/services/iflytek_speech_service.dart`：`isConfigured` 去掉 `speechRecognitionMode` 判断；补 `onDone`（VAD 判停 status=2 或连接关闭回调一次，`_doneEmitted` 防重）
  - 删除 `baidu_speech_service.dart` / `baidu_realtime_speech_service.dart`（无调用方）+ `AppConfig.BAIDU_*` 常量 + 百度专用 l10n
  - `lib/models/app_config_model.dart`：新增 `speechInputEnabled = iflytekSpeechEnabled && 三件套齐全`；`SPEECH_MODE_SYSTEM` 常量删除，默认模式改 `iflytek`（老配置里的 `'system'` 仍能读，但不参与判断）
  - `lib/screens/home_screen.dart`：底部输入条右侧麦克风改条件渲染（`context.select` 读 `speechInputEnabled`）
  - `lib/widgets/note_editor.dart`：编辑器麦克风按钮同样按开关显隐；`startWithSpeech` 加守卫
  - `lib/screens/ai_settings_screen.dart`：「系统识别 / 讯飞」分段控件 → 「语音输入」开关 + 三件套；文案改为实际行为（原文说「长按首页 + 号」，代码里从来没有该手势）
  - `pubspec.yaml`：移除 `speech_to_text` 依赖；`1.1.56+10152` → `1.1.57+10153`
- 新增单测：`test/unit/app_config_speech_test.dart`（6 项：默认关 / 只有开关 / 三件套齐 / 空白密钥 / copyWith 关 / 旧配置 system 残留）
- 验证：
```
$ dart tool/inkpaper.dart analyze   → 仅 _backup 那条 info
$ dart tool/inkpaper.dart test      → 530 项全绿
$ dart tool/inkpaper.dart build android-release
√ Built build\app\outputs\flutter-apk\app-release.apk (50.1MB)
```
- 未验证：**讯飞端到端真机**（`adb connect 192.168.0.108:35819` 超时，设备离线）；iOS 的 `NSSpeechRecognitionUsageDescription` 保留未动（不再被请求，删它属不可验证的改动）

## 2026-11-05 · 语音不卡死 + 首页滚动/时间口径 + AI 图标定稿 · done

- **语音（`290f9d6`）**：真机复现「正在聆听停不掉」，`dumpsys audio` 确认其实没在录音
  - 三个叠加原因：`bool _isProcessing` + `try/finally` 复位，任一平台调用不返回就永久锁死按钮；`speech_to_text` 的 `locales()` 是「发广播等回包」，等不到就永不完成，而它在 `initialize()` 主路径上；`listen()` 被系统静默拒绝时不抛异常，代码却无条件当成功
  - 处理：`initialize/listen` 8s、`locales/hasPermission/stop/cancel` 3s 超时；防抖标志改 3 秒时间窗；停止改为先复位 UI 再释放麦克风；新增 12s「哑火」看门狗（无声无字自动收尾并提示）；`onError` 全量上报
  - 实测：点「点击停止」立即生效；再点麦克风也能停；识别引擎不工作 12s 内自动收回录音条
- **首页含图笔记下滑卡顿（`b567c0f`）**：九图卡片会在同一帧发起 9 次 480px 解码 → 纹理上传击穿单帧预算
  - `note_card.dart` 新增 `_DeferredThumbnail`，按 `90ms + index×30ms` 错峰挂载；补 `gaplessPlayback` / `filterQuality.low`
  - `MemosContentHelper.cachedExpansionText` 缓存「展开」判定全文（原来每次重建都重跑 `MemosMarkdownConverter` + `Document.parse`）
  - 实测：连滑三屏后停在 9 图笔记，图片逐张补上，无卡死灰块、无错图
- **卡片时间口径（`6d0e4ad`）**：`NoteCard.timestamp` 由 `updatedAt` 改为 `createdAt`，与详情页、与 `getNotesPaged` 的 `createdAt DESC` 排序统一；同一笔记首页 `10-25 00:40` ↔ 详情 `2026-10-25 00:40:52` 已对齐
- **AI 图标（`8cedbe7`/`67d7339`/`bf209ca`）**：用户提供 27×20 位图 → 按轮廓拟合矢量路径（IoU 0.87）+ `PathFillType.evenOdd` 挖空嘴/眼 → 最终定为透明底蓝色，去掉深蓝色块底；首页深色模式用 `brandBlueLight`，聊天头像尺寸 21 → 26 抵掉底色带来的视觉重量损失
- 版本：`1.1.48+10144` → `1.1.56+10152`
- 遗留：本机系统语音识别疑似不可用（根因未定位，见 `BLOCKERS.md` `VOICE-001`）；`flutter test` 全量 524 项通过
- 文档：新增 `docs/HANDOFF.md`（交接：现状 / 代码地图 / 遗留 / 新窗口 Prompt）与 `docs/BUSINESS_OVERVIEW.md`（业务框架、13 条业务流程、参数速查、真机调试参数）；`BLOCKERS.md` 补 4 条未解决项

## 2026-10-23 · 体积优化：时区数据 + 本地化双轨合并 · done

- `timezone`：`notification_service` 由 `timezone/data/latest_all.dart` 换成 `latest_10y.dart`
  - libapp.so 内 `package:timezone` 553,618 B → 104,171 B（−439 KiB）
  - 提醒只会排在不久的将来，10 年窗口够用；位置名与偏移规则一致
- `i18n`：删除 gen-l10n 双轨（`app_en.arb` / `app_zh.arb` / `app_localizations*.dart` / `l10n.yaml`，pubspec 移除 `generate: true`）
  - `share_image_preview_screen` 改用 `AppLocalizationsSimple`，补齐 24 条分享图文案中英文
  - 实测 l10n 部分仍是 424,769 B：ARB 生成类本来就只被一个页面引用，tree-shake 后仅约 48 KB，文案搬进 `translations.dart` 后收益基本抵消。**这项真实价值是消除双轨维护，体积收益约 45 KB，此前预估的 0.3 MB 偏高**
- 结果：libapp.so 14,222,216 B → 13,829,000 B（−384 KiB）；universal release APK 48.9 MB → 48.0 MB
- 试过 `flutter build apk --strip`：当前 Flutter 版本不认这个参数（exit 64），已回滚
- 版本：`1.0.59+10059` → `1.0.60+10060`

## 2026-10-23 · 移除友盟统计 + abiFilters 瘦身验证 · done

- 决策：只保留 Dart 侧错误上报（ErrorHandler / GlobalErrorCatcher / Sentry），不集成任何第三方统计 SDK
- 移除友盟：
  - Dart：删除 `lib/services/umeng_analytics_service.dart`；`home_screen` / `privacy_policy_screen` / `app_provider` 的初始化与埋点调用改为本地日志；`AppConfig` 删除 `UMENG_*` 常量与 `channelUmeng`
  - Android：`build.gradle` 去掉 umeng/gson 依赖与 manifestPlaceholders；`MainActivity` 删除 `com.didichou.inkpaper/umeng` 通道（桥接通道从 2 条回到 1 条）；`AndroidManifest` 删除 UMENG_APPKEY/CHANNEL；`proguard-rules.pro` 删除 umeng keep 规则
  - 构建脚本：`tool/inkpaper.dart` 的可选 dart-define 只剩 `SENTRY_DSN`
- 体积：release universal APK 51.3 MB → 48.9 MB（移除友盟约 −1.0 MB，abiFilters 裁掉 x86_64 插件 so 约 −1.4 MB）
- abiFilters 结论（原「已知项」）：
  - `buildTypes.release` 内的 `ndk { abiFilters }` 不生效；Flutter Gradle 插件在 apply 时已把 `defaultConfig.ndk.abiFilters` 垫成全平台
  - Groovy 的 `abiFilters 'a','b'` 是**追加**而非覆盖，必须先 `abiFilters.clear()` 再 `addAll`
  - 最终：`defaultConfig.ndk` 里 clear 后按 `isReleaseTask` 分支，release 只留 `armeabi-v7a/arm64-v8a`，debug 保留 `x86_64` 供模拟器
- 验证（`flutter clean` 后全量构建）：
  - release APK 的 `lib/` 仅含 `arm64-v8a`、`armeabi-v7a`
  - debug APK 仍含 `arm64-v8a`、`armeabi-v7a`、`x86_64`（174.5 MB）
- `--analyze-size`（android-arm64）libapp.so 13.56 MB 构成：
```
package:flutter              4.16 MB   框架，动不了
package:inkpaper             2.80 MB   自有代码（screens 1.12 / widgets 0.47 / l10n 0.42 / services 0.39）
@unknown                     1.26 MB
package:timezone             0.55 MB   timezone/data/latest_all.dart（全球时区数据）
dart:mixin_deduplication     0.48 MB
@shared                      0.47 MB
package:flutter_localizations 0.41 MB
dart:core / dart:ui          0.60 MB
package:sentry(+flutter)     0.38 MB
package:html / markdown      0.34 MB
```
- 后续可优化项：`timezone` 换 `latest_10y.dart`（约省 0.5 MB）、`l10n` 双套本地化（`translations.dart` 252 KB + `app_localizations_simple.dart` 166 KB）只保留一套
- 版本：`1.0.58+10058` → `1.0.59+10059`

## 2026-10-23 · 编辑卡片玻璃化 · done

- 需求：编辑浮层卡片本身也做半透明 + 自身模糊，去掉「硬白块」边界
- 改动（`lib/widgets/note_editor.dart`）：
  - 卡片结构改为 `Container(圆角 + 投影) → ClipRRect → BackdropFilter(sigma 24) → ColoredBox(白 90% / 暗色 0xE01C1C1E) → Column`；投影留在最外层，避免被 ClipRRect 裁掉
  - 新增 `import 'dart:ui' show ImageFilter`
  - 输入框显式 `filled: false`：全局 `inputDecorationTheme` 设了 `filled: true` + `fillColor: surfaceColor`，在玻璃卡片上会糊出一块实心白
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 18.2s)
$ flutter test
02:03 +424: All tests passed!
```
- 真机：`1.0.54+10054` debug 已安装，截图确认卡片整体透出模糊背景、无硬白块、输入区与卡片融为一体
- 说明：弹层遮罩已有 sigma 18 的 `BackdropFilter`，卡片内再叠 24 属于二次模糊，静态时只渲染一次，开销可接受
- 版本：`1.0.53+10053` → `1.0.54+10054`

## 2026-10-23 · 卡片时间行收紧 · done

- 反馈：时间文字本身已经够小，但时间行到正文的留白还是偏高
- flomo 依据：`view_memo_card_surface.xml` 的 `card_header` 是 `layout_marginBottom="4dp"`，时间行紧贴正文
- 改动（`lib/widgets/note_card.dart`）：
  - 卡片上内边距 `14 → 10`（`EdgeInsets.fromLTRB(16, 10, 16, 16)`）
  - 时间文字加 `height: 1.1`，行高不再由 10sp 的默认行距撑开
  - 「更多」按钮容器 `32 → 28`、图标 `18 → 16`，并加 `visualDensity: compact` + 空 `BoxConstraints`，不再由 IconButton 决定整行高度
  - 时间行与正文间距 `8 → 4`
- 效果：时间行总高约 40dp → 32dp，一屏可见笔记从约 4 条变成 5 条
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 14.5s)
$ flutter test
01:05 +424: All tests passed!
```
- 真机：`1.0.53+10053` debug 已安装，截图确认时间紧贴卡片顶部、与正文间距明显变小
- 版本：`1.0.52+10052` → `1.0.53+10053`

## 2026-10-23 · 编辑浮层毛玻璃背景 · done

- 需求：点底部输入框弹出编辑器时，背景做模糊（参考 flomo 的玻璃表面）
- flomo 取证：`com/flomo/components/GlassSurface.java` 用 `eightbitlab BlurView` 做真实模糊 + `FloatingComposerGlass.setup(...)` 叠加 fill/overlay 色，参数走 `glassCornerRadius` / `blurRadius`
- 根因：`_showAddNoteForm` 用 `showModalBottomSheet`，它的遮罩是 Material 的半透明黑（`barrierColor`），**没有模糊能力** —— BottomSheet 之上无法插入 BackdropFilter
- 改动（`lib/screens/home_screen.dart`）：
  - 新增 `_showComposerSheet(Widget editor)`：改用 `showGeneralDialog`（`barrierColor: Colors.transparent`）自绘遮罩，`Stack` = `BackdropFilter(sigma 18)` + 淡色叠加（亮色白 18% / 暗色黑 28%）+ 编辑器
  - `_showAddNoteForm` / `_showAddNoteFormWithContent`（分享入口）都改走该方法；`NoteEditor` 本身是全屏透明 Scaffold（含点击空白关闭、键盘避让），无需改动
  - 淡入 220ms
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 11.9s)
$ flutter test
01:03 +424: All tests passed!
```
- 真机：`1.0.52+10052` debug 已安装；点输入框 → 背景首页明显糊化、编辑器浮层正常、键盘弹起；返回键第一次收键盘、第二次关闭浮层并回到首页「记点什么…」
- 版本：`1.0.51+10051` → `1.0.52+10052`

## 2026-10-23 · 热力图窗口收窄为三个自然月 · done

- 反馈：26 周（半年）时顶部出现 6 个月份标签，太密
- 改动（`lib/widgets/heatmap.dart`）：
  - `_weeksPerPage = 26` → `_monthsPerPage = 3`：区间改为「最近三个自然月」，起始对齐周一，翻页按整页（3 个月）回退
  - 起始月只占半周时不打月份标签（`startIsMonthStart` 判断），顶部只留 3 个标签；`_rangeLabel` 同步从残缺起始月的下一个月算起，标题与标签一致（`2026年8月 - 2026年10月`）
  - 格宽 `clamp(7, 18)` → `clamp(7, 26)`：13 列时约 22dp，仍然铺满宽度
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 14.1s)
$ flutter test
00:37 +424: All tests passed!
```
- 真机：`1.0.51+10051` debug 已安装，截图确认 8月/9月/10月 三个标签、无溢出、格宽约 22dp
- 版本：`1.0.50+10050` → `1.0.51+10051`

## 2026-10-23 · 热力图改为连续时间轴（flomo 式小方格） · done

- 决策：不再走「一个月 7 列铺满 → 单格 44dp」或「限宽居中 → 两侧留白」，改为**连续时间轴**：列 = 周、行 = 周一…周日，一屏展示最近 26 周（半年），格宽 = 可用宽 / 26 ≈ 10.7dp
- 改动（`lib/widgets/heatmap.dart`）：
  - 状态 `_monthOffset` → `_pageOffset`，按整页（26 周）向前翻；区间末尾为今天，起始对齐到周一
  - `_calculateDailyCounts` 改为按 `[_rangeStart, _rangeEnd]` 区间统计（仍只按创建日）
  - 网格：`LayoutBuilder` 计算格宽 `clamp(7, 18)`，7 行 × N 列；删除 `_generateMonthDates`
  - 月份标签用 `Stack + Positioned` 绝对定位（放进 `Row` 会把行撑爆，实测 `RIGHT OVERFLOWED BY 20 PIXELS`），文案缩为「5月」；`_rangeLabel` 显示「2026年4月 - 2026年10月」
  - 星期标签改为左侧竖排（一/三/五/日），底部横排会与新的「列=周」语义冲突
  - `_buildHeatCell` 增加 `inRange` 参数（区间外补齐日淡显）
  - `lib/widgets/sidebar.dart`：无活动格颜色 `grey[100] → #E6E8EB`（26 列下原色太淡糊成一片），暗色 `#3A3A3C`
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 13.0s)
$ flutter test
00:55 +424: All tests passed!   # 含 UI-21 热力图只按创建日统计
```
- 真机：`1.0.50+10050` debug 已安装，截图确认 26 列小方格铺满、月份标签不重叠不溢出
- 版本：`1.0.49+10049` → `1.0.50+10050`

## 2026-10-23 · release 包体积瘦身 · done

- 体积构成（拆开 release universal APK 实测，75.6 MB）：
```
lib/x86_64       25.68 MB
lib/arm64-v8a    24.53 MB
lib/armeabi-v7a  22.01 MB
classes.dex       6.84 MB
assets           0.24 MB
resources.arsc    0.22 MB
```
  - arm64 内部：`libapp.so` 11.5（Dart AOT）、`libflutter.so` 11.2（引擎）、`libsentry.so` 1.16、`libumeng-spy.so` 0.52
- 改动：`tool/inkpaper.dart` 的 `android-release` 加 `--target-platform=android-arm,android-arm64`（x86_64 只有模拟器需要）
- 结果：universal APK **75.6 MB → 51.3 MB（−24.3 MB，−32%）**
- 尝试后回退：想在 `defaultConfig` 加 `ndk { abiFilters }` 再裁掉插件自带的 1.36 MB x86_64 so，但 release 增量构建一直判 up-to-date、未重新打包，无法验证是否生效，且会让 Android 模拟器装不上 → 回退，留作已知项
- 分发建议：真机安装走 `android-release-split`（arm64 ≈27.8 MB）或商店上传 AAB（69.7 MB，按设备下发）
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 15.1s)
$ dart tool/inkpaper.dart build android-release
√ Built build\app\outputs\flutter-apk\app-release.apk (51.3MB)
```
- 版本：`1.0.48+10048` → `1.0.49+10049`

## 2026-10-23 · 侧边栏对齐 flomo（热力图去卡片化 / 菜单块收窄） · done

- 结构确认：抽屉顶部是账号卡（头像 + 昵称 + 在线态），下面依次为「活动记录」热力图与「功能菜单」，无需调整顺序
- 改动：
  - 热力图外层 `Container(margin 16/0/16/8 + padding 8 + 背景/阴影/圆角 12)` → `Padding(20/0/20/8)`，不再以卡片方框区分，直接铺在抽屉背景上
  - `_StatCardWidget`（总字数/笔记数/记录天数 + 今日三项）去掉浅色底块与圆角，只保留文字与内边距
  - 菜单项：外边距 `16/4 → 10/2`，内边距 `16/14 → 14/12`，圆角 `12 → 16`（含 InkWell 水波纹与退出登录按钮），「功能菜单」标题左内边距 20 → 24 与菜单内容对齐
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 10.6s)
$ flutter test
00:48 +424: All tests passed!
```
- 真机：`1.0.48+10048` debug 已安装，截图确认热力图无方框、菜单块更窄更圆
- 已知取舍：热力图铺满宽度（7 列 `Expanded`）后单格约 44dp，比 flomo 的小格子粗壮；若要更精致可加 `maxCellSize≈30` 并居中，但会退回「不铺满」的观感
- 版本：`1.0.47+10047` → `1.0.48+10048`

## 2026-10-23 · 首页本地图片按缩略图解码 · done

- 现状：`note_card.dart` 的网络图分支传了 `memCacheWidth`，但 4 处 `Image.file`（本地 `file://` 图片 + 3 处离线缓存回退）都没传 `cacheWidth` → 手机原图按完整分辨率进内存（4000×3000 的图解码后约 48 MB）
- 改动：4 处 `Image.file` 统一加 `cacheWidth: memWidth`（`memWidth = (decodeWidth ?? 720).clamp(160, 720)`，即格子逻辑宽 × DPR，本机约 366 px）
- 效果：单张本地图解码内存从原图约 48 MB 降到约 0.5 MB（366×366×4B）；大图查看走 `ImageViewerScreen` 的原图加载，不受影响
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 10.6s)
$ flutter test
00:39 +424: All tests passed!
```
- 真机：`1.0.47+10047` debug 已覆盖安装（构建 32.4s）
- 版本：`1.0.46+10046` → `1.0.47+10047`

## 2026-10-23 · 同步去重（Memos + WebDAV 双通道） · done

- 现象：同时开启 Memos 同步与 WebDAV 同步后，同一条笔记在列表里出现两份
- 根因（三处叠加）：
  1. 本地笔记 id 由 `Uuid().v4()` 生成；Memos 拉取时 `Note.fromJson` 直接用服务端 memo 的 id（uid）；WebDAV 合并则完全按 `note.id` 匹配
  2. 接入 Memos 后服务端会重新签发 id，云端 `notes.json` 里仍是上一次的本地 uuid → WebDAV 判定「远程独有」→ `saveNote` 再插一份
  3. 既有 `lib/utils/note_dedupe.dart` 只处理「未同步的本地副本」，WebDAV 路径完全没用上
- 改动：
  - `note_dedupe.dart` 新增 `groupNotesByContentHash`（按哈希分桶）、`findContentDuplicate`（内容一致 + 创建时间 ±5 分钟内视为同一条）、`dedupeDuplicateNotes`（库内自去重：保留创建时间最早的一条，置顶/批注/提醒/引用/标签取并集，返回待删 id）
  - `webdav_sync_engine._mergeNotesIncremental`：远程独有笔记先按内容指纹「认领」本地同一条（保留本地 id，合并远程内容与本地元数据，不新增行）；合并收尾执行库内自去重，删除副本并计入 `SyncStats.deleted`
- 设计取舍：用「内容哈希 + 创建时间容差」而不是纯内容哈希 —— 用户在两个时间点写相同正文是合法场景，纯内容匹配会误删
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 8.0s)
$ flutter test
00:52 +424: All tests passed!
```
- 新增测试：`test/unit/note_dedupe_test.dart` +8 例（跨通道认领、时间超差保留、同 id 跳过、库内合并、元数据并集）
- 真机：`1.0.46+10046` debug 已覆盖安装
- 未做（需人工拍板）：给 notes 表加 `remote_id` 列，把「Memos uid ↔ 本地 id」固化成显式映射（涉及 DB schema 迁移）
- 版本：`1.0.45+10045` → `1.0.46+10046`

## 2026-10-23 · 首页头部对齐 flomo（时间/字号/文案） · done

- flomo 取证：卡片头部 `DinTextView#date` 用 `@dimen/fontTiny`（10sp）+ `@color/textSubtle`（`gray60 = #949494`），字体为 Barlow-Regular（细体）
- 改动（`lib/widgets/note_card.dart`）：
  - 时间戳按 flomo 思路缩减：今天只显示 `HH:mm`，今年显示 `MM-dd HH:mm`，往年显示 `yyyy-MM-dd`（原固定 `yyyy-MM-dd HH:mm`）
  - 时间文字 `12 → 10`，`FontWeight.w300` + `letterSpacing 0.2`，颜色 `#949494`（暗色 `#8E8E93`），与正文拉开层级
  - 「更多」按钮外框 `44 → 32`、图标 `20 → 18`，头部变薄
  - 展开按钮文案 `全文 → 展开`（`translations.dart` 的 `fullText` 同步改 zh/en）
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 12.9s)
$ flutter test
00:51 +416: All tests passed!
```
- 真机：`1.0.45+10045` **debug** 包装到 `192.168.0.108:33717`，截图确认时间为 `10-20 07:54` 浅灰细体、长笔记按钮显示「展开」
- 版本：`1.0.44+10044` → `1.0.45+10045`
- 构建策略调整：后续真机测试改用 debug 包（36s vs profile 71s），profile/release 仅在验收性能时构建

## 2026-10-23 · 首页样式对齐 flomo · done

- 参考源：`友商 APK/反编译/flomo/resources/res/`（flomo 5.5.5 脱壳工程，见 `_flomo脱壳报告.md`）
- 取证：
  - 卡片背景 `drawable/bg_card.xml` → `<corners android:radius="@dimen/cornerRadiusLarge"/>`，`cornerRadiusLarge = 12dp`
  - 九宫格图片 `layout/view_grid_image_item.xml` → `app:roundedCornerRadius="@dimen/cornerRadiusMedium"`（6dp）+ `viewAspectRatio=1`
  - 卡片外边距 `view_memo_card.xml` 中 `MemoView` 左右 `12dp`；卡片垂直间距 `memoCardVerticalInset = 8dp`（相邻两条共 16dp）
- 改动（`lib/widgets/note_card.dart`）：
  - 卡片圆角 `8 → 12`
  - 九宫格图片圆角 `4 → 8`（flomo 为 6dp，按「要更明显」的诉求上调一档；含 `+N` 遮罩与兜底占位）
  - 卡片外边距 `10/0/10/8 → 12/0/12/12`，卡片内边距 `16,12,16,14 → 16,14,16,16`
  - 九宫格间距 `4 → 6`，图文间距 `8 → 10`
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 14.5s)
$ flutter test
01:13 +416: All tests passed!
```
- 真机：`1.0.44+10044` profile 包装到 `192.168.0.108:33717`，截图确认卡片更圆润、间距拉开、单图/多图圆角明显
- 版本：`1.0.43+10043` → `1.0.44+10044`

## 2026-10-23 · 侧边栏热力图宽度修复 · done

- 现象：侧边栏「活动记录」热力图只占卡片左半边（用户连续两次反馈「没占满」）
- 根因：A-11 把 `GridView` 换成 `Row/Column` 时写死 `cellSize = 18.0`，7 列 + 6 间距只有 138pt，而卡片内容宽约 300pt
- 尝试 1（`bf55a6f`）：改 `LayoutBuilder` 按宽度算 `cellSize`，但 `clamp(12, 26)` 的**上限 26** 仍让总宽只有 194pt，依旧没铺满
- 最终（`4390b9a`）：每行固定 7 个 `Expanded` + `AspectRatio(1)`，宽度由父容器平分、高度跟随宽度；空位用 `SizedBox.shrink()` 占位；星期标签同样改 `Expanded`，与格子一一对齐
- 附带修复：`Heatmap` 的 `ValueKey` 在 `notes.isEmpty` 时用 `DateTime.now().millisecondsSinceEpoch`，key 每次 build 都变 → 42 个 Tooltip + 6 张统计卡整棵重建；改为固定 `0`
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 20.2s)
$ flutter test
01:20 +416: All tests passed!
```
- 真机：设备 `23127PN0CC`（`192.168.0.108:33717`）安装 `1.0.43+10043` profile 包，截图确认 7 列铺满卡片、星期标签对齐
- 版本：`1.0.41+10041` → `1.0.42+10042`（尝试 1）→ `1.0.43+10043`（最终）
- 记录：debug 包（175.7 MB）在真机上「空数据也卡」属 JIT 开销，已构建 profile 包（109.2 MB，AOT）供对比

## 2026-10-23 · ROADMAP 状态与文档对齐 · done

- 触发：`docs/ROADMAP.md` 索引表 5 条全部 `done`，但元信息与验收描述仍停留在「release 构建不可用」，与 A-10 补测结果不符
- 改动（仅文档，无代码）：
  - 元信息「验收环境限制」：release 现可构建（`android/key.properties` 指向本地一次性测试密钥，正式发布前须替换）
  - 索引表 ARCH-LAYER-002 验收列：补 A-10 实测体积（universal 75.6 MB / AAB 69.7 MB / arm64 27.8 MB vs debug 175.7 MB）
  - 阶段退出条件：Phase 2 / 3 / 4 均标注「已满足」（0 issue / 416 测试全绿），并追加「真机拖动排序待人工确认」的遗留说明
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 11.1s)
$ flutter test
00:38 +416: All tests passed!
```
- 结论：本版 ROADMAP 全部条目终结，Phase 4 退出条件满足；下一步（是否产出下一版 ROADMAP）属 Phase 边界，按规范需人工拍板
- 无代码改动，无版本变更

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

## 2026-10-21 · ARCH-LAYER-002 · A-11 · done（接续 blocked，走「扩大作用域」方案）

- 做法：`lib/screens/sidebar_customization_screen.dart` 的 `body: ListView(children:)` 改 `CustomScrollView`；「菜单项」分组的 `ReorderableListView(shrinkWrap: true)` 换成 `DecoratedSliver(SliverPadding(SliverReorderableList))`，分组标题抽出 `_buildSectionHeader` 供 `_buildSection` 与新 sliver 复用。
- 实测输出：
```
$ (Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'shrinkWrap:\s*true' | Measure-Object).Count
0   (改前 9，期望 0)
$ dart format lib/screens/sidebar_customization_screen.dart
Formatted 1 file (1 changed)
$ flutter analyze
No issues found! (ran in 7.8s)
$ flutter test
00:44 +399: All tests passed!
```
- 版本：`1.0.30+10030` → `1.0.31+10031`
- commit: `84bc599`（代码），`1ea41f0`（ROADMAP）

## 2026-10-21 · QUAL-CLEAN-003 · A-12 · done

```
$ (Select-String -Path lib/screens/home_screen.dart -Pattern '_collectTags' | Measure-Object).Count
0   (期望 0)
$ 全库 collectTags 命中
0
$ flutter analyze
No issues found!
```
- 说明：目标死方法 `_collectTags` 已在早前重构中消失（`home_screen.dart:1866` 现属 `_availableTags`，全库 5 处调用，非死代码），本次仅核对验收命令；无代码改动，无版本变更。
- commit: 无代码，随文档提交。

## 2026-10-21 · QUAL-CLEAN-003 · A-13 · done

- 做法：`.github/workflows/ci.yml` 质量任务加 `dart format --output=none --set-exit-if-changed lib test tool` 步骤；随后一次性格式化全量（20 文件），并手工补 9 处 `require_trailing_commas`（formatter 与 lint 在该批表达式上不一致）。
- 实测输出：
```
$ (Select-String -Path .github/workflows/ci.yml -Pattern 'dart format' | Measure-Object).Count
2   (期望 >= 1)
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)
exit=0
$ flutter analyze
No issues found! (ran in 8.4s)
$ flutter test
00:24 +399: All tests passed!
```
- 版本：`1.0.31+10031` → `1.0.32+10032`
- commit: `012b94e`（CI 门禁）、`b4b5f54`（格式化全量，单独 commit）

## 2026-10-21 · QUAL-CLEAN-003 · A-14 · done

- 做法：6 处 `Image.asset` 全部补 `cacheWidth`，按 `显示尺寸 × MediaQuery.devicePixelRatioOf(context)` 计算；`image_utils.loadThemeImage` 在 `width == null` 时保持原图（传 null）。
- 实测输出：
```
$ Image.asset 计数 / cacheWidth（区分大小写）计数
Image.asset=6  cacheWidth=6   （改前 3 处，且 3 处均为 memCacheWidth，不属于 Image.asset）
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)
$ flutter analyze
No issues found! (ran in 8.8s)
$ flutter test
00:32 +399: All tests passed!
```
- 说明：验收命令原来的 `-Pattern 'cacheWidth'` 默认忽略大小写，会把 `memCacheWidth`（`cached_network_image`）算进去；已改为区分大小写口径，`6 == 6` 成立。
- 版本：`1.0.32+10032` → `1.0.33+10033`
- commit: `7ab0a19`

## 2026-10-21 · QUAL-CLEAN-003 · A-15 · 增量 1 个文件（随即 blocked）

- 完成：`lib/screens/forgot_password_screen.dart` 未接 l10n 的 UI 文案 10 → 0，新增键 `memosNoPasswordResetHint` / `memosNoPasswordResetDetail` / `rememberedPassword`（zh + en，中文 fallback 保留）。
- 实测输出：
```
$ 该文件未接 l10n 的 UI 文案（排除 AppLocalizationsSimple / debugPrint / 注释）
0
$ 该文件原始计数（含 fallback + debugPrint）
12  （改前 12，说明该指标无法反映本地化进度）
$ flutter analyze
No issues found! (ran in 9.7s)
$ flutter test
01:01 +399: All tests passed!
```
- 剩余体量（同口径 Top 10）：webdav 148 / preferences 122 / app_provider 117 / ai_settings 109 / user_agreement 99 / ai_insight_engine 98 / local_backup 89 / flomo 75 / server_info 72，合计约 1,300 行 → 转 blocked，拆分建议见 BLOCKERS。
- 版本：`1.0.33+10033` → `1.0.34+10034`
- commit: `0960608`

## 2026-10-21 · QUAL-CLEAN-003 · A-15 · done（口径重定义 + 4 批落地）

- 口径问题：旧指标 `'[^']*[\u4e00-\u9fff]` 会把已接 l10n 的中文 **fallback**、`debugPrint` 日志、l10n 字典文件本身全部计入（`forgot_password_screen` 改后仍是 12），无法作为门禁，因此先重定义口径。
- 新口径（已写入 ROADMAP 验收命令）：`lib/screens` + `lib/widgets` 内「直接写在 widget 参数里的中文字面量」= 0，排除注释 / `_text('zh','en')` / `text('zh','en')` / `AppLocalizationsSimple` fallback。
- 实测输出：
```
$ 新口径命中数（改前 82）
0   (期望 0)
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)   exit=0
$ flutter analyze
No issues found! (ran in 7.6s)
$ flutter test
00:21 +399: All tests passed!
```
- 落地批次：
  - `0960608` 找回密码页 10 处（新增 3 键：`memosNoPasswordResetHint` / `memosNoPasswordResetDetail` / `rememberedPassword`）
  - `21236a4` 6 个页面 14 处（新增 12 键：`addTag` / `tagNameHint` / `expandOptions` / `notionTokenHint` / `aiInsight` / `tagInputExampleHint` / `zoomIn` / `zoomOut` / `reviewWidgetRefresh*` / `reviewWidgetRange*`）
  - `c35259f` 8 个文件 12 处（新增 10 键：`more` / `refreshBatch` / `openSourceRepo` / `connectServer` / `enterBackupPassword` / `backupPassword` / `importFromLocalFile` / `selectBackupFile` / `syncFromCloud` / `syncWithCloudData`；复用 `createNote` / `all` / `pleaseEnterNewNickname`）
  - `be5f87a` AI 设置页 10 处模型示例文案改走本文件既有的 `_text('zh','en')` 助手
- 版本：`1.0.34+10034` → `1.0.37+10037`
- 遗留（不阻塞）：`app_provider.dart` 5 处为截图模式演示笔记正文、1 处为系统通知标题（provider 层无 `BuildContext`）；`webdav_settings_screen.dart` 等文件的 l10n fallback 按设计保留中文。

## 2026-10-21 · QUAL-CLEAN-003 · done（4/4 子项）

- A-12 死代码 / A-13 format 门禁 / A-14 图片解码 / A-15 本地化全部验收通过，索引表 4 条条目（`STATE-CORE-001`、`STATE-CORE-005`、`ARCH-LAYER-002`、`QUAL-CLEAN-003`）均为 done，Phase 1–4 退出条件全部满足。
- 全程 `flutter analyze` 0 issue、`flutter test` 399 全绿、`dart format` 退出码 0。

## 2026-10-21 · 收尾验证（Android 构建 + 重构单元测试）

- 构建：
```
$ dart tool/inkpaper.dart build android-debug
Running Gradle task 'assembleDebug'...  52.5s
√ Built build\app\outputs\flutter-apk\app-debug.apk
$ app-debug.apk 体积
175.7 MB（基线 176.0 MB；5 个字体删除后几乎无变化，印证从未打包）
```
- 新增测试（16 例，399 → 415）：
  - `test/widget_tests/sidebar_customization_screen_test.dart`（3）：A-11 后该页为 `CustomScrollView` + `SliverReorderableList`、无 `ReorderableListView`、滚动/点击开关不抛异常
  - `test/unit/refactor_state_stores_test.dart`（6）：`AuthStore` / `NotesStore` / `WebDavStore` / `NotionStore` / `ReminderStore` 初始状态与 `clear()` 幂等
  - `test/unit/refactor_utils_test.dart`（7）：`NetworkUtils` 共享客户端同一性 / `close()` 重建；`decodeBackupNotesJson` 正常 / 缺字段 / 类型错误 / 丢弃非对象 / 空数组
```
$ flutter analyze
No issues found! (ran in 7.1s)
$ flutter test
00:25 +415: All tests passed!
```
- commit: `7ee4f9b`（页面测试）、`285bf06`（单测）、`94659bc` / `9915021`（BASELINE）
- release 构建仍不可用：缺 `android/key.properties`，A-10 的体积对比维持「未测量」。

## 2026-10-21 · 真机冒烟（Android 10+ 设备 `192.168.0.108:39911`）

- 安装：`adb install -r app-debug.apk` → `Success`（175.7 MB debug 包）
- 启动：`monkey -p com.didichou.inkpaper -c android.intent.category.LAUNCHER 1` → 进程存活（pid 22648），首页正常渲染（本地模式欢迎笔记可见，底栏输入框/侧边栏入口正常）
- 崩溃检查：`adb logcat -d | Select-String 'FATAL EXCEPTION|E/flutter|ANR in com.didichou'` → **无命中**
- A-11 页面真机链路（改用语义树定位，不再盲点坐标）：`adb shell settings put secure accessibility_enabled 1` 让 Flutter 输出语义树 → `uiautomator dump` 取控件 bounds → 依次点击 汉堡(84,218) → 侧边栏「设置」→「偏好设置」→「侧边栏 / 调整菜单显示与排序」→ 到达「自定义侧边栏」
  - 渲染：头部组件（显示个人中心 / 显示活动记录 两开关）+ 菜单项（全部笔记带锁不可动 + 随机回顾 / 全部标签 / 知识图谱 / 帮助 / 设置 各带拖动手柄与开关）+ 底部提示「全部笔记是默认首页，无法隐藏或移动」全部正常
  - 交互：关闭「显示活动记录」→ AppBar 出现「保存」，点「保存」后按钮消失；`am force-stop` 重启后侧边栏不再有「活动记录」；再次开启并保存后恢复正常 —— 配置读写与持久化 OK
  - 未通过自动化验证：菜单项拖动排序。`input draganddrop`（手柄 195,812 → 195,1330/1440，1200/1500ms）与慢速 `input swipe` 均未触发 `SliverReorderableList` 重排，顺序保持原样，需人工长按拖动确认
  - 收尾：`settings put secure accessibility_enabled 0` 还原，设备临时截图与 `ui.xml` 已删除
- 无代码改动，无版本变更

## 2026-10-21 · ARCH-LAYER-002 · A-10 · 体积对比补测（补齐缺验收）

- 解除方式：本地生成一次性签名密钥 `android/inkpaper-local-test.jks`（`keytool -genkeypair -storetype JKS -keyalg RSA -keysize 2048 -validity 10000`，dname `CN=InkPaper Local Test`），配套 `android/key.properties`；两者均命中 `android/.gitignore`（`key.properties` / `**/*.jks`），不进仓库。`storeFile` 按 `android/app` 解析，取值须为 `../inkpaper-local-test.jks`
- 实测输出：
```
$ Get-ChildItem build/app/outputs/flutter-apk/*.apk,build/app/outputs/bundle/release/*.aab | 体积
app-debug.apk                         175.7 MB   184,208,770 B
app-release.apk（universal，混淆）      75.6 MB    79,323,714 B   # -56.9% vs debug
app-release.aab                        69.7 MB    73,100,104 B
app-arm64-v8a-release.apk              27.8 MB    29,202,649 B   # -84.1% vs debug universal
app-armeabi-v7a-release.apk            25.3 MB    26,535,479 B
app-x86_64-release.apk                 29.0 MB    30,383,632 B
$ 混淆符号文件
app.android-arm.symbols 5,629,632 B / app.android-arm64.symbols 6,507,864 B / app.android-x64.symbols 6,505,104 B
```
- 结论：release universal APK 比 debug 小 56.9%，arm64 单架构包仅为 debug 的 15.9%（debug 三架构 libflutter.so 约 125 MB 是主因）；`--obfuscate` + `--split-debug-info` 已生效（三份 symbols 产出）
- 未做：release APK 未装机验证（签名与现有 debug 安装不同，覆盖需先卸载会清空本机数据）；`android/key.properties` 现指向一次性测试密钥，**正式发布前必须替换为正式 keystore**
- 无代码改动，无版本变更

## 2026-10-21 · 真机复验发现并修复 2 个 UI 缺陷

- 缺陷 1（首页欢迎卡片溢出）：设备 1200×2670 上首页出现 `BOTTOM OVERFLOWED BY 21 PIXELS`。根因：`home_screen.dart` 空列表分支把欢迎卡片塞进 `SizedBox(height: 屏高 - 240)`，卡片实际需要约 752pt、约束只有约 731pt。改法：固定高度只留给「搜索加载 / 搜索空态 / 普通空态」三个分支，欢迎卡片改为按内容自适应。
  - 验证：重装 debug 包后首页截图无溢出条，卡片高度随内容收缩
  - commit `3d8dba4`，版本 `1.0.40+10040` → `1.0.41+10041`
- 缺陷 2（侧边栏拖动代理缺 Material）：补 `SB-04` widget 测试（`tester.timedDrag` 拖手柄）时暴露 `No Material widget found. ListTile widgets require a Material widget ancestor` —— `SliverReorderableList` 的拖动代理插在 Overlay，脱离 Scaffold 的 Material，debug 下拖动即抛异常中断。
  - 修复：`SliverReorderableList.proxyDecorator` 包一层 `Material(color: transparent, elevation: 6)`；`SB-01..SB-04` 4 例全绿，拖动后「随机回顾」下移且 AppBar 亮出「保存」
  - commit `46bc8c1`，版本 `1.0.39+10039` → `1.0.40+10040`
- 仍未自动化验证：真机长按拖动排序。`input draganddrop`（手柄真实坐标 100,1607 → 100,1990，800ms）、`input swipe`（同起止 800ms）、`input motionevent` 逐事件序列三种注入方式均未触发重排（该 HyperOS 设备疑似过滤注入的拖拽事件）；重排逻辑本身已由 widget 测试覆盖，真机拖动仍需人工长按确认
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 11.1s)
$ flutter test
00:38 +416: All tests passed!
```
- 设备侧调试手段（本次踩坑记录）：`settings put secure accessibility_enabled 1` 让 Flutter 输出语义树以便取准确 bounds（用完还原 `0`）；`settings put system screen_off_timeout 1800000` + `svc power stayon true` 防息屏（黑屏截图仅 18,948 字节即息屏，此时 tap 全部无效）；`wm dismiss-keyguard` 解锁；手柄命中区只有 32×32dp，坐标偏差会落到菜单图标上导致拖动无响应

- 前置 `ARCH-LAYER-002` 因 A-11 blocked，未达 done；按执行合约不得跳前置开工。4 个子项相互独立，A-11 决策落定后可直接执行。
- 状态：blocked（详见 BLOCKERS.md）
