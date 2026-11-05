# 项目指令（Project Instructions）

> 这份文本用于 IDE 的「项目指令 / Project Rules」设置——**在此项目下的所有任务都会自动带上它**。
> 因此刻意写得短（约 900 字，≈1.2k tokens）：只放「每次都必须遵守的硬约束」+「去哪里找细节」。
> 业务与流程细节不要塞进来，放 `docs/BUSINESS_OVERVIEW.md`，需要时再读。
> 修改流程：改本文件 → 同步粘贴到 IDE 设置里，两边保持一致。

---

```text
# InkPaper 项目指令

## 项目背景
Android 优先的 Flutter 笔记应用（包名 com.didichou.inkpaper，深链 inkpaper://）。
本地优先：数据全在本机 notes.db（schema v12），用户可选登录自建 Memos 服务器双向同步。
能力面：Markdown 笔记 + 本地图片/Live 图、标签、搜索、随机回顾、「问笔记」AI 对话、周/月回顾、
语音输入（系统/讯飞/百度）、定时提醒（Android 原生精确闹钟）、桌面小组件、Flomo/微信读书导入、JSON/ZIP 备份。
回复用简体中文；先给结论再给依据（文件路径:行号）。

## 构建与验证（只用这套，别手写 flutter build）
dart tool/inkpaper.dart analyze | test | verify
dart tool/inkpaper.dart build android-debug | android-release
- analyze 只允许剩 _backup/analyze_backup.dart 那条历史 info，其余必须为 0。
- 交付前至少跑 analyze + 相关单测；涉及 UI / 原生能力的改动必须装到真机点一遍。

## 硬规则
1. 改了代码就升版本：pubspec.yaml 的 version patch +1、versionCode 同步 +1（1.1.56+10152 → 1.1.57+10153）。
2. 最小 diff：不动无关文件、不改公开 API、不新增依赖（确需新增先说明理由并等我确认）。
3. 一个连贯改动一个 commit，Conventional Commits + 中文（如 fix(voice): ...）；只 add 本次涉及的文件。
4. 不改 git config，不用 --amend / --force；不删 .codebuddy/、_backup/、build/。
5. 不擅自动数据契约：notes 表字段、rowStatus 语义、createdAt / updatedAt / displayTime 三种时间口径。
6. 列表、分页、搜索、统计一律查 active_notes 视图，不要直接查 notes。

## 代码约定
- 新增逻辑先找同类实现对齐；详情页九宫格 lib/widgets/note_image_grid.dart 是「延后解码」的样板。
- 状态与业务编排放 AppProvider；页面不要直接碰 sqlite / HTTP。
- 注释写「为什么」而不是「做了什么」；用中文。
- 用户可见文案走 AppLocalizationsSimple 的 zh/en，不在 widget 里硬写中文。

## 真机（Android）
- adb connect 192.168.0.108:35819（小米 HyperOS 23127PN0CC，1200×2670），命令里显式加 -s 192.168.0.108:35819。
- 装机 install -r build/app/outputs/flutter-apk/app-release.apk；启停 am force-stop / am start -n com.didichou.inkpaper/.MainActivity。
- 截图用 shell screencap -p /sdcard/x.png 再 adb pull；不要用 exec-out 重定向（会破坏二进制）。
- 该机 logcat 读不到内容，排查靠 dumpsys + 截图；release 包不可 run-as，读数据库/偏好设置要先装 debug 包。
- 没有可用设备就明说「未真机验证」，不要假装验证过。

## 文档索引（需要时读，不要通读）
- docs/HANDOFF.md：现状、代码地图、未解决问题、新窗口 Prompt
- docs/BUSINESS_OVERVIEW.md：业务流程、参数速查、真机调试参数
- BLOCKERS.md：未解决 / 待决策（VOICE-001 / ORIENT-001 / PERF-IMG-001 / DOC-001）
- PROGRESS.md：最近改动记录（最新在最前）
发现文档与代码不一致时，先指出来，再改代码。
```

---

## 为什么这样写（设计说明）

1. **短**：项目指令是常驻上下文，每轮对话都要花 token。这里只保留「不能猜错的东西」——版本号规则、构建命令、数据契约、真机参数；其余全部用文档索引甩出去。
2. **命令可执行**：写「`dart tool/inkpaper.dart analyze`」而不是「跑一下静态检查」，模型不会自己发明 `flutter build apk --release` 这种和项目约定冲突的命令。
3. **把「禁止项」写成硬规则**：版本号不升会装不上、`--amend` 会改历史、把整套业务文档塞进常驻指令会挤爆上下文——这些都是踩过的坑，值得长期占位。
4. **留了「不确定就问」的口子**：最后一条要求「没设备就说未验证」「文档和代码不一致先说」，比让它编造验证结论更可控。
5. **`active_notes` 单独列一条**：这是最容易写错、又不会立刻报错的地方（漏了软删过滤，已删笔记会回到列表）。

如果 IDE 对项目指令有字数上限，按这个顺序删：先删「代码约定」整节 → 再删「文档索引」里的详细说明 → 保留「硬规则」和「真机」。
