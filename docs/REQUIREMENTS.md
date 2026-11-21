# 需求池（REQUIREMENTS）

> 用户口述需求的登记处。**这里是「想做什么」，不是「怎么做」**；技术方案与验收留在
> `ROADMAP.md`，开工前先按 ROADMAP 第 0 节的执行合约走一遍。
>
> 每条固定四段：**现象 / 期望 / 线索 / 待确认**。状态只有 `todo` → `doing` → `done`，
> 完成时在标题后补 `done: <commit>`，不要删条目。
>
> 建档：2026-11-21（用户当晚 04:27 口述，要求「只记录先不开发，明天再开发」）。

## 索引

| ID | 需求 | 状态 | 备注 |
| --- | --- | --- | --- |
| R-01 | 删除笔记：提示框尺寸/边距不对 + 删除卡顿 | done | 4deaa41 |
| R-02 | AI 洞察页视觉重做（参考 flomo 的审美） | done | 4b954a6 |
| R-03 | 搜索笔记的过渡动画太丑 | done | 02cf20b |
| R-04 | 详情页时间文字是纯黑，改成和首页一致的灰 | done | d9c55d3 |
| R-05 | 首页下拉区把最常用的三个功能放到最上面 | done | 0870d0f |
| R-06 | 随机回顾大页面改成首页那种信息流（5 条 + 下拉换 5 条） | done | faf5e36 |
| R-07 | 知识图谱整块先去掉 | done | 待补 |

---

## 落地结论（2026-11-21）

六条全部实现，统一在 1.1.120 验证；每条的做法与推翻的假设记在这里，免得下次再猜。

- **R-01**：用户确认「框」= 删除后的撤销提示条（不是确认弹窗）。两个根因：① 撤销条与
  普通提示条走两套 margin 算法，宽度/左右边距不一致 → 收敛成 `SnackBarUtils.toastMargin`，
  圆角统一 26；② 卡顿是删除要等落库才 `notifyListeners` → 改成乐观删除：先摘列表 +
  通知，再异步落库，失败回滚。`restoreNote` 会先等 `inFlightDelete` 落地并用 id 校验，
  否则撤销可能跑在删除之前。首页卡片上的删除也收敛到 `NoteActionsUi.deleteNote`。
- **R-02**：参考 flomo 实测（页面 #F9F9F9、分组白底 12dp、大标题 21sp、textSubtle #949494），
  重排三段（范围 → 视角网格 → 结果）并加 240ms 渐入切换。
- **R-03**：元凶是标题区的**横向 SizeTransition**（宽度 0→满，文字被压扁再撑开）以及
  leading 变 null 时残留的 44px 槽位。改成 leading/title/actions 三段同一条 Row 同步位移。
  注意：列表不能塞 AnimatedSwitcher（两个 ListView 抢同一个 ScrollController 会 assert），
  换源只做整体淡起。
  **落地后又踩一次（29b7bc1）**：抽屉按钮用 `AnimatedContainer(width: 0↔44)` 包
  `OverflowBox` 保尺寸，但 AppBar 的 title 槽位**高约束是无限的**，只给 width 时
  maxHeight=∞ 透传下去，OverflowBox 按 `fit: max` 撑到 Infinity → 整个 title 子树
  布局失败。release 不红屏，现象是抽屉按钮 + 标题一起消失（首版 1.1.120 装机才发现）。
  给 AnimatedContainer / OverflowBox 都补死高度 48 即可；搜索态那 12px 缝隙用
  IgnorePointer 关掉点击。
- **R-04**：详情页时间改用与首页同一档灰（新增 `AppTheme.timestampColor` 常量）。
- **R-05**：用户指「首页列表下拉」，并明确「直接看 flomo 源码」。答案是 flomo 首页
  `fragment_main.xml` 的 `headerLayout`：AI 洞察 / 每日回顾 / 随机漫步三颗白色胶囊。
  我们对应成 AI 洞察 / 周期回顾 / 随机回顾（都能落到已有路由）。
- **R-06**：PageView 一页一条 → ListView + NoteCard；一批默认 5 条，下拉与右上角
  「换一批」共用一条路径，用 `excludeIds` 排掉上一批；库比一批还小时回退全集。

---

## R-01 删除笔记：提示框尺寸/边距不对 + 明显的卡顿 done: 4deaa41

**现象**

1. 删除笔记时弹出来的那条提示框，**大小不对、左右两侧的间距也不对**。
2. 删除动作本身有明显卡顿（点击后有可感知的停顿才消失）。

**期望**

- 提示框与首页其它玻璃提示条一致：宽度、左右边距、圆角统一，不忽宽忽窄。
- 点删除后列表立刻反应，卡顿消除。

**线索**

- 删除入口：`lib/widgets/note_actions_ui.dart:80` `NoteActionsUi.deleteNote()`。当前是
  「不弹确认框，直接删 + 2.5 秒撤销」，提示条走 `SnackBarUtils.showAction`。
- 提示条视觉：`SnackBarUtils.showAction` 的 SnackBar 只当透明容器，真正外观由
  `LiquidGlassLayer + LiquidGlass` 给（见 LESSONS_LEARNED §5.5）。
- 首页另有一条删除路径：`lib/screens/home_screen.dart:1739` 直接调
  `appProvider.deleteNote(note.id)`，可能没走上面这个统一入口 ——「框不对」有可能就是
  两条路径长相不一致造成的。
- 卡顿方向：`NoteActionsService.delete` → `AppProvider.deleteNote`
  （`lib/providers/app_provider.dart:3152`）里的 await 链 + `notifyListeners()` 全量重建；
  删除后列表要重新排序/重建，可能整页重建。

**待确认**

- 用户说的「框」是**删除后的「笔记已删除 / 撤销」条**，还是某个**确认弹窗**？拍个截图最好。
- 卡顿是全列表一起卡，还是只有被删那一行动画不平滑。

---

## R-02 AI 洞察页视觉重做 done: 4b954a6

**现象**

现在的 AI 洞察页面「有点太难看」。

**期望**

参考 **flomo** 里对应的样式，做出同等水平的审美。具体参考哪一屏、要借鉴哪些元素
（卡片质感、留白、字阶、进度态）要等用户给参考图。

**线索**

- 页面：`lib/screens/ai_insight_screen.dart`（范围选择 → 视角网格 → 结果页三段）。
- 内置视角数据：`lib/models/insight_lens.dart`；请求组装：`lib/services/ai_insight_service.dart`。
- 注意：这一屏**不要**再套 `LiquidGlass`——LESSONS_LEARNED §5.5 的结论是纯色/近纯色
  背板上真玻璃只会发灰。
- 相关约定：内置视角提示词输出 480–560 字，`[n]` 引用，改动视觉时别动提示词。

**落地结论**

第一版（`4b954a6`）把 flomo 的参数抄对了（底色 #F9F9F9、白卡 12dp 圆角、21sp 大标题），
但**排列方式抄错了**：做成了 2×3 的双列方块墙。flomo 的模板是一行一条——36dp 图标槽 →
标题/描述 → 箭头，行间距 10。用户当场指出「还是一个一个方块，flomo 是分行的」。

第二版（`1339769`）改回行式：去掉 `GridView` 与固定卡高 176，纵向行 + 统一 `_rowCard`
外壳；行里不再重复 `by InkPaper` 署名（六条内置全是噪音），只给「已改」留一个 5dp 圆点；
范围选择行补同一层极浅阴影。行式还让描述能用满整行宽度，六个视角一屏放得下。

**待确认**

- 是否把「选视角」和「看结果」拆成两步而不是现在的一屏三态（依旧没动）。

---

## R-03 搜索笔记的过渡动画太丑 done: 02cf20b

**现象**

搜索笔记时的那段动画不好看。

**期望**

**实现方式暂定** —— 用户明确说「具体实现方式先记录在需求里，后面再去确认」。

**线索**

- 搜索是首页内嵌的，不是独立页面：`lib/screens/home_screen.dart`（搜索栏
  `_searchController`、`_isSearchActive`、`:1601` 起是结果区，`:1408` 「搜索笔记」占位）。
  所以「动画」大概是「进入搜索态时列表 ↔ 结果的切换」那一段。

**待确认**

- 要改成什么样：淡入淡出 / 共享元素 / 搜索栏展开成整页？等用户定。

---

## R-04 详情页的时间文字是纯黑，改成和首页一致的灰 done: d9c55d3

**现象**

笔记详情页里显示的时间是纯黑，比首页列表里的时间重得多。

**期望**

跟首页保持一致的那档灰色（次级文字色）。

**线索**

- 详情页：`lib/screens/note_detail_screen.dart`；首页时间样式可对照
  `lib/widgets/note_card.dart`。
- 主题色统一在 `lib/themes/app_theme.dart`：`textPrimaryColor` / `textSecondaryColor`
  一类，优先用现成常量而不是手写 `Colors.black`。
- ⚠️ **只改颜色，不要碰格式化逻辑**。时间一律按 `Note.createdAt` 字段值经
  `lib/utils/note_timestamp_format.dart` 输出，**禁止 `toLocal()`**（Memos 把北京时间
  当 UTC 存，见项目记忆「时间显示口径」）。

---

## R-05 首页下拉区：最常用的三个功能放到最上面 done: 0870d0f

**现象 / 期望**

参考 **flomo**：把最常用的三个功能做在最上面，**一拉下来就能看到**。

**线索**

- 首页：`lib/screens/home_screen.dart`，底部输入区 `_buildBottomComposerBar`（`:1461`）。
- 如果指的是「点开输入框后展开的那块面板」，图标行现在在下面；flomo 是顶部一行快捷
  入口（图片 / 语音 / 标签 之类）。

**待确认**

- 「下拉框」到底指哪个：**底部「+ 记点什么…」点开后上拉的面板**，还是首页顶部那排
  筛选/搜索控件？
- 三个功能具体是哪三个（图片、语音、标签？还是随机回顾、周期回顾、知识图谱？）。
  这一条决定实现方向，没定之前不要动手。

---

## R-06 随机回顾大页面改成信息流 done: faf5e36

**现象 / 期望**

「随机回顾」的独立大页面打算做成**首页那种信息流**的样子：默认展示 5 条随机回顾，
下拉再刷新出新的 5 条。

**线索**

- 页面：`lib/screens/random_review_screen.dart`。
- 首页信息流的卡片外观可复用 `lib/widgets/note_card.dart`。
- 现有的随机逻辑在 `AppProvider` 里（首页的「随机回顾」入口也用同一套）。

**待确认（用户原话：具体还没想好，方案待定）**

- 5 条是「一次抽 5 条、下拉整批换新」，还是「下拉无限追加」？
- 抽过的要不要去重（同一轮里不重复 / 跨轮不重复）？
- 空态（笔记太少抽不满 5 条）怎么表现？
- 是否保留现在的「换一条」单张卡片交互，还是这个页面彻底改成列表。

---

## R-07 知识图谱整块先去掉 done: 待补

**现象 / 期望**

用户原话：「知识图谱这个功能整块先去掉」。不是修 bug，是整块下线——侧边栏入口、
页面、路由、数据服务、文案、测试一起删，不留半死状态。

**落地**

- 删除 `screens/knowledge_graph_screen_custom.dart`（1402 行）、
  `services/graph_data_service.dart`、`services/graph_isolate_service.dart`，
  两个服务只被这一页用，没有别的调用方。
- 路由 `/knowledge-graph`（名称 `knowledgeGraph`）与侧栏枚举项
  `SidebarMenuItem.knowledgeGraph` 一起删；`SidebarConfig.fromJson` 本来就会把
  已下线的 id 从旧配置里清掉，老用户不会留下空菜单。
- l10n 的 `knowledgeGraph` 与八个 `graph*` 键、`defaultFeatureFlags` 里的
  `graph_view`、注册页与功能介绍里的卖点文案一并清掉。
- 测试 `knowledge_graph_screen_test.dart` 删除；`sidebar_back_navigation_test` 的
  SBG-08 改用「全部标签」验二级页横跳。
- 用户指南、站点介绍、FAQ、架构图的对应条目同步移除。

**待确认**

- 「先去掉」意味着以后可能回来。恢复时上述清单就是完整清单（页面 + 两个服务 +
  路由 + 侧栏项 + l10n + 开关），按此逐项加回即可。
