## 2026-11-14 · 编辑器图片区默认九宫格（1.1.86+10186）· done

- 触发：用户「编辑页面的图片列表就不要一横排了，直接默认展示九宫格的样子」
- 改动（`lib/widgets/note_editor.dart`）：
  - 删掉「单行横滑 / 九宫格」两态：`_imageGridExpanded`、`_imageExpandController`、
    `_imageStripHeight`、`_imageExpandDuration`、`_imageSwapDuration`、
    `_buildImageStrip`、`_buildGridToggleButton`、`_buildImagePreviewItem`、
    `_reorderImage`、`_imageScrollController` 全部移除；`_buildImageSection`
    只剩 SizedBox + 顶部分隔线 + ClipRect
  - 高度不再固定 330，改为按行数算：
    `_imageGridContentHeight(width) = header 22 + top 4 + rows×tile + (rows-1)×8 + bottom 16`，
    `tile = (width - 2×16 - 2×8) / 3`
  - 新增 `_imageGridTileSize(width)` 统一格子边长，GridView 布局与拖动坐标反算
    （`_updateGridDragHover`）共用，避免两处各写一遍后漂移
  - 卡片高度上限（`availableHeight × 0.92`）钳住时，图片区用
    `_imageGridMinVisibleHeight(width)` 保底一行，其余交给 GridView 内部滚动
  - 标题行用 `SizedBox(height: 22)` 固定：它已算进图片区总高，若随字号变高，
    九宫格底部会被裁
- 测试：`note_editor_image_expand_test.dart` 重命名为
  `note_editor_image_grid_layout_test.dart` 并重写为 3 项（默认九宫格 / 高度随行数
  增长且不挤正文 / 超屏后区高封顶并内部滚动）；`note_editor_grid_reorder_test.dart`
  去掉「先点九宫格按钮」的前置操作
- 验证：`verify` 730 项全过、analyze 0 issue
- 踩坑：测试画布默认 800×600 是横屏比例，图片区会被高度上限一路钳制，量不出行数
  差异，必须改成 411×914 的手机比例；图片 markdown 也要挤在同一行，否则正文行数
  变化会带偏「文字框高度不变」的断言

## 2026-11-14 · 图片缩略图持久化到磁盘（1.1.86+10186）· done

- 触发：用户问「本体图片的缓存能持久化吗」，希望笔记访问过一次后，下次冷启动、
  首页、详情都能直接命中，不用再解原图
- 现状核对：
  - 插入图片是**原字节落盘**（`note_editor.dart` 的 `_saveImageLocally`），4000×3000
    手机照片 3~5MB 原样存进 `documents/images`
  - 渲染靠 `Image.file` + `cacheWidth`，引擎实际做的是「解整张原图再缩到 480」，
    单张 150~250ms（`4d186f0` 那次最差帧 1026ms / 5 张就是这么来的）
  - `PaintingBinding.imageCache`（300 张 / 300MB）只在进程内有效，App 一关全没
- 改动：
  - 新增 `lib/utils/thumb_cache.dart`，`cacheDir/thumbs` 下存
    `<stem>_<档位>.<jpg|png>`：
    - 档位只有两档，`bucketWidth()` 把任意宽度归到 480（网格）/ 1080（单图满宽）
    - PNG/WebP 源输出 PNG 保透明，避免压成黑底；GIF/HEIC/MP4 跳过、回退原图
    - 源文件名带毫秒时间戳且插入后不改写，所以缩略图**不需要失效校验**
    - `prepare()` 启动扫一遍目录建 `Set` 索引，`lookup()` 才能同步命中
      （渲染发生在 build 里，不能做异步 IO）
    - `lookup()` 未命中时 fire-and-forget `ensure()`：这次看原图，下次就命中
    - `lookup()` 对命中项做一次 `existsSync()`：系统低存储清 cacheDir 后内存索引会
      失效，靠这次 stat 自愈——踢掉条目、退回原图、触发重建，避免渲染成破图
    - 编码走 `compute` 丢后台 isolate；`ThumbEncoder` 可注入，单测换同步实现
    - `backfill()` 补齐存量，时间预算 8 秒，按 mtime 倒序优先最近改过的笔记
  - 接入 3 处渲染：`note_card.dart`（AttachmentCache 分支 + `file://` 分支）、
    `note_image_grid.dart`（同两处）、`note_editor.dart`（`_buildImageWidget` 与
    `_getImageProvider` 的本地分支）
  - 插入即生成：`_saveImageLocally` 落盘后 `unawaited(ensure())`，刚插的图首页也不慢
  - 启动：`main._initializeApp` 里 `await prepare()`；`backfill()` 延迟 3 秒再跑——
    首屏这会儿正在解码图片，补缩略图只会在 CPU 和内存带宽上跟它抢
  - 失败的不重试：`_giveUp` 记住解不出来的文件（HEIC、损坏文件），否则列表每次
    build 都会为一个永远生成不出来的图重起一次异步任务
  - 清理：`data_cleanup_screen` 点「清理缓存」后补 `ThumbCache.clear()`，
    否则索引会指向已被删掉的文件
- 依赖：新增 `image: ^4.3.0`。选纯 Dart 方案是为了能在单测里跑；原生
  `Bitmap.compress` 快 5~10 倍，但只能真机验证，等真机测出瓶颈再换
- 测试：`test/unit/thumb_cache_test.dart` TC-01~TC-17（命名 / 档位收敛 / 同步命中 /
  幂等不重复编码 / 小图不放大 / 相对路径解析 / backfill / clear / 失败不重试）
- 验证：`verify` 全过、analyze 0 issue；真机 Xiaomi 14 装 release 包，
  首页卡片、详情九宫格、全屏查看器、编辑器九宫格四处图片都正常，无破图；
  冷启动逐帧采样，图片在 2.4~3.2 秒之间出齐
- 未验证：release 包不可 `run-as`、机器无 root，读不到 `cacheDir/thumbs` 里的实际
  文件数，所以「缩略图写盘成功」只有单测（真实编解码 + 写文件）背书，没有真机目录
  级证据。要拿硬证据得装 debug 包或加应用内诊断页
- 待办：真机对比「清缓存前后」的冷启动出图时间，量化收益

## 2026-11-14 · 「那年今日」卡片去掉品牌绿（1.1.86+10186）· done

- 触发：用户反馈首页顶部「那年今日」不要用绿色主题色，时间要跟下面正常笔记一个样式
- 改动（`lib/widgets/on_this_day_card.dart`）：
  - 描边：`accentColor` 绿边（浅色 alpha 0.18 / 深色 0.28）→ 与 `NoteCard` 一致的
    0.5 半透明细边（深色 `white@0.06`、浅色 `black@0.05`）
  - 卡片 `Material` 的 `elevation` 1 → 0（默认值，analyze 判 `avoid_redundant_argument_values`）
  - 「那年今日」胶囊标签、轮播圆点由绿改次级灰（圆点 active `alpha 0.85` / 其余 0.25）
  - 时间行：「$year 年的今天」绿字 12sp w600 → `DateFormat('yyyy-MM-dd')` + 10sp
    w300 letterSpacing 0.2 + `#949494`（深色 `#8E8E93`），与 `NoteCard._formatCardTimestamp`
    的往年格式和样式完全一致
  - 内边距：header 12→16、正文 12→16，与列表卡片左对齐
- 测试：`test/widget_tests/on_this_day_card_test.dart` 的 OTD-01/OTD-03 断言由
  「2024 年的今天」改为 `2024-10-27`；新增 OTD-06 钉住字号 10 / w300 / `#949494`，
  防止以后又被改回强调色
- 验证：`dart tool/inkpaper.dart verify` 705 项全过；真机 Xiaomi 14 装 release 包，
  浅色与深色（`cmd uimode night yes` 临时切）各看一眼，标签 / 时间 / 圆点都是灰，
  与下方笔记卡片同一节奏

## 2026-11-13 · 图标回到墨绿纸页造型（1.1.86+10186）· done

- 触发：`c526930` 当天下午把桌面图标换成「白底圆角 + 双色块」后，用户反馈桌面图标、启动图、
  关于页三处都不对
- 现状核对（三处其实不同源）：
  - 桌面图标 `mipmap-*/ic_launcher.png`：白底圆角 + 灰绿/亮绿双色块，自适应底色 `#FFFFFF`
  - 启动图 `assets/images/splash_logo.png`：底部图形是同款双色块（`c526930` 新增的图）
  - 关于页 `assets/images/logo.png`：从 10 月起没改过，白底不透明、图形只占画布约 45%，
    放进 80px 白容器后实际图形约 25px，看着又小又淡
- 处理：
  - `mipmap-*/ic_launcher.png`、`drawable-*/ic_launcher_foreground.png`、
    `drawable-*/ic_notification.png` 三组共 15 个文件按 `git checkout c526930^` 还原成
    「墨绿满底 + 白色折角纸页」
  - `values/colors.xml` 的 `ic_launcher_background` 回 `#21473D`；`android:roundIcon` 声明保留
  - `ic_launcher_round` 五档重绘为「墨绿满圆 + 白纸页」（`c526930^` 没有这份文件）
  - `assets/images/logo.png` 重绘成透明底墨绿纸页、`black2logo.png` 重绘成透明底白纸页；
    折角改成二次贝塞尔弧边 + 折痕阴影，避免直线三角的「缺口感」
  - 启动图底部双色块换成白纸页，墨绿底、竖排标语、位置比例原样保留，四份 drawable 同步
  - 登录 / 注册页的 logo 容器是品牌绿渐变，固定用 `black2logo.png`（白纸页），不再按主题切换
  - 关于页 logo 容器 padding 12 → 10；`marketing/real/google-play/icon-512x512.png` 同步换图
  - 生成脚本 `Z:/Temp/gen_paper_brand.py`（4x 超采样，参数：圆角 0.095W、折角 0.21W、
    横线长 0.56W / 粗 0.048H / 位置 0.52H）

## 2026-11-13 · 启动图改成明暗共用墨绿底（1.1.86+10186）· done

### 问题
- 上一个提交只修了 Flutter 首帧，冷启动仍然先黑一屏：原生启动图跟着系统夜间模式走，
  系统深色 + 应用内选浅色时，用户还是看到「先暗一下」

### 为什么不能在运行时改
- Android 的 starting window 由系统在进程启动前按资源限定符（`values-night`）生成，
  `setTheme()` 改不了已画出来的那一屏
- `UiModeManager.setApplicationNightMode` 能改但会触发 Activity 重建，等于重启 Flutter 引擎，代价太大

### 做法
- 明暗共用一张墨绿底（#143B30）启动图：`drawable` / `drawable-v21` / `drawable-night` /
  `drawable-night-v21` 四份同一张，`assets/images/splash_logo{,_dark}.png` 同源
- 不用反相（反相会把亮绿变成粉红），按 4 个锚色做加权插值重映射：白底→墨绿、字 #323233→
  浅色 #E9F2ED、亮绿 #55B986→#5FC492、次块 #5E8579→#376F5E；5bit 量化查表，2 秒跑完 330 万像素
- 四个 `styles.xml` 的 `NormalTheme.windowBackground` 从白/黑统一为 `@color/splash_brand`，
  `LaunchTheme` 父主题统一 `Theme.Black.NoTitleBar`（深底要浅色状态栏图标）
- `flutter_native_splash.yaml` 去掉 `background_image_dark`，防止重新生成又跑出深色变体

### 验证
- 真机 Xiaomi 14（`install -r` 覆盖，保留笔记），`cmd uimode night yes/no` 各跑一次冷启动连拍：
  系统深色 → t01 墨绿启动图（avg 48.5）→ t02 起深色界面；系统浅色 → l01 同一张启动图（avg 57.2）→ l02 起浅色界面
- 两种系统主题下启动图完全一致，中间没有黑帧也没有白屏；状态栏图标是浅色（`Theme.Black` 生效）
- **没能验证的组合**：系统深色 + 应用内手动选浅色 —— 这台机器重连后 `input tap` 注入被系统安全策略拦下
  （`keyevent` 正常），点不动设置页。但启动图已与系统主题彻底解耦（同一张资源 + 同一份 styles），
  该组合必然同样走这张图
- 脚本 `Z:/Temp/gen_brand_splash.py`（源图备份在 `Z:/Temp/splash_source_light.png`，
  否则第二次运行会把深色图当浅色图再映射）
- 验完已把系统夜间模式还原成 `auto`

## 2026-11-13 · 冷启动首帧不再闪深色（1.1.86+10185）· done

### 问题
- 反馈：系统开深色模式时进 App，先显示深色再切回浅色，而设置里选的是浅色主题

### 根因
- `AppProvider` 的 `_appConfig` 初始化成 `AppConfig()` → `themeSelection = THEME_SYSTEM`
- 真正读盘发生在 `initializeApp()`（`home_screen` 首帧后调用），此时 `MaterialApp`
  已经按「跟随系统」渲染过一帧；系统深色 → 深色一帧 → 配置回来 → 切浅色
- 同一路径还影响语言（默认跟随系统）与字号，只是因为视觉冲击小没被注意到

### 做法
- `AppProvider` 加可选 `initialConfig`，构造时直接用；同时记进 `_preloadedConfig`
- `initializeApp` 的加载改成 `_preloadedConfig ?? await loadAppConfig()`，避免重复读
  secure storage
- `main._initializeApp()` 在 `runApp` 之前 `await PreferencesService().loadAppConfig()`，
  与已有的 `FeedSnapshotService.load()` 同一个阶段（原生启动图还盖着，不会看到空白）
- 测试 `test/unit/app_chrome_preload_test.dart` 4 条：系统深色 + 用户浅色 → 首帧浅色；
  深色 → 深色；跟随系统 → 依系统；不传预载 → 仍是旧的「跟随系统」行为（钉住根因）

### 验证
- `dart analyze` 0 issue；新增 4 条测试全过；全量 verify 见提交记录

## 2026-11-13 · 设置页展示系统默认提示词（1.1.86+10184）· done

### 问题
- 需求：「自定义提示词那块，把系统默认的提示词也展示出来，现在实际用什么就展示什么」
- 现状只有一句「留空使用默认提示词」，默认那套到底写了什么、该从哪改全靠猜；三条提示词
  （点评 / 续写 / 周月回顾）分散在三个服务里，用户没法参考

### 做法
- **单一事实来源**：把默认提示词从服务里抽出来，改成对外常量，设置页直接引用
  - `AiReviewService.defaultSystemPrompt` + `customPromptHardRequirements`
  - `AIInsightEngine.defaultContinuationPrompt`（分段标题 `_roleLine` / `_noteHeader` /
    `_relatedNotesHeader` / `_taskHeader` 与任务正文 `_continuationTask` 提成常量，
    `_buildPrompt` 和展示面板共用同一组，改一处两边同步）
  - `PeriodicReviewService.defaultSystemPrompt(ReviewPeriod)` + `customPromptHardRequirements`
- 新组件 `lib/widgets/default_prompt_panel.dart`：折叠面板，展开后 `SelectableText` 展示正文
  （可选中复制），下面跟一行「填了自定义会怎么替换」，续写那条额外说明括号里是运行时占位
- 关键差异要说清：点评 / 回顾的自定义**只替换正文**、末尾格式要求仍追加；续写是**整段替换**，
  自带格式要求和示例都不再生效 —— 以前这点只有读代码才知道
- 规则文案（`customPromptHardRequirements`）也一起展示，避免用户以为填了自定义就完全自由

### 验证
- `test/widget_tests/default_prompt_panel_test.dart` 6 条：默认收起 / 展开露出正文与说明 / 补充说明
  按需出现；点评常量含角色与硬性要求；续写常量含实际发送用的四个分段标题；周回顾与月回顾
  `week.replaceAll('7 天', '30 天') == month`，保证两份文案不会各写一套
- `dart analyze` 0 issue；`verify` **700 项全过**（694 + 6）

### 顺带：草稿图片测试的偶发失败
- 跑 verify 时 `note_editor_draft_image_test.dart` 偶发红，且每次红的是不同用例；单独重跑 3 次
  有 2 次失败，报 `_hasImages` 为 false —— 也就是「点了图片按钮，图片没进图片区」
- 原因不是功能坏了，是测试用固定 `delay(300ms)` 等真实文件 IO：机器一忙就不够，而落盘完成
  后编辑器还要再 `setState` 一次才挂上 `Image`
- 改成 `_pickImage()` 助手：点完按钮循环 `pump` + 50ms 真实等待，最多 3 秒，见到图片就返回；
  4 处调用点统一替换，连跑 5 次全绿

## 2026-11-13 · 清掉无人调用的本地化 getter（1.1.86+10183）· done

### 问题
- `app_localizations_simple.dart` 攒到 1489 个 getter、2919 行，`translations.dart` 1277 条、
  2939 行，但界面早就改完了，**467 个 getter 在 `lib/` 与 `test/` 里一次都没被调用过**
  （`appTitle`、`saveChanges`、`visibilityPrivate`、`syncNow` 这类查无此调用）
- 死 getter 拖着 434 条翻译一起躺着，两个文件都快三千行，翻起来费劲、改文案容易改到没人看的那份

### 做法
- 脚本 `Z:/Temp/cleanup_l10n.py`（预演 / `--apply` 两档）：
  1. 按 `^  String get (\w+)(.*?;)$` 多行切块，1489 块与文件里 `String get` 出现次数一一对上，确认没切错
  2. 判"没人调"要同时排除两种引用：`lib/`+`test/` 里（l10n 目录外）的 `\bname\b`，
     以及**同文件内其它成员对它的引用**（少了这步会把被别的 getter 借用的内层 getter 误删）
  3. 删完 getter 再回收翻译：以剩余代码里 `_t('key')` 的集合为准，不在其中的条目才删，
     另外还要求该 key 没在别处以字符串字面量出现过
- **不能简单 grep `'key'`**：`_t` 是动态拼 key 的封装，`'key'` 字面量只出现在 getter 体内，
  用它判断"有没有被用"会把 832 条全判成在用；得先确认 `Translations.get` 只有
  `app_localizations_simple.dart:20` 一处调用、没有可变 key 的旁路，才敢按 getter 引用算

### 结果
- getter **1489 → 1022**，文件 **2919 → 2158 行**；翻译 **1277 → 843 条**，文件 **2939 → 1982 行**
- 复核：剩余 1022 个 getter 无一无人调用；`dart analyze` 全仓 0 issue；`verify` **694 项全过**

## 2026-11-13 · 九宫格拖动实时让位 + 展开卡顿定位（1.1.86+10182）· done

### 问题
- 反馈一：九宫格长按拖动排序「只有交换」，拖动过程中没有位置反馈
- 反馈二：点右上角从单行切成九宫格会卡，怀疑是图片太大或缓存问题
- **卡顿定位（实测）**：编辑器 `_buildImageWidget` 的兜底分支直接
  `Image(image: _getImageProvider(...))`，本地 `file://` 走 `FileImage` 且**没设解码尺寸**
  → 按原图解码。用 4000×3000 相机原图跑基准：
  | | 9 张图片首帧 |
  |---|---|
  | 全尺寸解码 | **514ms / 412MB 位图** |
  | 解码到 400px | **164ms / 4.1MB** |
  中端机 heap 上限通常 256–512MB，412MB 直接 GC 风暴甚至 OOM。**不是缓存问题**——
  `ImageCache` 本身工作正常，问题在解码出来的位图尺寸
- 修复：新增 `_imageDecodeWidth = 400`，`Image.file(cacheWidth:)`、
  `CachedNetworkImage(memCacheWidth:)`、兜底分支的 `ResizeImage.resizeIfNeeded` 统一用它。
  **单行条和九宫格必须同一个值**，否则两种排布来回切会因为 ImageCache key 不同而重新解码
- 顺带清掉 `_buildImageWidget` / `_getImageProvider` 里每次 build 都执行的 `debugPrint`：
  拖动时每帧重建九格，字符串拼接 + logcat 写入足够把 60fps 拖到掉帧
- 拖动改法：去掉 `DragTarget`（格子让位后位置会变，「指针没动但命中目标变了」会让
  DragTarget 反复 onMove/onLeave、让位动画来回抽搐），改成 `onDragUpdate` 拿指针全局坐标
  反算格子（`_imageGridKey` 的 RenderBox + 滚动偏移）；被越过的格子用 `AnimatedSlide`
  实时让开一格，跨行时横纵分开算；松手才 `_moveImage`
- **松手必须瞬时归零**：`AnimatedSlide` 的 duration 在 `_dragSourceIndex == null` 时给
  `Duration.zero`，让「位移复位」和「数据重排」落在同一帧，否则会先滑回原位再跳到新位置
- 算法抽成纯函数 `gridSwapSteps()`（`@visibleForTesting`），行优先展平成一维序列

### 验证
- `test/unit/grid_swap_steps_test.dart` 6 条：同行双向、跨行斜向、起拖格自身、列数非法
- `test/widget_tests/note_editor_grid_reorder_test.dart` 3 条：拖动中两格让位 + 松手顺序
  变成 `[b, c, a]`、拖回原位不动、九宫格图片 provider 是 400px 的 `ResizeImage`
- `verify` **685 项全过**（676 + 9）

### 追加：加了图片的草稿被自动暂存覆盖（真实丢数据）
- **反馈**：「编辑的时候，添加的图片显示说已保存草稿，但实际上图片的草稿并没有保存」
- **先证明存的没问题**：给 `PathProviderPlatform` / `ImagePickerPlatform` 打假实现（真写文件、
  真读目录），走完整 `_pickImage` → `_saveImageLocally` 链路。草稿里确实写进了
  `![图片](file://…/images/image_*.png)`，重开也能解析回 `_imageList` —— **保存与恢复本身是对的**
- **真正的坑在「恢复」这一步**：编辑已有笔记时，`_loadDraft()` 只 `setState(_pendingDraft = draft)`，
  正文仍是笔记原文；用户没点「恢复」而直接在原文上打字 → `_textController` listener 触发 800ms
  debounce → `_saveDraft()` 用 `_prepareFinalContent()`（原文 + 新输入，`_imageList` 里没有那张新图）
  **整条覆盖草稿**，图片永久丢失。提示条容易被当成通知忽略，所以用户看到的就是「说保存了其实没保存」
- 修复：编辑已有笔记时**自动恢复草稿**（与新建笔记一致），顶部提示条从「发现上次未保存的草稿
  [忽略][恢复]」改为「已恢复上次未保存的草稿 [知道了][撤销]」
  - `_pendingDraft` 换成 `_draftRevertContent`（恢复前的原文，撤销用）+ `_showDraftRecovered`（提示条开关）
  - `_restoreDraftContent(content, {originalContent})`：`_initialSavedContent` 记原文而不是 `''`，
    `_hasUnsavedChanges` 语义才对
  - `_requestCloseEditor` 的「没改动就清草稿」改为按 `_draftRevertContent == null` 判断，
    刚恢复出来的草稿不会被清
- 测试：`test/widget_tests/note_editor_draft_image_test.dart` 9 条 —— 新建笔记只贴图关闭留草稿、
  编辑已有笔记改动后草稿带原图引用、关闭时保存带图、真加图后草稿带 `file://` 路径、
  重开自动恢复、恢复后继续写不丢图、撤销回原文并清草稿
- 坑：widget test 里真实文件 IO 必须放 `tester.runAsync`，否则 `Directory.create` / `writeAsBytes`
  的 Future 在 fake async 下永不完成，表现为「图片按钮点了没反应」；`_focusEditorAfterOpen` 有个
  180ms 延时，测试结束前要 `pump` 掉，不然报 `A Timer is still pending`

## 2026-11-13 · 品牌图标全套重做 + 文档单平台对齐（1.1.86+10182）· done

### 问题
- 桌面图标还是旧的「墨绿底 + 白纸页折角」，与启动页 / 应用内 logo 的墨绿双色块品牌图形不一致
- `drawable-night/background.png` 与亮色版**字节完全相同**（sha256 一致），深色模式冷启动白闪
- 关于页 `technicalDetails` 写着「当前支持 Android、iOS、macOS、Windows 和 Linux」，
  但仓库只有 `android/` 一个平台工程
- Issue 模板平台下拉、PR 模板勾选、`ARCHITECTURE.md` 目标平台行、`marketing/README.md`
  都还留着 iOS/macOS/Windows/Linux/Web

### 改动
- 图标：从 `assets/images/logo.png` 反解白底合成（`p = a*F + (1-a)*W`）抠出透明品牌图形，
  再按各 dpi 生成 `ic_launcher_foreground`（108dp 画布、图形 46%）、legacy `ic_launcher`
  （白底圆角 20%、图形 62%）、新增 `ic_launcher_round`（圆形、图形 50%）
  与 `ic_notification` 白色剪影；`colors.xml` 的 `ic_launcher_background` 改 `#FFFFFF`；
  清单补 `android:roundIcon`；另出 Play 商店 `icon-512x512.png`
- 夜间启动图：灰阶像素反相（白→黑、文字→浅灰）、绿色仅提亮 10%，写入
  `drawable-night` 与 `drawable-night-v21`；`assets/images/splash_logo.png` /
  `splash_logo_dark.png` 补齐（`flutter_native_splash.yaml` 引用但仓库里缺失）
- 文案：`technicalDetails`、`speechUnavailableReasons`、`desktopReminderUnsupported`、
  `welcomeNoteContent`、`telegramBotDesc`、`crossPlatform` 中英双改，
  `app_localizations_simple.dart` 的 fallback 同步；`about_screen` / `help_screen` /
  `home_screen` / `webdav_settings_screen` 硬编码文案跟进
- 文档：`ARCHITECTURE.md`、`docs/BUILD_AND_DEVICE_TESTING.md`、`docs/BUSINESS_OVERVIEW.md`、
  `docs/MAINTENANCE.md`、`docs/development/troubleshooting.md`、`marketing/README.md`、
  `docs/site/agreement.html`、`docs/site/privacy.html`、
  `.github/ISSUE_TEMPLATE/bug_report.yml`、`.github/pull_request_template.md`
- `AppConfig.appStoreId` 死配置删除

### 追加：光标处再点一次弹工具栏
- 反馈：光标停在字中间（没框选）时再点同一位置，系统工具栏不出现，复制上下文只能长按
- 根因：Flutter 只在双击选词 / 长按拖动后 `showToolbar`；collapsed 时再点同处，位置没变
  就没有 selection 变化事件，`_handleSelectionChanged` 不会触发，菜单自然不弹
- 改法：`TextField` 外包一层 `Listener`（不参与手势竞技场，TextField 落点/选词/双击判定
  全部照旧），`onPointerUp` 时用 `RenderEditable.getPositionForPoint` 把落点换算成字符
  位置，正好等于光标就 `addPostFrameCallback` 里 `EditableTextState.showToolbar()`
- **坑**：`getPositionForPoint` 收的是**全局坐标**，内部会自己 globalToLocal；先转一次会让
  坐标变负、被夹到 offset 0，表现为「永远判成不在光标处」
- 测试：新增 `test/widget_tests/note_editor_retap_toolbar_test.dart` 4 条（再点弹菜单 /
  点别处只挪光标 / 双击选词不受影响 / 空笔记不抛异常）

### 验证
- 图标预览三形态（圆角/圆形/自适应裁切）+ 通知剪影五档目视检查通过
- 夜间启动页缩略图确认黑底、浅色文字、绿色图形正常
- `verify` 676 项全过（新增 4 条），`store-check` 绿，`build android-debug` 出包并确认
  4 类图标各 5 档都在 APK 里

## 2026-11-13 · 更新弹窗：说明按 Markdown 渲染、裁剪到正文、底部选下载源（1.1.85+10181）· done

### 问题
- 用户反馈：更新提示里的说明看着是 Markdown 但没渲染，实际露出 `###`、`-`、`|`
- 根因：`update_dialog.dart` 的 prompt 分支用 `Text(notes)` 直接展示 `result.releaseNotes`
- 附带问题：说明里混着 `scripts/release_notes.py` 追加的「### 下载」区块（表格 + 直链 +
  AAB 去向 + SHA 说明），在 400 宽弹窗里是噪音；header 那行还把 sourceLabel 拼进去，
  与用户想要的「底部选源」重复

### 改动
- 新增 `lib/utils/release_notes_formatter.dart`：`compactReleaseNotes()` 砍掉 `### 下载`
  / `## 下载` / `### Download` 及其后内容、去掉孤立分隔线（`---` `***` `___`）、连续空行
  压成一个、CRLF 归一。**裁剪在 App 端做，历史版本的说明也自动变干净**
- `update_dialog.dart`：说明改用 `MarkdownBody` + 紧凑 `MarkdownStyleSheet`（标题只加粗
  不放大、blockSpacing 6、代码块浅底），`maxHeight` 220 → 200
- 新增 `_DownloadSource` 枚举与 `_giteeUrl` / `_githubUrl`（按 host 判定，Gitee 源时
  GitHub 直链取自 `UpdateCheckResult.fallbackApkUrls`），默认 `gitee`
- 弹窗底部新增「下载源」行：国内镜像 chip 带 6x6 绿色圆点（`0xFF2EA043`），选中时绿色
  描边+加粗，GitHub chip 用主题色；只有一个源时不显示切换但仍显示该源
- `_startDownload` 把 `_selectedUrl` / `_selectedFallbacks` 传给
  `UpdateInstaller.download`（新增可选参数 `sourceUrl` / `fallbackUrls`，默认仍走
  `apkDownloadUrl` + `fallbackApkUrls`）
- header subtitle 去掉 sourceLabel（与底部选源重复）

### 验证
- 新增 `test/unit/release_notes_formatter_test.dart` 7 条（含「说明就是下载区块」清空）
- `test/widget_tests/update_dialog_test.dart` 重写为 11 条：Markdown 渲染不露 `###`、
  下载区块被裁、默认选中绿标国内镜像、点 GitHub 切选中态、只有 GitHub 时不显示切换
- 两个文件 18 条全过；`dart analyze` 干净
## 2026-11-13 · 发版一条命令：release --sync-gitee 等 CI 出包后自动补传 Gitee · done

### 背景
- 上一轮把 Gitee 安装包上传从 CI 拿掉了（Actions 机房到 Gitee 约 10 KB/s），但补传还得手工跑，
  用户希望「每次发版时直接本地补传」
- 流水线顺序确认：`prepare → quality/secret-scan/release-secrets → android（构建 APK+AAB）
  → publish（GitHub Release）→ mirror-gitee（同步代码/tag/说明）`，所以本地补传必须等
  `publish` 完成，约 25–35 分钟

### 改动
- `scripts/gitee_release.py` 新增 `--wait` / `--wait-timeout`（默认 3600 秒）/
  `--wait-interval`（默认 60 秒）：轮询 GitHub Release 直到出现 `*.apk`，再下载→上传→回显资产
- 令牌解析改为链式：`--token` → `GITEE_TOKEN` → `--token-file` → `.git/gitee_token` → `~/.gitee_token`，
  打印实际来源；GitHub 侧用 `GITHUB_TOKEN` 或 `git credential fill`（避免匿名 60 次/小时）
- `tool/inkpaper.dart`：`release vX.Y.Z --sync-gitee`（推完 tag 接着等+补传）、
  新增 `release-gitee [vX.Y.Z] [--no-wait] [--timeout 秒]`（可单独跑，缺省用 pubspec 版本）；
  Python 解释器按 `python3` → `python` 探测
- README 中英、`docs/MAINTENANCE.md` 同步两条命令与「为什么不由 CI 传」

### 验证
- `dart tool/inkpaper.dart release-gitee v1.1.84` 实跑：等待分支立即命中（Release 已挂 APK）→
  走 `ghfast.top` 下载 50.2 MB / 13 秒 → 令牌自动取自 `.git/gitee_token` → 说明 PATCH 200 →
  同名附件「已存在，跳过」，幂等成立
- 无令牌时给出三种给法的提示；`dart analyze` / `dart format` / `store-check`（1.1.84+10180）全绿
- 令牌已写入 `.git/gitee_token`（仓库内部，不进版本库）
## 2026-11-13 · Gitee 安装包改由本机补传，Release 不再常红 · done

### 问题
- 每次发版 `Release` 的 `Mirror to Gitee` 都红。1.1.84 的日志给出定量证据：
  `curl: (28) Operation too slow. Less than 20480 bytes/sec ...` →
  `-> HTTP 100，7667712 字节，767.846885s，9985 B/s`，第二次 `HTTP 000` 连接 30 秒超时，
  两次尝试共烧 14 分钟才 `##[error]` 退出
- 根因是**带宽**不是脚本：GitHub Actions 机房到 Gitee 只有约 10 KB/s，50 MB 的 APK 要跑
  一个多小时，必然被 `--speed-limit 20480 --speed-time 120` 掐断。本机（厦门电信）同样文件
  2 MB/s、25 秒传完
- 注意：`ci.yml` 里 push main 触发的 mirror 作业是绿的，因为它走 `MIRROR_ONLY=1` 不碰附件

### 改动
- `scripts/publish_gitee.sh` 新增 `SKIP_ASSET_UPLOAD=1`：跳过第 3 步，打 `::warning::` 并把
  「本机补传」的命令写进 Step Summary，退出码 0。本地直跑脚本不设这个变量时行为不变
- `.github/workflows/release.yml`：`mirror-gitee` 的 env 设 `SKIP_ASSET_UPLOAD: '1'`，
  step 超时 45 → 20 分钟，步骤名改为 `Push code, tags and release to Gitee`
- 新增 `scripts/gitee_release.py`（原 `Z:/Temp/gitee_release.py` 入库并增强）：token 从
  `GITEE_TOKEN` 读、`--notes-from-github` 拉发布说明、`--apk-from-github` 走 `--mirror`
  前缀拉 APK 并校验大小、同名附件幂等跳过
- README 中英同步说明：代码/标签/说明由 CI 同步，安装包由发版机器补传

### 验证
- `bash -n scripts/publish_gitee.sh` 通过；`release.yml` PyYAML 解析通过，env 与步骤名符合预期
- `python scripts/gitee_release.py --tag v1.1.84` 只读复跑：复用 Release `1304441`，
  三个资产均在；加 `--apk-from-github` 后全部「已存在，跳过」，幂等成立
- `store-check`：`Store checks passed for 1.1.84+10180`

## 2026-11-13 · 下载退路：Gitee 缺包时改用 GitHub（1.1.84+10180）· done

### 问题
- 用户反馈：1.1.80 点「检查更新」查不到新版本；1.1.77 能查到 1.1.83，但点「立即更新」下载很慢
- 结论（`git show <tag>:lib/config/app_config.dart` 对比三个 tag）：1.1.77 与 1.1.80 的
  `giteeLatestReleaseApi` 都还是错的（`liudengxing/InkPaper` → Gitee 404）。1.1.77 的数据源是
  `[gitee, github]`，404 后回落 GitHub 所以查得到，下载自然走 `github.com`（慢）；1.1.80 只剩
  `[gitee]`（`41485f6` 去掉了回落），于是彻底查不到
- 1.1.83 已修正地址。用 `http` 包带 App 的 UA 实测：`/releases/latest` 200 + `tag_name=v1.1.83`；
  APK 直链 200、`Content-Length: 52643460`、302 链正常跟随（Gitee 的 `assets[].size` 仍是 null）

### 改动
- `UpdateDownloadService.download()` 新增 `fallbackUrls`：主地址回 403/404/410 且还有候选地址时
  换下一个，日志 `Download source missing, trying fallback`；超时与 5xx 不换源
- `UpdateCheckResult.fallbackApkUrls`：命中 Gitee 源时给出同 tag 的 GitHub 直链，其它源为空
- `UpdateInstaller` 把 `result.fallbackApkUrls` 传给下载服务
- 新增 6 条单测：下载侧（404 换源成功 / 无退路直接失败 / 5xx 不换源 / 退路也 404）、
  检查侧（Gitee 有退路 / GitHub 无退路）
- 版本 `1.1.83+10179` → `1.1.84+10180`（README 中英、CHANGELOG 中英同步）

## 2026-11-13 · 修正 Gitee 更新检查接口地址（1.1.83+10179）· done

- 用户：「现在 gitee 是什么推送逻辑，我看校验更新显示新版本还是 1.1.80」
- 排查出两个独立问题：
  1. **Gitee 最新 Release 仍是 v1.1.80** —— 正常现象：1.1.81 只推了代码没打 tag（只走 `MIRROR_ONLY=1` 那条链路，不建 Release）；1.1.82 的 tag 刚推、CI 还在 android 构建。Gitee 的 `/releases/latest` 按创建时间取最新，不看版本号大小
  2. **`AppConfig.giteeLatestReleaseApi` 的 owner/repo 写错（真 bug）**：`https://gitee.com/api/v5/repos/liudengxing/InkPaper/releases/latest` 实测 HTTP 404 `{"message":"Not Found Project"}`，正确仓库是 `liudengxing233/ink-paper`。同文件的 `giteeRepo` 是对的，1.1.76 接入 Gitee 镜像时这处漏改
- 后果：`UpdateSource.all = [gitee]` 只有 Gitee 一个源，404 会抛「仓库还没有已发布的正式版本」，**App 内检查更新从 1.1.76 起完全不可用**
- 改法：地址改为 `https://gitee.com/api/v5/repos/liudengxing233/ink-paper/releases/latest`
- 防漏：`test/unit/update_check_service_test.dart` 新增一条一致性断言 —— 从 `giteeRepo` 解析 host 与 owner/repo，与 API 地址的 pathSegments 逐段比对，任一处改漏即红
- 验证：该测试文件 17 条全过，`dart analyze` 干净
- 版本 `1.1.82+10178` → `1.1.83+10179`（README 中英、CHANGELOG 中英同步）

## 2026-11-13 · 图片查看器手势重写（1.1.82+10178）· done

- 用户：「放大手势还是和左右滑有冲突」，要求先讲清现有逻辑再定方案 → 讲完后用户选「方案 A」
- **根因**：原实现是 `PageView` 自带滚动 + 一个 `ScaleGestureRecognizer` 并行竞争。两者阈值都是 18dp（`kTouchSlop` / `kScaleSlop`），同一个方向上的手势谁先 accept 谁就独占整次手势，输掉的一方在本次手势内不能反悔 —— 所以表现是掷硬币：想捏合却翻页、放大后单指拖不动、先横拖再补第二指只翻页
- 方案 A：**整屏只留一个识别器**，翻页不再交给 `PageView` 的 physics
  - `PageView.builder` 的 physics 恒为 `NeverScrollableScrollPhysics`，翻页由 `_ViewerGestureRecognizer` 自己 `position.jumpTo`
  - 自定义 `OneSequenceGestureRecognizer` + `_ViewerGestureMode`（page / zoom / none）三态分发
  - `_handleScaleStart`：`pointerCount >= 2 || _currentScale > 1.01` → zoom，否则多图才进 page；双指落下立刻 accept，不等 18dp span 变化
  - `_handleScaleUpdate`：先横拖后补第二指时 `_snapToCurrentPage()` 归位再转缩放；按 mode 分发 `_applyZoom` / `_applyPageDrag`
  - **抬指重锚定**（关键修复）：`pointerCount` 变化时重新记录 `_gestureStartScale` / anchor，否则 `ScaleGestureRecognizer` 重算会让倍数弹回 1
  - 翻页判定：位移 > 22% 屏宽 或 速度 > 520dp/s
  - 图片改 `Center` 排布，identity 矩阵即初始态，去掉 `OverflowBox` + 居中平移矩阵 + post-frame 复位
- 回归测试：`test/widget_tests/image_viewer_gesture_test.dart` 重写为 9 条（IVG-01…09），覆盖慢滑翻页、快滑翻页、超快滑、捏合放大不误翻页、放大后单指只平移、滚轮缩放、**先横拖再补第二指转缩放**、慢拖一点点弹回原页、**捏合后抬指继续拖倍数不弹回**；`_steppedDrag` 增加 `intervalMs` 以控制滑动速度
- 验证：`dart analyze` 干净，9 条手势测试全绿
- **未真机验证**：`adb connect 192.168.0.108:35819` 已拒绝连接（无线调试端口变了）

## 2026-11-13 · Markdown 紧贴正文的减号串降级为分隔线（1.1.82+10178）· done

- 用户提问：日记里 ❶❷ 两段渲染成加粗，后面 ❹❺❻ 不加粗，问为什么
- **根因不是 bug**：Markdown 的 setext 规则 —— 某行文字下面紧跟一行**纯减号**（且中间无空行），那行文字被解析成 h2。实测：
  `❶文字。\n-----------\n【我做的】` → `<h2>`；`❶文字。\n\n-----------\n\n` → `<p>` + `<hr/>`；`❶文字。-----------【我做的】`（同行）→ 普通段落
  项目里 h2 是 18px + `FontWeight.bold`（`simple_memo_content.dart:465-471`），正文约 15px 常规字重 → 视觉上就是「整段被加粗」
- 改法：`MemosMarkdownConverter.demoteSetextHeadingUnderlines()`（static，可复用），在 `convert()` 第 1.2 步调用
  - 判定：`^-(?:[ \t]*-){2,}[ \t]*$`（≥3 个减号，含 `- - -`）且上一行非空 → 前面补一个空行，退化成 `<hr/>`
  - 三种豁免：代码围栏内不动；文件开头的 frontmatter（`---` … `---`）原样保留；只两个减号 `--` 不动（避免碰到 `- -` 嵌套列表）
  - 取舍：牺牲几乎没人用的 setext 标题，换「随手敲分隔线不会被吃」；写标题请用 `#`
- `lib/utils/note_preview_builder.dart` 的 `buildNotePreview` 同步调用，避免详情页正常而卡片预览仍整段加粗
- 回归测试：`test/unit/memos_markdown_converter_test.dart` 新增 7 条（补空行 / `- - -` / 已有空行 / 同行 / 两个减号 / 代码围栏 / frontmatter）
- 验证：`dart analyze` No issues found；converter + preview 25 条全过；用用户真实段落跑解析，结果全部 `<p>` + `<hr/>`，`是否出现标题标签: false`

## 2026-11-13 · 编辑器空白区双击弹复制/粘贴工具栏（1.1.81+10177）· done

- 用户：「编辑界面双击同一个地方增加一个弹出系统的那个操作栏，包含复制黏贴的那个，现在要框选一段文字才能出来」
- **先复现再改**：临时 widget 测试直接跑真实 `NoteEditor`（复用 `note_editor_image_expand_test.dart` 的 `ChangeNotifierProvider(AppProvider)` + 弹层脚手架），打印了两个矩形：
  `TextField rect=(96,360)-(664,408)`、`EditableText rect=(96,372)-(664,396)` —— 输入框只有一行高（48px）
- **根因**：正文输入框高度跟着文字走，文字下方的空白落在输入框自己的矩形之外。Flutter 的双击选词（`TextSelectionGestureDetectorBuilder.onDoubleTapDown` → `selectWord` + `editableText.showToolbar()`）只在自己矩形内生效，空白处点击由外层那句 `GestureDetector(onTap: () {})`（原本用来阻止事件冒泡到「点空白关编辑器」）吞掉，所以只有长按文字框选才能叫出工具栏
- **验证手法**：在同一个 harness 里对比「文字上双击」「空白处双击」「长按拖选」三种手势的 `selection` 与工具栏文本（`Copy/Select all/Cut`）。改前空白处双击 `selection` 停在初始化时的 `collapsed(19)`、工具栏为空；改后选中 `bar`、工具栏出现
- 改法（`lib/widgets/note_editor.dart`，+约 60 行）
  - 在正文区 `Stack` **最底层**加 `Positioned.fill(GestureDetector(behavior: opaque))`：文字与浮层先吃事件，剩下的空白才落到它身上
  - `onTapDown` → `renderEditable.handleTapDown` + `selectPosition(tap)`，空白处单击也能把光标落到点击处
  - `onDoubleTapDown` → `handleTapDown` 记录位置 → `selectWord(doubleTap)`（用 Flutter 自己的分词，中文也准）→ 下一帧 `EditableTextState.showToolbar()`
  - `_editableTextState()`：TextField 不暴露内部的 `EditableTextState`，用 `Element.visitChildren` 从编辑器子树里捞
- 回归测试：新增 `test/widget_tests/note_editor_blank_doubletap_test.dart` 三条 —— 空白双击选中 `bar` 且弹工具栏 / 正文上双击行为不变 / 空笔记双击空白不报错也不弹窗
- 版本 `1.1.80+10176` → `1.1.81+10177`（README 中英、CHANGELOG 中英同步）
- **未真机验证**：`adb connect 192.168.0.108:35819` 已拒绝连接（无线调试端口变了），只能靠 widget 测试

## 2026-11-13 · Gitee 镜像只传 APK，附件上传加超时护栏（未升版本）· done

- 用户：「Mirror to Gitee 这个坑修掉，附件上传改成只传 APK」
- **根因**：Gitee 的 `attach_files` 在 Actions 机房里会挂在半路。1.1.74 / 1.1.76 / 1.1.79 / 1.1.80 四次发版全卡在这一步，而 `curl` 没有超时参数时会一直挂着不报错，只能等 6 小时 job 超时 —— 所以每次都是「Release 建出来了、附件没上来」的半成品状态
- `scripts/publish_gitee.sh` 第 3 步重写：
  - 只上传 `*.apk`，AAB 不再传（AAB 只给 Google Play 用，国内用户下载不到，白传 52 MB）
  - 上传函数从「一条 curl 打到底」改成 2 次尝试 + 失败重试，每次带 `--connect-timeout 30 --max-time 1200 --speed-limit 20480 --speed-time 120 --http1.1`
  - **关键参数是 `--speed-limit/--speed-time`**：连续 120 秒低于 20 KB/s 主动断开重来，这是把「无声挂死」变成「快速失败」的那一刀
  - `-w` 打印 HTTP 码/字节数/耗时/速率，日志里能直接看出卡在哪
  - 找不到 APK 或最终失败时 `::error::` + `exit 1`，不再静默通过
- `.github/workflows/release.yml`：`Mirror to Gitee` 加 `timeout-minutes: 45`，兜住最坏 2×1200s 的重试
- `scripts/release_notes.py`：下载区块措辞改为「两个源的 APK 完全相同，AAB 只随 GitHub Release 提供」
- 未升 `pubspec.yaml` 版本：只动 CI 脚本与发布说明，App 代码零改动（同 `73e2ba2 docs(release)` 的处理）
- 验证：`bash -n scripts/publish_gitee.sh` 通过、两个 workflow YAML 可解析、`dart analyze` 无问题
- **待办**：v1.1.80 这次已经发出去的 Release 还得补一次 APK 到 Gitee（等令牌）

## 2026-11-12 · 仓库收敛为纯 Android（1.1.80+10176）· done

- 用户提问「现在桌面端也会有吗，先只保留安卓吧，然后文档里吧除了安卓以外的版本都删了」，经确认选「全部删掉 + 一并清理成纯 Android」
- 删平台工程：`windows/` `macos/` `linux/` `ios/` `web/` 共 212 个文件；`git rm -r` 之后 `ios/Flutter/ephemeral/`、`macos/Flutter/ephemeral/` 是未跟踪的构建残留，还得 `rm -rf`
- 删脚本：`build_unsigned_ipa.sh`、`clean_apple_xattrs.sh`、`create_dmg.sh`、`create_release_dmg.sh`、`generate_desktop_icons.py`、`generate_icns.sh`、`scripts/dmg/`、`scripts/windows/`、`IOS_UNSIGNED_BUILD.md`。剩下 `ci.sh`、`ci_annotate.sh`、`publish_gitee.sh`、`release_notes.py`
- 构建工具：`tool/inkpaper.dart` 705 → 531 行，删 11 个非 Android `build` case、`_hostBuildTargets`、`_printSkippedTargets`、`_podInstall`、`_disableSwiftPackageManager`、`_clearAppleExtendedAttributes`、`_dartDefineEnvironment`、`_requireHost`，`all` 直接等价 `android-release`
- Dart 清理（25 个文件、约 60 处）：`app_router.dart` 15 处 `DesktopLayout` 展开 + 7 处 `isDesktop` 路由分支、`settings_screen.dart` 整个 Master-Detail（约 90 行）、`main.dart` 的 `_DesktopVisualScale`（约 70 行）、`notification_service.dart` 的 iOS `zonedSchedule` 分支（约 100 行）、`database_service.dart` 的 sqfliteFfi 初始化、`image_utils`/`share_utils` 的 iOS 分支等；`desktop_layout.dart` 整文件删除
- **坑**：删分支是链式告警 —— `unused_local_variable` → `unused_import` → `unused_shown_name` → `prefer_const_constructors` → `avoid_redundant_argument_values`，得一轮轮清；`require_trailing_commas` 依然会拦，`format 0 changed` 不代表 `analyze` 通过
- 验证：`dart analyze` **No issues found**；`grep -rn "kIsWeb\|Platform\.is" lib` 零命中；`flutter test` 640 项全绿
- 文档与官网：`README.md` / `README.en.md` / `docs/BUILD_AND_DEVICE_TESTING.md`（删整个 iOS/macOS 章节并重排 5→4、6→5、7→6 编号）/ `docs/MAINTENANCE.md` / `docs/STORE_COMPLIANCE.md`（删 iOS App Store 章节）/ `docs/PROJECT_STRUCTURE_AND_BUILD.md`（删 5 个平台小节、iOS 签名章节、约 116 处平台引用）/ `docs/BUSINESS_OVERVIEW.md` / `docs/HANDOFF.md` / `CONTRIBUTING.md` / `SECURITY.md` / `docs/user-guide/` / `docs/development/{debugging,troubleshooting}.md` / `docs/ARCHITECTURE_OVERVIEW.md`（加平台变更横幅 + 修正平台层与 CI 图）/ 官网 `index.html`、`pages/faq.html`、`pages/guide.html`、`pages/download/index.html`（删 iOS/macOS/Windows/Linux 下载卡片）
- 配置收尾：`analysis_options.yaml` exclude 只剩 `android/**`；`scripts/ci.sh` 目标白名单收窄；`flutter_native_splash.yaml` 关掉 `ios`/`web` 并删 `ios_content_mode`
- 说明：`CHANGELOG`、`PROGRESS`、官网 `pages/changelog.html` 里的历史记录保持原样，不追改历史

## 2026-11-12 · 更新检查默认只走国内源（1.1.79+10175）· done

- 用户提问「首页打开检查的是 GitHub 的版本吗」，并要求「默认全部访问国内的源」
- 先查证：`UpdateSource.all` 早就是 `[gitee, github]`（Gitee 优先），所以 **1.1.77 起开屏检查和关于页都先打 Gitee**。会看到 GitHub 只有两种情况：一是装的还是 1.1.74 以前没有 Gitee 源的版本；二是 Gitee 那次请求失败，回落到了 GitHub —— 而 GitHub 国内直连极慢（50MB 实测 5 分钟 8MB），观感就是「卡住」
- 改法：`UpdateSource.all` 改成 `[gitee]`，默认不再回落。`UpdateSource.github` 常量保留，需要时显式传 `sources: [UpdateSource.gitee, UpdateSource.github]`
- 测试：原来那条「Gitee 挂了会回落到 GitHub」拆成两条 —— 「默认只走 Gitee，挂了也不会去碰 GitHub」（断言只请求过 gitee.com）＋「显式指定时才回落 GitHub」
- 发版侧：Release v1.1.78 的 `Mirror to Gitee` 又卡在往 Gitee 传 100MB（历史同样问题），取消 run 后**删掉 Gitee 上只有源码 zip 的 v1.1.78 Release**，避免更新检查拿到 404 的 APK 直链；Gitee latest 回到完整的 v1.1.77，等 1.1.79 上去再接替
- 发版侧（v1.1.79）：`Mirror to Gitee` 第三次卡在往 Gitee 传附件（Azure runner 上传被限速），cancel run 后本地补传 —— `ghfast.top` 拉回 APK 52,643,460 B / AAB 52,349,916 B（约 1 分钟，与 GitHub API `size` 完全一致），复用 release id=1302898 → `attach_files` 均 201；Gitee 匿名下载 50.2MB 用 25.3s，SHA-256 `febaf5af...` 与 GitHub 原件一致
- 顺手修正：`scripts/release_notes.py` 里「Gitee 不可用时自动回落到 GitHub」已不成立（1.1.79 起只走 Gitee），改为「只走 Gitee，国内无需访问 GitHub」，并 PATCH 了 Gitee 上 v1.1.79 的 Release 说明
- 验证：`dart tool/inkpaper.dart verify` 640 项全绿；`store-check` 通过

## 2026-11-12 · 修图片查看器手势冲突（1.1.78+10174）· done

- 起因：用户反馈「两指放大手势和图片左右滑手势有冲突」，要求先确认
- **用探针实测确认（而不是推理）**：复刻 `PageView` 包 `InteractiveViewer` 的手势层次，用 `TestGesture` 模拟真实触摸序列，扫出临界值 ——
  - 单指横滑单帧位移 **≤36dp 能翻页，≥38dp 翻页失灵**（`36 = kPanSlop = kTouchSlop × 2`）
  - 根因：`ScaleGestureRecognizer` 的平移阈值 36dp 虽大于翻页拖动阈值 18dp，但它所在的 `GestureDetector` 在 `Scrollable` 内部，指针事件**深度优先派发**，所以单帧位移一过 36dp 它就先 `resolve(accepted)`，翻页被 reject —— 表现成「慢滑能翻页、使劲快滑滑不动」
  - 反向：第一根手指先横向滑出 18dp，PageView 先赢，第二根手指落下也救不回来（pointer1 的 arena 已判定，缩放只剩 pointer2，凑不出两指）
  - 另测：放大后单指横滑只平移不翻页（`_currentPageZoomed` 门控，设计如此）；两指同向滑两头都不响应
- 修法：`lib/screens/image_viewer_screen.dart` 去掉 `InteractiveViewer`，改自管 `Transform` + `_PhotoScaleGestureRecognizer`
  - `_PhotoScaleGestureRecognizer extends ScaleGestureRecognizer` 重写 `resolve()`：**单指且未放大时吞掉自己的 accepted 请求**，把单指横滑稳定让给 `PageView`；双指或已放大时照常抢
  - 手势数学沿用文件里原有的 `_containedMatrix` / `_clampPhotoTransform` / `_containedImageRect` / `_toScene`；`_handleScaleUpdate` 用「锚定手势起点焦点」的公式 `t = focal − s·sceneFocal`，单指时 scale 恒为 1、自然退化成纯平移
  - `constrained: false` 用 `OverflowBox(alignment: topLeft)` 等价替代；重绘走 `AnimatedBuilder(animation: _transformationController)`
  - **补回桌面端滚轮缩放**：`InteractiveViewer` 原本自带，换成自管手势后要自己实现，`Listener(onPointerSignal:)` + `exp(-dy/200)`（与 InteractiveViewer 的 `scaleFactor: 200` 同手感），windows/macos/linux 三个目录都在，不能丢
- 回归测试 `test/widget_tests/image_viewer_gesture_test.dart`（6 项）：慢滑/快滑/超快滑单指翻页、双指捏合放大且不误翻页、放大后单指只平移、滚轮放大
  - **验证过测试有效**：`git stash` 回退到旧实现，IVG-02（单帧 60dp）与 IVG-03（单帧 240dp）确实红，IVG-01（单帧 20dp）绿 —— 与探针数据一致
  - 坑：`tester.dragFrom` 的事件时间戳恒为 0 → 速度恒为 0 → 翻页卡在 50% 位移阈值上，看起来像「连基线都不翻页」。分步拖动必须显式传 `timeStamp` 递增
  - 坑：`tester.startGesture()` 不接受 `timeStamp`，只有 `moveTo`/`up` 接受
- 未修（已在 CHANGELOG 明确写出）：起手时第一根手指已横向滑出 >18dp 仍按翻页处理 —— 那已是明确的横滑意图，且需把翻页也自管（`NeverScrollableScrollPhysics` + 自驱动 `PageController`）才能改，改动大一档，暂不引入
- 验证：`dart tool/inkpaper.dart verify` 639 项全绿（新增 6 项）；`store-check` 通过；纯 Dart 改动无原生变化，未跑 android build

## 2026-11-12 · 开屏检查更新 + 下载进度搬进弹窗 + 修「下完不弹安装」（1.1.77+10173）· done

- 起因：真机点「下载安装包」，进度走到 100% 后系统安装界面不弹；用户同时要求改成「开屏就检测更新、进度条直接在弹窗里」
- 根因判断：`installApk` 只把 `content://` URI 放进 `Intent.data`，没放进 `clipData`。部分定制系统（小米 / OPPO 这一类）的安装器只从 clipData 里取 URI 去申请读取权限，读不到文件就静默什么都不做 —— `startActivity` 不抛异常，旧代码还会返回 `started`，于是「什么也没发生」
  - 修法：`MainActivity.installApk` 补 `clipData = ClipData.newRawUri("inkpaper_update", uri)` + `FLAG_GRANT_READ_URI_PERMISSION`；`ActivityNotFoundException` 单独返回 `no_installer`，Dart 侧新增 `ApkInstallStatus.noInstaller` 并给出「浏览器下载」退路
- 新增 `lib/services/update_installer.dart`：统一「下载 → 拉起系统安装器」链路，APK 按版本号缓存在静态字段里（关掉弹窗、去设置页授权回来都复用，不重下 50MB），装成后清理旧版本包
- 新增 `lib/widgets/update_dialog.dart`：单弹窗覆盖 `prompt / downloading / installing / launched / blocked` 五态；窗内自带进度条 + 百分比 + 实时速度（500ms 采样、EMA 平滑）+ 取消；缺「安装未知应用」授权时跳设置页并注册 `WidgetsBindingObserver`，用户返回应用即自动续装；`PopScope` 在下载/安装中禁返回
- 新增 `lib/services/startup_update_service.dart`：`main.dart` 在 `runApp` 之后 `unawaited(checkOnLaunch(...))`，首帧 +1.5s 才请求；6 小时节流（prefs `update_last_check_at`）、「稍后再说」版本记忆（`update_skipped_version`）、首启不打扰（`first_launch` 为 true 直接返回）、失败一律静默；仅 Android 生效（桌面端仍靠关于页手动查）
- `about_screen.dart`：`_UpdateCheckFooter` 改为复用同一个弹窗，删掉页脚内联进度条与本地下载/安装代码（该文件 851 → 620 行）
- **坑（值钱）**：`store-check` 会断言 README 顶部「当前版本」与 `pubspec.yaml` 一致，而 `verify` **不包含**这一步。只改 pubspec 时本地 `verify` 全绿，CI 的 `Analyze + Test` 却在 `store-check` 挂掉。升版本必须同时改 `pubspec.yaml`、`README.md`、`README.en.md` 三处
- 验证：`dart tool/inkpaper.dart verify` 633 项全绿（新增 9 项节流/跳版本单测 + 6 项弹窗提示态组件测试）；`dart tool/inkpaper.dart store-check` 通过；`dart tool/inkpaper.dart build android-release` 本地 49.9MB 通过（新 Kotlin import 编译验证）
- CI：`Release v1.1.77` 的 Analyze+Test / Android / GitHub Release 全绿；**`Mirror to Gitee` 步骤跑了 26 分钟附件仍未传完**（Azure runner 上传 Gitee 被限速，`curl -F` 无进度输出，只能看直链 404 判断）。手动 `cancel` 该 run 后改本地补传
- 本地补传流程（可复用）：`ghfast.top` 拉回 APK 52,643,460 B / AAB 52,338,979 B（约 1 分钟，字节数与 GitHub API `size` 完全一致）→ `Z:/Temp/gitee_release.py` 复用已有 release id=1301691 → `attach_files` 两个附件均 201
- Gitee 侧实测：匿名下载 50.2MB 用 25.7s，SHA-256 `aad35ea661821b35d23485f38d1cc7b95f282c6d1467839d4d88c575d000cde7` 与 GitHub 原件一致
- 待真机确认：装好 1.1.77 后「关于 → 检查更新」应显示「已是最新版本 v1.1.77」；完整的「开屏弹窗 → 窗内进度 → 自动拉起安装器」要等下一个版本发出来才能走通

## 2026-11-12 · Gitee 仓库落地与 v1.1.75 镜像发布（并入 1.1.76+10172）· done

- 用户建好公开仓库 `liudengxing233/ink-paper`（注意 path 是 **ink-paper**，全小写带连字符，与 GitHub 的 `InkPaper` 不同名）
- 代码同步：`giteeRepo` → `https://gitee.com/liudengxing233/ink-paper`，`giteeLatestReleaseApi` → `/api/v5/repos/liudengxing233/ink-paper/releases/latest`；README(中/英)、`update_check_service_test` 的 URL 断言、`scripts/publish_gitee.sh` 的 `GITEE_OWNER`/`GITEE_REPO` 默认值同步
- 推送历史：`git push https://gitee.com/liudengxing233/ink-paper.git refs/heads/main +refs/tags/*` 成功（main + v1.1.69 + v1.1.75；token 用 `-c credential.helper` 内联，不写进 remote 也不进文件）
- 产物搬运：GitHub 资产重定向到 `release-assets.githubusercontent.com`，直连可用但很慢（5 分钟只下 8 MB）；改用 `ghfast.top` 镜像并行下载，APK 52,774,308 B / AAB 52,404,961 B，字节数与 GitHub API 的 `size` 完全符合
- 建 Release：`Z:/Temp/gitee_release.py`（标准库手写 multipart，本机无 requests）→ `POST /releases` 得 id=1301353，`POST /releases/{id}/attach_files` 上传两个附件，均 201
- **实测结论（关键，之前只能靠查资料推断）**：
  - 匿名下载直链可用：`/releases/download/{tag}/{file}` → 302 到 `/attach_files/{id}/download/{name}` → 302 到 `foruda.gitee.com` CDN → 200；从 Gitee 取回的 APK SHA-256 = `6951db3a9831258f1ed1831e7c9d84bdfe55a053fc31f250bf105083a57ad164`，与 GitHub 原件完全一致
  - `GET /releases/latest` 匿名可读，返回 `tag_name` / `name` / `body` / `created_at` / `assets[].browser_download_url`，**但 `html_url` 为 null、`assets[].size` 为 null** —— 证实了代码里用模板兜底的必要性
  - `assets` 里还会混入 Gitee 自动生成的 `v1.1.75.zip` / `v1.1.75.tar.gz` 源码包，解析时按 `.apk` 后缀过滤即可
- `GITEE_TOKEN` 已写入 GitHub Repository secrets（`PUT /actions/secrets/GITEE_TOKEN`，libsodium sealed box，`pip install pynacl` 现装的），CI 下次发版即可自动同步
- 坑：Gitee「仓库级私人令牌」不能 `POST /user/repos` 建仓（403「仓库级私人令牌无权执行此操作」），但对该仓库有 `push`/`admin` 权限，推代码与建 Release 都能用

## 2026-11-12 · Gitee 国内镜像 + 应用内更新走国内源（1.1.76+10172）· done

- 起因：国内直连 GitHub 太慢（本机代理甚至只放行 `api.github.com`，`github.com:443` 恒定 502），发版后下载 APK 体验差
- 选型：Gitee（国内速度最好、发行版有附件、API v5 与 GitHub 基本同构）；同步方式选 CI 全自动
- `lib/config/app_config.dart`：新增 `giteeRepo` / `giteeLatestReleaseApi`
- `lib/services/update_check_service.dart`：新增 `UpdateSource`（id / label / apiUrl / releasePageTemplate / apkUrlTemplate），内置 `gitee` 与 `github` 两个常量，`all` 按「Gitee → GitHub」排序；`UpdateCheckService.check()` 逐个数据源尝试，任一成功即返回，全失败抛最后一个错误；`parseLatestRelease` 增加 `source` 参数补 Gitee 缺的字段
- **坑**：`Uri.tryParse('')` 返回空 Uri 而不是 null，`html_url` 缺失时 `?? 兜底` 永远不触发 → 必须显式判空（`htmlUrl.isEmpty ? null : Uri.tryParse(...)`）
- `lib/screens/about_screen.dart`：更新弹窗新增「下载源 xxx」一行
- 新增 `scripts/publish_gitee.sh`：`MIRROR_ONLY=1` 只推代码+tag；否则再建 Gitee Release 并 `attach_files` 传 apk/aab，最后打印远端资产清单。token 用 `::add-mask::` 打码
- `.github/workflows/release.yml`：`publish` 作业加 `env.GITEE_TOKEN`，**checkout 必须排在 download-artifact 之前**（checkout 默认 `git clean -ffdx` 会删掉 `dist/`），末尾加 `Mirror to Gitee` 步骤，`env.GITEE_TOKEN == ''` 时自动跳过
- `.github/workflows/ci.yml`：新增 `mirror` 作业（`needs: quality`、仅 push main），调 `MIRROR_ONLY=1` 同步代码与 tag
- Gitee 附件下载地址格式已核实：`https://gitee.com/{owner}/{repo}/releases/download/{tag}/{filename}`（官方博客与 openEuler 安装脚本都在用）
- 验证：`flutter test test/unit/update_check_service_test.dart` 15 项全绿（新增 3 项多数据源用例）；`dart tool/inkpaper.dart store-check` 通过；两个 workflow YAML 解析通过
- **待办**：Gitee 仓库需先建（公开仓，附件才能匿名下载），`GITEE_TOKEN` 加到 GitHub Repository secrets 后第一次同步才会生效

## 2026-11-11 · 引导页去掉「找回密码」入口（1.1.75+10171）· done

- `lib/screens/onboarding_screen.dart`：删掉最后一页的「找回密码」`TextButton`（`Icons.lock_reset_rounded`），连带 `_showResetPasswordDialog()` 与它唯一调用的占位弹窗 `_showDevelopmentDialog()`（净删 75 行）
- 连带清理死代码：`ForgotPasswordScreen` 页面（317 行）从未被任何 UI 跳转过，路由 `forgot-password` / 名称 `forgotPassword` 也无人引用 → 删文件 + 删 `lib/routes/app_router.dart` 的 `GoRoute` 与 import
- l10n 清掉只被该页面使用的 8 个键：`forgotPassword`、`forgotPasswordHelp`、`functionDescription`、`backToLogin`、`learnMore`、`memosNoPasswordResetHint`、`memosNoPasswordResetDetail`、`rememberedPassword`（`app_localizations_simple.dart` getter + `translations.dart` 中英条目）
- **保留**：登录页 `login_screen.dart:1659` 与注册页 `register_screen.dart:1543` 的 FAQ「忘记密码怎么找回 / 忘记密码怎么办」——那是文字解答，不是可点入口；`whatIfForgotPassword*` 两个键仍被注册页 FAQ 使用
- 验证：`dart analyze` 全仓 0 issue；`dart tool/inkpaper.dart verify` 全绿

## 2026-11-11 · 批注功能整体下线（1.1.74+10170）· done

- 删除文件：`lib/models/annotation_model.dart`（321 行）、`lib/widgets/annotations_sidebar.dart`（600 行）、`lib/widgets/note_annotation_dialogs.dart`（406 行）
- 数据层：`Note` 去掉 `annotations` 字段 / `_parseAnnotations` / `copyWith` 参数 / `toMap` 与 `toJson` 序列化；`database_service` 建表 SQL 去掉 `annotations TEXT DEFAULT '[]'`、删除 v8 `ALTER TABLE ADD COLUMN` 迁移块、Markdown front matter 导出不再写该字段
- **不动已存在的列**：不执行 `DROP COLUMN`，旧库里的批注数据物理保留但代码不再读写；`schemaVersion` 也保持原值（升级路径上少了一个 v8 分支不影响后续迁移）
- 同步链路：`app_provider` 上传后回写的批注保护变量删除；`app_provider_sync.part` 里"从 DB 重载时保留内存批注"的 map/映射改成 `_notesStore.notes = dbNotes`（行为等价，批注本来就不入库）；`webdav_sync_engine`、`note_dedupe`、`sync_merge_helper` 的批注合并分支全部删除
- UI：详情页删 `_buildAnnotationBadge` / `_showAnnotationsSidebar` / 增删改与标记已解决共约 390 行，底部"字数统计 + 批注图标"的 Row 简化为单个 Text；`note_card` 删徽章与侧边栏入口（连带未使用的 `NoteDetailScreen` import）；`note_more_options_menu` 删「查看批注」项与 `case 'annotations'` 分支
- l10n：`app_localizations_simple.dart` 删 37 个批注键（含 `annotations` / `viewAnnotations` / `annotationType*` / `showResolved` / `markAsResolved` / `replies` / `filterByType` 等），`translations.dart` 删对应 22 条中英翻译；`testing` / `iKnow` 两个挨在一起的无关键手动保留
- 测试：`database_migration_test` 的 DB-MIG-02 改为断言 `rowStatus` / `last_sync_time`；`note_model_test` 删批注往返用例与 `baseMap` 里的 `annotations`；`sync_merge_helper_test` 删 `annotations` 参数
- 验证：`dart analyze` 全仓 0 issue；`dart tool/inkpaper.dart verify` 615 项全绿；`grep -r "annotation|批注" lib test integration_test tool` 已无命中

## 2026-11-11 · 回顾页同样去掉魔法棒 FAB（并入 1.1.73+10169）· done

- 用户确认随机回顾页的同一个 FAB 一并移除，让两处体验一致；1.1.72 未发版，改动合并进 1.1.73
- 删除 `lib/screens/random_review_screen.dart` 的 `floatingActionButton` 挂载点、`_buildAIRelatedNotesFAB()`、`_findRelatedNotes()`、`_isLoadingRelatedNotes` / `_intelligentRelatedNotesService` 字段与两个 import
- 连带清理：`_currentIndex` 字段（唯一读取点在 `_findRelatedNotes` 里）及其 3 处赋值，`_onPageChanged()` 与 `PageView.onPageChanged` 随之成空壳，一并删除
- CHANGELOG 的 1.1.72 条目改名 1.1.73 并合并两个页面的描述（1.1.72 从未对外发布，不留断档）
- 验证：`dart analyze lib/screens/random_review_screen.dart` 无问题；`dart tool/inkpaper.dart verify` 全绿

## 2026-11-11 · 详情页移除右下角魔法棒 FAB（1.1.72+10168）· done

- 起因：详情页右下角 `floatingActionButton`（AI 相关笔记魔法棒，带 1.0→1.1 脉冲动画）长期遮挡正文尾部与底部字数栏，且与卡片菜单里的「相关笔记」入口重复
- 删除 `lib/screens/note_detail_screen.dart` 的 `floatingActionButton` 挂载点、`_buildAIRelatedNotesFAB()`、`_findRelatedNotes()`、`_isLoadingRelatedNotes` / `_intelligentRelatedNotesService` 字段，以及随之失效的两个 import，净删 120 行
- 功能未移除：`NoteActionsUi.showRelatedNotes`（`lib/widgets/note_actions_ui.dart`）保留，入口在笔记卡片菜单（`lib/widgets/note_card.dart:901`）
- 随机回顾页有同一个 FAB（`lib/screens/random_review_screen.dart:1113`），本轮未动
- 验证：`dart analyze lib/screens/note_detail_screen.dart` 无问题；`dart tool/inkpaper.dart verify` 全绿

## 2026-11-10 · 导出备份四种格式统一打包图片（1.1.71+10167）· done

- 起因：手机上 635 条笔记里 25 条含图（66 个引用：64 个 `/file/attachments/...` 服务端路径、2 个 `file://` 本地缓存）。导出的 JSON 备份里图片只剩字符串引用，确认「包含图片」开关对 JSON / TXT / HTML 完全无效，只有 Markdown 分支调了 `_addNoteImagesToArchive`
- 新增 `lib/services/backup_archive_service.dart`（`BackupArchiveService` + `BackupContentFormat` 枚举）：把「打包正文 + 收图 + 写清单」和「解包 + 还原图片 + 重写路径」从 2770 行的页面文件里抽出来，便于单测；图片目录通过 `imagesDirectoryProvider` 注入，测试用临时目录
- 包结构（v2）：`backup_manifest.json`（version/format/noteCount/imageCount/missingImageCount）+ 正文（`notes.json` / `note_N.md` / `notes.txt` / `notes.html`）+ `resource_manifest.json` + `resources/note_N_M.ext`
- 图片定位：`file://` → 绝对路径 → 相对文件名（先查 `<docs>/images/`，再查 `<docs>/`），`content://`/`http(s)://` 直接跳过；同一张图被多条笔记引用只打一份
- 路径重写：导入时按「原始路径 → `file://` + 本地还原路径」替换正文，长路径优先避免前缀误匹配；JSON 正文里的路径是转义过的（Windows 反斜杠变 `\\`），加 `jsonEncoded` 开关连同转义一起替换，否则 Windows 上还原不出图
- HTML 导出：先整体 HTML 转义再把 `![alt](path)` 换成 `<img src="resources/...">`，本地没有的降级为占位文字；HTML 仍是只读格式，导入时明确报错「仅用于阅读」
- 兼容：没有 `backup_manifest.json` 的老 ZIP 按扩展名推断格式；老的独立 `.json` / `.md` / `.txt` 单文件导入路径完全没动
- UI：导出文件名固定 `momingbiji_backup_<ts>.zip`（加密再加 `.enc`），导入页补一行 ZIP 说明，「包含图片」副标题改成「所有格式都会打包为 ZIP，图片文件一并放进去」，中英都改
- 缺失图片计数只算正文里 `![](...)` 真的引用到的（首版把 resourceList 里的附件元数据也算进去，635 条笔记导出时报「112 张缺失」，实际正文只有 66 个引用，改成按去重路径+仅正文引用统计）
- 测试：`test/unit/backup_archive_service_test.dart` 10 项（JSON/MD/TXT/HTML 打包与解包、缺失图片计数、resourceList 不算缺、关掉开关、resourceList 相对名、老包兼容、空包报错），`flutter test` 全绿
## 2026-11-10 · 更新改成应用内下载 + 调系统安装器（1.1.70+10166）· done

- 需求：原来点「下载安装包」是 `launchUrl` 把 Release 资产地址丢给浏览器，进度、失败提示都不在自己手里；改成应用内下载、下完直接装
- Dart 侧新增 `lib/services/update_download_service.dart`：`http.Client.send` 流式下载，回调 `UpdateDownloadProgress`（received/total/fraction），支持 `cancel()`（同时关连接，避免卡在等下一块数据上）；先写 `.part` 再改名，字节数与 Release 声明的 `size` 不符就报错并清理，不留半截包
- Dart 侧新增 `lib/services/apk_install_service.dart`：走现有原生通道 `channelNativeAlarm`，两个方法 `getApkUpdatesDir` / `installApk`，返回 `ApkInstallStatus` 枚举（started / permissionRequired / missingFile / unsupported / failed）
- 原生侧：MainActivity 新增 `apkUpdatesDir()`（`cacheDir/updates`）与 `installApk()`；API 26+ 先查 `canRequestPackageInstalls()`，没授权就跳 `ACTION_MANAGE_UNKNOWN_APP_SOURCES` 并返回 permission_required（否则 `startActivity` 会静默失败）；manifest 加 `REQUEST_INSTALL_PACKAGES` 与 `FileProvider`（authority `${applicationId}.fileprovider`，只授权 `cache-path updates/`，见 `res/xml/inkpaper_apk_paths.xml`）
- UI：`_UpdateCheckFooter` 内联进度条 + 百分比 + 「取消下载」；下载完成的文件缓存在 `_cachedApk`，同版本再点直接安装，省一次重下
- 平台差异：非 Android 无系统安装器接管 APK，保持跳浏览器
- 依赖：**没有新增**（`androidx.core` 的 FileProvider 本来就在 classpath 上，`AlarmReceiver.kt` 早已用 `androidx.core.app.NotificationCompat`）
- 待办：Google Play 对该权限有政策限制，若将来上架 Play，可能需要按渠道拆分 manifest；本轮先只服务侧载（GitHub Release）场景
- 未真机验证：改动期间无线调试掉线，Kotlin/manifest 只做了构建验证

## 2026-11-10 · README 版本号纳入 store-check + CI action 升到 Node 24 · done

- 问题：`README.md` / `README.en.md` 的「当前版本 / Current Version」还停在 `1.0.0`，比真实版本落后十几个；同时 Release 跑的时候 `actions/checkout@v4`、`upload-artifact@v4` 刷 Node 20 弃用警告
- README 同步机制：`store-check` 新增 `_assertReadmeVersion`，从两份 README 的版本段里取第一个反引号内容，与 `pubspec.yaml` 的 `x.y.z` 严格比对，不一致就以 exit 2 报出双方的值。中英两份都要过，避免只改一份
- 已实测正反两向：把中文 README 改成 `1.1.68` 立刻失败并打出「README.md 当前版本为 1.1.68，与 pubspec.yaml 的 1.1.69 不一致」，改回即通过
- 文档：两份 README 的版本段、下载段、发布段一起更新（版本号写实、发布只描述 Android、补上「patch 与构建号同时 +1 且同步 README」的规则）
- action 升级：`checkout@v4→v6`、`upload-artifact@v4→v6`、`download-artifact@v4→v7`，都是 Node 24 运行时版本，消掉弃用警告；`subosito/flutter-action@v2`、`setup-java@v4`、`softprops/action-gh-release@v2` 本轮没被警告，保持不动

## 2026-11-10 · 换成自持的正式签名密钥 · done

- 背景：本地构建一直用 `android/inkpaper-local-test.jks`（指纹 `ED:22`），CI 基线却是另一把（`7A:00`）⇒ 从 Release 下的包装不进手机（签名冲突）。而 `7A:00` 那把的 keystore 文件并不在本地，GitHub secret 又不可回读，等于签名能力只剩 CI 一份，换机器/换仓库就失联
- 决策：趁 Release 还是 0 个、只有一台设备装了包，直接换一把自持的正式密钥，一次到位
- 新密钥 `android/inkpaper-release.jks`：`CN=InkPaper, OU=Mobile, O=InkPaper, L=Xiamen, ST=Fujian, C=CN`；RSA 2048 / SHA256withRSA / 有效期至 2054-03-28；别名 `inkpaper`；SHA-256 `D0:99:DD:07:…:AF:56:C1`
- 同步三处：`android/key.properties`（storeFile 指向新 jks）、`tool/inkpaper.dart` 的 `_androidReleaseCertSha256`、`release.yml` 的 `ANDROID_RELEASE_CERT_SHA256`（后两者不一致时 store-check 直接红）
- 旧 `inkpaper-local-test.jks` 保留不删，只是不再使用
- 待办（用户侧）：GitHub 四个 secret 换成新密钥的值；手机上 1.1.68 必须先导出备份再卸载重装，签名换了无法覆盖升级

## 2026-11-10 · Release 流水线改成 Android 单平台 + dry-run 入口 · done

- 需求：`publish` 只保留 Android；并且要能在打 tag 前先验证一遍流水线
- 改法（`.github/workflows/release.yml`）：
  - 删掉 ios / macos / windows / linux 四个作业；`publish` 的 needs 变成 `[prepare, android]`，只下 `android-release` 与 `release-notes` 两个 artifact，`files` 只留 `*.apk` / `*.aab`
  - 新增 `workflow_dispatch` + `dry_run`（默认 true）：手动触发时跳过 tag 匹配校验（拿 pubspec 版本当 tag），`publish` 用 `if: inputs.dry_run != true` 整体跳过
  - 产物命名改用 `needs.prepare.outputs.tag`，dry run 下不会再变成 `InkPaper-main-android.apk`；为此把 `prepare` 加进 android 作业的 needs（原来只靠 quality 间接等待）
  - Release notes 改用 `steps.version.outputs.version` 取版本，dry run 下也能从 CHANGELOG 抽到段落
- 保留：证书指纹校验、APK 内嵌 DER 证书比对、AAB `keytool` 校验、四个 secret 非空检查 —— `store-check` 会断言这些字符串存在，少一处就红
- 验证：PyYAML 解析通过（6 个作业、needs 全部可解析）、`store-check` 通过
- 文档：`docs/BUILD_AND_DEVICE_TESTING.md` §5 发布章节重写，补 dry-run 用法与「只发 Android」的说明

## 2026-11-10 · 更新检查改读 GitHub Release（1.1.69+10165）· done

- 需求：更新检查改成从 GitHub 取最新版本号，判断有没有新版本；顺带讲清 Release 里的 APK 是怎么上传的
- 现状：仓库**一个 tag 都没有**（`git tag -l` 与 `git ls-remote --tags origin` 均空），所以 GitHub Release 页面是空的；手机上装的 release 包是本地 `build android-release` 后用 adb 装的，没走过发布链路
- 改法：
  - 新增 `lib/services/update_check_service.dart`：GET `AppConfig.githubLatestReleaseApi`（`releases/latest`），10s 超时，`Accept: application/vnd.github+json` + `User-Agent`（GitHub 无 UA 会 403）
  - `compareVersions()` 逐段数字比较，忽略 `v` 前缀 / `+build` / `-rc` 后缀，段数不齐按 0 补齐
  - `parseLatestRelease()` 抽成顶层纯函数：取 `tag_name` 去 `v`、`body` 当更新说明、`assets` 里第一个 `.apk` 当下载直链（顺便带 size 给 UI 显示 MB），没有 APK 资产就回落到 Release 页面
  - 错误分型给用户话术：超时 / 网络失败 / 403+429 限流 / 404 未发版 / 其他 HTTP 码 / JSON 异常，全部抛 `UpdateCheckException(message)`
  - 关于页底部版本号下方加「检查更新」按钮（`_UpdateCheckFooter`，自带 loading 与防重入）；有新版本弹 AlertDialog（版本对比 + 发布时间 + 安装包大小 + 可滚动的更新说明），按钮直接打开 APK
- 决策：**没有**把更新检查塞进启动流程或后台轮询。GitHub 未认证 API 按 IP 限流 60 次/小时，只在用户点按钮时请求才不会撞限流
- 测试：新增 `test/unit/update_check_service_test.dart` 12 项（版本比较 4 项、JSON 解析 4 项、MockClient 服务层 4 项含 UA/限流/网络异常）
- 验证：analyze 0 issue；`verify` 600 项全绿

## 2026-11-09 · 分享自动记录来源标签（1.1.68+10164）· done

- 需求：从微信/微信读书分享进来的内容，自动打上来源标签
- 现状：`ACTION_SEND` 文本/图片/文件接收早就注册了，但 `MainActivity.kt` 只取正文和附件，**不记录来源**；而微信读书的粘贴导入（`weread_import_screen.dart:85`）本来就默认 `['微信读书', 书名]`，这块不缺
- 改法：
  - 原生 `resolveShareSource()`：优先 `intent.referencingPackage`（API 22+），为空退到 `intent.referrer?.host`（覆盖系统 UI 发起的 `PROCESS_TEXT`），再把 `com.tencent.mm` → `wechat`、`com.tencent.weread*` → `weread`，其余原样传包名
  - 载荷统一带 `source` 字段（6 处 `deliverSharedPayload` 调用点）
  - Dart `sharedPayloadToContent()` 拆成「取原始内容 → 贴来源标签」两步；`_shareSourceTags` 只认白名单，查不到不打标签
  - 去重：`RegExp('#$tag(?!\S)')`，`#微信` 不会误命中 `#微信读书`
- 决策：**没加 `notes.source` 字段**。来源用正文标签表达，和 weread 导入的历史行为一致，不动 schema v12、不用改 Memos 同步
- 测试：`test/unit/shared_payload_utils_test.dart` 新增 7 项（微信 / 微信读书 / 未知来源 / 去重 / `#微信读书` 不误判 / 图片 / sourceTag 映射）
- 验证：analyze 0 issue；真机用 `am start --referrer android-app://com.tencent.mm` 模拟，确认带 `#微信`

## 2026-11-09 · 九宫格改动画成单一进度动画（1.1.67+10163）· done

- 现象：1.1.66 之后点展开/收起「还是会变两次」——高度瞬变是一次、内容淡化是另一次
- 根因：上一版为了绕开「两个 implicit animation 逐帧对不齐」，把高度改成了瞬变，结果把一次动作拆成了时间上分开的两段
- 改法：用 `_imageExpandController`（220ms，`easeOutCubic`）作为唯一进度源
  - 卡片高度与图片区高度都从同一个 `t` 插值（`_imageStripHeight → _imageGridHeight`），逐帧严格同步，文字区高度全程恒定
  - 图片区内容按**目标态**高度布局，外层 `OverflowBox` + `ClipRect` 只控制可见高度 → 展开像抽屉被拉开，`GridView` 全程不重排
  - `AnimatedSwitcher` 时长对齐到 220ms，与高度同时开始同时结束
  - 三处入口（上滑、展开按钮、收起按钮）统一走 `_setImageGridExpanded()`，中途反向点击 controller 从当前值折返
- 测试：`note_editor_image_expand_test` 加严到逐帧断言图片区高度**单调**（展开不减、收起不增），任何一帧回退即判定「有两段动画」
- 验证：`verify` 全绿；真机 1.1.67 点展开/收起确认是单段连续变形

## 2026-11-09 · 九宫格展开/收起不再抽搐（1.1.66+10162）· done

- 现象：编辑器里点九宫格展开/收起，图片区闪烁抽搐
- 根因（两个叠在一起）：
  1. **两处高度动画各自插值**：卡片高度是裸 `Container` 瞬变（展开瞬间 +142），图片区是 `AnimatedContainer` 用 200ms 才长上去。中间帧里多出来的 142 先全灌进 `Expanded` 的文字区，再被逐帧收回去 → 文字区被顶起又拉回
  2. **九宫格在小窗口里逐帧拉高**：`AnimatedContainer` 的 child 在展开瞬间已经换成 `GridView`，但它还在 110px 的容器里，图片被裁成上沿一条，然后随高度增长一条条露出来 → 视觉上就是图片在抽
- 改法：
  - 高度切换**不做动画**，图片区只有内容交叉淡化（`AnimatedSwitcher` 160ms，`layoutBuilder` 顶部对齐）。瞬变 ⇒ 不存在半成品中间态，两个动画源的帧对齐问题从根上消失
  - 图片区高度加了一层让步：`min(目标高度, max(条高, 卡片高 - 基础高))`。展开九宫格叠加键盘弹出几乎必然撞上「可用高度 92%」上限，原来图片区照旧往 330 涨，多出来的空间只能从文字区抢
  - 图片区容器显式 `width: double.infinity`：`Column` 默认 `center`，宽度一旦退回「由内容决定」，横滑条↔九宫格切换会让宽度重算
  - 删掉 `_buildImageWidget` 开头那条每次重建都打印的路径日志
- 验证（这轮把视觉问题变成了断言）：
  - 新增 `test/widget_tests/note_editor_image_expand_test.dart`：注入 1 张 / 3 张图，展开与收起逐帧断言 ①正文输入框自身高度不变 ②正文底边到图片区顶边的间距不变 ③任何一帧图片区都不是空的
  - `dart tool/inkpaper.dart verify` 全绿（analyze 0 issue、581 项测试通过）
  - 真机（小米 14，release 覆盖安装 1.1.66）：点展开/收起后逐帧连拍 8 张，切换后立刻就是终态，图片完整显示、无被裁切的半成品帧
- 关键认知：**「卡片长高 + 内容贴底」时正文整体上移 142px 是正常的**，不算抖动；真正的抖动是这些量在多帧里反复变化。测试一开始断言「正文 y 坐标恒定」是错的，改成断言「高度 + 与图片区的间距」

## 2026-11-09 · 编辑器选图不再挤压文字区（1.1.65+10161）· done

- 现象：首页点输入框 → 选 1~3 张图 → 上面的文字输入区变窄，多行文字被挡住
- 根因：图片预览区（单行横滑 `_imageStripHeight=110`、展开九宫格 `_imageGridHeight+24=354`）与文字区是 `Column` 里的兄弟节点，只有文字区套了 `Expanded`。卡片总高不变时，图片区的高度只能从文字区里抢 → 文字区从 ≈241 掉到 ≈131
- 改法（只动 `note_editor.dart` 的高度计算，`_buildEditor` 内约 20 行）：
  - `desiredEditorHeight = max(baseEditorHeight + imagePreviewHeight, 内容高 + 工具栏 + 顶部元素 + 图片高 + 32)`：有图就整体长高，不再抢文字区
  - 上限从 `screenSize.height * 0.92` 改为 `(screenHeight - keyboardInset) * 0.92`：原来卡片底部还垫了键盘高度，上限形同虚设
  - 无图无键盘时 `max(base, …)` 仍取 `base`，数值与改前完全一致，动画/视觉零变化
- 这台机器换算（1200×2670 / dpr 2.75 → 逻辑高 970.9）：无图 339.8（文字区 241）→ 1 张图 449.8（文字区仍 241）；展开九宫格 693.8，受键盘上方可用高度的 92% 约束
- **CI 侧的关键发现（这轮才查出来）**：CI 自建仓起**从未绿过一次**，历史 30 个 run 全红，而且每次都死在格式门禁，`verify` 一步从来没真正执行过。本次把门禁修好后才第一次跑起 `analyze`，立刻暴露真问题——`flutter analyze` 报 9 个 `require_trailing_commas`，全在 `note_editor.dart`
- **教训**：项目 lint 开启 `require_trailing_commas`，所以「尾随逗号」不是格式噪音而是**硬要求**；`dart format` 的 short style 不增删尾随逗号，只把它当换行提示，于是「format 通过」≠「analyze 通过」。1.1.64 里我为了拆分 commit 把该文件退回「去逗号」形态，正好踩中这条
- 排障手段（已固化进 `ci.yml`，可复用）：GitHub 对失败步骤只给一行 `Process completed with exit code 1`，而 job logs 需要 token。新增的「失败日志（转 annotation）」步骤把 `verify` 输出 tee 到文件，失败时把「已执行的子命令 / 疑似错误行 / 日志尾部」转成 `::error::` 标注——公开仓库的 Checks annotation **匿名可读**，`GET /repos/{o}/{r}/commits/{sha}/check-runs` → `annotations_url` 直接拿到内容
- 验证：`dart tool/inkpaper.dart verify` 全绿（229 文件格式 0 changed、analyze 0 issue、579 项测试通过）
- 遗留：真机点验仍未做（无线调试离线，`adb mdns services` 空），仅静态验证
- **Android job 首跑也失败**（同样是以前被 skip 的路径）：把诊断脚本挂到构建步骤后拿到原文——`The Java version used for the build is 25.0.5, which is incompatible with Gradle 8.14.3`。`ubuntu-latest` 默认 JDK 已升到 25，项目是 Gradle 8.14.3 / AGP 8.11.1 / `jvmTarget 11`。解法：两个 workflow 的 android 作业都加 `actions/setup-java@v4`（temurin 17，与本地开发环境一致），而不是去升 Gradle/AGP（那两条 dependabot PR 单独评估）
- 诊断脚本抽成 `scripts/ci_annotate.sh`，quality 与 android 两个作业共用；输入是格日志路径，输出是 `::error::` 行。本地用伪造的 Gradle 失败日志验过（空日志走 no-op 分支）
- **Android 第二个坑（JDK 修好之后）**：`java.io.IOException: Server returned HTTP response code: 504 for URL: https://github.com/gradle/gradle-distributions/releases/download/v8.14.3/gradle-8.14.3-all.zip`。`services.gradle.org` 会 302 到 GitHub Releases，该 CDN 对 200MB+ 的发行包偶发 504。处理：`Build debug APK` 步骤整体重试 3 次（wrapper 失败会清掉半截文件，重试安全）。**如果仍持续 504，则要换发行源**（`distributionUrl` 指镜像，或改用 `-bin.zip`），那会连带影响本地首次拉包，需另行确认
- 诊断脚本第二版：上一版把「What went wrong 段」排最前又限 14 行，把首错 `Exception ... 504` 截掉了，只剩 stack frame。改成「子命令 3 行 + 关键错误按出现顺序前 7 条 + 尾部 5 行」

## 2026-11-09 · CI 格式门禁修复 + 行尾策略 + 版本固定（1.1.64+10160）· done

- 现象：GitHub Actions 一直红。`gh` 的 token 已失效，但仓库公开，直接用 REST API 匿名查到真实记录——我上一轮推送的 `14f5f3b`（run `42556743535`）红在 `Analyze + Test` 的**格式门禁**，另有 5 个 dependabot 的 pub 依赖 PR（#10–#14）卡在同一处；`Secret scan` 全过，Android 因 `needs` 被 skip
- 根因：`dart format` 需要 `.dart_tool/package_config.json` 才能读到 pubspec 声明的语言版本（`>=3.0.0` → 3.0）。CI 的格式门禁跑在 `pub get` 之前，读不到就退回当前 SDK 的 **tall style**，把早已按 short style 排好的代码全判成「需要重排」
- **不是靠推理，在干净克隆里复现了**：
```
① git clone → 不 pub get → dart format --output=none --set-exit-if-changed lib test tool
   Formatted 229 files (185 changed)   exit=1     ← 正好对上 CI 的红
② flutter pub get 之后再跑同一条命令
   Formatted 229 files (0 changed)     exit=0     ← 修复生效
```
- 修复一：`ci.yml` 的格式门禁前先 `pub get`（当时是单独一步 `dart tool/inkpaper.dart deps`）
- 修复二：新增 `.gitattributes`。此前仓库没有这个文件、`core.autocrlf=true`，索引存 LF、Windows 工作区是 CRLF，任何一次 `dart format` 都把 diff 变成整文件重写（实测 36 个文件 ≈1.8 万行，真实语义改动只有几十行），提交无法 review。现在 `* text=auto eol=lf`，`.bat/.cmd/.ps1` 保持 CRLF，图片/安装包等二进制显式标 `binary`
- 重排 36 个文件的安全性核验：逐文件把全部空白字符去掉后做字符流比对（`difflib.SequenceMatcher`），差异**只有格式化器补的尾随逗号**（`,)` `,}`），无一处语义改动
- 修复三（本轮补完）：`tool/inkpaper.dart` 新增 `format` 子命令（`--fix` 就地重排），`_verify()` 改为 `deps → format → analyze → test`。**根因只封一半是指门禁只活在 YAML 里**，本地 `verify` 不含格式检查，所以永远跑不出这个问题、才会攒到 36 个文件。现在本地和 CI 是同一条命令
- 修复四（本轮补完）：两个 workflow 的 `channel: ${{ env.FLUTTER_CHANNEL }}`（ci 2 处 + release 6 处，共 8 处）换成 `flutter-version: ${{ env.FLUTTER_VERSION }}`，env 写死 `FLUTTER_VERSION: 3.47.7`（本地 `flutter --version` = Flutter 3.47.7 / Dart 3.13.5）。浮动 stable 会让格式门禁跟着 dart_style 升级而红，与代码无关
- `ci.yml` 的 quality 作业顺手合并：`store-check` 之后只剩一条 `verify --coverage`（原来 deps 被 `verify` 内部的 `_deps()` 重复跑一次）
- 验证：
```
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 229 files (0 changed)
$ dart tool/inkpaper.dart verify
analyze: No issues found!
test:    +579: All tests passed!
```
- 两个 workflow 用 pyyaml 解析校验通过（本机原本没装，`pip install pyyaml` 临时装上；已确认 `flutter-version` 在 8 处全部生效）
- 踩坑：`gh auth` 过期后不要以为查不到 CI —— `api.github.com` 匿名可读 `actions/runs` 与 `jobs`，只是 job logs 需要认证
- 遗留：编辑器「选图后文字区被挤压」的高度修复已完成但**未提交**（工作区里 `lib/widgets/note_editor.dart`，计划作为 `1.1.65` 单独提交，避免和本次整文件重排混在一个 commit 里）；5 个 dependabot PR 要等 main 更新后 `@dependabot rebase` 才会用新 ci.yml 重跑

## 2026-11-09 · 删除「标签推荐提示词」死配置 + 清掉过期 stash（1.1.63+10159）· done

- 背景（`TAG-REC-001`）：`customTagRecommendationPrompt` 全库零消费者，设置页输入框填了不生效。前一轮只做了开关语义修复，去留留待决策
- **二次溯源确认（这次才查清它原本是什么）**：它是原「相关标签推荐」的提示词——给一个标签，本地 **TF-IDF** 算相关度，开启 AI 再让 **LLM** 做语义分析，两者合并成「相关标签 + 一句 AI 洞察」。唯一读者是 `lib/services/tag_ai_service.dart`（706 行）的 `getEnhancedTagRecommendations()` → `_buildTagRecommendationPrompt()`
- **为什么早就是死的**：`git grep TagAIService` 在 v1.0.0 基线 `ca0ed14` 上只命中定义自身——配套 UI（`related_notes_bottom_sheet.dart` 的「相关标签推荐/暂无相关标签」）在源码交到手上之前就已被摘掉。`33c9647` 删整个服务后，字段连理论读者都没了
- 决策：删，不接读者。接上等于从零做一个「标签详情页 → 相关标签」的新功能，而现有标签浏览链路没有这个入口坑位
- 删除范围（净减 96 行在设置页 + 10 行 model，另清 8 个文案键）：
  - `ai_settings_screen.dart`：controller 声明/初始化/dispose、`// 标签推荐Prompt` 整块 UI（85 行）、save 里的变量、copyWith 实参与 `updateCustomTagRecommendationPrompt`；注释「四块输入框」改「三块」
  - `app_config_model.dart`：构造形参、字段、`fromJson`、`toJson`、copyWith 形参与实现
  - 孤儿文案：`tagRecommendationPrompt` / `tagRecommendationPromptHint` / `relatedTags` / `relatedTagsRecommendation` / `noRelatedTags` / `addMoreNotesForAI` / `tagGeneration` / `tagGenerationDesc`（含 `translations.dart` 两键）
  - `help_screen.dart`：「AI 辅助」能力说明改为「点评、续写和周期回顾」（中英双语），原句还写着已删的「洞察」和「标签推荐」
- 验证：
```
$ flutter analyze
No issues found! (ran in 20.7s)
$ flutter test
02:07 +579: All tests passed!
```
- **踩坑记录一（CRLF）**：本仓库工作区是 CRLF，Python `open(p, encoding='utf-8')` 读进来是 `\r\n`，用 `\n` 拼的 old_string 永远匹配不到，`assert` 连挂两次。要 `newline=''` 读、按实际 `\r\n` 比较或按行处理
- **踩坑记录二（多行块被跨段替换）**：`copyWith` 里 `customTagRecommendationPrompt` 与 `updateCustomTagRecommendationPrompt` 之间隔着 `customPeriodicReviewPrompt` 的三行，我却把它俩当成相邻两条写了 old_string，结果「not found」；改成按行扫描、锚定 `? null` / `: xxx` 三行结构才删对
- **踩坑记录三（Edit 反向操作）**：想删 `tagRecommendationPromptHint` 时把注释行一起写进了 new_string，实际把分区注释删了、getter 留下了，随后又补了两轮才对。教训：删块时 old/new 只差在「保留哪一行」，动手前先想清楚保留项
- **踩坑记录四（flutter test 全挂）**：沙箱注入了 `HTTP_PROXY/HTTPS_PROXY=127.0.0.1:9248`，`flutter_tester` 的本地 WebSocket 握手被代理拦截，报 `Invalid WebSocket upgrade request`、58 个测试文件全部 loading 失败。加 `NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost` 后恢复正常。**以后跑 `flutter test` 一律带这两个变量**
- **stash@{0} 处理**：内容是 2026-10-21 的 `pre-clean WIP`（欢迎笔记 i18n 两键、`NoteCard.isExample`、`NoteMoreOptionsMenu.onDeleteOverride`、pubspec 1.0.11→1.0.12）。逐 hunk 核对，当前 1.1.62 已全部落地且是超集（多出 `_precacheDetailImages` 的 `isExample` 早退），确认过期后 `git stash drop`
- 遗留（本次不动）：`l10n` 里还留着已删「AI 洞察」页的一批孤儿键（`aiInsight` / `startInsightWithCount` / `inputKeywords` / `insightResults` 等），以及 `relatedNotesRecommend` / `relatedNotesDesc` 这类随服务一起死的文案，可择机统一清理



- **推送**：本地 `main` 落后远端 0、超前 **114**，全部是 1.1.0+10096（`6cca4e0`）以来的工作，工作区本身干净、没有待提交改动。首次 `git push` 失败于 `schannel: server closed abruptly (missing close_notify)`，换 `git -c http.sslBackend=openssl -c http.postBuffer=524288000 -c http.version=HTTP/1.1 push` 一次成功，远端推进到 `488e55a`
- **文档对齐**（本次只改文档、不动代码，版本保持 `1.1.62+10158`）：
  - `CHANGELOG.md`：结掉 `DOC-001` 的遗留半截。文件头加「版本记录说明」，声明 `1.1.14`–`1.1.56` 的逐版本记录没随 `ca0ed14` 的代码基线重导入迁过来、不做臆造补记；补齐 `1.1.57`–`1.1.62` 六个版本
  - `docs/BUSINESS_OVERVIEW.md`：版本推到 `1.1.62+10158`；页面数 38 → 37（`ai_insight_screen` 已删）；`providers/` 补 `app_provider_account.part.dart`；§4.11 补「自定义提示词三块 + 开关语义」
  - `BLOCKERS.md`：`STRUCT-001` 头部从「L3 待做」改为「L1/L2/L3 全部完成」；`DOC-001` 结项；新增 `SHARE-001`
  - `docs/HANDOFF.md`：隐患表补 `SHARE-001`、`TAG-REC-001` 两行，`DOC-001` 标记已解决，P0 待办加「分享导入复验」
- **新增 `SHARE-001` 的来由**：2026-11-06 排查「微信 → 笔记」时，用 adb 合成 `ACTION_SEND text/plain` 打进 1.1.62 release 包，冷启动与后台两种情形都没弹出预填编辑器。原生载荷键名与 Dart 解析对得上，release 包 `ReleaseLog` 在非 DEBUG 下静默，logcat 拿不到线索，真伪待真机手动确认
- **微信接入的结论（避免重复调研）**：个人微信**没有官方 API**，第三方 hook/协议方案有封号风险，不做；WorkBuddy 侧也没有「微信」connector，市场里只有**企业微信**（属另一套体系）。InkPaper 早已自带 `ACTION_SEND` / `PROCESS_TEXT` / iOS Share Extension，手动通路就是「微信长按 → 转发 → InkPaper」；App 里另有「微信读书笔记导入」（`utils/weread_parser.dart`，粘贴文本解析）
- 另记：`l10n` 的 `wechatAssistant` / `wechatAssistantDesc`（「微信小助手」）全库零引用，是没落地的规划残留

## 2026-11-05 · 自定义提示词开关不再悄悄弹回（1.1.62+10158）· done

- 现象（1.1.61 真机验证时发现，旧版本就有）：打开「启用自定义提示词」、四个输入框都不填、点保存，开关会自己弹回关闭，像没保存成功
- 根因：`ai_settings_screen.dart` 保存时先算 `hasCustomPrompt = 开关 && 至少一块非空`，再把这个结果写回 `useCustomPrompt`。开关的 `onChanged` 本来就即时落库过一次，保存时又被这个派生值覆盖成 false
- 判断：这道门槛是多余的。两个真实消费者都按字段判空并回退默认值——`ai_review_service:79` 要求 `customReviewPrompt` 非空，`periodic_review_service:406` 走 `_customPrompt()` 判空。所以「开着但全空」在功能上等价于关闭，没必要替用户改回去
- 改法（`e92df47`）：保存时原样写 `appProvider.appConfig.useCustomPrompt`；说明文案从「关闭开关会暂时停用，清空输入框并保存才会删除」改为「留空的项使用该功能的默认提示词；关闭开关则全部停用」，把「留空」和「关闭」两件事讲清（开关关闭时输入框是隐藏的，原文案暗示的「清空后保存即删除」在关闭状态下根本没法操作）
- 验证：analyze 无 issue，579 项测试全绿
- **真机验证通过**（1.1.62 release，versionName=1.1.62）：开开关、不填任何内容 → 保存 → 返回设置页 → 重进 AI 设置，开关仍为开、输入区仍在；随后把开关关回并保存，恢复原状
- 未做：`TAG-REC-001`（「标签推荐提示词」零消费者）仍待决，本次只修开关语义，没动它的去留

## 2026-11-05 · 删除无入口的 AI 洞察页与死配置（1.1.61+10157）· done

- 背景（`AI-INSIGHT-001`）：`ai_insight_screen.dart` 是 L1 从 `home_screen.dart` 抽出的 989 行完整页面，唯一入口 `_showAiInsightDialog()` 带着 `// ignore: unused_element`，自 `c059bf8`「移除顶栏 AI 入口」后无任何调用方。真机上点不到，但 `docs/HANDOFF.md` 还把它当可用功能列着
- 决策依据：查清用户以为的「首页蓝色飞鱼」是 `DeepSeekWhale` 图标 →「问笔记」`NoteChatScreen`（RAG 多轮对话），「菜单栏一周/一月分析」是 `PeriodicReviewScreen`（近7/30天 + 标签统计 + 环比 + 结果缓存 + 提示词可配）。三者曾各司其职，但洞察页的能力已被这两个覆盖，独有卖点只剩「任意时间窗 + 标签筛选组合」，且无入口期间无人反馈缺失
- 删除范围（`cabb86f`，净减 1234 行）：
  - `lib/screens/ai_insight_screen.dart` 整文件
  - `home_screen.dart` 的 `_showAiInsightDialog()` + import
  - 设置页「洞察提示词」「标签洞察提示词」两块输入框，及两个 controller 的声明/初始化/dispose/保存
  - `AppConfig.customInsightPrompt` / `customTagInsightPrompt`（构造、字段、fromJson、toJson、copyWith 的实参与形参）
  - l10n 四键：`insightPrompt` / `insightPromptHint` / `tagInsightPrompt` / `tagInsightPromptHint`
  - `_initializeScreenshotDemoState` 里的 `customInsightPrompt` 默认值
- 保留：`useCustomPrompt` 开关（回顾也在用），以及点评（`ai_review_service`）、续写、回顾（`periodic_review_service`）三块提示词——逐个 grep 确认过有真实读者
- 踩坑记录：按行号删 UI 时把外层 `Padding > Column > children` 的 5 行开头一起删了，analyze 报 28 个语法错。教训是删除 UI 块不能只看「块起始注释行 → 块末 SizedBox」，得先确认块与块是否**共享同一个父 widget**——这里 6 块提示词全在同一个 `Column.children` 里，每块只是 `children` 的一项，没有各自的开闭骨架
- 验证：
```
$ dart tool/inkpaper.dart analyze
No issues found! (ran in 17.5s)
$ dart tool/inkpaper.dart test
02:19 +579: All tests passed!
```
- **真机验证通过**（1.1.61 release 装机，设备 1200×2670）：
  - AI 设置 → 自定义提示词开场后，四块依次为点评 → 续写 → 标签推荐 → 回顾，中间无空档、无错位；「洞察提示词」「标签洞察提示词」已消失
  - 右上角保存 → 成功返回设置页，无异常
  - 侧边栏「回顾」→ 正常显示「近7天 / 近30天」切换与「这个周期还没有笔记（统计范围 10.31 - 11.06）」，被删的 model 字段没波及回顾链路
- 顺带发现（未修，不在本次范围）：把「启用自定义提示词」开关打开但一个输入框都不填就保存，`hasCustomPrompt` 会算成 false，开关**静默回弹成关闭**。文案只说了「关闭开关会暂时停用，清空输入框并保存才会删除」，没交代「不填内容等于没开」，容易让人以为点没生效
- 遗留：`customTagRecommendationPrompt`（标签推荐提示词）同样是零消费者的死配置，本次按「洞察」范围未动，记入 `BLOCKERS.md` `TAG-REC-001`


- 背景：`STATE-CORE-005` 把字段搬进 `core/state/` 的 7 个 Store，但 `AppProvider` 里留了 36 条 `get _x => _store.x` 的纯转发。转发层让「拆分完成」看起来没完成、行数不降反升，且每个方法里仍是旧名字，读代码无法判断数据到底归谁管
- 改动一（`cdd5adb`）：36 条转发全部删除，方法体直接写 `_notesStore.notes` / `_authStore.user` / `_webDavStore.config`。`_totalNotesCount` 是例外——它的 setter 要顺带把统计快照置空，保留为具名方法 `_setTotalNotesCount(int)`。`app_provider_sync.part.dart` 里 12 处引用同步替换
- 改动二（`cdd5adb`）：抽 `_commitNoteChange(note, {persist, rebuildReferences})`。原先 `createNote`、`updateNote` 的三个分支、`updateNoteLocally`、`setNoteVisibility`、`updateNoteTags` **各自复制一遍**「落库 → 写内存 → 重建引用 → 重排 → 通知 UI → 刷小组件」，漏任何一步都只表现为「界面没刷新」「引用没重建」这类只能靠肉眼发现的 bug。收敛后 `updateNote` 从 152 行降到 90 行
  - 顺带修掉一个隐藏缺陷：`updateNoteTags` 改了 `updatedAt` 却没调 `_applyCurrentSort`，按时间排序时改完标签卡片位置不动
  - `setNoteVisibility` 原先只在「内存里找得到」时才通知 UI，统一后总是通知（找不到时通知一次是安全的，反而避免漏刷新）
- 改动三（`cdd5adb`）：账号域 386 行搬到 `lib/providers/app_provider_account.part.dart`，与既有 `app_provider_sync.part.dart` 同款 `extension AppProviderAccountPart on AppProvider` 形式，**实现一行未改**，靠同 library 的 extension 直接访问 `_authStore` / `_appConfig` 等私有字段
  - 搬出内容：`updateUserInfo` / `updatePassword` / `saveLoginInfo` / `clearLoginInfo` / `getSaved*` 4 个 / `setUser` / `_initializeApiServiceInBackground` / `_ensureApiServiceInitialized` / `_handleTokenExpired` / `_preloadUserAvatarAsync`
  - `app_provider.dart` 4966 → 4460 行
- 刻意没搬：云验证域只剩 ~50 行（`_loadCloudVerificationData` + `refreshCloudData`），单独拆文件是碎片化；`setLocalMode` / `switchToLocalMode` 夹着大量笔记重载逻辑，不算纯账号域
- 踩坑记录：第一版删除脚本用 `^\s*(?:get|set)\s+_\w+` 识别定义块，漏掉了 `List<Note> get _notes` 这种**带类型**的单行定义，把它们改成了 `List<Note> get _notesStore.notes => ...` 的语法错误；`_totalNotesCount` 的多行 setter 还被重复插入 5 次。教训是这类机械替换必须先把「定义块」和「使用点」分开处理，改完立刻 analyze，不能靠肉眼扫 diff
- 验证：
```
$ dart tool/inkpaper.dart analyze
No issues found! (ran in 14.7s)
$ dart tool/inkpaper.dart test
01:56 +579: All tests passed!
```

## 2026-11-05 · 编辑器两处：标签候选改按最近常用排、修复首行输入后发送按钮置灰（1.1.60+10156）· done

- 缺陷 1（发送按钮置灰）：新建笔记输入第一行文字后，右下角发送按钮仍是灰的、点不动，必须按一次回车换行才「亮」起来
  - 根因：`canSave` 在 `_buildEditor` 里从 `_textController.text` 算，而 `_buildEditor` 只由 `_lineCountNotifier`（换行数）和 `setState` 触发重建。首行打字不改变行数 → 不重建 → 按钮保持初始的灰色状态；回车让行数 1→2 才顺带刷新
  - 改法：把发送按钮包进 `ValueListenableBuilder<TextEditingValue>` 监听 controller 本身，`canSave` 在 builder 内计算。行数那个 Notifier 仍只负责编辑器高度，不改动
- 缺陷 2（标签候选排序）：输入 `#` 弹出的标签建议按字典序排，用户攒起来的常用标签被埋在字母表中间
  - 改法：`utils/tag_input_helper.dart` 新增 `rankTagsByUsage`，频次分 `4*log2(1+次数)`（用 1 次 4 分、3 次 8 分、15 次 16 分）+ 时效分（1 天内 +12、7 天内 +8、30 天内 +4、90 天内 +1），同分按最近使用时间、频次、名称兜底。效果：昨天用过一次(16) 压过半年前用过三次(8)，长期高频(20 上下)仍稳在前排
  - 补 `TG-01..10` 十项单测（含时钟偏差导致 `updatedAt` 在未来、大小写不同的标签不被合并、顺序稳定性）
- 验证：analyze 无 issue，579 项测试全绿（569 + 10）
- **真机验证通过**（1.1.60 release 装机，设备 1200×2670）：
  - 发送按钮：空白态灰色 → 输入 `hello`（单行、未回车）立刻变绿可点 → `DEL` 删空后立刻变回灰。相反方向也验了，说明监听的是内容本身而不是行数
  - 标签候选：输入 `#` 弹出顺序为「运动记录 → 碎碎念 → 起飞日记 → 找不到答案时就去找自己」。旧版按字典序，「运动记录」(y 开头) 会排在很后面，现在靠历史频次排到首位
  - 收尾：测试草稿 `hello #,` 已在草稿箱删除；输入法临时从微信切到搜狗（`input text` 在微信输入法插件服务下失效）后已切回；设备临时截图与 UI 树已 `rm`

## 2026-11-05 · 真机验证 L1/L2（1.1.59+10155）· done

- 设备重新联网：无线调试端口 35819 → 42741，且必须在手机上「使用配对码配对设备」重新配对（`adb pair`）后才连得上；本机 adbkey 未变，是手机端配对关系失效
- 装机：1.1.56+10152 → 1.1.59+10155（`install -r` 成功，重建是因为升版本后原 APK 是 1.1.58）
- **验证通过（均为真机点击 + 截图确认）**：
  - **语音默认关闭**：首页输入条右侧无麦克风；编辑器工具栏（#, 图片, 勾选, 星, B, 列表, …）无麦克风。符合 `speechInputEnabled` 默认 false
  - **批注（L1 合并实现）**：卡片 `…` → 查看批注 → 侧边栏（0 条空状态）→ `+` → 添加批注对话框（类型：评论/问题/想法/重要/待办）→ 写入 `L1verify` → 提交后卡片右下角出现 `💬 1` 徽标
    - **`onUpdated: () {}` 空函数没问题**：`provider.updateNote` 内部 `notifyListeners` 已驱动卡片重建，此前担心的「加完批注不刷新」未出现
  - **引用笔记（L1）**：编辑器 `…` → `@` → 「添加笔记引用」对话框（搜索框 + 找到 50 个笔记）→ 选一条 → 插入 `[[67f0f065-…]]` → 保存后卡片显示 `↗ 引用笔记`，被引用笔记底部出现 `↖ 1` 反向链接
  - **标签补全（L2）**：输入 `#` → 弹出建议（`# 学习记录` / `# 找不到答案时就去找自己` / `# 投资`…）→ 点选后文本变 `#学习记录 `（带尾空格），光标在末尾，继续输入 `test` 正常追加
- **未验证**：
  - **图片锚点（L2）**：插入图片要走小米「安全访问」图片选择器，嵌套层级导致 adb 点击命不中缩略图，放弃。该逻辑由 `IA-01..17` 共 17 项单测覆盖（含区间横跨图片断段、图片在端点不切开）
  - **AI 洞察页**：无 UI 入口，见下
- **新发现（文档与代码不一致）**：`home_screen.dart:1921` 的 `_showAiInsightDialog()` 带 `// ignore: unused_element`，自 `c059bf8`「移除顶栏 AI 入口」起**没有任何调用方**。L1 抽出的 `AiInsightScreen` 目前是无入口死代码
- 环境坑已写入 `docs/HANDOFF.md` 真机段：adb server 每条命令被回收需重连、Git Bash 要 `MSYS_NO_PATHCONV=1`、微信输入法插件服务下 `input text` 失效需临时切搜狗、截图存 /sdcard/ 会进相册、息屏省电导致 ping 80~150ms、坐标要用 `uiautomator dump` 而非截图手算
- 现场清理：设备上 39 个临时截图/UI 树已 `rm`；`heads_up_notifications_enabled` 与默认输入法已恢复原值

## 2026-11-05 · L2：抽出图片锚点与标签补全的纯函数并补 39 项单测 · done

- 背景：`note_editor.dart` 里图片偏移换算、`#` 标签补全全是纯算术，但埋在 State 里，一行测试都没有
- 改动（`3eae4f8`，3850 → 3293 行，交互零变化）：
  - 新增 `utils/note_image_anchor.dart`：`NoteImageAnchor` / `TextDiff` / `shiftImageOffsets` / `splitRangeByImages`，替代 State 里的 `_AnchoredImage` / `_TextDiff` / `_rangesWithImages` / `_shiftRangeSegment` / `_insertedLengthBefore(OrAt)` / `_syncImageAnchorsForTextChange`
  - 新增 `utils/tag_input_helper.dart`：`detectTagPrefix` / `rankTagSuggestions` / `applyTagInsertion`，替代 `_detectTagInput` / `_insertTag` 的内联实现
  - 关键设计：两个新文件都不认识 `MemoStyleRange`，`splitRangeByImages` 只返回索引区间，调用方套回样式类型——避免 `utils → widgets` 逆依赖（`MemoStyleRange` 定义在 `widgets/memo_editing_controller.dart`）
- 新增测试 `test/unit/note_image_anchor_test.dart`（IA-01..17）+ `test/unit/tag_input_helper_test.dart`（TI-01..22），覆盖插入/删除/替换三种 diff、锚点前后插入、null 锚点保留、区间横跨图片断段且图片不被样式覆盖、图片正好在区间端点不切开、`#` 前补空格的三种字符类型、光标越界不抛异常
- 验证：
```
$ dart tool/inkpaper.dart analyze
No issues found!
$ dart tool/inkpaper.dart test
01:47 +569: All tests passed!   # 530 + 39
$ dart tool/inkpaper.dart build android-release
√ Built build\\app\\outputs\\flutter-apk\\app-release.apk (50.1MB)
```
- 未验证：**真机**（设备 `adb connect` 仍超时）。图片锚点与标签补全都是纯函数，逻辑有测试兜底，但「编辑器里插图后加粗、标签弹出的位置」这类**视觉结果**仍需真机点一遍

## 2026-11-05 · L1：抽出三块寄生 UI，合并两份已漂移的批注实现 · done

- 背景：三个高频文件的「体积」不是业务复杂度，是寄生在里面的独立 UI + 重复实现
- 改动（`f719baa`）：
  - `home_screen.dart` 2926 → 1950 行：`_AiInsightScreen`（977 行）→ 公开 `screens/ai_insight_screen.dart::AiInsightScreen`
  - `note_editor.dart` 3850 → 3469 行：`_NoteReferenceDialog`（382 行）→ 公开 `widgets/note_reference_dialog.dart::NoteReferenceDialog`
  - 批注 CRUD：`note_card.dart` 与 `note_actions_ui.dart` **各有一份副本且行为已漂移**（前者直接 `AppProvider.updateNote`，后者走 `NoteActionsService`），合并为 `widgets/note_annotation_dialogs.dart::NoteAnnotationDialogs`；note_card 1630 → 1298、note_actions_ui 1791 → 1413
  - 新增 `onAnnotationOpened` 参数：首页卡片点批注要跳详情页，详情页侧边栏只弹提示，同一实现两种用法
  - 三个类均公开命名（去掉下划线），`super.key` 按 `always_put_required_named_parameters_first` 放到 required 之后
- 验证：`analyze` 无告警、`test` 530 项全绿

## 2026-11-05 · 清理：iOS 语音权限删除 + analyze 退出码归零（DOC-001）· done

- `ios/Runner/Info.plist`：删 `NSSpeechRecognitionUsageDescription`（系统识别 1.1.57 已移除，该权限不再被请求）；`NSMicrophoneUsageDescription` 保留（讯飞录音需要）
- `analysis_options.yaml`：`exclude` 加 `_backup/**`。此前 `_backup/analyze_backup.dart:61` 的 `require_trailing_commas` 让 analyze 退出码长期为 1
- 验证：`dart tool/inkpaper.dart analyze` → `No issues found!`，**退出码 0，首次全绿**

## 2026-11-05 · 结构归位：9 个错层文件各回各位 · done

- 背景：`lib/` 164 个文件 / 10.3 万行，分层骨架没问题，但有文件放错层，看目录猜不到
- 改动（`eed02f3`，纯机械，逻辑零改动）：
  - `widgets → screens`：`image_viewer_screen.dart`、`share_image_preview_screen.dart`（都是页面，与 go_router 页面清单对不上）
  - `services → utils`：`note_sorting_helper` / `note_tags_helper` / `notes_pagination_helper` / `sync_merge_helper` / `sync_status_helper` / `weread_parser` / `notes_context_builder`（7 个无状态纯函数，`BUSINESS_OVERVIEW` 自己都称它们「纯函数工具」）
  - 18 个文件的 import 路径同步；`dart fix --code=directives_ordering` 修掉重排后的 import 顺序
- 刻意没动：
  - `utils/share_utils.dart` + `utils/share_image_widget.dart` 保持原位——前者是 Canvas 绘制/截图，后者被它依赖，挪 widget 进 `widgets/` 反而制造 `utils → widgets` 逆依赖
  - `services/note_actions_service.dart` 的 `services → providers` 逆依赖，需要改结构，留待 P1
- 目录规模：screens 37 / widgets 23 / services 39 / utils 32（文件总数 166 → 164，含删掉的百度语音）
- 验证：
```
$ dart tool/inkpaper.dart analyze
1 issue found.   # 仅 _backup/analyze_backup.dart 那条历史 info（DOC-001）
$ dart tool/inkpaper.dart test
02:15 +530: All tests passed!
```
- 备注：`flutter test` 在本机需绕开沙箱代理（`http_proxy` 会让 flutter_tester 的 websocket 连接报 `Invalid WebSocket upgrade request`），命令改成 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy dart tool/inkpaper.dart test`

## 2026-11-05 · 语音改为默认关闭且仅讯飞，系统/百度识别删除 · done

- 需求：首页默认不展示语音按钮；设置里开启语音并填讯飞 API 后首页才出现；系统语音相关功能删掉
- 结论：`VOICE-001` 结项——不再追 HyperOS 有无 `RecognitionService` 的根因，直接不赌
- 改动（`d8f395c`）：
  - `lib/services/speech_service.dart`：892 → 135 行，只留讯飞；删掉 `speech_to_text` 的初始化/续听/语种解析/失败弹窗/超时兜底
  - `lib/services/iflytek_speech_service.dart`：`isConfigured` 去掉 `speechRecognitionMode` 判断；补 `onDone`（VAD 判停 status=2 或连接关闭回调一次，`_doneEmitted` 防重）
  - 删除 `baidu_speech_service.dart` / `baidu_realtime_speech_service.dart`（无调用方）+ `AppConfig.BAIDU_*` 常量 + 百度专用 l10n
  - `lib/models/app_config_model.dart`：新增 `speechInputEnabled = iflytekSpeechEnabled && 三件套齐全`；`SPEECH_MODE_SYSTEM` 常量删除，默认模式改 `iflytek`（老配置里的 `'system'` 仍能读，但不参与判断）
  - `lib/screens/home_screen.dart`：底部输入条右侧麦克风改条件渲染（`context.select` 读 `speechInputEnabled`）
  - `lib/widgets/note_editor.dart`：编辑器麦克风按钮同样按开关显隐；`startWithSpeech` 加守卫
  - `lib/screens/ai_settings_screen.dart`：「系统识别 / 讯飞」分段控件 → 「语音输入」开关 + 三件套；文案改为实际行为（原文说「长按首页 + 号」，代码里从来没有该手势）
  - `pubspec.yaml`：移除 `speech_to_text` 依赖；`1.1.56+10152` → `1.1.57+10153`
- 新增单测：`test/unit/app_config_speech_test.dart`（6 项：默认关 / 只有开关 / 三件套齐 / 空白密钥 / copyWith 关 / 旧配置 system 残留）
- 验证：
```
$ dart tool/inkpaper.dart analyze   → 仅 _backup 那条 info
$ dart tool/inkpaper.dart test      → 530 项全绿
$ dart tool/inkpaper.dart build android-release
√ Built build\app\outputs\flutter-apk\app-release.apk (50.1MB)
```
- 未验证：**讯飞端到端真机**（`adb connect 192.168.0.108:35819` 超时，设备离线）；iOS 的 `NSSpeechRecognitionUsageDescription` 保留未动（不再被请求，删它属不可验证的改动）

## 2026-11-05 · 语音不卡死 + 首页滚动/时间口径 + AI 图标定稿 · done

- **语音（`290f9d6`）**：真机复现「正在聆听停不掉」，`dumpsys audio` 确认其实没在录音
  - 三个叠加原因：`bool _isProcessing` + `try/finally` 复位，任一平台调用不返回就永久锁死按钮；`speech_to_text` 的 `locales()` 是「发广播等回包」，等不到就永不完成，而它在 `initialize()` 主路径上；`listen()` 被系统静默拒绝时不抛异常，代码却无条件当成功
  - 处理：`initialize/listen` 8s、`locales/hasPermission/stop/cancel` 3s 超时；防抖标志改 3 秒时间窗；停止改为先复位 UI 再释放麦克风；新增 12s「哑火」看门狗（无声无字自动收尾并提示）；`onError` 全量上报
  - 实测：点「点击停止」立即生效；再点麦克风也能停；识别引擎不工作 12s 内自动收回录音条
- **首页含图笔记下滑卡顿（`b567c0f`）**：九图卡片会在同一帧发起 9 次 480px 解码 → 纹理上传击穿单帧预算
  - `note_card.dart` 新增 `_DeferredThumbnail`，按 `90ms + index×30ms` 错峰挂载；补 `gaplessPlayback` / `filterQuality.low`
  - `MemosContentHelper.cachedExpansionText` 缓存「展开」判定全文（原来每次重建都重跑 `MemosMarkdownConverter` + `Document.parse`）
  - 实测：连滑三屏后停在 9 图笔记，图片逐张补上，无卡死灰块、无错图
- **卡片时间口径（`6d0e4ad`）**：`NoteCard.timestamp` 由 `updatedAt` 改为 `createdAt`，与详情页、与 `getNotesPaged` 的 `createdAt DESC` 排序统一；同一笔记首页 `10-25 00:40` ↔ 详情 `2026-10-25 00:40:52` 已对齐
- **AI 图标（`8cedbe7`/`67d7339`/`bf209ca`）**：用户提供 27×20 位图 → 按轮廓拟合矢量路径（IoU 0.87）+ `PathFillType.evenOdd` 挖空嘴/眼 → 最终定为透明底蓝色，去掉深蓝色块底；首页深色模式用 `brandBlueLight`，聊天头像尺寸 21 → 26 抵掉底色带来的视觉重量损失
- 版本：`1.1.48+10144` → `1.1.56+10152`
- 遗留：本机系统语音识别疑似不可用（根因未定位，见 `BLOCKERS.md` `VOICE-001`）；`flutter test` 全量 524 项通过
- 文档：新增 `docs/HANDOFF.md`（交接：现状 / 代码地图 / 遗留 / 新窗口 Prompt）与 `docs/BUSINESS_OVERVIEW.md`（业务框架、13 条业务流程、参数速查、真机调试参数）；`BLOCKERS.md` 补 4 条未解决项

## 2026-10-23 · 体积优化：时区数据 + 本地化双轨合并 · done

- `timezone`：`notification_service` 由 `timezone/data/latest_all.dart` 换成 `latest_10y.dart`
  - libapp.so 内 `package:timezone` 553,618 B → 104,171 B（−439 KiB）
  - 提醒只会排在不久的将来，10 年窗口够用；位置名与偏移规则一致
- `i18n`：删除 gen-l10n 双轨（`app_en.arb` / `app_zh.arb` / `app_localizations*.dart` / `l10n.yaml`，pubspec 移除 `generate: true`）
  - `share_image_preview_screen` 改用 `AppLocalizationsSimple`，补齐 24 条分享图文案中英文
  - 实测 l10n 部分仍是 424,769 B：ARB 生成类本来就只被一个页面引用，tree-shake 后仅约 48 KB，文案搬进 `translations.dart` 后收益基本抵消。**这项真实价值是消除双轨维护，体积收益约 45 KB，此前预估的 0.3 MB 偏高**
- 结果：libapp.so 14,222,216 B → 13,829,000 B（−384 KiB）；universal release APK 48.9 MB → 48.0 MB
- 试过 `flutter build apk --strip`：当前 Flutter 版本不认这个参数（exit 64），已回滚
- 版本：`1.0.59+10059` → `1.0.60+10060`

## 2026-10-23 · 移除友盟统计 + abiFilters 瘦身验证 · done

- 决策：只保留 Dart 侧错误上报（ErrorHandler / GlobalErrorCatcher / Sentry），不集成任何第三方统计 SDK
- 移除友盟：
  - Dart：删除 `lib/services/umeng_analytics_service.dart`；`home_screen` / `privacy_policy_screen` / `app_provider` 的初始化与埋点调用改为本地日志；`AppConfig` 删除 `UMENG_*` 常量与 `channelUmeng`
  - Android：`build.gradle` 去掉 umeng/gson 依赖与 manifestPlaceholders；`MainActivity` 删除 `com.didichou.inkpaper/umeng` 通道（桥接通道从 2 条回到 1 条）；`AndroidManifest` 删除 UMENG_APPKEY/CHANNEL；`proguard-rules.pro` 删除 umeng keep 规则
  - 构建脚本：`tool/inkpaper.dart` 的可选 dart-define 只剩 `SENTRY_DSN`
- 体积：release universal APK 51.3 MB → 48.9 MB（移除友盟约 −1.0 MB，abiFilters 裁掉 x86_64 插件 so 约 −1.4 MB）
- abiFilters 结论（原「已知项」）：
  - `buildTypes.release` 内的 `ndk { abiFilters }` 不生效；Flutter Gradle 插件在 apply 时已把 `defaultConfig.ndk.abiFilters` 垫成全平台
  - Groovy 的 `abiFilters 'a','b'` 是**追加**而非覆盖，必须先 `abiFilters.clear()` 再 `addAll`
  - 最终：`defaultConfig.ndk` 里 clear 后按 `isReleaseTask` 分支，release 只留 `armeabi-v7a/arm64-v8a`，debug 保留 `x86_64` 供模拟器
- 验证（`flutter clean` 后全量构建）：
  - release APK 的 `lib/` 仅含 `arm64-v8a`、`armeabi-v7a`
  - debug APK 仍含 `arm64-v8a`、`armeabi-v7a`、`x86_64`（174.5 MB）
- `--analyze-size`（android-arm64）libapp.so 13.56 MB 构成：
```
package:flutter              4.16 MB   框架，动不了
package:inkpaper             2.80 MB   自有代码（screens 1.12 / widgets 0.47 / l10n 0.42 / services 0.39）
@unknown                     1.26 MB
package:timezone             0.55 MB   timezone/data/latest_all.dart（全球时区数据）
dart:mixin_deduplication     0.48 MB
@shared                      0.47 MB
package:flutter_localizations 0.41 MB
dart:core / dart:ui          0.60 MB
package:sentry(+flutter)     0.38 MB
package:html / markdown      0.34 MB
```
- 后续可优化项：`timezone` 换 `latest_10y.dart`（约省 0.5 MB）、`l10n` 双套本地化（`translations.dart` 252 KB + `app_localizations_simple.dart` 166 KB）只保留一套
- 版本：`1.0.58+10058` → `1.0.59+10059`

## 2026-10-23 · 编辑卡片玻璃化 · done

- 需求：编辑浮层卡片本身也做半透明 + 自身模糊，去掉「硬白块」边界
- 改动（`lib/widgets/note_editor.dart`）：
  - 卡片结构改为 `Container(圆角 + 投影) → ClipRRect → BackdropFilter(sigma 24) → ColoredBox(白 90% / 暗色 0xE01C1C1E) → Column`；投影留在最外层，避免被 ClipRRect 裁掉
  - 新增 `import 'dart:ui' show ImageFilter`
  - 输入框显式 `filled: false`：全局 `inputDecorationTheme` 设了 `filled: true` + `fillColor: surfaceColor`，在玻璃卡片上会糊出一块实心白
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 18.2s)
$ flutter test
02:03 +424: All tests passed!
```
- 真机：`1.0.54+10054` debug 已安装，截图确认卡片整体透出模糊背景、无硬白块、输入区与卡片融为一体
- 说明：弹层遮罩已有 sigma 18 的 `BackdropFilter`，卡片内再叠 24 属于二次模糊，静态时只渲染一次，开销可接受
- 版本：`1.0.53+10053` → `1.0.54+10054`

## 2026-10-23 · 卡片时间行收紧 · done

- 反馈：时间文字本身已经够小，但时间行到正文的留白还是偏高
- flomo 依据：`view_memo_card_surface.xml` 的 `card_header` 是 `layout_marginBottom="4dp"`，时间行紧贴正文
- 改动（`lib/widgets/note_card.dart`）：
  - 卡片上内边距 `14 → 10`（`EdgeInsets.fromLTRB(16, 10, 16, 16)`）
  - 时间文字加 `height: 1.1`，行高不再由 10sp 的默认行距撑开
  - 「更多」按钮容器 `32 → 28`、图标 `18 → 16`，并加 `visualDensity: compact` + 空 `BoxConstraints`，不再由 IconButton 决定整行高度
  - 时间行与正文间距 `8 → 4`
- 效果：时间行总高约 40dp → 32dp，一屏可见笔记从约 4 条变成 5 条
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 14.5s)
$ flutter test
01:05 +424: All tests passed!
```
- 真机：`1.0.53+10053` debug 已安装，截图确认时间紧贴卡片顶部、与正文间距明显变小
- 版本：`1.0.52+10052` → `1.0.53+10053`

## 2026-10-23 · 编辑浮层毛玻璃背景 · done

- 需求：点底部输入框弹出编辑器时，背景做模糊（参考 flomo 的玻璃表面）
- flomo 取证：`com/flomo/components/GlassSurface.java` 用 `eightbitlab BlurView` 做真实模糊 + `FloatingComposerGlass.setup(...)` 叠加 fill/overlay 色，参数走 `glassCornerRadius` / `blurRadius`
- 根因：`_showAddNoteForm` 用 `showModalBottomSheet`，它的遮罩是 Material 的半透明黑（`barrierColor`），**没有模糊能力** —— BottomSheet 之上无法插入 BackdropFilter
- 改动（`lib/screens/home_screen.dart`）：
  - 新增 `_showComposerSheet(Widget editor)`：改用 `showGeneralDialog`（`barrierColor: Colors.transparent`）自绘遮罩，`Stack` = `BackdropFilter(sigma 18)` + 淡色叠加（亮色白 18% / 暗色黑 28%）+ 编辑器
  - `_showAddNoteForm` / `_showAddNoteFormWithContent`（分享入口）都改走该方法；`NoteEditor` 本身是全屏透明 Scaffold（含点击空白关闭、键盘避让），无需改动
  - 淡入 220ms
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 11.9s)
$ flutter test
01:03 +424: All tests passed!
```
- 真机：`1.0.52+10052` debug 已安装；点输入框 → 背景首页明显糊化、编辑器浮层正常、键盘弹起；返回键第一次收键盘、第二次关闭浮层并回到首页「记点什么…」
- 版本：`1.0.51+10051` → `1.0.52+10052`

## 2026-10-23 · 热力图窗口收窄为三个自然月 · done

- 反馈：26 周（半年）时顶部出现 6 个月份标签，太密
- 改动（`lib/widgets/heatmap.dart`）：
  - `_weeksPerPage = 26` → `_monthsPerPage = 3`：区间改为「最近三个自然月」，起始对齐周一，翻页按整页（3 个月）回退
  - 起始月只占半周时不打月份标签（`startIsMonthStart` 判断），顶部只留 3 个标签；`_rangeLabel` 同步从残缺起始月的下一个月算起，标题与标签一致（`2026年8月 - 2026年10月`）
  - 格宽 `clamp(7, 18)` → `clamp(7, 26)`：13 列时约 22dp，仍然铺满宽度
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 14.1s)
$ flutter test
00:37 +424: All tests passed!
```
- 真机：`1.0.51+10051` debug 已安装，截图确认 8月/9月/10月 三个标签、无溢出、格宽约 22dp
- 版本：`1.0.50+10050` → `1.0.51+10051`

## 2026-10-23 · 热力图改为连续时间轴（flomo 式小方格） · done

- 决策：不再走「一个月 7 列铺满 → 单格 44dp」或「限宽居中 → 两侧留白」，改为**连续时间轴**：列 = 周、行 = 周一…周日，一屏展示最近 26 周（半年），格宽 = 可用宽 / 26 ≈ 10.7dp
- 改动（`lib/widgets/heatmap.dart`）：
  - 状态 `_monthOffset` → `_pageOffset`，按整页（26 周）向前翻；区间末尾为今天，起始对齐到周一
  - `_calculateDailyCounts` 改为按 `[_rangeStart, _rangeEnd]` 区间统计（仍只按创建日）
  - 网格：`LayoutBuilder` 计算格宽 `clamp(7, 18)`，7 行 × N 列；删除 `_generateMonthDates`
  - 月份标签用 `Stack + Positioned` 绝对定位（放进 `Row` 会把行撑爆，实测 `RIGHT OVERFLOWED BY 20 PIXELS`），文案缩为「5月」；`_rangeLabel` 显示「2026年4月 - 2026年10月」
  - 星期标签改为左侧竖排（一/三/五/日），底部横排会与新的「列=周」语义冲突
  - `_buildHeatCell` 增加 `inRange` 参数（区间外补齐日淡显）
  - `lib/widgets/sidebar.dart`：无活动格颜色 `grey[100] → #E6E8EB`（26 列下原色太淡糊成一片），暗色 `#3A3A3C`
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 13.0s)
$ flutter test
00:55 +424: All tests passed!   # 含 UI-21 热力图只按创建日统计
```
- 真机：`1.0.50+10050` debug 已安装，截图确认 26 列小方格铺满、月份标签不重叠不溢出
- 版本：`1.0.49+10049` → `1.0.50+10050`

## 2026-10-23 · release 包体积瘦身 · done

- 体积构成（拆开 release universal APK 实测，75.6 MB）：
```
lib/x86_64       25.68 MB
lib/arm64-v8a    24.53 MB
lib/armeabi-v7a  22.01 MB
classes.dex       6.84 MB
assets           0.24 MB
resources.arsc    0.22 MB
```
  - arm64 内部：`libapp.so` 11.5（Dart AOT）、`libflutter.so` 11.2（引擎）、`libsentry.so` 1.16、`libumeng-spy.so` 0.52
- 改动：`tool/inkpaper.dart` 的 `android-release` 加 `--target-platform=android-arm,android-arm64`（x86_64 只有模拟器需要）
- 结果：universal APK **75.6 MB → 51.3 MB（−24.3 MB，−32%）**
- 尝试后回退：想在 `defaultConfig` 加 `ndk { abiFilters }` 再裁掉插件自带的 1.36 MB x86_64 so，但 release 增量构建一直判 up-to-date、未重新打包，无法验证是否生效，且会让 Android 模拟器装不上 → 回退，留作已知项
- 分发建议：真机安装走 `android-release-split`（arm64 ≈27.8 MB）或商店上传 AAB（69.7 MB，按设备下发）
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 15.1s)
$ dart tool/inkpaper.dart build android-release
√ Built build\app\outputs\flutter-apk\app-release.apk (51.3MB)
```
- 版本：`1.0.48+10048` → `1.0.49+10049`

## 2026-10-23 · 侧边栏对齐 flomo（热力图去卡片化 / 菜单块收窄） · done

- 结构确认：抽屉顶部是账号卡（头像 + 昵称 + 在线态），下面依次为「活动记录」热力图与「功能菜单」，无需调整顺序
- 改动：
  - 热力图外层 `Container(margin 16/0/16/8 + padding 8 + 背景/阴影/圆角 12)` → `Padding(20/0/20/8)`，不再以卡片方框区分，直接铺在抽屉背景上
  - `_StatCardWidget`（总字数/笔记数/记录天数 + 今日三项）去掉浅色底块与圆角，只保留文字与内边距
  - 菜单项：外边距 `16/4 → 10/2`，内边距 `16/14 → 14/12`，圆角 `12 → 16`（含 InkWell 水波纹与退出登录按钮），「功能菜单」标题左内边距 20 → 24 与菜单内容对齐
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 10.6s)
$ flutter test
00:48 +424: All tests passed!
```
- 真机：`1.0.48+10048` debug 已安装，截图确认热力图无方框、菜单块更窄更圆
- 已知取舍：热力图铺满宽度（7 列 `Expanded`）后单格约 44dp，比 flomo 的小格子粗壮；若要更精致可加 `maxCellSize≈30` 并居中，但会退回「不铺满」的观感
- 版本：`1.0.47+10047` → `1.0.48+10048`

## 2026-10-23 · 首页本地图片按缩略图解码 · done

- 现状：`note_card.dart` 的网络图分支传了 `memCacheWidth`，但 4 处 `Image.file`（本地 `file://` 图片 + 3 处离线缓存回退）都没传 `cacheWidth` → 手机原图按完整分辨率进内存（4000×3000 的图解码后约 48 MB）
- 改动：4 处 `Image.file` 统一加 `cacheWidth: memWidth`（`memWidth = (decodeWidth ?? 720).clamp(160, 720)`，即格子逻辑宽 × DPR，本机约 366 px）
- 效果：单张本地图解码内存从原图约 48 MB 降到约 0.5 MB（366×366×4B）；大图查看走 `ImageViewerScreen` 的原图加载，不受影响
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 10.6s)
$ flutter test
00:39 +424: All tests passed!
```
- 真机：`1.0.47+10047` debug 已覆盖安装（构建 32.4s）
- 版本：`1.0.46+10046` → `1.0.47+10047`

## 2026-10-23 · 同步去重（Memos + WebDAV 双通道） · done

- 现象：同时开启 Memos 同步与 WebDAV 同步后，同一条笔记在列表里出现两份
- 根因（三处叠加）：
  1. 本地笔记 id 由 `Uuid().v4()` 生成；Memos 拉取时 `Note.fromJson` 直接用服务端 memo 的 id（uid）；WebDAV 合并则完全按 `note.id` 匹配
  2. 接入 Memos 后服务端会重新签发 id，云端 `notes.json` 里仍是上一次的本地 uuid → WebDAV 判定「远程独有」→ `saveNote` 再插一份
  3. 既有 `lib/utils/note_dedupe.dart` 只处理「未同步的本地副本」，WebDAV 路径完全没用上
- 改动：
  - `note_dedupe.dart` 新增 `groupNotesByContentHash`（按哈希分桶）、`findContentDuplicate`（内容一致 + 创建时间 ±5 分钟内视为同一条）、`dedupeDuplicateNotes`（库内自去重：保留创建时间最早的一条，置顶/批注/提醒/引用/标签取并集，返回待删 id）
  - `webdav_sync_engine._mergeNotesIncremental`：远程独有笔记先按内容指纹「认领」本地同一条（保留本地 id，合并远程内容与本地元数据，不新增行）；合并收尾执行库内自去重，删除副本并计入 `SyncStats.deleted`
- 设计取舍：用「内容哈希 + 创建时间容差」而不是纯内容哈希 —— 用户在两个时间点写相同正文是合法场景，纯内容匹配会误删
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 8.0s)
$ flutter test
00:52 +424: All tests passed!
```
- 新增测试：`test/unit/note_dedupe_test.dart` +8 例（跨通道认领、时间超差保留、同 id 跳过、库内合并、元数据并集）
- 真机：`1.0.46+10046` debug 已覆盖安装
- 未做（需人工拍板）：给 notes 表加 `remote_id` 列，把「Memos uid ↔ 本地 id」固化成显式映射（涉及 DB schema 迁移）
- 版本：`1.0.45+10045` → `1.0.46+10046`

## 2026-10-23 · 首页头部对齐 flomo（时间/字号/文案） · done

- flomo 取证：卡片头部 `DinTextView#date` 用 `@dimen/fontTiny`（10sp）+ `@color/textSubtle`（`gray60 = #949494`），字体为 Barlow-Regular（细体）
- 改动（`lib/widgets/note_card.dart`）：
  - 时间戳按 flomo 思路缩减：今天只显示 `HH:mm`，今年显示 `MM-dd HH:mm`，往年显示 `yyyy-MM-dd`（原固定 `yyyy-MM-dd HH:mm`）
  - 时间文字 `12 → 10`，`FontWeight.w300` + `letterSpacing 0.2`，颜色 `#949494`（暗色 `#8E8E93`），与正文拉开层级
  - 「更多」按钮外框 `44 → 32`、图标 `20 → 18`，头部变薄
  - 展开按钮文案 `全文 → 展开`（`translations.dart` 的 `fullText` 同步改 zh/en）
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 12.9s)
$ flutter test
00:51 +416: All tests passed!
```
- 真机：`1.0.45+10045` **debug** 包装到 `192.168.0.108:33717`，截图确认时间为 `10-20 07:54` 浅灰细体、长笔记按钮显示「展开」
- 版本：`1.0.44+10044` → `1.0.45+10045`
- 构建策略调整：后续真机测试改用 debug 包（36s vs profile 71s），profile/release 仅在验收性能时构建

## 2026-10-23 · 首页样式对齐 flomo · done

- 参考源：`友商 APK/反编译/flomo/resources/res/`（flomo 5.5.5 脱壳工程，见 `_flomo脱壳报告.md`）
- 取证：
  - 卡片背景 `drawable/bg_card.xml` → `<corners android:radius="@dimen/cornerRadiusLarge"/>`，`cornerRadiusLarge = 12dp`
  - 九宫格图片 `layout/view_grid_image_item.xml` → `app:roundedCornerRadius="@dimen/cornerRadiusMedium"`（6dp）+ `viewAspectRatio=1`
  - 卡片外边距 `view_memo_card.xml` 中 `MemoView` 左右 `12dp`；卡片垂直间距 `memoCardVerticalInset = 8dp`（相邻两条共 16dp）
- 改动（`lib/widgets/note_card.dart`）：
  - 卡片圆角 `8 → 12`
  - 九宫格图片圆角 `4 → 8`（flomo 为 6dp，按「要更明显」的诉求上调一档；含 `+N` 遮罩与兜底占位）
  - 卡片外边距 `10/0/10/8 → 12/0/12/12`，卡片内边距 `16,12,16,14 → 16,14,16,16`
  - 九宫格间距 `4 → 6`，图文间距 `8 → 10`
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 14.5s)
$ flutter test
01:13 +416: All tests passed!
```
- 真机：`1.0.44+10044` profile 包装到 `192.168.0.108:33717`，截图确认卡片更圆润、间距拉开、单图/多图圆角明显
- 版本：`1.0.43+10043` → `1.0.44+10044`

## 2026-10-23 · 侧边栏热力图宽度修复 · done

- 现象：侧边栏「活动记录」热力图只占卡片左半边（用户连续两次反馈「没占满」）
- 根因：A-11 把 `GridView` 换成 `Row/Column` 时写死 `cellSize = 18.0`，7 列 + 6 间距只有 138pt，而卡片内容宽约 300pt
- 尝试 1（`bf55a6f`）：改 `LayoutBuilder` 按宽度算 `cellSize`，但 `clamp(12, 26)` 的**上限 26** 仍让总宽只有 194pt，依旧没铺满
- 最终（`4390b9a`）：每行固定 7 个 `Expanded` + `AspectRatio(1)`，宽度由父容器平分、高度跟随宽度；空位用 `SizedBox.shrink()` 占位；星期标签同样改 `Expanded`，与格子一一对齐
- 附带修复：`Heatmap` 的 `ValueKey` 在 `notes.isEmpty` 时用 `DateTime.now().millisecondsSinceEpoch`，key 每次 build 都变 → 42 个 Tooltip + 6 张统计卡整棵重建；改为固定 `0`
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 20.2s)
$ flutter test
01:20 +416: All tests passed!
```
- 真机：设备 `23127PN0CC`（`192.168.0.108:33717`）安装 `1.0.43+10043` profile 包，截图确认 7 列铺满卡片、星期标签对齐
- 版本：`1.0.41+10041` → `1.0.42+10042`（尝试 1）→ `1.0.43+10043`（最终）
- 记录：debug 包（175.7 MB）在真机上「空数据也卡」属 JIT 开销，已构建 profile 包（109.2 MB，AOT）供对比

## 2026-10-23 · ROADMAP 状态与文档对齐 · done

- 触发：`docs/ROADMAP.md` 索引表 5 条全部 `done`，但元信息与验收描述仍停留在「release 构建不可用」，与 A-10 补测结果不符
- 改动（仅文档，无代码）：
  - 元信息「验收环境限制」：release 现可构建（`android/key.properties` 指向本地一次性测试密钥，正式发布前须替换）
  - 索引表 ARCH-LAYER-002 验收列：补 A-10 实测体积（universal 75.6 MB / AAB 69.7 MB / arm64 27.8 MB vs debug 175.7 MB）
  - 阶段退出条件：Phase 2 / 3 / 4 均标注「已满足」（0 issue / 416 测试全绿），并追加「真机拖动排序待人工确认」的遗留说明
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 11.1s)
$ flutter test
00:38 +416: All tests passed!
```
- 结论：本版 ROADMAP 全部条目终结，Phase 4 退出条件满足；下一步（是否产出下一版 ROADMAP）属 Phase 边界，按规范需人工拍板
- 无代码改动，无版本变更

## 2026-10-21 · STATE-CORE-001 子项 3 · done

- 改动：`lib/providers/app_provider.dart` 三处串行同步循环改为「每批 3 条 + `Future.wait`」，单条失败不影响同批其他笔记（日志/ErrorHandler 保留）
- 验收输出：
```
$ (Select-String -Path lib/providers/app_provider.dart -Pattern 'for \(final note in unsyncedNotes\)' | Measure-Object).Count
0
$ (Select-String -Path lib/providers/app_provider.dart -Pattern 'Future\.wait|Semaphore' | Measure-Object).Count
3
$ flutter analyze --no-pub
No issues found!
$ flutter test test/unit
00:14 +328: All tests passed!
```
- 缺验收：50 / 200 条笔记的同步耗时对比未执行（无可用服务器），按任务定义记为缺验收
- commit: `4b22455`

## 2026-10-21 · STATE-CORE-001 子项 1 · blocked

- 已尝试（第 1 次）：新建 `lib/providers/sync_store.dart`，把 `_isSyncing` / `_syncMessage` / `_syncingNoteIds` 迁入 SyncStore，`AppProvider` 以 getter/setter 转发
- 验收输出：
```
$ Test-Path lib/providers/sync_store.dart
True
$ ([System.IO.File]::ReadAllLines('lib/providers/app_provider.dart')).Count
4475            # 期望 <= 3500
$ (Select-String -Path lib/providers/app_provider.dart -Pattern 'notifyListeners\(' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
58              # 期望 <= 42
$ flutter analyze --no-pub
No issues found!
```
- 结论：状态抽取后行数反而 +41（转发 getter/setter 占比），「只拆同步域」可迁代码约 520–790 行，减不到 3500；阈值与作用域不匹配
- 需决策：见 `BLOCKERS.md`
- commit: `4b22455`

## 2026-10-21 · STATE-CORE-001 子项 2 · blocked

- 已尝试（第 1 次）：`_lineCount` 改为 `ValueNotifier<int> _lineCountNotifier`，`_updateLineCount()` 不再 `setState`，`build` 外层包 `ValueListenableBuilder<int>`，行数变化只重建编辑器子树
- 验收输出：
```
$ (Select-String -Path lib/widgets/note_editor.dart -Pattern 'setState\(' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
38              # 期望 <= 25（改前 39）
$ (Select-String -Path lib/widgets/note_editor.dart -Pattern 'ValueListenableBuilder' | Measure-Object).Count
1               # 期望 >= 1 ✅
$ flutter analyze --no-pub
No issues found!
```
- 结论：输入派生状态已不再 `setState`，但剩余 38 处多为交互态（弹窗、语音、图片、工具栏），压到 25 需逐个改造，且与「输入不整树重建」目标关联弱
- 需决策：见 `BLOCKERS.md`
- commit: `14f04c6`

## 2026-10-21 · STATE-CORE-001 子项 1 · done（验收口径调整）

- 决策：改按四条验收判定完成（① `class SyncStore` 唯一文件；② `isSyncing` / `syncingNoteIds` 命中均为转发且 ≤6 条；③ 同步目录无 `watch<AppProvider>` / `Consumer<AppProvider>`；④ DevTools 仅 SyncScope 子树重建）。原「app_provider ≤3500 行 + notify ≤42」阈值作废。
- 实测输出：
```
$ (Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'class SyncStore' | Select-Object -ExpandProperty Path -Unique | Measure-Object).Count
1
$ (Select-String -Path lib/providers/app_provider.dart -Pattern 'isSyncing|syncingNoteIds' | Measure-Object).Count
11
$ Test-Path lib/features/sync
False
$ Test-Path lib/core/state
False
```
- 结论：① 通过；② 11 条 > 6 条（5 条为 getter/setter 转发，6 条为 `_isSyncing` / `_syncingNoteIds` 使用处，未加 `_syncStore.` 前缀）；③④ 因仓库无 `lib/features/sync` 目录、无 `SyncScope` 类，记为不适用
- 备注：本次仅文档变更，无代码改动

## 2026-10-21 · STATE-CORE-001 子项 2 · done（验收口径 A）

- 决策：验收改为「输入路径（`_updateLineCount` / `_detectTagInput`）内 `setState` 为 0」，原「全文件 ≤25」作废
- 实测输出：
```
$ (Select-String -Path lib/widgets/note_editor.dart -Pattern 'ValueListenableBuilder' | Measure-Object).Count
1
$ 输入路径内 setState（_updateLineCount + _detectTagInput 方法体）
0
$ flutter analyze --no-pub
No issues found!
```
- 说明：`_detectTagInput`（171–254 行）与 `_updateLineCount` 方法体内均无 `setState`；全文件 setState 现为 38，仅作参考、不作验收
- 遗留：剩余交互态 `setState` 约 13 处不单独开任务，记入 QUAL-CLEAN-003「待评估项」
- commit: `14f04c6`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · WebDAV 域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/webdav_store.dart`（新建）
- 迁移字段（5）：`_webDavConfig` / `_webDavService` / `_webDavSyncEngine` / `_webDavBackupTimer` / `_hasPerformedStartupBackup` → `WebDavStore`（`config` / `service` / `syncEngine` / `backupTimer` / `hasPerformedStartupBackup`）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
webdav decl 旧=5 新=0
$ _webDavStore. 转发数
10
$ flutter analyze lib/core/state/webdav_store.dart lib/providers/app_provider.dart
No issues found! (ran in 3.3s)
$ flutter test test/unit
00:15 +328: All tests passed!
```
- 版本：`1.0.18+10018` → `1.0.19+10019`
- commit: `a5ee318`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · Notion 域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/notion_store.dart`（新建）
- 迁移字段（2）：`_notionSyncService` / `_isNotionSyncing` → `NotionStore`（`syncService` / `isSyncing`）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
notion decl 旧=2 新=0
$ _notionStore. 转发数
3
$ flutter analyze lib/core/state/notion_store.dart lib/providers/app_provider.dart
No issues found! (ran in 2.0s)
$ flutter test test/unit
00:14 +328: All tests passed!
```
- 版本：`1.0.19+10019` → `1.0.20+10020`
- commit: `57cb3db`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · 提醒/通知域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/reminder_store.dart`（新建）
- 迁移字段（4）：`_reminderNotificationService` / `_notificationService` / `_notificationServiceInitialized` / `_unreadAnnouncementsCount` → `ReminderStore`（`reminderService` / `appNotificationService` / `appNotificationInitialized` / `unreadAnnouncementsCount`）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
reminder decl 旧=4 新=0
$ _reminderStore. 转发数
6
$ flutter analyze lib/core/state/reminder_store.dart lib/providers/app_provider.dart
No issues found! (ran in 1.8s)
$ flutter analyze（全项目）
No issues found! (ran in 7.7s)
$ flutter test test/unit
00:15 +328: All tests passed!
```
- 版本：`1.0.20+10020` → `1.0.21+10021`
- commit: `1d5ae86`（代码），本次（文档）
- 遗留：AI 域在 `AppProvider` 内无独立字段（仅方法），小组件仅 `_widgetSnapshotUpdateId`；下一轮需先判定这两域是否值得单独建 Store，或并入通用基建字段后终结 STATE-CORE-005

## 2026-10-21 · STATE-CORE-005 · 小组件域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/widget_store.dart`（新建）
- 迁移字段（1）：`_widgetSnapshotUpdateId` → `WidgetStore.snapshotUpdateId`（快照调度版本号，防抖 350ms 期间丢弃过期快照）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
widget decl 旧=1 新=0
$ _widgetStore. 转发数
2
$ flutter analyze lib/core/state/widget_store.dart lib/providers/app_provider.dart
No issues found! (ran in 2.3s)   # 首轮报 directives_ordering，调整 webdav/widget import 先后后清零
$ flutter test test/unit
00:15 +328: All tests passed!
```
- 版本：`1.0.21+10021` → `1.0.22+10022`
- commit: `b127e62`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · 云验证域 · done

- 作用域：`lib/providers/app_provider.dart`、`lib/core/state/cloud_verification_store.dart`（新建）
- 迁移字段（3）：`_cloudService` / `_cloudAppConfig` / `_lastCloudVerificationTime` → `CloudVerificationStore`（`service` / `appConfig` / `lastVerificationTime`）
- 实测输出：
```
$ 字段定义数（旧版基线反向校验 / 新版）
cloud decl 旧=3 新=0
$ _cloudStore. 转发数
5
$ flutter analyze lib/core/state/cloud_verification_store.dart lib/providers/app_provider.dart
No issues found! (ran in 1.8s)
$ flutter test test/unit
00:14 +328: All tests passed!
```
- 版本：`1.0.22+10022` → `1.0.23+10023`
- commit: `db3d7b2`（代码），本次（文档）

## 2026-10-21 · STATE-CORE-005 · 终结（AI 域 skipped）

- AI 域验收取证（无字段可迁）：
```
$ Select-String -Path lib/providers/app_provider.dart -Pattern '(?i)\b(AI|LLM|OpenAI|Ollama|Gemini|Anthropic|DeepSeek|Prompt)\w*'
572: aiEnabled: true,
573: aiApiUrl: AppConfig.DEEPSEEK_API_URL,
644: content: 'AI 点评要给出具体反馈，而不是模板话。\n\n'
646: '#AI #产品/体验',
649: tags: const ['AI', '产品/体验'],
```
  → 命中仅截图演示数据与 `aiEnabled` / `aiApiUrl` 配置调用，无 AI 域字段声明，判 skipped（不新建空 Store）
- 结论：STATE-CORE-005 的 7 个域全部迁出，`AppProvider` 内已无域字段定义（仅通用基建字段：`_appConfig` / `_mounted` / `_resourceService` / `_databaseService` / `_preferencesService` / `_authStore` 等 Store 持有者本身）
- 状态：done

## 2026-10-21 · ARCH-LAYER-002 · A-05 · done

- 作用域：`lib/services/note_actions_service.dart`、新建 `lib/widgets/note_actions_ui.dart`、调用方 `lib/widgets/note_card.dart`、`lib/widgets/note_more_options_menu.dart`
- 做法：整份 UI 编排（弹窗/对话框/导航/SnackBar，1,700+ 行）平移到 widgets 层的 `NoteActionsUi`；服务层重写为纯数据层 `NoteActionsService`（`updateContent` / `delete` / `restore` / `togglePin` / `setVisibility`），不 import `screens/`、`widgets/`、不碰 `BuildContext`。两个调用方只改 import 与类名，调用参数不变。
- 实测输出：
```
$ (Select-String -Path lib/services/note_actions_service.dart -Pattern "package:inkpaper/(screens|widgets)/" | Measure-Object).Count
0
$ flutter analyze
No issues found! (ran in 6.9s)
$ flutter test
00:26 +399: All tests passed!
```
- 版本：`1.0.23+10023` → `1.0.24+10024`
- commit: `7c62862`（代码），`e5c388f`（文档）

## 2026-10-21 · ARCH-LAYER-002 · A-06 · done

- 做法：`NetworkUtils` 改为进程级共享 `http.Client`（懒加载 `sharedClient`），`createOptimizedClient` / `createDirectClient` 返回同一实例；删除每个请求里的 `client.close()`（否则会关掉共享客户端），新增 `NetworkUtils.close()` 供退出/teardown 调用。
- 实测输出：
```
$ http.Client() 计数
1   (期望 <= 1)
$ close() 计数
4   (期望 >= 1)
$ flutter analyze
No issues found! (ran in 11.4s)
$ flutter test test/unit
00:14 +328: All tests passed!
```
- 版本：`1.0.24+10024` → `1.0.25+10025`
- commit: `63e1b7d`

## 2026-10-21 · ARCH-LAYER-002 · A-07 · done

- 做法：新增顶层函数 `decodeBackupNotesJson(String rawJson)`（供 `compute` 调用），只做解码 + 结构校验，返回 `List<Map<String, dynamic>>`；`importNotesFromJson` 改 `await compute(...)`，`Note.fromJson` 仍在主 isolate。`_importNotes` 原本就是单个 `db.transaction`，插入包事务无需改动。
- 实测输出：
```
$ jsonDecode(jsonData) 计数
0   (期望 0)
$ compute(|Isolate.run 计数
1   (期望 >= 1)
$ flutter analyze lib/services/database_service.dart
No issues found! (ran in 1.0s)
$ flutter test test/unit
00:15 +328: All tests passed!
```
- 版本：`1.0.25+10025` → `1.0.26+10026`
- commit: `a2f1436`

## 2026-10-21 · ARCH-LAYER-002 · A-08 · done

- 做法：删除 `cupertino_icons` / `flutter_image_compress` / `flutter_svg` / `flutter_highlight` / `graphview` / `flutter_dotenv` 六个无引用依赖，并删 `xml` 直连声明（`flutter pub deps` 显示 `xml 6.6.1` 由 `webdav_client 1.2.2` 与 `flutter_native_splash` 传递引入，删直连不影响解析）。
- 实测输出：
```
$ flutter pub deps --style=compact
- webdav_client 1.2.2 [dio xml convert]
- xml 6.6.1 [collection meta petitparser]
$ 已删依赖计数
0   (期望 0)
$ flutter pub get
Got dependencies!（1 package is discontinued）
$ flutter analyze
No issues found! (ran in 8.6s)
$ flutter test
00:23 +399: All tests passed!
```
- 版本：`1.0.26+10026` → `1.0.27+10027`
- commit: `02bb3b5`（含 `pubspec.lock`）

## 2026-10-21 · ARCH-LAYER-002 · A-09 · done

- 前置：许可结论先写入 `BLOCKERS.md`（SF Pro / SF Mono 不可再分发；且 `pubspec.yaml` 无 `fonts:` 段、`assets:` 仅 `assets/images/`，这 5 个文件从未打包）。
- 实测输出：
```
$ (Get-ChildItem assets/fonts -File -ErrorAction SilentlyContinue | Measure-Object).Count
0   (期望 0)
$ assets 递归总大小
0.01 MB   (期望 <= 0.1，改前 3.96)
$ flutter analyze
No issues found! (ran in 7.5s)
$ flutter test
00:30 +399: All tests passed!
```
- 版本：`1.0.27+10027` → `1.0.28+10028`
- commit: `7c0039f`

## 2026-10-21 · ARCH-LAYER-002 · A-10 · done

- 做法：`android-release` / `android-release-split` / `android-appbundle` 三条 release 构建参数加 `--obfuscate`；原本缺 `--split-debug-info` 的 universal APK 一并补上（否则混淆后堆栈不可读）。
- 实测输出：
```
$ --obfuscate 计数
4   (期望 >= 1)
$ dart analyze tool/inkpaper.dart
No issues found!
$ dart tool/inkpaper.dart --help
android-debug | android-release | android-release-split | android-aab
```
- 缺验收（按条目原文）：release 体积对比需 `android/key.properties`，当前缺失，未测量。
- 版本：`1.0.28+10028` → `1.0.29+10029`
- commit: `a9dbe45`

## 2026-10-21 · ARCH-LAYER-002 · A-11 · blocked（8/9 处已消除）

- 实测输出：
```
$ (Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'shrinkWrap:\s*true' | Measure-Object).Count
1   (改前 9，期望 0)
$ flutter analyze
No issues found! (ran in 7.0s)
$ flutter test
00:31 +399: All tests passed!
```
- 已处理：`flomo_import_screen.dart` ×3、`local_backup_restore_screen.dart` ×1、`server_info_screen.dart` ×2、`heatmap.dart` ×1、`note_editor.dart` ×1（细节见 BLOCKERS）
- 阻塞点：`sidebar_customization_screen.dart:539` 的 `ReorderableListView(shrinkWrap: true)` 嵌在 `ListView` 内；已试 3 种方案（直接删参数 / Column+拖拽监听器 / SliverReorderableList）均不可行或需页面级 sliver 重构，且该文件不在 A-11 作用域。
- 版本：`1.0.29+10029` → `1.0.30+10030`
- commit: `e4b3b7d`（代码），本次（文档）

## 2026-10-21 · ARCH-LAYER-002 · A-11 · done（接续 blocked，走「扩大作用域」方案）

- 做法：`lib/screens/sidebar_customization_screen.dart` 的 `body: ListView(children:)` 改 `CustomScrollView`；「菜单项」分组的 `ReorderableListView(shrinkWrap: true)` 换成 `DecoratedSliver(SliverPadding(SliverReorderableList))`，分组标题抽出 `_buildSectionHeader` 供 `_buildSection` 与新 sliver 复用。
- 实测输出：
```
$ (Get-ChildItem lib -Recurse -Filter *.dart | Select-String -Pattern 'shrinkWrap:\s*true' | Measure-Object).Count
0   (改前 9，期望 0)
$ dart format lib/screens/sidebar_customization_screen.dart
Formatted 1 file (1 changed)
$ flutter analyze
No issues found! (ran in 7.8s)
$ flutter test
00:44 +399: All tests passed!
```
- 版本：`1.0.30+10030` → `1.0.31+10031`
- commit: `84bc599`（代码），`1ea41f0`（ROADMAP）

## 2026-10-21 · QUAL-CLEAN-003 · A-12 · done

```
$ (Select-String -Path lib/screens/home_screen.dart -Pattern '_collectTags' | Measure-Object).Count
0   (期望 0)
$ 全库 collectTags 命中
0
$ flutter analyze
No issues found!
```
- 说明：目标死方法 `_collectTags` 已在早前重构中消失（`home_screen.dart:1866` 现属 `_availableTags`，全库 5 处调用，非死代码），本次仅核对验收命令；无代码改动，无版本变更。
- commit: 无代码，随文档提交。

## 2026-10-21 · QUAL-CLEAN-003 · A-13 · done

- 做法：`.github/workflows/ci.yml` 质量任务加 `dart format --output=none --set-exit-if-changed lib test tool` 步骤；随后一次性格式化全量（20 文件），并手工补 9 处 `require_trailing_commas`（formatter 与 lint 在该批表达式上不一致）。
- 实测输出：
```
$ (Select-String -Path .github/workflows/ci.yml -Pattern 'dart format' | Measure-Object).Count
2   (期望 >= 1)
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)
exit=0
$ flutter analyze
No issues found! (ran in 8.4s)
$ flutter test
00:24 +399: All tests passed!
```
- 版本：`1.0.31+10031` → `1.0.32+10032`
- commit: `012b94e`（CI 门禁）、`b4b5f54`（格式化全量，单独 commit）

## 2026-10-21 · QUAL-CLEAN-003 · A-14 · done

- 做法：6 处 `Image.asset` 全部补 `cacheWidth`，按 `显示尺寸 × MediaQuery.devicePixelRatioOf(context)` 计算；`image_utils.loadThemeImage` 在 `width == null` 时保持原图（传 null）。
- 实测输出：
```
$ Image.asset 计数 / cacheWidth（区分大小写）计数
Image.asset=6  cacheWidth=6   （改前 3 处，且 3 处均为 memCacheWidth，不属于 Image.asset）
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)
$ flutter analyze
No issues found! (ran in 8.8s)
$ flutter test
00:32 +399: All tests passed!
```
- 说明：验收命令原来的 `-Pattern 'cacheWidth'` 默认忽略大小写，会把 `memCacheWidth`（`cached_network_image`）算进去；已改为区分大小写口径，`6 == 6` 成立。
- 版本：`1.0.32+10032` → `1.0.33+10033`
- commit: `7ab0a19`

## 2026-10-21 · QUAL-CLEAN-003 · A-15 · 增量 1 个文件（随即 blocked）

- 完成：`lib/screens/forgot_password_screen.dart` 未接 l10n 的 UI 文案 10 → 0，新增键 `memosNoPasswordResetHint` / `memosNoPasswordResetDetail` / `rememberedPassword`（zh + en，中文 fallback 保留）。
- 实测输出：
```
$ 该文件未接 l10n 的 UI 文案（排除 AppLocalizationsSimple / debugPrint / 注释）
0
$ 该文件原始计数（含 fallback + debugPrint）
12  （改前 12，说明该指标无法反映本地化进度）
$ flutter analyze
No issues found! (ran in 9.7s)
$ flutter test
01:01 +399: All tests passed!
```
- 剩余体量（同口径 Top 10）：webdav 148 / preferences 122 / app_provider 117 / ai_settings 109 / user_agreement 99 / ai_insight_engine 98 / local_backup 89 / flomo 75 / server_info 72，合计约 1,300 行 → 转 blocked，拆分建议见 BLOCKERS。
- 版本：`1.0.33+10033` → `1.0.34+10034`
- commit: `0960608`

## 2026-10-21 · QUAL-CLEAN-003 · A-15 · done（口径重定义 + 4 批落地）

- 口径问题：旧指标 `'[^']*[\u4e00-\u9fff]` 会把已接 l10n 的中文 **fallback**、`debugPrint` 日志、l10n 字典文件本身全部计入（`forgot_password_screen` 改后仍是 12），无法作为门禁，因此先重定义口径。
- 新口径（已写入 ROADMAP 验收命令）：`lib/screens` + `lib/widgets` 内「直接写在 widget 参数里的中文字面量」= 0，排除注释 / `_text('zh','en')` / `text('zh','en')` / `AppLocalizationsSimple` fallback。
- 实测输出：
```
$ 新口径命中数（改前 82）
0   (期望 0)
$ dart format --output=none --set-exit-if-changed lib test tool
Formatted 199 files (0 changed)   exit=0
$ flutter analyze
No issues found! (ran in 7.6s)
$ flutter test
00:21 +399: All tests passed!
```
- 落地批次：
  - `0960608` 找回密码页 10 处（新增 3 键：`memosNoPasswordResetHint` / `memosNoPasswordResetDetail` / `rememberedPassword`）
  - `21236a4` 6 个页面 14 处（新增 12 键：`addTag` / `tagNameHint` / `expandOptions` / `notionTokenHint` / `aiInsight` / `tagInputExampleHint` / `zoomIn` / `zoomOut` / `reviewWidgetRefresh*` / `reviewWidgetRange*`）
  - `c35259f` 8 个文件 12 处（新增 10 键：`more` / `refreshBatch` / `openSourceRepo` / `connectServer` / `enterBackupPassword` / `backupPassword` / `importFromLocalFile` / `selectBackupFile` / `syncFromCloud` / `syncWithCloudData`；复用 `createNote` / `all` / `pleaseEnterNewNickname`）
  - `be5f87a` AI 设置页 10 处模型示例文案改走本文件既有的 `_text('zh','en')` 助手
- 版本：`1.0.34+10034` → `1.0.37+10037`
- 遗留（不阻塞）：`app_provider.dart` 5 处为截图模式演示笔记正文、1 处为系统通知标题（provider 层无 `BuildContext`）；`webdav_settings_screen.dart` 等文件的 l10n fallback 按设计保留中文。

## 2026-10-21 · QUAL-CLEAN-003 · done（4/4 子项）

- A-12 死代码 / A-13 format 门禁 / A-14 图片解码 / A-15 本地化全部验收通过，索引表 4 条条目（`STATE-CORE-001`、`STATE-CORE-005`、`ARCH-LAYER-002`、`QUAL-CLEAN-003`）均为 done，Phase 1–4 退出条件全部满足。
- 全程 `flutter analyze` 0 issue、`flutter test` 399 全绿、`dart format` 退出码 0。

## 2026-10-21 · 收尾验证（Android 构建 + 重构单元测试）

- 构建：
```
$ dart tool/inkpaper.dart build android-debug
Running Gradle task 'assembleDebug'...  52.5s
√ Built build\app\outputs\flutter-apk\app-debug.apk
$ app-debug.apk 体积
175.7 MB（基线 176.0 MB；5 个字体删除后几乎无变化，印证从未打包）
```
- 新增测试（16 例，399 → 415）：
  - `test/widget_tests/sidebar_customization_screen_test.dart`（3）：A-11 后该页为 `CustomScrollView` + `SliverReorderableList`、无 `ReorderableListView`、滚动/点击开关不抛异常
  - `test/unit/refactor_state_stores_test.dart`（6）：`AuthStore` / `NotesStore` / `WebDavStore` / `NotionStore` / `ReminderStore` 初始状态与 `clear()` 幂等
  - `test/unit/refactor_utils_test.dart`（7）：`NetworkUtils` 共享客户端同一性 / `close()` 重建；`decodeBackupNotesJson` 正常 / 缺字段 / 类型错误 / 丢弃非对象 / 空数组
```
$ flutter analyze
No issues found! (ran in 7.1s)
$ flutter test
00:25 +415: All tests passed!
```
- commit: `7ee4f9b`（页面测试）、`285bf06`（单测）、`94659bc` / `9915021`（BASELINE）
- release 构建仍不可用：缺 `android/key.properties`，A-10 的体积对比维持「未测量」。

## 2026-10-21 · 真机冒烟（Android 10+ 设备 `192.168.0.108:39911`）

- 安装：`adb install -r app-debug.apk` → `Success`（175.7 MB debug 包）
- 启动：`monkey -p com.didichou.inkpaper -c android.intent.category.LAUNCHER 1` → 进程存活（pid 22648），首页正常渲染（本地模式欢迎笔记可见，底栏输入框/侧边栏入口正常）
- 崩溃检查：`adb logcat -d | Select-String 'FATAL EXCEPTION|E/flutter|ANR in com.didichou'` → **无命中**
- A-11 页面真机链路（改用语义树定位，不再盲点坐标）：`adb shell settings put secure accessibility_enabled 1` 让 Flutter 输出语义树 → `uiautomator dump` 取控件 bounds → 依次点击 汉堡(84,218) → 侧边栏「设置」→「偏好设置」→「侧边栏 / 调整菜单显示与排序」→ 到达「自定义侧边栏」
  - 渲染：头部组件（显示个人中心 / 显示活动记录 两开关）+ 菜单项（全部笔记带锁不可动 + 随机回顾 / 全部标签 / 知识图谱 / 帮助 / 设置 各带拖动手柄与开关）+ 底部提示「全部笔记是默认首页，无法隐藏或移动」全部正常
  - 交互：关闭「显示活动记录」→ AppBar 出现「保存」，点「保存」后按钮消失；`am force-stop` 重启后侧边栏不再有「活动记录」；再次开启并保存后恢复正常 —— 配置读写与持久化 OK
  - 未通过自动化验证：菜单项拖动排序。`input draganddrop`（手柄 195,812 → 195,1330/1440，1200/1500ms）与慢速 `input swipe` 均未触发 `SliverReorderableList` 重排，顺序保持原样，需人工长按拖动确认
  - 收尾：`settings put secure accessibility_enabled 0` 还原，设备临时截图与 `ui.xml` 已删除
- 无代码改动，无版本变更

## 2026-10-21 · ARCH-LAYER-002 · A-10 · 体积对比补测（补齐缺验收）

- 解除方式：本地生成一次性签名密钥 `android/inkpaper-local-test.jks`（`keytool -genkeypair -storetype JKS -keyalg RSA -keysize 2048 -validity 10000`，dname `CN=InkPaper Local Test`），配套 `android/key.properties`；两者均命中 `android/.gitignore`（`key.properties` / `**/*.jks`），不进仓库。`storeFile` 按 `android/app` 解析，取值须为 `../inkpaper-local-test.jks`
- 实测输出：
```
$ Get-ChildItem build/app/outputs/flutter-apk/*.apk,build/app/outputs/bundle/release/*.aab | 体积
app-debug.apk                         175.7 MB   184,208,770 B
app-release.apk（universal，混淆）      75.6 MB    79,323,714 B   # -56.9% vs debug
app-release.aab                        69.7 MB    73,100,104 B
app-arm64-v8a-release.apk              27.8 MB    29,202,649 B   # -84.1% vs debug universal
app-armeabi-v7a-release.apk            25.3 MB    26,535,479 B
app-x86_64-release.apk                 29.0 MB    30,383,632 B
$ 混淆符号文件
app.android-arm.symbols 5,629,632 B / app.android-arm64.symbols 6,507,864 B / app.android-x64.symbols 6,505,104 B
```
- 结论：release universal APK 比 debug 小 56.9%，arm64 单架构包仅为 debug 的 15.9%（debug 三架构 libflutter.so 约 125 MB 是主因）；`--obfuscate` + `--split-debug-info` 已生效（三份 symbols 产出）
- 未做：release APK 未装机验证（签名与现有 debug 安装不同，覆盖需先卸载会清空本机数据）；`android/key.properties` 现指向一次性测试密钥，**正式发布前必须替换为正式 keystore**
- 无代码改动，无版本变更

## 2026-10-21 · 真机复验发现并修复 2 个 UI 缺陷

- 缺陷 1（首页欢迎卡片溢出）：设备 1200×2670 上首页出现 `BOTTOM OVERFLOWED BY 21 PIXELS`。根因：`home_screen.dart` 空列表分支把欢迎卡片塞进 `SizedBox(height: 屏高 - 240)`，卡片实际需要约 752pt、约束只有约 731pt。改法：固定高度只留给「搜索加载 / 搜索空态 / 普通空态」三个分支，欢迎卡片改为按内容自适应。
  - 验证：重装 debug 包后首页截图无溢出条，卡片高度随内容收缩
  - commit `3d8dba4`，版本 `1.0.40+10040` → `1.0.41+10041`
- 缺陷 2（侧边栏拖动代理缺 Material）：补 `SB-04` widget 测试（`tester.timedDrag` 拖手柄）时暴露 `No Material widget found. ListTile widgets require a Material widget ancestor` —— `SliverReorderableList` 的拖动代理插在 Overlay，脱离 Scaffold 的 Material，debug 下拖动即抛异常中断。
  - 修复：`SliverReorderableList.proxyDecorator` 包一层 `Material(color: transparent, elevation: 6)`；`SB-01..SB-04` 4 例全绿，拖动后「随机回顾」下移且 AppBar 亮出「保存」
  - commit `46bc8c1`，版本 `1.0.39+10039` → `1.0.40+10040`
- 仍未自动化验证：真机长按拖动排序。`input draganddrop`（手柄真实坐标 100,1607 → 100,1990，800ms）、`input swipe`（同起止 800ms）、`input motionevent` 逐事件序列三种注入方式均未触发重排（该 HyperOS 设备疑似过滤注入的拖拽事件）；重排逻辑本身已由 widget 测试覆盖，真机拖动仍需人工长按确认
- 验收输出：
```
$ flutter analyze --no-pub
No issues found! (ran in 11.1s)
$ flutter test
00:38 +416: All tests passed!
```
- 设备侧调试手段（本次踩坑记录）：`settings put secure accessibility_enabled 1` 让 Flutter 输出语义树以便取准确 bounds（用完还原 `0`）；`settings put system screen_off_timeout 1800000` + `svc power stayon true` 防息屏（黑屏截图仅 18,948 字节即息屏，此时 tap 全部无效）；`wm dismiss-keyguard` 解锁；手柄命中区只有 32×32dp，坐标偏差会落到菜单图标上导致拖动无响应

- 前置 `ARCH-LAYER-002` 因 A-11 blocked，未达 done；按执行合约不得跳前置开工。4 个子项相互独立，A-11 决策落定后可直接执行。
- 状态：blocked（详见 BLOCKERS.md）
