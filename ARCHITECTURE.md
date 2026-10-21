# InkPaper 架构说明（Stage 0 · 只读）

> 生成时间：2026-10-21
> 数据来源：仓库静态检查（`flutter --version`、文件统计、grep、`pubspec.yaml`）
> 口径说明：只记录事实，不做好坏评价；所有运行时数字见 `BASELINE.md`。

## 1. 技术栈

| 项 | 值 | 来源 |
| --- | --- | --- |
| UI 框架 | Flutter 3.47.7 / Dart 3.13.5 | `flutter --version` |
| SDK 约束 | `>=3.0.0 <4.0.0` | `pubspec.yaml:9` |
| 当前版本 | `1.0.15+10015` | `pubspec.yaml:6` |
| 状态管理 | `provider: ^6.1.2`（ChangeNotifier） | `pubspec.yaml:22` |
| 路由 | `go_router: ^10.2.0` | `pubspec.yaml:59` |
| 本地数据库 | `sqflite: ^2.3.3+1`（`notes.db`，schema 11） | `pubspec.yaml:25` |
| 网络 | `http: ^1.2.2`、`webdav_client: ^1.2.2` | `pubspec.yaml:37`、`:40` |
| 本地化 | 自研 `AppLocalizationsSimple` + `translations.dart`（zh / en） | `lib/l10n/` |
| 崩溃上报 | `sentry_flutter: ^8.9.0` | `pubspec.yaml:118` |
| 应用 ID | `com.didichou.inkpaper`，深链 `inkpaper://` | `android/app/build.gradle` |
| 目标平台 | Android（`android/`）、iOS（`ios/` 目录存在） | 目录 |

关键依赖（与本次审计相关）：`flutter_markdown ^0.6.23`、`flutter_local_notifications ^17.2.3`、`timezone ^0.9.4`、`speech_to_text ^7.0.0`、`record ^6.1.2`、`image_picker ^1.1.2`、`flutter_secure_storage ^8.1.0`、`share_plus ^7.2.2`、`file_picker ^8.1.2`、`crypto ^3.0.3`、`uuid ^4.5.1`、`url_launcher ^6.3.0`、`shared_preferences ^2.2.3`。

## 2. 目录结构与规模

`lib/` 共 **147** 个 Dart 文件 / **97,053** 行（按物理行统计，`[System.IO.File]::ReadAllLines`）。

| 目录 | 文件数 | 行数 | 职责 |
| --- | --- | --- | --- |
| `lib/screens/` | 35 | 38,365 | 页面级 Widget（全部 Stateful 或含状态壳） |
| `lib/services/` | 43 | 17,233 | 数据/网络/系统能力（DB、Memos API、WebDAV、AI、通知、导入导出） |
| `lib/widgets/` | 21 | 15,747 | 可复用组件（`note_card`、`note_editor`、侧栏等） |
| `lib/l10n/` | 5 | 8,107 | `translations.dart`（键表）+ `app_localizations_simple.dart`（访问器） |
| `lib/utils/` | 21 | 7,002 | 工具（时间、图片、分享、网络、格式） |
| `lib/providers/` | 2 | 4,823 | `app_provider.dart` 4434 行；另一文件 389 行 |
| `lib/models/` | 12 | 2,346 | 数据模型（`Note`、`AppConfig` 等） |
| `lib/themes/` | 3 | 1,071 | 主题与排版 |
| `lib/routes/` | 1 | 971 | `app_router.dart`（go_router 全量路由） |
| `lib/config/` | 3 | 624 | 版本、功能开关、统计配置 |
| `lib/main.dart` | 1 | 764 | 启动链路 + 根 Widget + `_AppChrome` |

测试：`test/` 41 个文件 / 6,568 行。

## 3. 分层与依赖方向

```
main.dart → routes/app_router.dart → screens/* → providers/app_provider.dart
                                              → services/* → models/*
                                              → widgets/* → themes/*, utils/*
```

实测依赖方向（import 统计）：

- `screens/` → `services/`：19 个文件（页面直接调用服务，属既定设计）。
- `widgets/` → `services/`：7 个文件。
- **反向依赖**：`services/` → `screens|widgets/` 共 **7 条 import**，全部集中在同一个文件：
  `lib/services/note_actions_service.dart:10`（`screens/note_detail_screen.dart`）、`:14`（`widgets/annotations_sidebar.dart`）、`:15`（`widgets/ios_datetime_picker.dart`）、`:16`（`widgets/note_editor.dart`）、`:17`（`widgets/permission_guide_dialog.dart`）、`:18`（`widgets/references_sidebar.dart`）、`:19`（`widgets/share_image_preview_screen.dart`）。

即服务层承担了「弹窗/导航编排」职责，这是当前唯一的跨层倒置点（详见 `AUDIT.md` A-05）。

## 4. 启动链路

`lib/main.dart`（764 行）：

1. `main()` → `await AppInfoService.init()`（`main.dart:44`）、`await SentryFlutter.init(...)`（`main.dart:48`）。
2. `await _runApp()`（调用点 `main.dart:64`、`:69`；定义 `main.dart:74`）内部依次 `await FeatureFlagService().init()`（`:129`）、`await initializeDateFormatting('zh_CN')`（`:153`）、`await ImageCacheManager.initialize()`（`:160`）。
3. 处理深链 / 系统分享 payload（`main.dart:160` 之后至 `:376` 之前）。
4. `runApp(...)`（`main.dart:376`）。
5. 根 Widget：`ChangeNotifierProvider.value`（整个 `AppProvider` 单实例）→ `Selector<AppProvider, _AppChrome>` 只订阅主题/字体/语言（`main.dart:537-548`）。
6. 首帧回调移除原生启动图（`main.dart:531-533`）。

要点：`runApp` 之前至少有 5 处 `await`（`main.dart:44`、`:48`、`:129`、`:153`、`:160`），另有深链/分享处理段内的等待；其中功能开关、日期格式、图片缓存均属可延迟项。数据库是否在 `runApp` 前打开，取决于 `AppProvider` 构造（`_runApp` 内未直接看到 `openDatabase`）。

## 5. 状态管理现状

| 指标 | 数值 |
| --- | --- |
| `notifyListeners()` 调用 | 63（`lib/providers/app_provider.dart` 内） |
| `Selector<` 使用 | 4（`main.dart:539`、`app_provider.dart:238`、`home_screen.dart:799`、`home_screen.dart:1217`） |
| `Consumer<` | 5 |
| `context.watch` | 2 |
| `context.select` | 4 |
| `setState(` | 349（全 `lib/`） |

`AppProvider` 作为单一 ChangeNotifier 提供：笔记集合、同步状态、认证、配置、AI、提醒等；`main.dart:537` 以 `.value` 注入，`Selector` 仅隔离主题相关字段。

## 6. 数据层

`lib/services/database_service.dart`（1,098 行），schema **11**：

- 表：`notes`（`database_service.dart:84`）、`reminder_notifications`（`:107`）、`pending_operations`（`:143`）。
- 索引：`idx_notes_created_at`（`:129`）、`idx_notes_is_synced`（`:132`）、`idx_reminder_triggered_at`、`idx_reminder_note_id`。
- 视图：`active_notes`（软删除过滤，见 ROADMAP `perf(db)` 记录）。
- 迁移：`_onUpgrade` 逐版本追加（schema 11 为当前基线）。

备份/恢复：`importBackup` 在 `database_service.dart:798` 用 `jsonDecode` 一次性解析整包 JSON。

## 7. 路由与页面

`lib/routes/app_router.dart`（971 行），go_router，共 **35** 个页面文件，路由路径 40 条（含嵌套子路由）。主要路径：

`/privacy-policy`、`/privacy-policy-detail`、`/user-agreement`、`/legal-documents`、`/account-deletion`、`/onboarding`、`/welcome`、`/`（首页）、`account-info`、`server-info`、`data-cleanup`、`recently-deleted`、`preferences`、`sidebar-customization`、`ai-settings`、`user-preferences`、`webdav-settings`、`login`、`register`、`forgot-password`、`notifications`、`note/:id`、`edit`、`/random-review`、`/tags`、`/knowledge-graph`、`/help`、`/settings`、`import-export`、`local-backup-restore`、`flomo-import`、`weread-import`、`notion-settings`、`/feedback`、`/laboratory`。

页面规模 Top（行数）：

| 文件 | 行数 |
| --- | --- |
| `screens/preferences_screen.dart` | 2,759 |
| `screens/home_screen.dart` | 2,801 |
| `screens/ai_settings_screen.dart` | 2,272 |
| `screens/local_backup_restore_screen.dart` | 1,989 |
| `screens/flomo_import_screen.dart` | 1,982 |
| `screens/register_screen.dart` | 1,904 |
| `screens/login_screen.dart` | 1,829 |
| `screens/note_detail_screen.dart` | 1,465 |
| `screens/webdav_settings_screen.dart` | 1,455 |
| `screens/account_info_screen.dart` | 1,344 |

全局 >1000 行的文件：**31** 个。

## 8. 构建与发布

- `android/app/build.gradle`：`applicationId com.didichou.inkpaper`、`minifyEnabled true` + `shrinkResources true` + proguard（release）。
- Release 签名依赖 `android/key.properties`：**当前仓库内不存在该文件**（`Test-Path` 为 false），因此本机无法产出 release APK/AAB。
- `tool/inkpaper.dart` 构建脚本：`--split-per-abi`（`:265`）、`--split-debug-info=build/symbols`（`:266`、`:276`）；**未见 `--obfuscate`**。
- CI：`.github/workflows/ci.yml`、`release.yml`（含 `flutter analyze`、`flutter test` 步骤；未见 `dart format` 校验）。

## 9. 资源

- `assets/` 总计 **3.96 MB**，其中 `assets/fonts/` 5 个文件占 **3.94 MB**（SF Pro Display 4 个字重 0.81–0.91 MB + SF Mono 0.44 MB）。
- `pubspec.yaml:178-179` 仅声明 `assets/images/`；**没有 `fonts:` 段**，`assets/fonts/` 未被声明。
- `assets/images/` 最大的文件为 `black2logo.png`（0.01 MB）。

## 10. 依赖健康度

`pubspec.yaml` 中声明、但 `lib/`+`test/`+`tool/` 内无 `package:<name>/` import 的依赖（8 个）：

| 依赖 | 声明行 |
| --- | --- |
| `cupertino_icons` | `pubspec.yaml:19` |
| `flutter_image_compress` | `pubspec.yaml:32` |
| `xml` | `pubspec.yaml:41` |
| `flutter_svg` | `pubspec.yaml:80` |
| `flutter_highlight` | `pubspec.yaml:89` |
| `graphview` | `pubspec.yaml:112` |
| `flutter_dotenv` | `pubspec.yaml:121` |

（`characters` 来自 Flutter SDK 传递依赖，未计入。）

## 11. 本地化实现

- `lib/l10n/translations.dart`（3,049 行）：`Map<String, Map<String, String>>`，键 → `{zh, en}`。
- `lib/l10n/app_localizations_simple.dart`（3,124 行）：`_t(key, fallback:)` 访问器，`of(context)` 返回可空实例。
- 调用模式：`l10n?.xxx ?? '中文兜底'`，缺键时回退中文。
- 语言切换入口：`preferences_screen.dart` → 语言 → 写 `appConfig.locale` 并重建 MaterialApp。
- 覆盖率：`login_screen`、`recently_deleted_screen`、`data_cleanup_screen`、`note_actions_service`（部分）已接入；仍有多页面硬编码中文（数量见 `AUDIT.md` 与 `docs/ROADMAP.md` P3-4）。
