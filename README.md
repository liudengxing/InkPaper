# 小纸 (InkPaper)

小纸是一款面向个人知识记录的 Android 笔记应用。它推荐本地记录，也可以连接自托管 Memos 服务进行同步。应用提供 Memos 兼容 Markdown、图片、标签、提醒、搜索、WebDAV 备份、导入导出、系统分享、小组件和可选 AI 辅助等能力。

[下载最新版本](https://gitee.com/liudengxing233/ink-paper/releases/latest) · [GitHub 仓库](https://github.com/liudengxing/InkPaper) · [问题反馈](https://github.com/liudengxing/InkPaper/issues) · [English](README.en.md)

## 当前版本

`1.1.140`

当前源码已通过 Android 真机安装验收。公开安装包以发行页为准。

## 功能

- 本地笔记、官方服务器和自部署 Memos 同步。
- Markdown 渲染、待办事项、链接、图片和标签。
- 多层级标签，例如 `#工作/项目A`。
- 全文搜索、置顶、提醒和随机回顾。
- 随机漫步可在本机沿笔记关联向前探索、返回上一步并查看本次路径小结。
- 首页卡片左滑可在本机查找全库相关笔记，查看引用、正文片段等推荐依据。
- 图片上传、预览、保存和多图浏览。
- WebDAV 备份和恢复，可选择是否备份图片附件。
- Flomo、微信读书等数据导入。
- Android 系统分享入口。
- 快速记录和随机回顾桌面小组件。
- AI 辅助写作、自定义提示词和六视角 AI 洞察，分析摘要可在 AI 设置中关闭。
- 中文和英文界面。
- 仅维护 Android 单平台，发布 APK 与 AAB。

在首页列表顶部下拉，即可打开 **AI 洞察、随机漫步、随机回顾**。随机漫步也可以从侧边栏进入。每张候选卡片预留五行正文，点进后可在卡片内查看跳转原因和展开全文。

## 下载

发布包在 [Gitee 发行版](https://gitee.com/liudengxing233/ink-paper/releases)（国内推荐）与 [GitHub Releases](https://github.com/liudengxing/InkPaper/releases) 同步提供，两边内容一致。

国内网络直连 GitHub 较慢，代码、标签与发行版说明会由 CI 自动同步到 Gitee 镜像仓（AAB 只留在 GitHub）；安装包因为 CI 机房到 Gitee 的上传带宽只有约 10 KB/s，改由发版机器补传。应用内「检查更新」只读 Gitee。想在本地 clone 也用镜像的话：

```bash
git clone https://gitee.com/liudengxing233/ink-paper.git
```

GitHub Releases 的 Android APK 用于手动安装和测试分发；Google Play 上架使用发布流程生成的签名 AAB。仓库只保留 Android 平台，没有其他平台的构建目标。

## 开发

安装 Flutter 后运行：

```bash
flutter pub get
dart tool/inkpaper.dart verify
```

常用命令：

```bash
dart tool/inkpaper.dart doctor
dart tool/inkpaper.dart analyze
dart tool/inkpaper.dart test
dart tool/inkpaper.dart store-check
dart tool/inkpaper.dart build android-debug
dart tool/inkpaper.dart build android-release
```

构建需要 Android SDK（见下方"Android 环境"）与 JDK 17。

### Android 环境

1. 安装 [Android command-line tools](https://developer.android.com/studio#command-tools)，解压后设置 `ANDROID_HOME` 指向 SDK 目录。
2. 通过 `sdkmanager` 安装：

```bash
sdkmanager "platform-tools" "platforms;android-36" "build-tools;35.0.0"
sdkmanager --licenses
```

3. 确保 `adb`（位于 `$ANDROID_HOME/platform-tools`）可用，连接设备或启动模拟器后即可 `flutter run`。

## 发布

版本号统一维护在 `pubspec.yaml`，`x.y.z` 是语义版本，`+N` 是构建号：

```yaml
version: 1.1.140+10240
```

构建新版本时同步增加 `x.y.z` 的 patch 和 `+N`，并更新中英文 README 的当前版本。`dart tool/inkpaper.dart store-check` 会核对版本一致性。

发布入口：

```bash
# 打 tag → CI 检查构建并发布 GitHub Release → 等 APK 出来再补传到 Gitee
dart tool/inkpaper.dart release vX.Y.Z --sync-gitee

# 只想先打 tag，稍后（CI 约半小时）再补传
dart tool/inkpaper.dart release vX.Y.Z
dart tool/inkpaper.dart release-gitee vX.Y.Z
```

这个命令先校验 tag 与 `pubspec.yaml` 一致，然后创建并推送 tag（示例版本号按实际替换）。GitHub Actions 收到 tag 后执行检查、构建并发布 Android APK/AAB。

Gitee 镜像仓的代码、tag 和发行说明由 CI 同步；安装包因为 Actions 机房到 Gitee 的上传带宽只有约 10 KB/s，改由本机的 `release-gitee` 补传（需要 Python 3，令牌取 `GITEE_TOKEN` 环境变量或 `.git/gitee_token`）。

## 文档

- [项目结构与构建指南](docs/PROJECT_STRUCTURE_AND_BUILD.md)
- [维护指南](docs/MAINTENANCE.md)
- [商店合规清单](docs/STORE_COMPLIANCE.md)
- [更新日志](CHANGELOG.md)
- [安全政策](SECURITY.md)
- [贡献指南](CONTRIBUTING.md)

## 法律与隐私

本项目隐私、用户协议与账号数据删除等法律条款以仓库内 [SECURITY.md](SECURITY.md) 与 [CONTRIBUTING.md](CONTRIBUTING.md) 为准。

## 许可证

小纸沿用 MIT License。详见 [LICENSE](LICENSE)。
