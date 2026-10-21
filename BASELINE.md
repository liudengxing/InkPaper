# InkPaper 基线测量（Stage 1 · 只读）

> 生成时间：2026-10-21
> 原则：只记录实测值；无法测量的项标 **未测量** 并写明原因，不做估算。

## 1. 环境

| 项 | 值 |
| --- | --- |
| OS | Windows（开发机） |
| Flutter | 3.47.7（stable） |
| Dart | 3.13.5 |
| 设备 | Android 真机 `192.168.0.108:39911`（无线调试，1024 宽） |
| 分支 / 版本 | `main` @ `245b9c5`；`pubspec.yaml:6` = `1.0.15+10015` |
| 签名 | `android/key.properties` 不存在 |

## 2. 静态检查

命令：`flutter analyze --no-pub`

| 级别 | 数量 |
| --- | --- |
| error | **0** |
| warning | **0** |
| info | **0** |

输出无 `error - / warning - / info -` 行（2026-10-21 清掉最后 4 条 `unawaited_return_in_try_block`，见 commit `cd9d880`）。

## 3. 测试

命令：`flutter test`

| 项 | 值 |
| --- | --- |
| 用例数 | **399** |
| 结果 | 全部通过（`All tests passed!`） |
| 耗时 | 02:28 |
| 测试文件 | 41 个 / 6,568 行 |

## 4. 覆盖率

命令：`flutter test --coverage` → 解析 `coverage/lcov.info`

| 项 | 值 |
| --- | --- |
| 行覆盖 | **14.1%**（LH 3,145 / LF 22,258） |
| 计入文件 | 103 个 |
| 口径 | 仅统计测试执行期间被加载的 Dart 文件；未覆盖文件不计入分母 |

## 5. 包体积

| 项 | 值 | 说明 |
| --- | --- | --- |
| Release APK/AAB | **未测量** | `flutter build apk --analyze-size` 因缺少 `android/key.properties` 失败（release 签名配置为空），无法产出可测量产物 |
| Debug APK | 176.0 MB | `build/app/outputs/flutter-apk/app-debug.apk`，含 JIT 与全部 ABI，**不代表发布体积** |
| `--split-per-abi` 产出 | **未测量** | 同上，依赖 release 构建 |

## 6. 运行时性能

| 项 | 值 | 原因 |
| --- | --- | --- |
| 冷启动耗时 | **未测量** | 需要 profile 构建 + `flutter run --profile` + DevTools 时间线，本轮仅只读分析 |
| 首帧 / 启动到可交互 | **未测量** | 同上 |
| 滚动帧率（jank 比例） | **未测量** | 需要 profile 模式跑滚动场景并采集 `FrameTiming` |
| 内存峰值 / 图片缓存占用 | **未测量** | 需要 DevTools Memory 或 `dumpsys meminfo` 采样 |
| 同步耗时（N 条笔记） | **未测量** | 需要已登录服务器与不同笔记量样本 |

## 7. 资源体积

| 项 | 值 |
| --- | --- |
| `assets/` 合计 | 3.96 MB |
| `assets/fonts/` | 3.94 MB（5 个字体：SF Pro Display Light/Regular/Medium/Bold + SF Mono） |
| `assets/images/` | 约 0.02 MB（最大 `black2logo.png` 0.01 MB） |
| 字体是否打包 | **否**（`pubspec.yaml:178-179` 仅声明 `assets/images/`，无 `fonts:` 段），但文件仍占用仓库体积 |

## 8. 代码规模

| 项 | 值 |
| --- | --- |
| `lib/` | 147 文件 / **97,053** 行 |
| `test/` | 41 文件 / 6,568 行 |
| >1000 行文件 | **31** 个 |
| 最大文件 | `providers/app_provider.dart` 4,434 行 |
| 次大 | `widgets/note_editor.dart` 3,284；`l10n/app_localizations_simple.dart` 3,124；`l10n/translations.dart` 3,049；`screens/home_screen.dart` 2,801；`screens/preferences_screen.dart` 2,759；`utils/share_utils.dart` 2,434；`screens/ai_settings_screen.dart` 2,272 |

## 9. 静态代码指标（`lib/` 全量 grep 计数，非人工清单）

| 指标 | 次数 | 备注 |
| --- | --- | --- |
| `Widget _build*` 方法定义 | 280 | 拆方法本身不减少重建，仅影响可读性 |
| `setState(` | 349 | 分布于 StatefulWidget；`note_editor.dart` 39 次 |
| `notifyListeners(` | 63 | 全部在 `app_provider.dart` |
| `Selector<` | 4 | `main.dart:539`、`app_provider.dart:238`、`home_screen.dart:799`、`:1217` |
| `Consumer<` | 5 | — |
| `context.watch` | 2 | — |
| `context.select` | 4 | — |
| `ListView(` | 18 | 非 builder 形式 |
| `ListView.builder` | 15 | 含 `.separated` 变体未计入 |
| `SingleChildScrollView` | 51 | 含表单页、设置页 |
| `shrinkWrap: true` | 9 | — |
| `Opacity(` | 12 | — |
| `ClipRRect(` | 21 | — |
| `RepaintBoundary` | 13 | — |
| `Image.asset` | 6 | 其中 3 处带 `cacheWidth`（`utils/image_utils.dart`） |
| `cacheWidth` | 3 | — |
| `jsonDecode` | 32 | 含 API 响应解析、备份恢复 |
| `http.Client` | 7 | `utils/network_utils.dart` 每次调用新建实例 |
| `.timeout(` | 21 | 超时策略分散 |
| `Timer(` | 6 | — |
| 硬编码中文字面量（排除注释/日志/已带 l10n 的 fallback） | 约 1,500 处 | 见 `docs/ROADMAP.md` P3-4；该数字为静态匹配计数，供排序用 |

## 10. 依赖健康度

声明但无直接 import 的依赖 **8 个**（`cupertino_icons`、`flutter_image_compress`、`xml`、`flutter_svg`、`flutter_highlight`、`graphview`、`flutter_dotenv`、`characters`），声明行见 `ARCHITECTURE.md` 第 10 节。

## 11. 门禁现状

| 门禁 | 状态 |
| --- | --- |
| `flutter analyze` 进 CI | 有（`.github/workflows/ci.yml`） |
| `flutter test` 进 CI | 有（同上） |
| `dart format` 校验 | 无（workflow 中未见 `dart format` / `set-exit-if-changed`） |
| release 混淆 `--obfuscate` | 无（`tool/inkpaper.dart` 仅 `--split-debug-info`，见 `:265-266`） |
| 本地 release 构建 | 不可用（缺 `android/key.properties`） |

## 12. 未测量清单（汇总）

1. Release 包体积与体积构成（`--analyze-size`），原因：缺签名配置。
2. 冷启动 / 首帧 / TTID，原因：需 profile 运行与时间线采集。
3. 滚动 jank 率、掉帧分布，原因：需 profile + 真机采集。
4. 内存峰值、图片内存占用，原因：需 DevTools Memory。
5. 同步吞吐（N 条笔记的耗时），原因：需服务器与样本数据。
6. 崩溃率 / ANR（线上），原因：需 Sentry 后台数据，仓库内无导出。
7. 通知、语音、录音、相册等系统能力的真机行为，原因：本 Stage 为只读静态分析，未做交互测试。
