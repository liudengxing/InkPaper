# 构建与真机测试指南

本文覆盖小纸（InkPaper）的 Android 本地构建方式、发布流程，以及真机测试时需要特别留意的行为与坑点。仓库只维护 Android 平台，没有其他平台的工程与构建目标。日常开发只跑 `dart tool/inkpaper.dart` 里的命令即可，不要手写零散的 `flutter build`，以免漏掉签名与 Gradle 前置步骤。

## 1. 环境准备

| 目标平台 | 必需环境 |
| --- | --- |
| 通用 | Flutter stable（当前验证版本 3.47.x）、Dart SDK、Git |
| Android | Android SDK（compileSdk 34 / build-tools 34.0.0）、NDK `28.2.13676358`、JDK 17 |

首次拉仓库后：

```bash
flutter pub get
dart tool/inkpaper.dart doctor    # 检查 Flutter、SDK、签名文件、平台工具
dart tool/inkpaper.dart verify    # analyze + test + store-check 一把跑完
```

## 2. 常用开发命令

```bash
dart tool/inkpaper.dart analyze        # 静态分析
dart tool/inkpaper.dart test           # 单元与组件测试
dart tool/inkpaper.dart deps           # 依赖体检
dart tool/inkpaper.dart store-check    # 商店合规自检（隐私清单、删除入口、签名证书等）
dart tool/inkpaper.dart all            # 构建当前宿主可构建的全部 debug 产物
```

`all` 等价于 `android-release`，构建发布 APK。

### 构建目标

| 命令 | 说明 |
| --- | --- |
| `build android-debug` | Android 调试 APK |
| `build android-release` | Android 发布 APK（universal，含全部 ABI，发布/CI 用这个） |
| `build android-release-split` | 按 ABI 拆分的发布 APK（本机安装、测包体），产物三个 |
| `build android-aab` | Google Play 用的签名 AAB |

产物位置：

- Android：`build/app/outputs/flutter-apk/app-debug.apk`、`app-release.apk`
- Android 拆包：`build/app/outputs/flutter-apk/app-{armeabi-v7a,arm64-v8a,x86_64}-release.apk`
- Android 符号表：`build/symbols/`（`--split-debug-info` 输出，堆栈还原用，不要提交）
- Android AAB：`build/app/outputs/bundle/release/app-release.aab`

### 构建期 Dart 变量

以下变量通过 `--dart-define` 注入，`tool/inkpaper.dart` 会读取同名环境变量：

| 变量 | 用途 |
| --- | --- |
| `ENVIRONMENT` | 运行环境，缺省 `production` |
| `CLOUD_VERIFY_APP_KEY` | 云校验 AppKey |
| `SENTRY_DSN` | 崩溃上报（可选，Dart 侧错误上报） |

界面截图/自动化时还可以用 `INKPAPER_SCREENSHOT_MODE=true` 与 `INKPAPER_INITIAL_LOCATION=/path` 固定初始路由（见 `.env.example`）。

## 3. Android 构建与安装

调试：

```bash
dart tool/inkpaper.dart build android-debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

发布构建需要 `android/key.properties` 指向密钥库，缺少时 Gradle 会直接报错而不是静默降级：

```properties
storeFile=../inkpaper-release.jks
storePassword=***
keyAlias=inkpaper
keyPassword=***
```

CI 侧对应 4 个 Secret：`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`；工作流会校验 APK/AAB 的签名证书 SHA-256 是否与 `tool/inkpaper.dart` 中记录的指纹一致。

当前正式密钥是 `android/inkpaper-release.jks`（`CN=InkPaper, OU=Mobile, O=InkPaper, C=CN`，RSA 2048 / SHA256withRSA，有效期到 2054-03-28），SHA-256 为 `D0:99:DD:07:…:AF:56:C1`。这个指纹在 `tool/inkpaper.dart` 与 `release.yml` 各存一份，`store-check` 会断言两边一致。密钥库与 `key.properties` 都在 gitignore 里，务必备份到代码仓库之外——丢了就再也无法给已发布版本发升级包。

应用 ID 为 `com.didichou.inkpaper`，深链 scheme 为 `inkpaper://`（快速记录、随机回顾、分享都走它）。改名前的旧包与本包会被系统视为两个独立应用。

### 3.1 性能基线采集

优化前后必须用同一台设备、同一个 profile 构建对比，否则数字没有意义。

```bash
# profile 模式（release 的优化 + 可观测）
flutter run --profile

# 顺带记录包体
dart tool/inkpaper.dart build android-release-split
ls -lh build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

| 指标 | 采集方式 | 目标（中端机） |
| --- | --- | --- |
| 滚动帧耗时 | DevTools → Performance → 录制主页连续滚动 30 秒，看 `Frame` 轨道 99 分位 | < 16ms，无超过 2 帧的尖峰 |
| 冷启动 | `adb shell am start -W com.didichou.inkpaper/.MainActivity`，读 `TotalTime` | ≤ 1.5s（1000 条笔记） |
| 内存 | DevTools → Memory，滚动前后各拍一次快照，看图片缓存占用 | 不持续增长 |
| 预览缓存命中率 | 断点或在 DevTools console 里读 `NotePreviewCache.hitRate` | > 90% |

采集前先准备数据量：导入或批量创建 1000 条笔记（含 20% 带图笔记），否则测不出长列表的问题。

## 4. 发布

当前 `release.yml` **只发布 Android（APK + AAB）**。仓库已删除其他平台目录，
若将来要恢复，从 git 历史里把对应工程与作业搬回来，并把作业名加回 `publish` 的 `needs` 与 `files`。

先手动验证一遍流水线（不打 tag、不创建 Release）：

```text
GitHub → Actions → Release → Run workflow → dry_run 保持勾选
```

验证跑会执行门禁（verify / gitleaks / keystore 检查）和 APK、AAB 构建，产物在 run 页面的 Artifacts 里，
可以下载试装。`dry_run` 关掉则等同于正式发布，会直接创建 Release。

确认无误后正式发版：

```bash
# 1. 改 pubspec.yaml 版本号，例如 1.0.1+10001
# 2. 同步 CHANGELOG.md 对应版本段落（Release 说明从它生成）
# 3. 提交所有改动（release 命令要求工作区干净）
dart tool/inkpaper.dart store-check
dart tool/inkpaper.dart release v1.0.1
```

`release` 会校验 tag 与 `pubspec.yaml` 一致、本地与远端无同名 tag，然后打 tag 推送。GitHub Actions 收到 tag
后构建 Android，并把 `InkPaper-vX.Y.Z-android.apk` / `.aab` 挂到 Release；应用内「检查更新」读的就是这个 Release。

## 5. 真机测试注意事项

### 5.1 安装与数据

- 应用 ID 已从旧命名改为 `com.didichou.inkpaper`，覆盖安装会变成第二个 App，旧数据不会迁移。测试前请先卸载旧包，或明确以全新用户视角验证。
- 数据库文件为 `notes.db`，查看方式：
  ```bash
  adb shell run-as com.didichou.inkpaper ls databases
  adb exec-out run-as com.didichou.inkpaper cat databases/notes.db > notes.db
  ```

### 5.2 Android 系统分享

- 需要覆盖多个入口：浏览器、阅读器、系统选中文本（PROCESS_TEXT）、相册/图片、文件管理器，以及纯文本、带链接文本、多图混合。
- 重点回归：分享内容为空白、分享后闪退、链接被截断、图片未上传。分享成功应落到新建笔记草稿而不是覆盖现有笔记。
- Android 10+ 为分区存储，图片读取走 SAF/MediaStore；Android 13+ 需要 `POST_NOTIFICATIONS` 才有提醒通知。

### 5.3 桌面小组件

- 长按桌面 → 小组件 → 选择「快速记录」「随机回顾」；首次添加前建议先启动一次 App，让快照数据写入完成。
- 随机回顾要求已有笔记；数据为空时会显示引导文案，这是设计行为。
- 快照存于 SharedPreferences（`inkpaper_widget`），卸载或清除数据后小组件会退回占位状态，重新打开 App 即可恢复。

### 5.4 提醒与后台

- 提醒依赖精确闹钟与通知权限，Android 12+ 需允许「闹钟和提醒」，否则时间会被推迟。
- 小米、华为、OPPO、vivo 等厂商需要额外允许自启动、关闭电池优化，否则锁屏后提醒可能不触发。
- 语音输入需要 `RECORD_AUDIO` 授权；首次使用会弹权限框，拒绝后不要直接判定功能损坏。

### 5.5 同步与自建服务

- 自建 Memos 覆盖 0.21.0 至 0.29.1，登录失败时先确认服务器版本与账号密码，再看同步日志。
- 局域网调试不要填 `localhost`，真机应使用电脑的局域网 IP；HTTP 服务需要允许明文流量，HTTPS 自签证书需要设备信任。
- 换服务器或换账号前先导出备份，避免本地笔记与远端状态冲突。
- WebDAV（如坚果云）需使用应用密码；开启「备份图片附件」时注意体积与超时。

### 5.6 其他回归点

- 图片查看：点击退出、原图查看、多图左右切换、双指缩放与左右滑动不打架。
- Markdown：标题、引用、链接、下划线、相关笔记引用、换行保留。
- 标签：多层级标签（`#工作/项目A`）、中文标签、侧边栏返回路径。
- 搜索、置顶、随机回顾、导入导出（Flomo、微信读书）。
- 字号设置验证不同档位下列表与详情页不出现布局溢出。

## 6. 排查建议

| 现象 | 先看什么 |
| --- | --- |
| 构建失败提示缺少依赖 | `dart tool/inkpaper.dart doctor`、`flutter pub get` |
| Android 分享无反应 | `adb logcat | findstr inkpaper` 看 Intent 是否命中 |
| 提醒不响 | 通知权限、精确闹钟权限、厂商后台限制 |
| 同步失败 | 服务器版本、地址是否可达、证书是否受信 |
