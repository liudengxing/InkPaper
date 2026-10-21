# BLOCKERS

> 记录被阻塞的条目、已尝试方案与具体报错；`ARCH-LAYER-002 / A-09` 要求的许可结论也记在此处。

## ARCH-LAYER-002 · A-09 · 字体许可结论（2026-10-21）

- **对象**：`assets/fonts/` 下 5 个字体文件（`SF-Mono-Regular.ttf`、`SF-Pro-Display-{Regular,Medium,Bold,Light}.ttf`），合计 3.94 MB。
- **结论：不可再分发**。SF Pro / SF Mono 为 Apple 系统字体，Apple 授权仅允许在 Apple 平台/系统内使用，禁止把字体文件本身再分发；随仓库与应用包分发存在许可风险。
- **现状核验**：`pubspec.yaml` 无 `fonts:` 段，`assets:` 只声明 `assets/images/`，因此这 5 个文件**从未进入构建产物**；全库 `Select-String -Pattern 'assets/fonts'` 零命中（代码里 `fontFamily: 'SF Mono'` / `'SF Pro Display'` 均为系统字体名，不是资源引用）。
- **处置**：删除 `assets/fonts/` 整目录（无代码改动）。`preferences_screen` 的字体选项（`AppConfig.FONT_FAMILY_*`）在 `AppTheme.getFontStyle` 中映射为 `sans-serif` / `serif` 等系统字体族，与字体文件无关，保持现状。
- **验收取证**：`(Get-ChildItem assets/fonts -File -ErrorAction SilentlyContinue | Measure-Object).Count` → 0；`assets/` 递归总大小 3.96 MB → 0.02 MB。
