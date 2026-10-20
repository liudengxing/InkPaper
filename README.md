# 小纸 (IntPaper)

小纸是一款面向个人知识记录的跨平台笔记应用。它可以本地优先使用，也可以连接官方服务器或自托管 Memos 服务进行同步。应用提供 Memos 兼容 Markdown、图片、标签、提醒、搜索、WebDAV 备份、导入导出、系统分享、小组件和可选 AI 辅助等能力。

> 本项目是 [InkRoot](https://github.com/yyyyymmmmm/InkRoot)（旧名「墨迹」，现更名「小纸」）的延续与重命名版本，代码在此基础上继续维护，仓库现托管于 [liudengxing/IntPaper](https://github.com/liudengxing/IntPaper)。

[下载最新版本](https://github.com/liudengxing/IntPaper/releases/latest) · [问题反馈](https://github.com/liudengxing/IntPaper/issues) · [English](README.en.md)

## 当前版本

`1.0.0`

正式版本构建

## 功能

- 本地笔记、官方服务器和自部署 Memos 同步。
- Markdown 渲染、待办事项、链接、图片和标签。
- 多层级标签，例如 `#工作/项目A`。
- 全文搜索、置顶、提醒和随机回顾。
- 图片上传、预览、保存和多图浏览。
- WebDAV 备份和恢复，可选择是否备份图片附件。
- Flomo、微信读书等数据导入。
- Android 和 iOS 系统分享入口。
- 快速记录和随机回顾桌面小组件。
- AI 辅助写作和自定义提示词。
- 中文和英文界面。
- Android、iOS、macOS、Windows 和 Linux 构建。

## 下载

发布包在 [GitHub Releases](https://github.com/liudengxing/IntPaper/releases) 页面提供。

GitHub Releases 的 Android APK 用于手动安装和测试分发；Google Play 上架使用发布流程生成的签名 AAB。
Windows 用户下载压缩包后运行应用。
Linux 用户下载压缩包后解压运行。
iOS 和 macOS 包当前用于测试分发。

## 开发

安装 Flutter 后运行：

```bash
flutter pub get
dart tool/inkroot.dart verify
```

常用命令：

```bash
dart tool/inkroot.dart doctor
dart tool/inkroot.dart analyze
dart tool/inkroot.dart test
dart tool/inkroot.dart store-check
dart tool/inkroot.dart build android-debug
dart tool/inkroot.dart build ios-sim
dart tool/inkroot.dart build macos-debug
dart tool/inkroot.dart build windows-debug
dart tool/inkroot.dart build linux-debug
```

> 注：项目内部维护脚本仍沿用 `tool/inkroot.dart` 命名，属历史约定，后续可随项目演进重命名。

不同桌面或移动平台需要对应系统环境。例如 iOS 和 macOS 需要 macOS 与 Xcode，Windows 需要 Windows 与 Visual Studio C++ 桌面组件，Linux 需要 GTK、CMake 和 Ninja。Android 构建需要 Android SDK（见下方"Android 环境"）。

### Android 环境

1. 安装 [Android command-line tools](https://developer.android.com/studio#command-tools)，解压后设置 `ANDROID_HOME` 指向 SDK 目录。
2. 通过 `sdkmanager` 安装：

```bash
sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"
sdkmanager --licenses
```

3. 确保 `adb`（位于 `$ANDROID_HOME/platform-tools`）可用，连接设备或启动模拟器后即可 `flutter run`。

## 发布

版本号统一维护在 `pubspec.yaml`：

```yaml
version: 1.1.13+10113
```

发布入口：

```bash
dart tool/inkroot.dart release v1.1.13
```

这个命令会创建并推送版本 tag。GitHub Actions 收到 tag 后自动执行检查、构建并发布 Android APK/AAB、iOS、macOS、Windows 和 Linux 产物。

## 文档

- [项目结构与构建指南](docs/PROJECT_STRUCTURE_AND_BUILD.md)
- [维护指南](docs/MAINTENANCE.md)
- [商店合规清单](docs/STORE_COMPLIANCE.md)
- [更新日志](CHANGELOG.md)
- [安全政策](SECURITY.md)
- [贡献指南](CONTRIBUTING.md)

## 法律与隐私

本项目基于 InkRoot 代码继续维护。隐私、用户协议与账号数据删除等法律条款以仓库内 [SECURITY.md](SECURITY.md) 与 [CONTRIBUTING.md](CONTRIBUTING.md) 为准；原 InkRoot 的在线法律页面（inkroot.cn）不再适用本仓库。

## 许可证

小纸基于 InkRoot 代码，沿用 MIT License。详见 [LICENSE](LICENSE)。
