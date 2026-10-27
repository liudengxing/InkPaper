# ROADMAP

> 本文件是任务唯一真相。AI 每轮开工先读第 0 节的执行合约，再读第 2 节索引表取任务，只加载该条目详情与作用域内文件。

## 0. 执行合约（优先级高于其他一切）

```
1. 读本文件，找状态为 doing 的条目；没有则取索引表中第一条 todo 且前置已全部 done 的。
2. 只加载该条目的「作用域」内文件，不重读全项目。
3. 完成后按条目「验收」实际执行命令，把真实输出追加到 PROGRESS.md。
4. 验收通过 → 状态改 done → 立刻取下一项，不汇报、不询问。
5. 验收不通过 → 最多尝试修复 2 次；仍失败则改 blocked，写 BLOCKERS.md
   （含已尝试方案 + 具体报错），跳过继续下一项。
6. 禁止：中途总结进度、询问"是否继续"、改作用域外代码、跳过验收命令。
7. 只在全部条目终结、或连续 3 条 blocked 时，才输出文字汇报。
```

## 1. 项目元信息

| 项 | 值 |
|---|---|
| 项目 | `<项目名>` |
| Flutter / Dart | `<3.x.x>` / `<3.x.x>` |
| 审计基线 | 见 `BASELINE.md`（analyze N 条 / 包体积 X MB） |
| 本轮目标 | 完成 Phase 1 + Phase 2 |
| 单轮任务上限 | 3 条 |

## 2. 索引表（AI 靠这张表选任务，不必先读详情）

| ID | 标题 | 优先级 | 前置 | 状态 |
|---|---|---|---|---|
| LIST-PERF-001 | 首页长列表改用 builder | P0 | — | todo |
| STATE-AUTH-002 | auth 模块 setState 下沉到 Notifier | P1 | — | todo |
| IMG-ASSET-003 | 首页大图压缩并指定解码尺寸 | P1 | — | todo |
| QUAL-CLEAN-004 | P3 问题合并清理批次 | P2 | LIST-PERF-001 | todo |

阶段退出条件：Phase 1 = 全部 P0 条目终结；Phase 2 = 全部 P1 终结且 size 已重测；Phase 3 = 全部 P2 终结且 analyze 无新增。

---

## 3. 任务详情

### LIST-PERF-001 · 首页长列表改用 builder

| 字段 | 内容 |
|---|---|
| 优先级 | P0 |
| 前置 | 无 |
| 作用域 | `lib/features/home/home_page.dart`、`lib/features/home/widgets/feed_item.dart` |
| 现状证据 | `home_page.dart:88` `SingleChildScrollView(child: Column(children: items.map((e) => FeedItem(e)).toList()))`；数据源为分页接口，单页 50 条，累积无上限 |
| 做什么 | 1) 外层改 `ListView.builder` + `itemCount`；2) 保留原有分页触发逻辑，改挂在 `ScrollController`；3) `FeedItem` 抽为独立 Widget 类并加 `const` 构造 |
| 验收 | ① `rg -c "SingleChildScrollView" lib/features/home/` 输出 0<br>② `rg -c "ListView.builder" lib/features/home/` 输出 ≥ 1<br>③ `flutter analyze` 无 error<br>④ profile 模式下滚动 300 条，DevTools 无 > 32ms 长帧 |
| 收益 | 首次渲染节点数从全量降为可视区 + 缓存区；长列表滚动帧耗时预期下降（基线：未测量，需 profile 补测） |
| 回滚 | 单 commit，`git revert` |
| 不许做 | 不改分页接口协议、不动 `home` 之外的页面、不调整 FeedItem 视觉样式 |
| 状态 | todo |

### STATE-AUTH-002 · auth 模块 setState 下沉到 Notifier

| 字段 | 内容 |
|---|---|
| 优先级 | P1 |
| 前置 | 无 |
| 作用域 | `lib/features/auth/**`、`lib/core/state/auth_notifier.dart`（新建） |
| 现状证据 | `login_page.dart:41` 与 `register_page.dart:57` 各自 `setState` 维护 loading + error；`login_page.dart:63` `setState(() => _loading = true)` 触发整页重建 |
| 做什么 | 1) 新建 `AuthNotifier extends ChangeNotifier`，持有 `AuthState {loading, error, user}`；2) 两个页面改为 `Consumer<AuthNotifier>`，只订阅所需字段；3) 页面内 `setState` 全部删除 |
| 验收 | ① `rg -c "setState" lib/features/auth/` 输出 0<br>② `rg -c "Consumer<AuthNotifier>" lib/features/auth/` 输出 ≥ 2<br>③ 登录过程中用 DevTools rebuild 统计确认：仅 `Consumer` 子树重建，页面根节点不重建<br>④ `flutter analyze` 无新增 issue |
| 收益 | 表单输入场景下每敲一个字符不再重建整页（基线：登录页 rebuild 次数待测） |
| 回滚 | 新增文件 + 两页改动，单 commit 可整体 revert |
| 不许做 | 不引入新的状态管理库（沿用项目现有方案）、不改登录接口、不调整表单校验规则 |
| 状态 | todo |

### IMG-ASSET-003 · 首页大图压缩并指定解码尺寸

| 字段 | 内容 |
|---|---|
| 优先级 | P1 |
| 前置 | 无 |
| 作用域 | `assets/images/home_*.png`、`lib/features/home/widgets/feed_item.dart` |
| 现状证据 | `home_banner.png` 2.4 MB / 2400×1200，实际显示宽度 360dp；`feed_item.dart:34` `Image.asset('assets/images/home_banner.png')` 未指定 cacheWidth |
| 做什么 | 1) 转 WebP 并按 3x 屏输出（最大边 ≤ 1080）；2) `Image.asset` 加 `cacheWidth: 1080`；3) 删除原 png，更新 pubspec 引用 |
| 验收 | ① `assets/images/home_*` 总体积 ≤ 400 KB（改前记录实际值）<br>② `rg -c "cacheWidth" lib/features/home/` 输出 ≥ 1<br>③ `flutter build apk --analyze-size` 中 assets 项体积较改前下降<br>④ 首屏冷启动无劣化 |
| 收益 | 解码内存从约 11 MB 降至约 4.6 MB（2400×1200×4 → 1080×540×4），包体积下降 |
| 回滚 | 单 commit；原图先备份到 `assets/_originals/`（不入包，加 pubspec 除外） |
| 不许做 | 不改图片视觉效果、不动其他非 home 资源、不改 `pubspec.yaml` 的 assets 目录结构 |
| 状态 | todo |

### QUAL-CLEAN-004 · P3 问题合并清理批次

| 字段 | 内容 |
|---|---|
| 优先级 | P2 |
| 前置 | LIST-PERF-001 |
| 作用域 | `analysis_options.yaml`、`lib/**`（仅 const / 未使用 import / 死代码） |
| 现状证据 | 见审计 Stage 2 清单中置信度高的全部 P3 条目（共 N 条，附录 A） |
| 做什么 | 1) `analysis_options.yaml` 启用 `flutter_lints` recommended；2) 批量补 const 与删除未使用 import；3) 删除注释死代码 |
| 验收 | ① `flutter analyze` info 数从 N 降到 ≤ M<br>② `dart analyze` 无 error<br>③ `git diff --stat` 改动行数与原 info 数量级相当（防止顺带重写逻辑） |
| 收益 | 质量门禁可长期生效；无性能收益 |
| 回滚 | 单 commit |
| 不许做 | 只做机械修复，不改任何业务逻辑；不调整 lint 规则到严格模式（另开任务） |
| 状态 | todo |

---

## 附录 A · 审计 finding 索引

对应 `AUDIT.md`（Stage 2 产出）。每个 finding 的 `file:line` 已搬到对应任务的「现状证据」，此处只保留 ID 映射，方便追溯：

| finding | 任务 |
|---|---|
| F-01 首页 Column 渲染全量 | LIST-PERF-001 |
| F-04 登录页整页 setState | STATE-AUTH-002 |
| F-07 首页 banner 2.4MB | IMG-ASSET-003 |
| F-11~F-26（P3） | QUAL-CLEAN-004 |

---

## 附录 B · PROGRESS.md 格式（AI 只 append，不改旧行）

一条任务占一段，命令输出必须贴真实的，不许写"验收通过"四个字了事：

```markdown
## 2026-10-21 15:40 · LIST-PERF-001 · done
- 改动：home_page.dart(88-120) 改 ListView.builder；feed_item.dart 抽为 Widget 类
- 验收输出：
  $ rg -c "SingleChildScrollView" lib/features/home/
  0
  $ flutter analyze
  No issues found!
- 备注：分页触发改挂 ScrollController，阈值沿用原 200px
- commit: a3f9c21
```

失败或跳过的也要记，理由是下次恢复现场的依据：

```markdown
## 2026-10-21 16:05 · IMG-ASSET-003 · blocked
- 已尝试：转 WebP 后透明度丢失；改用 pngquant 压缩
- 报错：`pngquant: cannot write to readonly assets/`（目录权限）
- 需决策：是否允许调整 assets 目录权限，或改为在 CI 中做压缩
```

## 附录 C · BLOCKERS.md 格式

只有 `blocked` 状态的条目才进这里，`skipped` 不进。每条必须能被你一眼决策：

```markdown
## IMG-ASSET-003 · 2026-10-21 16:05
**问题**：assets 目录只读，压缩工具无法写入
**已尝试**：pngquant / 直接覆盖 / 复制到临时目录再替换
**要你决定**：
- A. 放开 assets 目录写权限（影响：其他自动化流程也可能改动资源）
- B. 压缩步骤挪到 CI，本地只存原图（影响：需新增构建脚本）
**影响**：阻塞该条任务，已跳过，正在做 QUAL-CLEAN-004
```

## 附录 D · 每轮开工的自检三问

1. 索引表里有没有两条以上 `doing`？有 → 说明上一轮没收尾，先修正状态，别开始新任务。
2. 选中的任务「前置」是否全部 `done`？有 `blocked` 在链上 → 跳到无关任务，别硬上。
3. 任务「验收」能不能直接复制执行？不能 → 说明条目不合格，先补验收再动手。
