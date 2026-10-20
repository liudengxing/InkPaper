# 构建与真机测试指南

本文覆盖小纸（InkPaper）各平台的本地构建方式、发布流程，以及真机测试时需要特别留意的行为与坑点。日常开发只跑 `dart tool/inkpaper.dart` 里的命令即可，不要手写零散的 `flutter build`，以免漏掉 `pod install`、扩展属性和签名前置步骤。

## 1. 环境准备

| 目标平台 | 必需环境 |
| --- | --- |
| 通用 | Flutter stable（当前验证版本 3.47.x）、Dart SDK、Git |
| Android | Android SDK（compileSdk 34 / build-tools 34.0.0）、NDK `28.2.13676358`、JDK 17 |
| iOS / macOS | macOS + Xcode（iOS 部署目标 13.0）+ CocoaPods（工程已关闭 Swift Package Manager） |
| Windows | Windows + Visual Studio「使用 C++ 的桌面开发」 |
| Linux | GTK 3、CMake、Ninja、clang |

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

`all` 会构建 `android-debug`，并在对应宿主上追加 `ios-sim` / `macos-debug` / `windows-debug` / `linux-debug`，不支持的平台会打印跳过原因。

### 构建目标

| 命令 | 说明 |
| --- | --- |
| `build android-debug` | Android 调试 APK |
| `build android-release` | Android 发布 APK（universal，含全部 ABI，发布/CI 用这个） |
| `build android-release-split` | 按 ABI 拆分的发布 APK（本机安装、测包体），产物三个 |
| `build android-aab` | Google Play 用的签名 AAB |
| `build ios-sim` | iOS 模拟器（需 macOS，自动 `pod install`） |
| `build ios-unsigned-ipa` | 未签名 IPA，走 `scripts/build_unsigned_ipa.sh` |
| `build macos-debug` / `build macos-release` | macOS 桌面端 |
| `build windows-debug` / `build windows-release` | Windows 桌面端 |
| `build linux-debug` / `build linux-release` | Linux 桌面端 |

产物位置：

- Android：`build/app/outputs/flutter-apk/app-debug.apk`、`app-release.apk`
- Android 拆包：`build/app/outputs/flutter-apk/app-{armeabi-v7a,arm64-v8a,x86_64}-release.apk`
- Android 符号表：`build/symbols/`（`--split-debug-info` 输出，堆栈还原用，不要提交）
- Android AAB：`build/app/outputs/bundle/release/app-release.aab`
- iOS：`build/ios/…`（未签名 IPA 由脚本输出到 `build/`）
- macOS：`build/macos/Build/Products/Release/InkPaper.app`
- Windows：`build/windows/x64/runner/Release/`
- Linux：`build/linux/x64/release/bundle/`

### 构建期 Dart 变量

以下变量通过 `--dart-define` 注入，`tool/inkpaper.dart` 会读取同名环境变量：

| 变量 | 用途 |
| --- | --- |
| `ENVIRONMENT` | 运行环境，缺省 `production` |
| `CLOUD_VERIFY_APP_KEY` | 云校验 AppKey |
| `UMENG_ANDROID_APPKEY` / `UMENG_IOS_APPKEY` / `UMENG_CHANNEL` | 友盟统计 |
| `SENTRY_DSN` | 崩溃上报 |

界面截图/自动化时还可以用 `INKPAPER_SCREENSHOT_MODE=true` 与 `INKPAPER_INITIAL_LOCATION=/path` 固定初始路由（见 `.env.example`）。

## 3. Android 构建与安装

调试：

```bash
dart tool/inkpaper.dart build android-debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

发布构建需要 `android/key.properties` 指向密钥库，缺少时 Gradle 会直接报错而不是静默降级：

```properties
storeFile=../inkpaper-new-release.keystore
storePassword=***
keyAlias=***
keyPassword=***
```

CI 侧对应 4 个 Secret：`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`；工作流会校验 APK/AAB 的签名证书 SHA-256 是否与 `tool/inkpaper.dart` 中记录的指纹一致。

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

## 4. iOS / macOS

1. `cd ios && pod install`（CLI 已自动执行）。
2. 打开 `ios/Runner.xcworkspace`，为三个 target 配置同一开发团队与签名：`Runner`、`InkPaperWidgets`、`InkPaperShareExtension`。
3. Bundle ID 分别为 `com.didichou.inkpaper`、`com.didichou.inkpaper.widgets`、`com.didichou.inkpaper.share`；三者都必须勾选 App Group `group.com.didichou.inkpaper`，否则小组件与分享扩展读不到数据。
4. 真机运行前确认设备的开发者模式与信任证书；免费账号签名有效期只有 7 天。

未签名 IPA：

```bash
bash scripts/build_unsigned_ipa.sh
```

macOS 打包脚本：`scripts/create_dmg.sh`、`scripts/create_release_dmg.sh`（`scripts/dmg/` 下另有增强版流程）。

## 5. 发布

```bash
# 1. 改 pubspec.yaml 版本号，例如 1.0.1+10001
# 2. 提交所有改动（release 命令要求工作区干净）
dart tool/inkpaper.dart store-check
dart tool/inkpaper.dart release v1.0.1
```

`release` 会校验 tag 与 `pubspec.yaml` 一致、本地与远端无同名 tag，然后打 tag 推送。GitHub Actions 收到 tag 后构建并发布 Android APK/AAB、iOS IPA、macOS、Windows、Linux 产物。

## 6. 真机测试注意事项

### 6.1 安装与数据

- 应用 ID 已从旧命名改为 `com.didichou.inkpaper`，覆盖安装会变成第二个 App，旧数据不会迁移。测试前请先卸载旧包，或明确以全新用户视角验证。
- 数据库文件为 `notes.db`，查看方式：
  ```bash
  adb shell run-as com.didichou.inkpaper ls databases
  adb exec-out run-as com.didichou.inkpaper cat databases/notes.db > notes.db
  ```
- iOS 端小组件/分享扩展与主 App 通过 App Group 交换数据；切换签名或 bundle id 后，旧容器数据不再可见，属于预期现象。

### 6.2 Android 系统分享

- 需要覆盖多个入口：浏览器、阅读器、系统选中文本（PROCESS_TEXT）、相册/图片、文件管理器，以及纯文本、带链接文本、多图混合。
- 重点回归：分享内容为空白、分享后闪退、链接被截断、图片未上传。分享成功应落到新建笔记草稿而不是覆盖现有笔记。
- Android 10+ 为分区存储，图片读取走 SAF/MediaStore；Android 13+ 需要 `POST_NOTIFICATIONS` 才有提醒通知。

### 6.3 桌面小组件

- 长按桌面 → 小组件 → 选择「快速记录」「随机回顾」；首次添加前建议先启动一次 App，让快照数据写入完成。
- 随机回顾要求已有笔记；数据为空时会显示引导文案，这是设计行为。
- 快照存于 SharedPreferences（`inkpaper_widget`），卸载或清除数据后小组件会退回占位状态，重新打开 App 即可恢复。

### 6.4 提醒与后台

- 提醒依赖精确闹钟与通知权限，Android 12+ 需允许「闹钟和提醒」，否则时间会被推迟。
- 小米、华为、OPPO、vivo 等厂商需要额外允许自启动、关闭电池优化，否则锁屏后提醒可能不触发。
- 语音输入需要 `RECORD_AUDIO` 授权；首次使用会弹权限框，拒绝后不要直接判定功能损坏。

### 6.5 iOS 分享扩展与小组件

- 分享扩展首次使用需在系统分享面板「更多」中启用 InkPaper；扩展激活规则见 `ios/InkPaperShareExtension/Info.plist`。
- 分享扩展只负责把内容写入 App Group，主 App 下次启动或后台唤醒时才导入，测试时请完整回到 App 确认。
- WidgetKit 刷新受系统节流（通常 15 分钟以上），验证随机回顾切换时不要以「立即刷新」作为判断标准，可先打开 App 再回桌面观察。
- 扩展崩溃多半是签名/App Group 不一致导致，先在 Xcode 里单独运行扩展 target 复现。

### 6.6 同步与自建服务

- 自建 Memos 覆盖 0.21.0 至 0.29.1，登录失败时先确认服务器版本与账号密码，再看同步日志。
- 局域网调试不要填 `localhost`，真机应使用电脑的局域网 IP；HTTP 服务需要允许明文流量，HTTPS 自签证书需要设备信任。
- 换服务器或换账号前先导出备份，避免本地笔记与远端状态冲突。
- WebDAV（如坚果云）需使用应用密码；开启「备份图片附件」时注意体积与超时。

### 6.7 其他回归点

- 图片查看：点击退出、原图查看、多图左右切换。
- Markdown：标题、引用、链接、下划线、相关笔记引用、换行保留。
- 标签：多层级标签（`#工作/项目A`）、中文标签、侧边栏返回路径。
- 搜索、置顶、随机回顾、导入导出（Flomo、微信读书）。
- 桌面端字号设置等价于整体界面缩放，验证窗口最小尺寸下不出现布局溢出。

## 7. 排查建议

| 现象 | 先看什么 |
| --- | --- |
| 构建失败提示缺少依赖 | `dart tool/inkpaper.dart doctor`、`flutter pub get` |
| iOS 编译报 Pod 相关错误 | `cd ios && pod install --repo-update` |
| 扩展/小组件没有数据 | 三端 Bundle ID 与 App Group 是否一致 |
| Android 分享无反应 | `adb logcat | findstr inkpaper` 看 Intent 是否命中 |
| 提醒不响 | 通知权限、精确闹钟权限、厂商后台限制 |
| 同步失败 | 服务器版本、地址是否可达、证书是否受信 |
