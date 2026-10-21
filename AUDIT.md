# InkPaper 审计报告（Stage 2 · 只读）

> 生成时间：2026-10-21（基于 `main` @ `245b9c5`，版本 `1.0.15+10015`）
> 方法：静态检查（文件统计、grep、逐处读码）+ `flutter analyze` + `flutter test --coverage`
> 证据规则：每条 finding 必须给 `file:line` 与不超过 3 行代码；无证据的猜想统一放文末「待确认」。
> 运行时指标（启动、帧率、内存、release 体积）未测量，见 `BASELINE.md` 第 12 节。

## 摘要

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| P0（阻断/崩溃） | **0** | 静态审计未见 P0；`flutter analyze` 0 error，399 项测试全绿 |
| P1（显著影响性能/体验） | **4** | 单一巨型 Provider、编辑器 setState 风暴、串行同步、巨型页面拆方法 |
| P2（结构性/工程问题） | **7** | 分层倒置、连接不复用、主线程解码大 JSON、未使用依赖、字体资产、无混淆、嵌套列表 |
| P3（可维护性/一致性） | **4** | 死代码、无 format 门禁、渲染裁剪缺失、本地化遗留 |

---

## P0 · 阻断级

无。证据：`flutter analyze --no-pub` 无 error/warning/info；`flutter test` 399 项全部通过。

---

## P1 · 显著影响

### A-01 `AppProvider` 单文件 4,434 行，承载全部域状态，通知面过宽（置信度：高）

`lib/providers/app_provider.dart`（4,434 行）内 `notifyListeners()` 出现 **58** 次（全库 63 次）；根节点以 `.value` 注入整个实例，仅 4 处 `Selector` 收窄订阅。

```dart
lib/main.dart:537
Widget build(BuildContext context) => ChangeNotifierProvider.value(
  value: widget.appProvider,
  child: Selector<AppProvider, _AppChrome>(
```

**影响**：任意一次 `notifyListeners()` 都会让订阅整实例的 Widget 重新走 `build`，只有 `main.dart:539`、`app_provider.dart:238`、`home_screen.dart:799`、`:1217` 四处做了字段级筛选。笔记量增大时，重建面随之变大。

**验证方法**：DevTools Performance → rebuild stats，在同步/编辑/切换标签时观察 `AppConsumer` 类重建次数（未测量）。

**修复方向**：按域拆分（`NoteStore` / `SyncStore` / `AuthStore` / `PrefsStore`），先拆同步域（ROADMAP P1-5）。**成本：高**，建议分批。

### A-02 编辑器 3,284 行、39 处 `setState`，输入路径整树重建（置信度：高）

```dart
lib/widgets/note_editor.dart:143
      setState(() {
lib/widgets/note_editor.dart:465
      setState(() {
lib/widgets/note_editor.dart:562
      setState(() {
```

**影响**：编辑正文时高频 `setState` 触发整个编辑器子树重建（含 Markdown 预览、工具栏）。长文档输入是最容易感知掉帧的路径。

**验证方法**：profile 模式打开 5,000 字笔记连续输入，抓 `FrameTiming`（未测量）。

**修复方向**：把输入区改为 `TextEditingController` + 局部 `ValueListenableBuilder`，仅让依赖该字段的小组件重建；预览做防抖。**成本：中高**。

### A-03 同步循环串行 `await`，每条笔记一次请求（置信度：高）

```dart
lib/providers/app_provider.dart:2048
      for (final note in unsyncedNotes) {
lib/providers/app_provider.dart:2050
          syncedCount += await _syncUnsyncedNotesSnapshot([note]);
```

**影响**：同步耗时 ≈ 笔记数 × 单请求 RTT；弱网或首次全量同步时明显。代码已用 try/catch 逐条容错，行为正确，仅并发度不足。

**验证方法**：构造 50 / 200 条离线笔记，记录同步总时长（未测量，需可用服务器）。

**修复方向**：改为有限并发（信号量 2–3）或服务端批量接口；保留失败隔离与 `pending_operations` 顺序语义。**成本：中**。

### A-04 巨型页面用 `_buildXxx` 拆分，方法拆分不减少重建（置信度：高）

`home_screen.dart` 2,801 行，`_build*` 定义与调用共出现 52 次；`lib/` 内 `Widget _build*` 定义 **280** 处。

```dart
lib/screens/home_screen.dart:809
  Widget _buildNotificationBannerBody(BuildContext context, int unreadCount) {
lib/screens/home_screen.dart:1461
  Widget _buildBottomComposerBar(BuildContext context) {
```

**影响**：同文件内 `_buildXxx()` 在同一 `build` 中执行，无法被框架跳过；文件体量与 31 个 >1000 行文件共同抬高维护成本。

**验证方法**：对比把 `_buildNotificationBannerBody` 抽成 `StatelessWidget` 后 DevTools rebuild 次数（未测量）。

**修复方向**：优先抽「列表项、输入条、通知条」三类为独立 `StatelessWidget`，配合 `const` 构造。**成本：中**。

---

## P2 · 结构性 / 工程问题

### A-05 服务层反向依赖 UI（7 条 import，置信度：高）

```dart
lib/services/note_actions_service.dart:10
import 'package:inkpaper/screens/note_detail_screen.dart';
lib/services/note_actions_service.dart:16
import 'package:inkpaper/widgets/note_editor.dart';
```

同文件 `:14`、`:15`、`:17`、`:18`、`:19` 还 import 了 `annotations_sidebar`、`ios_datetime_picker`、`permission_guide_dialog`、`references_sidebar`、`share_image_preview_screen`。**影响**：服务层无法脱离 `BuildContext` 单测，UI 重构会波及服务；`screens → services → screens` 形成概念上的环。**修复方向**：服务返回「意图」（枚举/结果对象），由调用方展示弹窗与跳转。**成本：中**。

### A-06 每次请求新建 `http.Client`，无复用、无 `close`（置信度：高）

```dart
lib/utils/network_utils.dart:10
  static http.Client createOptimizedClient() {
    final client = http.Client();
    return client;
```

`createDirectClient()`（同文件 `:16-19`）同样新建。**影响**：连接/TLS 无法复用，弱网下每次请求多一次握手；长期运行存在未关闭 client 的隐患。**验证**：抓包统计握手次数（未测量）。**修复方向**：进程内单例 client + 请求级 `.timeout()`（仓库已有 21 处 `.timeout(`，可统一到 client 封装）。**成本：低**。

### A-07 备份恢复在主线程一次性 `jsonDecode` 整个文件（置信度：高）

```dart
lib/services/database_service.dart:798
      final Map<String, dynamic> data = jsonDecode(jsonData);
      if (!data.containsKey('notes') || data['notes'] is! List) {
```

**影响**：备份包含数万条笔记时，解码与后续 `for` 插入都在 UI isolate 上执行，可能触发掉帧甚至 ANR。**验证**：用 1 万 / 5 万条 JSON 导入并记录耗时（未测量）。**修复方向**：`compute()` 或 isolate 解码，插入包在单个事务内并分批。**成本：中**。

### A-08 声明但无 import 的依赖 7 个（置信度：高）

```yaml
pubspec.yaml:41
  xml: ^6.5.0
pubspec.yaml:80
  flutter_svg: ^2.0.10
pubspec.yaml:89
  flutter_highlight: ^0.7.0
```

其余：`cupertino_icons`（`:19`）、`flutter_image_compress`（`:32`）、`graphview`（`:112`）、`flutter_dotenv`（`:121`）。**影响**：依赖树与构建时间膨胀（`flutter_svg`/`flutter_highlight` 均带子依赖）。**注意**：`xml` 可能被 `webdav_client` 的上游需要，删除前需 `flutter pub deps` 复核。**成本：低**。

### A-09 3.94 MB SF Pro 字体未声明、未使用，仍留在仓库（置信度：高）

```yaml
pubspec.yaml:178
  assets:
    - assets/images/
```

`assets/fonts/` 下 5 个文件占 3.94 MB（`SF-Pro-Display-Light/Regular/Medium/Bold.ttf`、`SF-Mono-Regular.ttf`）；`pubspec.yaml` 无 `fonts:` 段，`lib/` 内无 `assets/fonts/` 引用。**影响**：不进包，但仓库体积与合规风险（Apple 字体许可）；`preferences_screen` 的字体名若指向它们会静默回退。**修复方向**：确认许可后删除或移出仓库，并在字体选项中只保留系统字体与 Google Fonts。**成本：低**。

### A-10 release 未启用 `--obfuscate`，本机无法验证 release 产物（置信度：高）

```dart
tool/inkpaper.dart:265
        '--split-per-abi',
tool/inkpaper.dart:266
        '--split-debug-info=build/symbols',
```

`android/key.properties` 不存在 → `flutter build apk --analyze-size` 直接失败（`BASELINE.md` 第 5 节）。**影响**：符号表随包暴露、体积偏大；无法在本机建立 release 基线。**修复方向**：构建脚本加 `--obfuscate`；补签名文件或用 CI secrets。**成本：低**。

### A-11 嵌套滚动列表用 `shrinkWrap: true` + `NeverScrollableScrollPhysics`（置信度：高）

```dart
lib/screens/flomo_import_screen.dart:704
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
lib/screens/local_backup_restore_screen.dart:685
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
```

同类共 **9** 处（`flomo_import_screen.dart:705/1806/2007` 等）。**影响**：`shrinkWrap` 会一次性布局全部子项，导入历史/预览条目多时首帧变慢、内存上升。**修复方向**：改为外层 `CustomScrollView` + `SliverList`，或限制预览条数。**成本：中**。

---

## P3 · 可维护性 / 一致性

### A-12 未使用的私有方法（死代码，置信度：高）

```dart
lib/screens/home_screen.dart:1863
    for (final note in widget.notes) {
      tags.addAll(note.tags);
lib/screens/home_screen.dart:1866
    return tags.toList()..sort();
```

`_collectTags` 在仓库内调用次数 **0**（`Select-String` 计数），属残留代码。**修复方向**：删除；若后续标签聚合需要，迁到 provider 并缓存。**成本：低**。

### A-13 无 `dart format` 校验门禁（置信度：高）

`.github/workflows/ci.yml`、`release.yml` 中未见 `dart format` 或 `set-exit-if-changed`；`ARCHITECTURE.md` 第 8 节记录同一事实。**影响**：格式随提交漂移，review 噪音增加。**修复方向**：CI 加 `dart format --output=none --set-exit-if-changed lib test tool`，先一次性格式化全量。**成本：低**。

### A-14 图片解码未统一按目标尺寸（置信度：中）

`Image.asset` 共 6 处，仅 3 处经 `utils/image_utils.dart` 传 `cacheWidth`；`login_screen.dart:886`、`register_screen.dart:773`、`about_screen.dart:102` 直接使用资源路径。

```dart
lib/screens/login_screen.dart:886
    Theme.of(context).brightness == Brightness.dark
    ? 'assets/images/black2logo.png'
```

当前图片均为 0.01 MB 级 logo，影响有限；**风险**在未来替换为高清图时。**成本：低**。

### A-15 本地化仍有约 1,500 处中文未接入（置信度：中）

统计口径：含中文字符串字面量、排除注释 / `debugPrint` / 已带 l10n 的 fallback。集中文件：`webdav_settings_screen.dart`(125)、`providers/app_provider.dart`(117)、`ai_insight_engine.dart`(98)、`ai_settings_screen.dart`(88)、`user_agreement_screen.dart`(63)。该数字为静态匹配计数，需人工区分「用户可见文案 / 内部消息」。**详见 `docs/ROADMAP.md` P3-4**。**成本：高**（分批）。

---

## 待确认（证据不足，不下结论）

| # | 事项 | 当前掌握 | 需要什么 |
| --- | --- | --- | --- |
| Q1 | release 包体积与构成 | **未测量**：缺 `android/key.properties` | 签名或 CI secrets 后跑 `flutter build apk --analyze-size` |
| Q2 | 冷启动 / 首帧 / TTID | 只知 `runApp`（`main.dart:376`）之前有 5 处 `await`：`main.dart:44`、`:48`、`:129`、`:153`、`:160` | profile 模式 + DevTools 时间线 |
| Q3 | 滚动 jank、掉帧率 | `BASELINE.md` 记录了静态指标（280 个 `_build`、`ListView(` 18 处） | profile + `FrameTiming` 采集 |
| Q4 | 内存峰值 / 图片缓存占用 | `ImageCacheManager.initialize()` 存在（`main.dart:84-150` 区间），具体上限未读 | DevTools Memory 或 `dumpsys meminfo` 采样 |
| Q5 | A-03 同步串行在真实网络下的影响幅度 | 已确认串行结构 | 服务器 + 50/200 条样本 |
| Q6 | `xml` 是否为 `webdav_client` 必需 | 仓库内无 `package:xml/` import | `flutter pub deps --style=compact` 输出 |
| Q7 | `assets/fonts` 是否曾被打包进历史版本 | 当前 `pubspec` 未声明 | 解包历史 release APK 核对（需产物） |
| Q8 | 通知 / 语音 / 录音 / 相册的真机行为 | 本轮未做交互测试 | 真机功能回归（已有手测记录见 ROADMAP 第六节） |
| Q9 | 覆盖率 14.1% 具体缺口位置 | 只有总量（LH 3,145 / LF 22,258） | 按文件拆分 lcov（下一轮可做） |

---

## 与既有路线的对应关系

- 本报告 A-01 ↔ `docs/ROADMAP.md` **P1-5**（拆 AppProvider）
- A-05 ↔ **P2-3**（巨型 UI/服务文件拆分）
- A-08 / A-09 / A-10 ↔ **P2-5**（死配置/资源清理）、**P2-6**（门禁与发布）
- A-15 ↔ **P3-4**（本地化收尾）
- 新提出（ROADMAP 尚未收录）：**A-02** 编辑器 setState、**A-03** 同步串行、**A-06** client 复用、**A-07** 备份解码、**A-11** 嵌套列表、**A-12** 死代码、**A-13** format 门禁

## 建议的 Stage 3 候选（等待确认，未执行任何修改）

1. **A-06 + A-08 + A-09 + A-12 + A-13**（低风险、可一次验证）：client 复用、删未用依赖、清字体资产、删死代码、加 format 门禁。
2. **A-01 第一阶段**：仅拆同步域（`SyncStore`），保持 `AppProvider` 对外接口不变。
3. **A-02**：编辑器输入路径局部化，单文件内改造，风险集中在长文输入。
