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

本机同时跑着 `SRBMiner-MULTI`（`F:/WaKuang`），占约 10G 内存，物理内存被挤到 36.8G/39.8G。
Gradle 的 native 层拿不到连续内存就直接 abort，日志会落在 `android/hs_err_pid*.log`。

**处理**

```bash
# 提权执行，暂停 / 恢复矿机
F:/WaKuang/bin/pause-miner.bat
F:/WaKuang/bin/resume-miner.bat
```

构建前扫一眼提交内存；CI 上不需要这一步。**别把 OOM 当成代码问题去查依赖。**

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

---

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

伪 UTC 的绝对时刻整体晚 8 小时，排序和 range 过滤是按绝对时刻比较的。
→ 目前只在 **8 小时窗口内跨源混排**时可能错位。彻底修要动 `_parseTimestamp`，会牵动 WebDAV 冲突判断，风险大于收益，暂不动。改这块前先想清楚影响面。

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

**结论**：纯色/近纯色背板上的选中态，**不要花时间调参**，直接手搓同样的光学层次，确定性最好：

- 品牌色纵向渐变（浅色 0.30 → 0.16）
- 顶部 22dp 的白色高光带（0.55 → 0），这是「玻璃感」的主要来源
- 品牌色描边 0.22 + 外阴影（品牌色 0.18，blur 12，y 4）
- 文字用 `Color.lerp(accent, Colors.black, 0.42)` 压深，否则绿字压绿底会糊

真渲染器留给「背后确实有内容」的地方（底部输入条、SnackBar）。

**方法论教训**：这种纯视觉问题不要连续盲猜参数（这次白跑了 3 个 3 分钟构建）。做个临时「对照页」把 5 个候选并排渲染、一次装机截图对比，一轮就能定稿；定稿后把对照页和路由一起删掉。

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
