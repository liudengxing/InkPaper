# 踩坑与经验（Lessons Learned）

> 只记「不写下来下次一定会再踩」的东西。每条按 **症状 → 原因 → 处理** 三段写，
> 带具体文件路径和命令，避免下次还要重新摸索。
>
> 配套文档：[故障速查表](troubleshooting.md) · [调试指南](debugging.md) · [交接文档](../HANDOFF.md) · [构建与真机测试](../BUILD_AND_DEVICE_TESTING.md)
>
> 最后更新：2026-11-19（版本 `1.1.117+10217`）

---

## 0. 最贵的五条（先看这里）

1. **构建莫名失败先看内存。** 矿机进程吃满内存会让 Gradle native 层和 Dart isolate 同时崩，报错信息完全看不出是内存问题。
2. **跑测试必须禁用本地代理。** 否则 `flutter_tester` 的本地 WebSocket 被代理拦掉，报 `Invalid WebSocket upgrade request`。
3. **时间戳一律不要 `toLocal()`。** Memos 存的是伪 UTC，转一次就错 8 小时。
4. **「GitHub 连不上」九成不是断网，是代理换了形态。** 先探测形态，再决定命令参数。
5. **改小组件布局后必须杀桌面进程。** 否则看到的永远是旧背景，会误判成改动没生效。

---

## 1. 构建与环境

### 1.1 Gradle native OOM / Dart 起不了线程

**症状**

```
A fatal error has been detected by the Java Runtime Environment
  ... Chunk::new ...
# There is insufficient memory for the Java Runtime Environment to continue
```
或 Dart 侧：`Could not start thread DartWorker`。构建耗时异常长后直接失败。

**原因**

本机同时跑着 `SRBMiner-MULTI`（`F:/WaKuang`），常驻约 4.5G 提交内存（加上 WorkBuddy
自身 4.5G，32–34G 是常态）。挤到接近 39.8G 的上限时，Gradle 的 native 层拿不到连续
内存就直接 abort，日志会落在 `android/hs_err_pid*.log`。

**处理**

> 🚫 **矿机不许暂停**（2026-11-21 用户明确要求）。以前的做法是提权跑
> `pause-miner.bat`，但那会弹 UAC 打断用户，已经被否掉。

现在只用无侵入的手段：

```bash
cd android && ./gradlew --stop     # 清掉残留 daemon，通常能收回几百 M 到 1G
```

再不够就少开并行任务（别同时跑 analyze + build）、等内存自然回落；确实扛不住时
把情况说明给用户，由他决定，不要自己动手停矿机。CI 上不需要这一步。
**别把 OOM 当成代码问题去查依赖。**

### 1.1.1 `Could not create service of type FileAccessTimeJournal`

**症状**

`flutter build` / `dart tool/inkpaper.dart build` 一两秒就失败，Flutter 只说
「Gradle threw an error while downloading artifacts from the network」，**这句是误导**。
加 `--stacktrace` 才看得到真因：

```
Could not create service of type FileAccessTimeJournal
Caused by: java.io.FileNotFoundException:
  ...\gradle-home\caches\8.14.3\fileHashes\fileHashes.lock (拒绝访问)
```

**原因**：不是网络，是 **`GRADLE_USER_HOME` 里两个 daemon 抢同一个缓存锁**。
Windows 把「文件被占用」也报成 `拒绝访问`，所以看起来像权限问题。常见于：

- 上一次构建的 daemon 卡在 `STOPREQUESTED` 状态（`./gradlew --status` 能看到）；
- daemon 之间 JVM 参数不一致（`incompatible`），新构建只能另起一个 JVM 去抢锁。

**处理**

```bash
cd android && ./gradlew --stop        # 常规手段，但卡死的 daemon 它清不掉
# 不行就按 PID 杀掉所有 java.exe（Gradle/ Kotlin 守护进程都是 java.exe）
./gradlew assembleRelease --no-daemon # 绕开 daemon 复用，一定能过
```

判断锁是否真的放开了，用 PowerShell 独占打开锁文件试一次，比看进程列表可靠：

```powershell
[System.IO.File]::Open("...\journal-1\journal-1.lock",'Open','ReadWrite','None')
```

能打开说明没进程占用。**别急着怀疑 ACL**（这次 ACL 一直是好的），也别重装 Gradle。

### 1.2 测试被代理拦掉

**症状**

```
Invalid WebSocket upgrade request
```
只在 `flutter test` 出现，`flutter analyze` 正常。

**原因**

环境变量里有 `HTTP_PROXY` / `HTTPS_PROXY`，`flutter_tester` 起本地 WebSocket 时被代理接管。

**处理**

```bash
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost dart tool/inkpaper.dart test
```

### 1.3 CI 环境的三个历史修正

- JDK 必须是 **temurin 17**，`Android` workflow 依赖这个版本跑。
- `android/gradle.properties` 的 tmpdir 改**相对路径**，绝对路径在 runner 上不存在。
- gitleaks 下载偶发超时，已加重试。
- `Android` workflow 偶发红在 `gradle-8.14.3-all.zip` 被 CDN 返回 504，已重试 3 次；再红就是 CDN 问题，重跑 job 即可，别改依赖。

Flutter 版本 CI 钉死 **3.47.7 / Dart 3.13.5**，本地对齐再复现问题。

### 1.4 只验 Kotlin 编译，别全量构建

改 Android 原生代码（小组件、MethodChannel）时，全量 `build android-release` 要三分半。
只验编译用：

```bash
cd android && ./gradlew :app:compileReleaseKotlin -x compileFlutterBuildRelease
```

### 1.5 装机不要用 `adb install -r`

**症状**：命令返回 Success，但设备上还是旧版本（streamed 安装静默失败）。

**处理**

```bash
adb push build/app/outputs/flutter-apk/app-release.apk /data/local/tmp/inkpaper.apk
adb shell pm install -r -d /data/local/tmp/inkpaper.apk
```

### 1.6 Kotlin 改完不生效（同版本号也一样）

见 [6.1](#61-改完小组件看不到变化)。

---

## 2. Dart / Flutter 代码

### 2.1 「format 0 changed」≠ analyze 通过

**症状**：`dart format` 报告零改动，`dart analyze` 却报 `require_trailing_commas`。

**原因**：`dart format` **不增删尾随逗号**，两者是独立检查。

**处理**：改完代码必须跑 `dart tool/inkpaper.dart analyze`，多层构造调用末尾补 `,`。
`verify` 已经是 deps → format → analyze → test 全链路，本地提交前跑它最稳。

### 2.2 历史文件是 CRLF

`.gitattributes` 已加 `eol=lf`，但老文件本身还是 CRLF 内容。

- Python 读写一律 `open(..., newline='')`。
- 用编辑工具做多行替换时，CRLF 文件容易匹配失败，先在 `git diff` 里确认没整文件重写。

### 2.3 字符串插值只认函数名

```dart
// 错：$_tags(x) 只插值函数本身，输出 "Closure: (String) => String(x)"
'$body\n\n$_tags(x)'

// 对
'$body\n\n${_tags(x)}'
```

### 2.4 测试里构造中文 HTTP 响应会抛异常

`http.Response(String, 200)` 默认按 **latin1** 解码，塞中文直接抛异常。

```dart
http.Response.bytes(utf8.encode(jsonEncode(payload)), 200)
```

### 2.5 `pumpAndSettle` 遇到无限动画会超时

**症状**：测试挂住直到超时，报 `pumpAndSettle timed out`。

**原因**：图片查看器有无限转圈加载动画、玻璃组件有兜底 `Future.delayed`，永远不会 settle。

**处理**：改用定长 `pump(Duration(...))` 推进；有兜底 timer 的测试末尾补 `pump(const Duration(seconds: 5))` 清掉 pending timer，否则报 `A Timer is still pending`。

### 2.6 玻璃组件在测试里是假的

`liquid_glass_renderer` 需要 Impeller，`flutter test` 环境直接走 FakeGlass。
→ **单元测试只能验结构和交互，观感必须上真机看**。别拿测试通过当视觉验收。

### 2.7 应用展示名只认 `InkPaper`

`MaterialApp.router(title:)` 就是 **Android 最近任务卡片的标签**，必须用 `AppConfig.appName`。
分享文案、备份 HTML 抬头、l10n 里的 `backupShare*` 已统一；`InkPaper-<tag>-android.apk` 属文件名/URL，保持英文不动。

---

### 2.8 保存路径上不要做全表加载

**症状**：点保存后要卡一下编辑器才关，笔记越多越明显。

**根因**：`_processNoteReferences` 无条件调 `UnifiedReferenceManager.updateReferencesFromContent`，
而它第一件事就是 `getNotes()` 把整库拉进内存（每条还要 `json.decode` resourceList /
relations、`DateTime.parse` 四次）。**一条纯文字笔记也要过一遍整库。**

**处理**：内容里没有 `[[`、并且这条笔记身上也没有已存的引用关系时直接 return。
不能只判 content —— 删掉已有的 `[[x]]` 后正文不含 `[[`，但仍要跑一次清理旧关系。
`createImportedNotes` 早就用 `contains('[[')` 短路了，单条保存这条路一直漏着。

**再往下还有一层（OPT-10，2026-11-23）**：短路只挡住了「没有引用」的笔记，
真有引用时 `updateReferencesFromContent` 仍会 `getNotes()` 全表加载，接着对每个
引用调 `createReference` / `removeReference`，而这两个内部**又是** `getNotes()`——
一条正文引用三个笔记，保存一次读四遍整库。现在按下面的顺序解析：

1. 编辑器插入的就是 `[[<id>]]`（`note_editor.dart` 的 `[[${referencedNote.id}]]`），
   先 `DatabaseService.getNotesByIds()` 一次批量查（900 个一批，绕开 SQLite 999 变量上限）。
2. 按 id 查不到才回落到历史兼容路径（`[[正文]]` / `[[正文前缀]]`），只有这条才 `getNotes()`。
3. `createReference` / `removeReference` 改成 `getNoteById` 取源和目标两行。
4. 回调语义从「全量笔记」改成「本次受影响的笔记」（`onNotesChanged`）——传整表
   会让分页列表被整体替换，和 OPT-02 的分页状态打架。

新增引用相关逻辑时别再调用 `getNotes()` 做 ID 匹配，也别把 `onNotesChanged` 当全量用。

**维护入口（OPT-10B）**：`AppProvider.rebuildAllReferences` 以前遍历 `_notesStore.notes`
—— 首页分页缓存，只有已经加载的那几十条会被重建；而且中间两次 `loadNotesFromLocal()`
把 `pagingState` 换回初始值（`currentPage = 0`、`hasMoreData = true`）却塞了整库进
`notes`，滑到底会按第 1 页再追加一次，列表出现重复条目。现在重建整段在
`UnifiedReferenceManager.rebuildAllFromDatabase()` 里按库跑（全量读 → 清关系 →
内存里双向配对 → 批量写回），AppProvider 只负责重建后 `loadInitialNotes()` 重查首屏，
分页状态由 `applyInitialPageResult` 按「已加载 / 总数」算。**批量维护操作不要用
`loadNotesFromLocal()` 收尾**，它是「整库塞进内存 + 分页归零」的组合，和分页列表不兼容。

保存路径上的其他原则：

- 桌面小组件快照别用 `Duration.zero`。快照要遍历全部笔记跑待办正则 + 过平台通道，
  原生侧还会重绘 13 个组件，放在保存同一帧就是和关闭动画抢主线程。延后到 900ms。
- 保存按钮要有 loading 态。只把 `onPressed` 置 null，用户看不到任何反馈，会把
  几百毫秒放大成「卡死」。

### 2.9 `enum` 成员名和 l10n key 都会撞名

**症状**：加「AI 洞察」时一次报了三个错——`A member named 'values' can't be declared
in an enum`、`The type 'InsightLensIcon' used in the 'for' loop must implement
'Iterable'`，以及 l10n 的 `duplicate_definition`。

**原因**：

- Dart 的 enum 自带隐式静态成员 `values`，任何成员叫 `values` 都会被拒；连带着
  所有 `Xxx.values` 的遍历写法一起失效，第二个报错只是它的连带症状。
- `app_localizations_simple.dart` 里早就有一个 `aiInsight` getter（指单条笔记的
  AI 洞察，文案是「AI洞察」），我又加了一个同名 getter。功能名撞车是常事。

**处理**：

- enum 成员换名（`values` → `clarify`），但序列化用的 `key` 保持 `'values'`，
  已存盘的配置才不会失效。
- 新增 l10n key 前先 `grep -n "'<key>'" lib/l10n/*.dart`。既有的 key 优先复用，
  只改文案值，不要再写一个同名 getter。

一次 grep 的成本远低于跑一遍 analyze（本项目 30-75 秒）。

### 2.10 洞察类提示词要写「内核」，不能只写步骤

**症状**：AI 洞察第一版六个视角每个只写了 3–5 条动作（「找出 2-3 条线索」「指出
矛盾」）。结构齐全，但输出像填表：每条都对，每条都没信息量，还会硬凑条数。

**原因**：只给步骤，模型只会照做，不知道「为什么要做」，于是拿通用标签交差——
完美主义、内耗、高敏感。字数也只给了上限（600-900），模型会写满上限并掺水。

**处理**：

- 每个视角写四层：**内核**（这个方法论到底在做什么）→ **步骤**（可执行 + 验收
  标准）→ **输出骨架**（分几段、每段多少字）→ **质量红线**（这个视角最容易跑
  偏的地方）。
- 步骤要给判断标准，不要给动作。反面：「找出 2-3 条线索」。正面：「模式必须能
  写成触发 → 反应 → 代价三段，写不成的都还只是主题」。
- 字数给区间不给上限（480-560），并要求「证据只有一条就说只有一条」，否则模型
  会为了凑满结构编依据。
- 红线要写具体。CBT 视角写「替代说法里不许出现『其实你已经很棒了』」比写「不要
  安慰」有效得多。
- 测试锁结构：`ai_insight_service_test.dart` 断言每个视角都含四层小标题，以后改
  提示词漏层会直接红，不用靠人眼复查。

**参考**：flomo 帮助中心把每个视角的定位写得比名字细得多（默认洞察「挖掘思维模式
与深层内在矛盾」、价值澄清「从混乱回到核心」），是写内核的好素材；但它不下发
prompt，所以只能对齐意图，不能照抄。

### 2.11 全量口径的统计与抽样：读窄列，抽样别先全筛

**症状**：保存/删除后仍偶发掉帧；桌面小组件重建一次要几百毫秒，库越大越明显。

**根因**（OPT-04，2026-11-23 实测 1500 条库）：小组件快照一次构建做了两件不必要
的重活——

1. `getNotes()` 把整库构造成完整 `Note`，每行还要 `jsonDecode` 一次 `relations`
   和一次 `resourceList`，而快照只用到正文、时间、标签和几个状态位。
2. 挑 8 条回顾候选时，为了「有可见文字」这条规则**先对全库每条跑一遍**
   `previewVisibleText`（完整 Markdown 解析），1500 条就是 540ms，最后只留 8 条。

**处理**：

- **整库统计用专用窄列查询**（`getWidgetStatNotes`）：不读关系那段 JSON；附件列表
  要留着（「这是一条含图片的笔记」靠它判断）。只有要落盘/要双链的完整笔记才走
  `getRecentActiveNotes(20)`，按需取最近 N 条。
- **抽样别先全筛再洗牌**。「洗牌后取前 N 个满足条件的」与「先筛出满足条件的再
  洗牌取前 N 个」分布相同，但前者取满就停：解析量从 O(全库) 降到 O(命中条数)。
  只有「范围内一条都不满足」时才回到全库兜底，这条分支要显式写上，否则小库/
  图片型库会抽不出卡片。
- 判定指标要可断言：`MemosContentHelper.debugPreviewParseCount` 数真实解析次数，
  比耗时断言稳定。改回全筛会直接跳到 300+。

**注意**：`Note.fromMap` 的 `relations` 是同步写进来的 JSON，**只有统计口径**可以
不读它；任何要判断双链、要 `toMap` 落盘的路径都必须读完整行。

### 2.12 本地 `DateTime` 很贵：统计口径别构造它

**症状**：桌面小组件统计路径把整库（1500 条）读一遍仍要 240ms 级，而且 SQL 只占
5~6ms——剩下的全在 Dart 侧。

**根因**（OPT-04B，2026-11-23 实测）：`Note.fromMap` 每行解析 3 个时间字段，
`DateTime.parse` 出来的是**本地** `DateTime`，构造时每次都要向系统查一次时区偏移。
本机实测（flutter test 的 JIT）：

| 操作 | 20,000 次耗时 |
| --- | --- |
| `DateTime.parse('2026-11-23T19:50:34.123')` | 约 560ms（28µs/次） |
| `DateTime(y, m, d, …)` | 约 890ms（45µs/次） |
| `DateTime.utc(y, m, d, …)` | 约 2ms（0.1µs/次） |
| `DateTime.utc(...).toLocal()` | 约 230ms |

也就是说：**贵的是本地时间 vs UTC 的换算，不是字符串解析**。手写一个 ISO 解析器
替掉 `DateTime.parse` 几乎没用（实测只快 5%）。1500 行 × 3 = 4500 次，正好是那
240ms。

**处理**（`lib/models/widget_stat_note.dart`）：

- 统计/回顾只需要「哪一天」「谁更新得更晚」。ISO 8601 前 10 位就是挂钟日期，同格式
  的 ISO 串按字典序排就是按时间排——**全程留在字符串形态**，一行都不用解析。
- 真要渲染的只有回顾 8 条 + 置顶 1 条（`_noteSnapshot` 的 `createdAtLabel` /
  `ageLabel`），这几个时间字段做成惰性 getter + 缓存，解析次数从 4500 降到个位数。
- 标签排序（`rankTagsByUsage` 要 `DateTime` 算新鲜度）改成「先按标签记下最晚更新的
  ISO 串，只对去重后的标签解析」。
- 判定指标：`Note.debugDateTimeParseCount`（`fromMap` 里的解析次数）与
  `WidgetStatNote.debugLazyParseCount`（惰性解析次数）。改回整库 `fromMap` 会从
  0 跳到 900。

**注意**：

- 别顺手把 `Note.fromMap` 改成解析成 `DateTime.utc`。字段值是对的，但
  `toIso8601String()` 会多出 `Z`、`DateTime.now()` 比较整体差 8 小时——这就是那条
  伪 UTC 老坑的另一种写法。
- 换字符串比较后，「今天」「N 天范围」变成按自然日而不是按精确时刻：窗口最多宽出
  不到一天。对周/月格子和回顾范围这种粒度反而更自洽（格子本来就按日期分组）。
- 待办计数（`TodoParser.countTodos`）顺带加了两条：正则提到类级常量（原先**每行**
  new 一次）、没有 `[` 直接返回。1500 条 × 60 行：29~48ms → 6~8ms，但口径必须与
  `parseTodos` 保持一致，`TD-16` 逐例对照锁住。

### 2.13 启动首帧：准备一次发起，别在开屏路上等网络

**症状**：开屏「有时」慢，冷启动更明显；一旦构建时带了 `--dart-define=FEATURE_FLAG_URL=...`，
启动会整整卡到 5 秒超时。

**根因**（OPT-06A，2026-11-23）：

1. 首屏快照与主题/语言配置这两项，原本是在「日期格式 + 三个缓存」四项 `await`
   完之后才发起的，等于在最慢项之上又串了一轮；
2. `FeatureFlagService.init()` 在首帧前 `await`，它后面跟着一次 HTTP。默认
   `FEATURE_FLAG_URL` 为空所以早退，一旦有人配置了，开屏就是在等网络兜底超时。

**处理**：

- 六项准备（日期格式、图片/附件/缩略图缓存、首屏快照、外壳配置）收进
  `lib/utils/startup_essentials.dart` 的 `loadStartupEssentials()`：**连续六行发起，
  再统一 `Future.wait`**。谁把某一项改成「前一项 await 完再发起」，`SE-01/02/03`
  立刻红（串行 258ms vs 并行 52ms，六个 50ms 的合成任务）。
- 用一次 `Future.wait` 收口，而不是逐个 `await`：一次注册全部监听，任何一项失败
  都不会因为「还没轮到 await」被当成未捕获异常。
- 功能开关拆成 `loadLocal()`（首帧前，只读 SharedPreferences）与
  `refreshRemote()`（首帧后 fire-and-forget）。判断依据是「首次访问是否安全」：
  日期格式、附件/缩略图索引未就绪会直接降级成原图或抛异常，必须等；
  远程开关只是「尽量升级」，晚到无感。
- 谁能推迟要拿数据说话：缩略图索引扫描是全组最慢的（合成目录 5000 个文件 37ms），
  但它决定首帧卡片能否命中缩略图，移走等于让首屏去解原图——保留，别凭「看着慢」就挪。
  （后来找到了两全的挪法：先补一次 stat 兜底再挪，见 §2.14。）

### 2.14 缩略图索引能挪到首帧后，前提是 `lookup` 补一次 stat

**背景**（OPT-06C，2026-11-23）：§2.13 里「保留」的那一项，慢的不是目录可用，是**扫目录**。

- 首帧真正需要的只有目录路径（写缩略图要用）。`getTemporaryDirectory()` +
  `create()` 是毫秒级；扫描只是把已有缩略图名字读进 `_known`，换来「未命中不用 stat」。
- 做法：`prepare()` 只等到目录可用就返回，`_scanDisk()` 改成 fire-and-forget
  （`indexReady` 给需要完整清单的人等）。扫描没完成的窗口里，`lookup` 对**未收录**
  的名字补一次同步 `existsSync()`，命中就顺手补进 `_known` 走快速路径；`ensure`
  同样先 stat 再决定编不编码，否则会把盘上已有的缩略图重解一遍。
- 扫描完成后必须**关掉兜底**：索引里没有就当未命中，不再 stat。`TC-25` 钉的就是
  这个闸门——漏了它，每次 miss 都白付一次系统调用。
- 需要完整清单的后台任务一律 `await indexReady`：补齐的 `_pendingSources`
  （否则把已生成的图全部重排一遍）、磁盘记账 `_runDiskMaintenance`（否则
  `_diskBytes` 算漏、淘汰算错）、`clear()`（否则扫描会把刚删的名字加回去）。
- 量级（本机 5000 个缩略图，热页缓存）：`prepare` 6.5ms / 4.0ms（两次），扫描
  58ms / 55ms —— 首帧前少等约 55ms；代价是窗口内每张卡片多一次 stat
  （55.7~71.1µs，索引命中 36.6~42.2µs），首批可见十几张图合计 0.2~0.5ms。
  冷缓存下扫描更慢、收益更大。

**返修（OPT-06C 复验，2026-11-24）：收尾 ≠ 完整。** 上面那版把「扫描结束」和
「索引可信」用同一个 `_indexComplete` 表示，`_scanDisk` 的 `finally` 无条件置 true
——扫描半途 IO 失败时，`_known` 只是**部分清单**却被标成完整，于是：

- `lookup` 关掉了 stat 兜底，盘上确实存在的缩略图被判未命中 → 退回原图并重新编码
  （缓存白做，还挤占编码槽，正好是最不该发生的事）；
- `ensure` 也不再看盘上文件，同一张图会被重解一遍。

改法是把状态拆成两个维度：`_indexSettled`（流程收尾，决定 `indexReady` / 补齐 /
磁盘整理能不能放行）与 `_indexComplete`（索引可信，决定要不要 stat 兜底）。失败时
`settled = true, complete = false`。连带两处：`_pendingSources` 在索引不可信时直接
跳过这一轮（没有「缺哪些」的依据，硬排就是把已有缩略图全刷一遍），
`_runDiskMaintenance` 只在可信时才置 `_diskIndexed`（兜底补进来的条目下次还能记账）。

教训：状态机里「流程结束」和「数据可信」是两件事，合成一个 bool，失败路径上必然
撒谎。造样本要能注入失败——真实文件系统不会给你「扫到一半抛错」，本轮为此加了
`debugSetDiskLister`（`TC-27/28/29` 咬住兜底、补齐与 `clear()` 三条路径）。

### 2.15 两种时间来源混存：排序要比「墙钟」，不能一边比字符串一边比时刻

**背景**（OPT-02A 返修，2026-11-24）：本地新建的笔记写 `2026-11-23T09:00:00.000`（本地时间、无后缀），Memos 同步的写 `2026-11-23T02:00:00.000Z`（把北京时间当 UTC 存）。同一对笔记：

- SQL 拿列比字符串：`"…T09" > "…T02"` → 本地 09:00 在前；
- Dart 拿 `DateTime` 比绝对时刻：`09:00+08 = 01:00Z < 02:00Z` → 远端 02:00 在前。

首批（SQL）和切换排序后（内存重排）顺序相反，看起来像「排序坏了」。**只要两边比较口径不同，就一定会分叉**——所以要么都按绝对时刻（要改 `_parseTimestamp`，牵动 WebDAV），要么都按墙钟（与界面显示口径一致，选了这条）。

- SQL 侧：`substr(replace(col, ' ', 'T'), 1, 23)`。三个细节各有原因——截到 23 位取毫秒（Dart 侧同样不比微秒，否则同毫秒不同微秒的行两边顺序不同）；`Z` 不参与比较（它是来源标记，不是时区）；`replace` 归一空格，因为老的 `DateTime.toString()` 是空格分隔，而空格 0x20 < `T` 0x54，同一时刻的两种写法在 SQL 里会排出先后。
- Dart 侧：`compareNoteWallClock` 逐字段比年月日时分秒毫秒，**不看 `isUtc`**。
- **两边改一处不够**：只改 SQL 会让内存重排与新查询不一致，只改比较器同理。反向验证要分别把一端改回去，两侧的用例都要红。
- 测试样本必须有「墙钟并列、来源不同、且 `id` 顺序与字符串里带不带 `Z` 相反」的一组，否则漏掉 `id` 兜底也测不出来。
- 代价：`ORDER BY` 变成表达式后用不上 `idx_notes_created_at`，走临时排序。纯本地或纯 Memos 库顺序不变（同来源内两种比较等价）。

### 2.16 两个「按类型取路径」的方法并排调用 = 同一份正文扫两遍

**背景**（OPT-09B，2026-11-24）：卡片要同时拿图片和视频（互斥渲染），于是连调
`extractNoteImagePaths` + `extractNoteVideoPaths`。两个方法长得像「独立的小工具」，
但各自都把 `note.content` 交给同一个正则跑一遍 `allMatches`，再各自过一遍 `resourceList`。
滚动时每帧都付两次——4359 字正文实测：合并 **31.88µs**、分开两次 **61.55µs**。

- **识别信号**：两个方法签名只差一个 `video` / `images` 参数、内部都从同一个字段取值、
  调用点总是成对出现。这就是「同一份输入的两次遍历」，该合成一个返回两条列表的入口。
- **不能顺手共用的东西**：去重集合。图片与视频的「是不是同一个」是两套独立判断——
  资源声明为图片、正文却写成 `![视频](...)` 时，两边各保留一次。共用 `Set` 会静默吃掉一条。
- 旧的两个方法**保留成转发**，别删：调用点分散，改签名等于给自己制造无关 diff。
- 断言「合并了」不要靠耗时（JIT 抖动大），加个 `@visibleForTesting` 扫描计数，
  直接断言「一次合并 = 1，两个旧入口 = 3」。

### 2.17 分页窗口不是缓存：往 `notes` 里 `add` 一条，后面全错位

**背景**（OPT-10 返修，2026-11-24）：引用管理器改到一条深页笔记时，回调为了「让引用面板能显示对端标题」，
把它 `add` 进了 `AppProvider.notes`。那个列表是分页窗口，续页按 `OFFSET` 取，下一条 SQL 照样返回它 ——
同一个 id 两张卡片。

- **判别标准**：这个 `List` 的第 i 个位置是否对应 SQL 的 `OFFSET i`？是，就不能往中间或末尾插。
  `hasMoreData`、`totalNotesCount` 的比较、滚动位置恢复都建立在「窗口 = 库的一个前缀」上。
- **要显示窗口外的数据，就按 id 查库**：`getNotesByIds` 走一次点查，比污染窗口便宜得多。
  异步补查在 build 里调度时用 `addPostFrameCallback`，回来 `setState`；未回来的那一帧显示 `…` 而不是
  「未找到」——否则用户会看到假的失败态。
- **去重闸门**：续页 `addAll` 前按 id 过滤（`filterUnloadedNotes`）。它平时不触发，但把「窗口里不会出现
  两条同 id」变成结构保证而不是约定；纯泛型函数也便于直接单测，不用先造一个真分页窗口。
- **`testWidgets` 里碰真库要用 `tester.runAsync`**：FakeAsync 不推进真实 IO，直接 `await` +
  `pumpAndSettle` 会一直卡到进程被 SIGTERM，症状是「测试没输出、耗时很久、退出码 1」。

### 2.18 时间区间别退化成「按日」，也别为此解析 DateTime——用挂钟字符串键

**背景**（OPT-04B 返修，2026-11-24）：小组件回顾要「最近 7 天的笔记」。为了不做 1500 次本地
`DateTime` 解析（45µs/次），实现退化成比 `yyyy-MM-dd` —— 18:00 请求时，7 天前 09:00 也被算成
「最近 7 天」，窗口宽出将近一整天。

- **不用二选一**：库里存的就是 ISO 串，截前 23 位（`YYYY-MM-DDTHH:MM:SS.mmm`）当键，
  字典序 = 挂钟时间序。与 `noteTimeKeySql` / `compareNoteWallClock` 同一口径，见 §2.15。
  `DateTime.parse` 只是把串变成对象，**并不会让比较更准确**，只会更贵。
- **下界也要同精度**：cutoff 用同样的 23 位键（`noteWallClockKey(now - N 天)`），
  否则「截断只发生在一侧」，边界又歪了。
- **`Z` 与微秒都不参与**：截到 23 位自然就排除了它们；混存来源因此落在同一条坐标轴上。
- **坏数据要降级，不要崩**：库里的时间字段来自 Memos、导入、老版本，`DateTime.parse('')` 会抛
  `FormatException`，而它常在「构建整份快照」的循环里 —— 一条坏行能让整个桌面小组件不更新。
  渲染路径统一用 `DateTime.tryParse`，解析不出来就给空文案；排序/统计键本来就不解析，天然免疫。
- **加可注入的 `now`**：窗口边界类逻辑一定要能在测试里固定「此刻」，否则用例只能在某些时刻红。

---

### 2.19 缩略图别先解整张图：`img.decodeImage` 全解 vs 引擎采样

**背景**（OPT-07A，2026-11-24）：缩略图编码一直用 `img.decodeImage` 全量解码再
`copyResize`。对手机照片来说这是先花几十上百 MB 换一张 480 宽的图。本机 JIT 实测：

| 样本 | `img.decodeImage` | `ui.instantiateImageCodec(targetWidth:)` |
| --- | --- | --- |
| 24MP（6000×4000） | 1467ms、RSS +393MB | 31ms、+1MB |
| 32MP 长截图（1080×30000） | 2582ms、RSS +463MB | 293ms、+24MB |
| 50MP 手机照（外推） | 约 800MB | 几十 MB |

- **分流而不是全量替换**：先读图片头部拿尺寸（`findDecoderForData` +
  `startDecode`，只解析头部、不解像素），超过 8MP 才走引擎采样；普通截图仍在
  `compute` 里全解，行为面最小。
- **`findDecoderForData` 自己会抛**：几个 `isValidFile` 直接按下标读魔数，一两个
  字节的坏文件能抛 `RangeError` 到外面（`TC-17` 的 `broken.jpg` 当场复现）。
  包 `try` 里。
- **只给一个目标维度**：`targetWidth` + `targetHeight` 同时给等于「输出就是这个
  尺寸」，而头部宽高是 **EXIF 方向应用之前**的——竖拍照片会被拉伸成横的。
  长度限制改成「先按宽度采样，出来还超上限再按高度重解一次」，两次都等比。
  不会变形，方向也与 `img.decodeImage` 路径一致（实测两边都 480×720）。
- **`toByteData()` 默认是预乘 alpha**：`rawRgba` 的解码结果 alpha 预乘过，image
  包按非预乘解读，半透明图会发黑（实测 200 被压成 100）。要显式传
  `ImageByteFormat.rawStraightRgba`。
- **输出高度也要封顶**：1080×30000 按宽缩到 480 后还有 13333 高，缩略图自己就
  25MB，而卡片 `BoxFit.cover` 只显示中间一条。上限取 4096，长图改为按高度缩、
  宽度随之变窄。
- 引擎解码只能在根 isolate（不能用 `compute`），但解码在引擎 IO 线程、主 isolate
  只剩几毫秒的字节转换与编码，不卡帧。

### 2.20 大图的 evict 别写在使用它的 widget 里

**背景**（OPT-07A-2，2026-11-24）：查看器的高清图在 `_PhotoPageState.dispose`
里 `provider.evict()`，而预取走的是全局 `imageCache`。看起来都在「收尾」，实际
两个方向都错：

- **该留的没留**：`PageView` 的 `cacheExtent` 是 0，翻走的那一页立刻 dispose，
  于是刚离开的那张被清掉 —— 回看要重新解码（12MP 原图 150~300ms）。
- **该清的没清**：`precacheImage` 预取的邻居可能从未被显示，它没有页面，也就
  没有 dispose 替它收尾，退出查看器后还留在全局缓存里占一块纹理。

用 `ImageCache.containsKey(key)` 采样（`o`=在缓存，4 张图，打开→翻→翻→回→退出）：

| 阶段 | 修前 | 修后 |
| --- | --- | --- |
| 打开 @0 | `[o,o,x,x]` | `[o,o,x,x]` |
| 翻到 1 | `[x,o,o,x]` | `[o,o,o,x]` |
| 翻到 2 | `[x,x,o,o]` | `[x,o,o,o]` |
| 回看到 1 | `[x,o,x,o]` | `[x,o,o,x]` |
| 退出 | `[x,x,x,o]` | `[x,x,x,x]` |

- **保留窗口放在页面之上一级**：`_retainAround(index)` 维护「当前页左右各一张」，
  窗口外的立刻 evict，窗口内的登记在一张 map 里、由查看器自己的 `dispose`
  统一回收。谁显示、谁预取、谁释放三件事由同一个对象拍板，才谈得上「共用同一
  保留范围」。
- **键必须一致**：页面、预取、窗口三处都走同一个 `_viewerProvider(index)`（同一
  路径 + 同一 `viewerDecodeWidth`）。width 差一档就是两个缓存键，预取白做、
  evict 也清不到正主。
- **预取要按「窗口里谁还没解」挑边**：只认「下一张」的话，回看方向永远没有预热。
  先 `obtainKey` 再看 `containsKey`，已在缓存（含正在解码）就跳过，仍然只解一张。
- **测试怎么断言「不重解码」**：`ImageCache` 不暴露解码次数，但键还在缓存里就说明
  `resolve` 会命中。用固定的 surface（800×600@3x）把解码宽度钉成 1600，再用
  `ResizeImage(FileImage(file), width: 1600)` 自己算键比对。真实图片解码需要
  `tester.runAsync` 里推进真实 IO，`pumpAndSettle` 会因为加载指示器转不停而超时，
  改用「runAsync 30ms + pump 60ms」循环几次。

### 2.21 ZIP 想流式，就别让 deflate 碰大文件

**背景**（OPT-07B，2026-11-24）：本地备份原来把每个附件 `readAsBytes()` 塞进
`Archive`，再 `ZipEncoder().encode` 出一整包。视频上限是单段 150MB / 合计
200MB，这条路上峰值是总量的好几倍。

`archive` 包给了 `ZipFileEncoder`（写文件、`OutputFileStream` 按 1MB 缓冲）和
`InputFileStream`（按块读），但它们**只对 STORE 条目才是流式的**：

- `ZipEncoder.addFile` 的压缩分支是 `file.content.toUint8List()` → `Deflate(...)`
  → `InputStream(bytes)`。传进去的是流也先被读成一整块，等于白省。
- STORE 分支直接把 `InputStreamBase` 当 `compressedData`，`writeInputStream`
  在 `OutputFileStream` 上按 1MB 分块写出；CRC 也分块算（代价是先把文件扫一遍）。

所以「流式」的前提是给大文件 `..compress = false`。视频本来就压不动，体积几乎
不变；图片留在压缩分支没关系 —— 它反正要整张读出来切动图片段，单张的拷贝不随
总量累积。

| 样本（本机 JIT） | 整包 encode | 流式落盘 |
| --- | --- | --- |
| 5×8MB 压不动的图片 | 2569ms / 峰值 +131MB | 2585ms / +49MB |
| 单个 60MB 视频 | 3726ms / +92MB | 1157ms / +49MB |

- **交付才是剩下的那份内存**：系统选择器（`FilePicker.saveFile(bytes:)`）和加密
  都只收 `Uint8List`，所以 `buildArchive` 最后仍要读一次整包。要继续降只能改成
  路径交付（分享 `XFile(path)`、应用目录 `copy`），那是 UI 流程的活。
- **临时目录别用 `Directory.systemTemp`**：Android 上它可能落在授权范围外，写出
  来的文件再分享会被 FileProvider 拒。用 `getTemporaryDirectory()`，并把它做成
  构造参数，单测里注入 `Directory.systemTemp` 绕开 path_provider 通道。
- **失败要删半成品**：`create()` 之后任何异常都先 `close()` 放句柄再删文件，然后
  抛原异常。留一个写了一半的 zip 比不留更糟 —— 用户会把它当成有效备份。

## 3. 时间显示口径（最容易反复踩）

### 3.1 Memos 存的是「伪 UTC」

`...T19:53:00Z` 里的 `19:53` 就是**北京时间的挂钟时间**，结尾的 `Z` 是错的。

**铁律**：一律按 `Note.createdAt` 字段值直接格式化，**禁止 `toLocal()`**。
统一走 `lib/utils/note_timestamp_format.dart`：

| 场景 | 格式 |
| --- | --- |
| 往年 | `yyyy-MM-dd HH:mm` |
| 今年 | `MM-dd HH:mm` |
| 今天 | `HH:mm` |

Kotlin 小组件只裁 ISO 字符串，不要交给 `SimpleDateFormat`（它会按本地时区再算一遍）。

**已经因此出过 bug 的位置**（见到 `toLocal()` 就删）：小组件时间、修改时间菜单、那年今日卡片。

### 3.2 遗留问题

伪 UTC 的绝对时刻整体比真实时刻早 8 小时。

- **首页排序已按墙钟口径修好**（OPT-02A，`lib/utils/note_sorting_helper.dart`）：SQL 用 `noteTimeKeySql`、
  Dart 用 `compareNoteWallClock`，两端同口径，见 §2.15。混合来源下「排出来的顺序」与「界面显示的时刻」
  重新对齐。
- **range 过滤与 WebDAV 冲突判断仍按绝对时刻**：只在 **8 小时窗口内跨源混排**时可能错位。彻底修要动
  `_parseTimestamp`，风险大于收益，暂不动。改这块前先想清楚影响面，并顺手检查排序那一侧是否还一致。

---

## 4. 备份与媒体

### 4.1 WebDAV 附件是内容寻址，哈希必须与整块一致

文件名 `sha1.ext`。视频走 `startChunkedConversion` 流式哈希，**流式哈希结果必须与整块哈希同名**，否则同一文件会在服务端存两份。
`_digestCache` 按「路径 + size + mtime」缓存，mtime 变了要重算。

### 4.2 大文件只走文件句柄，别整块 read

附件统一按「本地文件」处理而不是 bytes（要兼容 `file://`、`images/` 相对路径、AttachmentCache、本机同名、服务端与外链流式）。
读写只用 `writeFromFile` / `read2File`，整块 `read()` 会 OOM。

### 4.3 服务端 `/o/r/<uid>` 没有扩展名

从 Memos 拉附件时 URL 不带扩展名，要靠 resourceList 里的 `filename` 补扩展名；视频兜底按 `mp4`。
恢复时**服务端视频不落离线副本**（`restore(includeVideos)` 过滤 videoLike），否则手机存储会被塞爆。

### 4.4 本地 ZIP 备份有硬上限

图片和视频共用 `![alt](path)` 语法，靠 `MediaPaths.isVideoMarkdown` 分流，**图片分支必须排掉视频**，否则视频会被当图片塞进 ZIP。

上限：**单段 150MB / 合计 200MB**。原因：`ZipEncoder().encode()` 整块进内存，加密后还要 base64 再翻一倍。
超限就跳过并计数，别赌 OOM。还原时文件名带 `_${restored.length}`，防同一毫秒内撞名。

### 4.5 缩略图生成

- 视频不生成缩略图。
- `.gif` 取首帧存 PNG；`.heic/.heif` 走 `ImageDecoder`，必须 `ALLOCATOR_SOFTWARE` + `setTargetColorSpace(SRGB)`，否则黑图/偏色。
- **`img.decodeImage` 必须传 `frame: 0`**，默认取最后一帧。
- **MethodChannel 只能在主 isolate 调**，放 `compute()` 里会直接崩。
- 解码失败返回 `null`，调用方退回原图，不要抛异常打断列表渲染。

### 4.6 Live 图（动态照片）

插入时 `LivePhotoUtils.extractMotionPhoto` 从 JPEG 尾部抽内嵌 MP4，存成 `<图片名>.live.mp4`。
`hasLiveVideo` 要同时试 `file://` 与裸路径；网络 URL / content URI 一律返回 false。

⚠️ **`pickMultiImage()` 不能加 `quality` / `maxWidth`**——重编码会把内嵌视频丢掉。

查看器当前页 550ms 后自动播一遍（静音、不循环），**必须排在原图解码 260ms 之后**，否则抢占解码导致闪烁。

---

## 5. UI / 交互

### 5.1 详情页正文必须用 `Text.rich`

`SelectableText` / `SelectionArea` 会吞掉单击事件，正文点不进编辑态（FS-05 用例锁住了这个行为）。
复制全文靠外层 `onLongPress` 长按菜单实现。

### 5.2 编辑入口是「单页双态」

- 新建：底部玻璃卡片，`NoteEditor(fullScreen: false)`
- 改已有笔记：一律全屏 `NoteEditorPage.open()`，200ms 淡入

五个入口统一走 `lib/widgets/note_editor_page.dart`，只切容器不换实现。

### 5.3 编辑态与详情页字号必须同源

**症状**：点进编辑页会「闪一下」，因为两处字号不同导致重排。

**根因**：编辑页正文自定义了 `style` / `hintStyle`，与详情页的排版参数不一致。

**处理**：两处共用 `AppTextStyles.bodyLarge(context, height: 1.6, ...)`。**改排版只改这一处**，别再给编辑页单独写 style。

### 5.4 编辑页九宫格要能点开大图

`_buildGridTile` 原本只有长按拖动和右上角删除，点击无响应。
现在点击走 `GestureDetector.onTap` → `ImageViewerScreen.open(context, imagePaths: viewerPaths, initialIndex: viewerIndex)`：

- 图片序列按「过滤掉视频」计算，与详情页保持一致；
- 初始下标用 `identical` 定位被点的那张；
- 拖拽幽灵 / footprint 传 `interactive: false`，避免拖拽时每帧为九格白算列表（该处曾有掉帧问题）。

### 5.5 撤销 SnackBar 的视觉不在 SnackBar 里

`SnackBarUtils.showAction` 的 SnackBar 只当**透明容器**，真正视觉由 `LiquidGlassLayer + LiquidGlass` 给（`ios27Regular`、tint 0.35、refraction 14/40、圆角 26）。改样式别去动 SnackBar 自带的 backgroundColor。

**玻璃的两个反直觉点**：

1. **它采样的是身后真实的像素。** 底部输入条能出效果，是因为 `Scaffold.extendBody` 让列表从下面穿过；纯白/纯色平面背后没有花样，折射等于零，观感只剩「高光边 + 内阴影」。
2. **只给选中的那颗铺玻璃。** 侧边栏有 7 个菜单项，每个 `LiquidGlassLayer` 都要读一次背景，铺满必掉帧。用 `LiquidGlass`（需要祖先 layer）而不是 `LiquidGlass.auto`，未选中项保持扁平。

`FadeTransition` 包在 `LiquidGlassLayer` **外面**时整体会一起淡入（OpacityLayer 作用在合成结果上）；包在里面（`LiquidGlass(child: Opacity(...))`）时只有内容淡、玻璃不淡 —— SnackBar 那条渐变 tint 就是为后者补的。

### 5.5.1 抽屉里不要用真玻璃渲染器（侧边栏选中态，2026-11-20 定论）

**症状**：选中项是一块发灰的板子，改 `tintAmount`（0.18 → 0.30）、改 `appearance.tint` alpha、换 `LiquidGlassColorModel.direct`、在背后垫品牌色渐变，四种组合真机上都只是「更绿一点的灰板」，最后一种甚至变成**深绿底 + 深色字**（几乎读不出字）。

**根因**：`LiquidGlassLayer` 采样的「身后」在 Drawer 里是 **遮罩 + 半透明白**，不是设计稿上那块纯白。遮罩把采样值拉到中灰，`ios27` 颜色模型还会对低饱和背板去饱和，于是怎么加 tint 都往灰里走。在 `Scaffold(backgroundColor: Colors.white)` 的独立页面里同样的参数却是干净的薄荷绿 —— 差异只来自「背后是什么」。

**结论**：纯色/近纯色背板上的选中态，**不要花时间调参**，也不要手搓花样。1.1.118 之前一直是那套最朴素的写法，观感反而最好：

- 一层极淡的品牌色底：浅色 `primaryColor(alpha 0.10)` / 深色 `primaryLightColor(alpha 0.15)`
- 一点点同色投影：品牌色 0.10、blur 4、y 2
- 圆角 16，文字和图标**直接用品牌绿本身**，不压深

真渲染器留给「背后确实有内容」的地方（底部输入条、SnackBar）。

> **两次绕远路的记录（2026-11-21）**：
> ① 先手搓「品牌色渐变 + 顶部 22dp 白色高光 + 描边 + 压深字色」，做出玻璃胶囊；
> ② 再把整抽屉改成毛玻璃（§5.5.2），并让选中态退成薄色块；③ 毛玻璃真机不通过、
> 整体回退时，却把 ① 的胶囊一起留了下来。
> 结果是「白抽屉 + 一块偏重的绿渐变胶囊」，和原来的淡色块完全不是一个观感，用户一眼
> 看出没回退干净。**回退样式要回退到具体 commit 的原始参数，不能只回退容器结构。**
> 现在三处选中态统一走 `_selectedRowDecoration`，参数就是上面那四条。

**方法论教训**：这种纯视觉问题不要连续盲猜参数（这次白跑了 3 个 3 分钟构建）。做个临时「对照页」把 5 个候选并排渲染、一次装机截图对比，一轮就能定稿；定稿后把对照页和路由一起删掉。

---

### 5.5.2 整抽屉毛玻璃：试过，回退了（2026-11-21）

**结论先行**：抽屉毛玻璃技术上做得出来，但真机观感不如原来那块实心底 + 手搓胶囊，
已整体回退。**别再试了**，除非产品方向明确要求「侧栏悬浮在内容之上」。

**为什么一开始做不出来**：玻璃观感来自三件事，全部要求背后有**高频细节** —— 明暗
对比、色彩透出、边缘折射。`Drawer` 打开时 `Scaffold` 会盖一层 `drawerScrimColor`
（默认 `Colors.black54`），玻璃采到的其实是「内容 × 0.46 + 黑」，这才是 §5.5.1
那种中灰的真正来源。把抽屉底色改成纯白也没用，纯白是低频的极端，模糊和折射都无处
发生。

**当时做出来的办法**（留档，不要再照抄）：

- 10 处挂 `const Sidebar()` 的 Scaffold 全部 `drawerScrimColor: Colors.transparent`
- `Drawer(backgroundColor: Colors.transparent)` + `BackdropFilter(sigma 14)`
  + 内层半透明底（浅 `0xBFFFFFFF` / 深 `0xC41A1A1C`）+ 右缘 0.5dp 细边
- `_blurEnabled` 默认 `true`（原来 false，等于挂着个空 BackdropFilter）

**为什么回退**：

1. 抽屉从「推出一块板」变成「悬浮在内容上」，笔记列表的模糊轮廓一直铺在菜单底下，
   扫读时持续干扰视线，找菜单项比原来慢。
2. 菜单文字压在动态内容上，白底 alpha 要在浅色/深色壁纸下各调一次，怎么调都有一头
   不好看（浅了发灰、深了失去玻璃感）。
3. 选中项必须从手搓胶囊退成薄色块，否则两层玻璃打架、选中项变实心板 —— 选中感
   明显变弱，这是最直接的退步。
4. 净收益只有「有质感」，代价是可读性和选中辨识度。每天要开几十次的入口，后者更重要。

**顺带踩的坑**：给 Drawer 多套一层容器后整段代码缩进 +2，`dart format` 把原本一行
的 `BorderRadius.circular(10)` 拆成多行却**不会补尾随逗号**，直接触发
`require_trailing_commas`。深缩进改动后务必重跑 analyze，别信 format 的输出。

---

### 5.6 分页缓存不能当全量数据源

**症状**：「有图片」只显示最近滑过的那些图，早一点的笔记里的图全不见了。

**根因**：首页是 **50 条一页** 的分页缓存（`getNotesPaged`），没滑到的页不在内存。
画廊直接扫 `appProvider.notes`，等于只统计了已加载的部分。

**处理**：任何「全量视角」的页面都必须自己查库。现在的做法：

- `DatabaseService.getNotesByMedia(filter)`：SQL 先用 `content LIKE '%!['`
  和 resourceList 非空做粗筛，再用 `NoteMediaFilter.matches` 精确判定。
- **精确规则不要抄进 SQL**。视频扩展名表、alt 约定（服务端 `/o/r/<uid>` 没扩展名）、
  图片/视频互斥，这些规则都在 `MediaPaths` 里，SQL 抄一份迟早和 Dart 侧对不上。
- 筛选结果一次查全放内存，不走分页（`hasMoreData` 在筛选态直接返回 false）。
- **顶部横条不认筛选**：进入「有图片」后「那年今日」卡片还挂着（它展示的是任意旧笔记，
  可能是纯文字的），等于筛选失效。列表 index 0 处的横幅要在筛选态跳过，
  仅 `NoteMediaFilter.all` 才渲染。

### 5.7「有图片 / 有视频」是筛选参数，不是相册

参考 flomo：菜单里的「有图片」产出的仍然是**笔记列表**，能点开、能编辑、能接着操作。
做成独立相册页会让「看图」和「找笔记」割裂，而且相册页天然容易写成只扫内存列表。

- 侧边栏与标题下拉共用同一个 `NoteMediaFilter`，都指向首页 `/`，只是切换筛选。
- 侧边栏选中态要结合当前筛选判断（三项共用 `/` 路由，光比路径会同时高亮）。
- 画册仍然保留，挂在筛选态的右上角，作为「看图」的快捷方式。

### 5.8 侧边栏每一行的几何参数只能有一份

**症状**：「全部标签」的图标比上面几项往右错 8dp，圆角只有一半，行间距也大 3dp。

**原因**：`_buildAllTagsExpandableItem` 是单独实现的可展开项，自己写了一套
`margin 16 / padding 16 / radius 8 / icon 20`，而 `_buildMenuItem` 用的是
`10 / 14 / 16 / 22`。两处互不相干，改一边不会同步另一边。

**处理**：文件顶部统一 `_sidebarRowMargin` / `_sidebarRowPadding` /
`_sidebarRowRadius` / `_sidebarIconSize` / `_sidebarIconGap`，两处都从常量取。
以后加新的特殊行（可展开、带徽标、带开关）也只覆盖「额外那部分」，不要重写整行。

**测试**：`SBG-06` 直接比对两行文字左边缘的 `dx`，差超过 0.5 就失败。

> 测这类位置时**必须 `pumpAndSettle`**：菜单项外面包着 `AnimatedMenuWidget`
> 的 `SlideTransition`（`Offset(-0.3, 0)`），动画没播完时整行是负偏移，
> 会把「动画中」误判成「布局错位」。我第一次就是这么误报的。

### 5.9 文案里的「选中色」要跟着底色走

这一轮把「全部标签」的选中底从原来的淡薄荷实色 `0xFFE9F6F1` 换成和普通菜单项
同一套 `_selectedRowDecoration`，选中字色也一并统一成品牌绿本体。凡是给某行换了
底色，都要顺手检查它上面所有前景色（标题、计数徽标、展开箭头、图标）是否还够
对比度 —— 它们往往分散在几个小部件里，不会跟着一起变。

> 反过来也成立：**不要为了迁就底色去 `Color.lerp` 压深字色**。压深后字色和未选中
> 项区分不明显，选中感反而被削弱；而淡底本来就不会把品牌绿吞掉。真觉得对比不够，
> 先降底色 alpha，别动字色。

---

### 5.10 侧栏进二级页要用 push，不能一律 go

**症状**：从侧边栏进「随机回顾 / 周期回顾 / AI 洞察」，按系统返回键
不是回笔记列表，而是直接退出 App。

**根因**：侧栏导航统一走 `router.go(path)`「平级切换」。`go()` 会按目标路径
**重建整个匹配栈**，从 `/` 跳到 `/random-review` 之后栈里就只剩 `/random-review`
一层 —— 没有可 pop 的路由，系统只能把 Activity 退到后台。

**处理**（`_navigateWithSmoothTransition`，2026-11-21）：

| 场景 | 做法 | 栈 |
| --- | --- | --- |
| 目标是 `/` | `go('/')` | `[/]`，清干净 |
| 从 `/` 去二级页 | `push(path)` | `[/, 目标]` |
| 已在二级页之间横跳 | `pushReplacement(path)` | `[/, 新目标]` |

判断「从哪出发」用 `GoRouterState.of(context).matchedLocation == '/'`；抽屉还没关，
这里读到的一定是上一页。用 `pushReplacement` 而不是 `replace`：`replace` 作用在
`currentConfiguration` 上，对命令式 push 进来的页面不生效。

**测试坑（两个，都静默失败）**：

1. 别用 `router.routerDelegate.currentConfiguration.uri` 断言跳转结果。`push()` 是
   命令式导航，不走 `RouteInformationProvider`，那个 uri 会一直停在旧值 —— 明明
   `canPop()` 已经是 `true`，测出来却是「没跳转」。改成看顶层页面的 key：Navigator
   会把被盖住的 route 置 offstage，`find` 默认跳过 offstage。
2. 默认测试视口只有 **800×600**，侧栏下半截（设置）在屏幕外，`tap()` 打
   不中**不会报错**，只表现为「点了没反应」。侧栏测试统一先把
   `tester.view.physicalSize` 拉到 1080×2400。

---

## 6. Android 小组件

### 6.1 改完小组件看不到变化

**原因**：launcher 缓存了旧布局/背景图，`install -r` 同版本号也一样。

```bash
adb shell am force-stop com.miui.home
adb shell input keyevent KEYCODE_HOME
```

**必须杀桌面进程**，再按 HOME 让它重建。这一步不做，会误判成「改动没生效」而反复改代码。

### 6.2 新增小组件要三处登记

1. `android/app/src/main/AndroidManifest.xml` 里的 `<receiver>`
2. `InkPaperWidgetProvider.kt` 的 `inkPaperWidgetProviders` 登记表（13 项）
3. `updateAllInkPaperWidgets()` 的刷新路径

`test/unit/widget_provider_registry_test.dart` 会解析 manifest 和 Kotlin 登记表，**两边数量必须都是 13**。少登记一个，该小组件就永远不跟着快照刷新。

### 6.3 快照 schema 与格子墙布局

- 快照 `schemaVersion = 2`，字段改动要同步 Dart 侧 `widget_snapshot_service.dart` 和 Kotlin 解析。
- 月统计格子墙：列数 `cols ≈ sqrt(格数 × 宽高比)`，格子画正方形并整体居中；`todayIndex` 用它描边高亮。
- 月统计曾经整块空白，**不是数据缺失**，而是三处渲染缺陷叠加：快照缺 `todayIndex`、格子尺寸计算、`levelColor(0)` 取了几乎透明的颜色。排查小部件空白先核对快照字段齐不齐，再核对绘制参数，别先怀疑数据源。

### 6.4 RemoteViews 里 ListView 的两个必需属性

```xml
android:cacheColorHint="@android:color/transparent"
android:listSelector="@android:color/transparent"
```

不写会带出系统默认的深色背景块。

### 6.5 判断渲染问题先放大原始像素

截图看着「有重影」时，用 **NEAREST 放大原始像素**再看。2x LANCZOS 插值会自己造出重影，把好图看成坏图。

### 6.6 没有真模糊，底色不透明度是补偿

RemoteViews 不支持模糊，玻璃观感靠底色不透明度模拟。**78% 白**是深色壁纸下的实测平衡点，调这个值要真机 + 同一张壁纸对比。

### 6.7 回顾小组件的层级（参考 flomo）

顶部语境标签 `ageLabel`（刚刚 / N 小时前 / 今天 / 昨天 / N 天前 / 上周 / N 周前 / N 个月前 / 去年今日 / N 年前的今天）+「换一条」
→ 正文（14.5sp、行距 3dp、ListView 可滚）
→ 底部「时间 · #标签」+ 右端 InkPaper 落款。

「换一条」走广播 `ACTION_SHUFFLE_REVIEW` + prefs `review_offset` 自增，`selectReviewNote(snapshot, offset)` 在时间桶上叠加偏移取模。
**不要重排定时器、不要唤醒 App**——小组件交互必须零启动成本。

---

## 7. 微信读书同步（实验室功能）

入口：设置 → 实验室 → 微信读书笔记同步（`/settings/weread-sync`）。
网关 `POST https://i.weread.qq.com/api/agent/gateway`，Key `wrk-` 开头，只存安全存储 `weread_api_key`。

**三条铁律**

1. **业务参数平铺在 body 顶层。** 包进 `params` 会让分页永远停在第一页。
2. `bookId` 大小写不统一：`/book/bookmarklist` 用 `bookId`，`/review/list/mine` 用 **小写 `bookid`**。
3. **`skill_version` 必须跟官方最新**（当前 `1.0.6`）。落后会让整次同步直接失败；`upgrade_info` 里带 `latest_version` 和 `upgrade_url`（`https://cdn.weread.qq.com/skills/weread-skills.zip`）——只显示 `message` 用户根本不知道去哪下载。

**「读完了」的判据只认 `/book/getprogress` 的 `finishTime > 0`**

- 文档写的 `markedStatus == 1` 表示读完是**错的**，实测取值 1/2/3/4。
- 书架接口的 `finishReading` 只覆盖 35 本，不全。
- `finish` 字段表示「这本书本身完结出版」，连载中的书也是 1，不能用。

**生成粒度**

- 一条划线一条笔记：`local_wr_bm_*`；一条想法/点评一条笔记：`local_wr_rv_*`。
- 读完的书额外一条档案：`local_wr_fin_<bookId>`（封面 + 读完时间 + 阅读天数（start→finish 自然日跨度）+ 累计时长 + `#微信读书 #读完 #书名`）。

**去重与增量**

- 去重靠 `DatabaseService.getExistingNoteIds`，**查 notes 全表含软删行**——用户删掉的笔记不能复活。
- 书侧水位用 `sort` + 总笔记数双水位；读完候选 = `notebooks(maybeFinished)` ∪ `shelf(finishReading==1)`，查过但没有 `finishTime` 的按元信息版本记 `finishedMiss`。
- 首次全量实测 76 秒：153 本 → 1379 条划线 + 104 条档案，0 失败。
- 自动同步：开 App 延迟 8 秒、6 小时节流、异常静默不打扰用户。

**生成项是独立开关**：`weread_auto_sync` / `weread_sync_highlights` / `weread_sync_reviews`（想法·点评，用户口中的「笔记」）/ `weread_sync_finished` / `weread_period_review`。
关掉的不请求也不生成；`WeReadSyncOptions.isEmpty` 时 sync 抛错、autoSync 静默跳过；只开回顾时连笔记本列表都不拉。
**水位要带 `detail` 签名**（`'10'` / `'11'`）：划线/想法组合变了要清 books 水位重扫，只开完成情况时不能覆盖签名。

**周报 / 月报**

`/readdata/detail`（`mode=weekly|monthly` + `baseTime` 传周期内任一时间戳，服务端自己归一到周一/月初）。字段坑：

- `totalReadTime` 单位是**秒**，不是分钟；
- `readDays` 是「单日满 1 分钟」的有效天数；
- `readLongest` 只返回 ≥5 分钟的条目；
- `readStat` 自带单位，别再拼一次。

生成时机 = **周期结束后第一次同步**（不绑死周一），回溯上限 6 周 / 3 月，首次只生成最近一期。
时长为 0 不建笔记，但要推进水位（`state.periods`）。
id 规则：`local_wr_week_<yyyyMMdd>` / `local_wr_month_<yyyyMM>`，标签 `#周报` / `#月报`，笔记时间落在周期最后一刻。

**接入点**：`AppProvider.createImportedNotes`（批量一事务 + 一次 notify；引用重建只对含 `[[` 的笔记跑）、`WeReadSyncService.existingNoteIds`（测试覆写用）。

---

## 8. 发版、Git 与网络

> 这一节的通用版已经沉淀成用户级 skill `github-release-ops`（`gho` 命令），跨项目复用。

### 8.1 「GitHub 连不上」先探测形态

代理客户端会换，**别认死一个端口**。先看当下谁在监听（`Get-NetTCPConnection -State Listen`）和注册表里的系统代理，再按形态选参数：

| 形态 | 特征 | 命令要点 |
| --- | --- | --- |
| Clash 系 HTTP 代理 | 本地端口（如 7892）监听 | git 要 `http.proxy` + `http.userAgent=curl/8.9.1`（按 UA 放行 CONNECT） |
| Watt Toolkit / Steam++ | hosts 把 github.com 指到 127.0.0.1，无端口代理 | 直连即可，但 curl 要 `--ssl-no-revoke`（schannel 报 `CRYPT_E_NO_REVOCATION_CHECK`），git 要 `http.schannelCheckRevoke=false` |
| 沙箱注入代理 | `HTTP(S)_PROXY=127.0.0.1:1345` | 脚本里先 `unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy`（bash 没有 `unexport`） |

**反代下 Release 大文件会挂死**：HEAD 正常但 GET 0 字节 → 改走 `https://ghfast.top/https://github.com/...`（约 160KB/s）。

### 8.2 推送顺序：只试一次

① `curl -m 8 https://github.com` 探连通 → ② 通了才 `git push origin main`，**只试 1 次、60 秒上限** → ③ 失败立刻转 Git Data API。

不要连续重试三次，浪费时间且容易把状态搞乱。

### 8.3 API 兜底推送

`python Z:\Temp\push_one.py <local_commit> <remote_parent_sha>`，推完再 `fetch` + `update-ref` + `reset --hard`（**tree 一致才安全**）。

- `git/commits/{sha}` 不认短 SHA。
- API 生成的 sha 与本地不同（时间规范成 UTC），但 tree 相同 → **tag 要指向远端 sha**，本地 fetch 后校验重建。
- **不要用镜像 push**，token 会外泄到第三方。

### 8.4 断网时打 tag

`release` 会卡在 `git ls-remote`。改本地 `git tag -a` + `python Z:\Temp\push_tag.py <tag> <sha> <msg>`。

### 8.5 Gitee 镜像的硬规则

- 仓库名 **全小写 `ink-paper`**，与 GitHub 的 `InkPaper` 不同名。
- 改仓库地址要**四处同改**：`lib/config/app_config.dart`（`giteeRepo` / `giteeLatestReleaseApi`）、`README.md`、`README.en.md`、`scripts/publish_gitee.sh`，外加 `test/.../update_check_service_test.dart` 的断言。
- `/releases/latest` 匿名可读，但 `html_url` 和 `assets[].size` 是 `null`；assets 里混着源码 zip，要按 `.apk` 过滤。
- `PATCH /releases/{id}` **必须同时带 `tag_name` 和 `name`**，只带一个会失败。
- `access_token` 拼在 query 上（只对 GET 生效的写法会导致 401）。
- ⚠️ **建 Release 的瞬间 `latest` 就指向新 tag**。APK 还没传完时，App 里点「检查更新」会 404，用户体感是「更新坏了」。所以要么先传附件再置 latest，要么接受这个窗口期并尽快补传。

### 8.6 CI 不能把 APK 传到 Gitee

CI runner 到 Gitee 只有约 10KB/s。所以 `mirror-gitee` 设 `SKIP_ASSET_UPLOAD=1`，只同步代码 / tag / 说明。
APK 靠本地补传：`dart tool/inkpaper.dart release vX.Y.Z --sync-gitee`（轮询 GitHub 25–35 分钟）或 `release-gitee`。

### 8.7 令牌只放凭据管理器

Windows 凭据管理器里已有 `git:https://github.com`（`gho_` 40 位，scopes: repo / workflow / gist）和 `git:https://gitee.com`（32 位），`git credential fill` 全局可取。
**仓库和脚本里不要再放明文令牌**（原来的 `.git/gitee_token` 已删除）。`scripts/gitee_release.py` 的查找顺序是 环境变量 → 凭据管理器 → 文件，CI 侧仍走 secrets。

`gh` CLI 的 keyring 令牌已失效且缺 `read:org`，已 logout，**整条链路不依赖 gh**。

### 8.8 Git Bash 会改写参数里的路径

```bash
# 会把 /rate_limit 变成 C:/Program Files/Git/rate_limit
MSYS_NO_PATHCONV=1 curl ...
export MSYS2_ARG_CONV_EXCL='*'   # 等价于对全部参数关闭转换
```

`gho` 命令已经内建 `MSYS_NO_PATHCONV=1`。自己写脚本调 API 时记得手动加，否则报的错完全牛头不对马嘴。

### 8.9 发版说明自动生成

`scripts/release_notes.py --since <上一版>` 会合并该版本之后所有 CHANGELOG 段落（分类归拢 + 逐行去重，占位行固定放「修复」末尾）。

- **不加开场白**（用户定稿的风格）。
- 切段前先去掉版本之间的 `---` 分隔线，否则会渲染出假条目 `- ---`。
- CI 自动取 `releases/latest` 的 tag，查不到就回退成单版本。

### 8.10 排查 CI 只能看 annotation

job logs 需要 token，但 **Checks annotation 匿名可读**：`scripts/ci_annotate.sh`。
匿名 API 配额 60 次/小时；用浏览器打开 run 页面不耗配额（同 URL 15 分钟缓存，加 `?x=1` 绕开）。

---

## 9. 真机 / adb

设备：Xiaomi 14（`23127PN0CC`），HyperOS，1200×2670，density 480。

- **无线调试端口每次开机都可能变**，配对端口和主端口也不同。端口未知时用 Windows TcpClient 扫 30000–65535。
- 连不上先看 ARP：**能列出设备但 ping 不通是正常的**（HyperOS 息屏会丢 ICMP），别据此判定「不在同一局域网」。
- 必须先 `adb pair <ip>:<配对端口> <配对码>`，再 `adb connect <ip>:<主端口>`。
- **Git Bash 里 adb server 会随命令退出**：`connect` 和后续操作必须写在同一条命令里。
- `input keyevent 4` 在键盘没弹时**会直接退出当前页**，别用它收键盘；点 TextField 要点到输入框正中才聚焦，用 `dumpsys input_method | grep mInputShown` 确认。
- 抓图：`adb pull` 的本地路径要写 **Windows 路径**（`Z:/Temp/x.png`），`MSYS2_ARG_CONV_EXCL=*` 下 `/z/Temp/...` 传不过去。截图超过 ~2MB 先缩到 600px 宽。
- 截图写 `/sdcard/` 会进系统相册，验完 `rm` 掉。
- 默认输入法是微信输入法的插件服务时，`input text` 完全不生效 → 临时切搜狗 `com.sohu.inputmethod.sogou.xiaomi/.SogouIME`，验完切回。
- 该机 release 包读不到 logcat 内容，排查靠 `dumpsys` + 截图；要读数据库 / 偏好设置得先装 debug 包（release 不可 `run-as`）。

---

## 10. 工作方式约定

- **攒批部署**：平时只本地 `git commit`，不装真机、不升版本；确认「推送到真机」时才统一升版本（`x.y.z+N` 的 patch 与 N 同步加）+ 补 CHANGELOG + 一次装机。
- **提交与推送分离**：解决一个问题就本地提交，攒到发版再推。
- 一个连贯改动一个 commit，Conventional Commits + 中文；只 `git add` 本次涉及的文件；不用 `--amend` / `--force`。
- **文档与代码不一致时，先指出来再改代码**。
- 没有真机验证就明说「未真机验证」，不要假装验证过。
- 构建 / 测试 / 发版只走 `dart tool/inkpaper.dart`，不要手写零散的 `flutter build` / `flutter test`（参数和顺序是踩过坑定下来的）。
