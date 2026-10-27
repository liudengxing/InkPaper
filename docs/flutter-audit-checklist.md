# Flutter 项目审计规则集（供 AI 逐维度对照）

用途：放到项目的 `docs/flutter-audit-checklist.md`，配合 `FLUTTER_AUDIT_PROMPT.md` 使用。
每条都给了检测方法，AI 应当**实际执行检测**，而不是凭印象判断。
严重度缩写：P0 明显浪费/崩溃风险 · P1 高频路径性能 · P2 架构债 · P3 风格。

---

## 1. 架构与分层

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| 页面内直接创建网络客户端 | `rg "Dio\(|http\.(get|post|Client)" lib/`，看是否发生在 page/widget 层 | P2 |
| 缺少 repository/service 层，UI 直接调 API | 看 page 里是否 import 了接口地址常量或直接拼 URL | P2 |
| 跨层反向引用（presentation 引 data 的内部实现） | `rg "import .*(data|infra)/" lib/presentation lib/pages lib/features` | P2 |
| 路由用裸字符串，无集中注册 | `rg "pushNamed\(" ` 后对照是否所有 route 名都来自常量/枚举 | P3 |
| 业务逻辑写在 Widget 内（校验、金额计算、格式转换） | 看 build 方法和事件回调的体量 | P2 |
| 全局可变单例被到处 import | `rg "static final .*= .*\(\)"` + 看引用处数量 | P2 |

分层合格的判断标准不是"有没有文件夹"，而是**依赖方向单向**：UI 依赖抽象，抽象在 domain，实现可替换。

---

## 2. 状态管理与重建范围

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| setState 覆盖整页，任意小改动触发全页重建 | `rg "setState\(" -c lib/` 统计密集文件；读回调内部改了几个字段 | P1 |
| Provider 在根部提供大对象，订阅粒度太粗 | `rg "context\.watch|Consumer<|Selector<"`，watch 大对象 = 全量重建 | P1 |
| 该用 `select` 的地方用了 `watch` | 对比 `context.select` 出现次数 | P1 |
| 状态类同时承担 IO、缓存、UI 状态 | 看类的方法数，超过 15 个方法通常该拆 | P2 |
| 初始化逻辑写在 build 里 | `rg "\.then\(|await " 在 build 作用域内 | P0 |
| ChangeNotifier 忘记 dispose | `rg "ChangeNotifier"` 后检查对应 dispose | P1 |

---

## 3. Widget 重建

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| 缺 const 构造 | `flutter analyze` 中 prefer_const_constructors 计数 | P1 |
| 用方法返回 Widget（`Widget _buildX()`）拆 UI | `rg "Widget _build"`，这类拆法不减少重建，应抽成独立 Widget 类 | P1 |
| build 内做排序/过滤/JSON 解析 | 读 build 方法体，找 `sort(` `where(` `map(` `jsonDecode` | P1 |
| Opacity 包大子树 | `rg "Opacity\("`，非动画场景应改用颜色带透明度的写法 | P2 |
| ClipRRect / ClipPath 包整页 | `rg "ClipRRect\("` 看包裹范围 | P2 |
| 高频动画区域未加 RepaintBoundary | 滚动列表 item、独立动画组件 | P2 |
| build 内 new 对象传给子组件（破坏 const 传播） | 看子组件是否因传闭包/列表导致无法 const | P2 |

---

## 4. 列表与滚动

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| 长列表用 Column + SingleChildScrollView | `rg "SingleChildScrollView"`，内部是否有 `.map(` 或大量子 Widget | P0 |
| 列表未用 builder 系列 | 对比 `ListView\(` 与 `ListView.builder` 出现次数 | P0 |
| 缺 itemExtent / prototypeItem（等高空列表） | 看 builder 参数 | P2 |
| 用 index 作为 key | `rg "key: ValueKey\(index\)|Key\('?\$index"` | P1 |
| shrinkWrap: true 造成全量布局 | `rg "shrinkWrap: true"` | P1 |
| 嵌套滚动（ListView 套 ListView） | 同上，通常应该合并成 CustomScrollView + Sliver | P1 |
| 列表 item 是 Stateful 且有动画，滚动时被反复重建 | 看 item 组件生命周期 | P2 |

---

## 5. 图片与资源

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| 本地图片未指定解码尺寸 | `rg "Image\.asset"`，检查有无 cacheWidth/cacheHeight | P1 |
| 网络图未走缓存库 | `rg "Image\.network"`，应为 cached_network_image 或自建缓存 | P1 |
| 资源目录有大图 | 遍历 assets 目录按文件大小排序，列出 Top 10 | P0 |
| 图标未 tree-shake | 检查构建命令是否有 `--tree-shake-icons` | P2 |
| 全量字体打包（含未使用字重） | 看 pubspec 的 fonts 声明与实际使用字重 | P2 |
| 图片格式未优化（大 PNG 可转 WebP） | 按体积排序看扩展名分布 | P2 |

---

## 6. 异步与 isolate

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| 大 JSON 在主 isolate 解码 | `rg "jsonDecode"`，判断数据量（接口返回体大小）| P1 |
| 循环内串行 await | `rg "for \(|forEach"` 附近出现 `await`，应改 `Future.wait` | P1 |
| 文件/数据库同步 API 阻塞 UI | `rg "readAsStringSync|writeAsStringSync|\.rawQuery"` | P0 |
| 搜索/输入无防抖 | `rg "onChanged|addListener"` 附近看有无 Debounce/Timer | P1 |
| 未处理的 Future 异常 | `rg "unawaited|\.then\("` 无 catchError | P1 |
| compute 被滥用在小任务上 | 反查：数据量小时 isolate 开销大于收益 | P3 |

---

## 7. 网络与缓存

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| 无统一拦截器（日志/token 刷新/重试） | 读网络客户端初始化处 | P2 |
| 未设置超时 | `rg "Dio\(|BaseOptions"` 看 connectTimeout/receiveTimeout | P1 |
| 错误处理分散，每处 try-catch 各写一套 | 统计 catch 块数量与差异 | P2 |
| 高频只读接口无本地缓存 | 看是否有缓存层或 shared_preferences 兜底 | P2 |
| 缺少取消机制（页面销毁后请求仍回写状态） | `rg "CancelToken|mounted"` | P1 |

---

## 8. 启动与包体积

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| main 里同步做耗时初始化 | 读 main 与 runApp 前的所有 await | P1 |
| 首屏依赖的网络请求阻塞渲染 | 看首屏是否 await 后才 setState | P1 |
| 未开混淆与符号分离 | 检查构建脚本 `--obfuscate --split-debug-info` | P3 |
| 声明了但未使用的依赖 | `for pkg in pubspec依赖; rg "package:$pkg"; 无结果即未使用` | P2 |
| 依赖里有重型重型库可替换 | 看 pubspec 里体积大的包（如全量 intl、全量图表库）| P2 |

---

## 9. 代码复杂度

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| 单文件超 500 行 / 单类超 800 行 | 行数 Top 20 排序 | P2 |
| 单方法超 80 行 | 扫描方法体长度 | P2 |
| 嵌套超过 4 层（if/for 混嵌） | 人工抽读热点文件 | P2 |
| 魔法数字/字符串散落 | `rg "\"[a-z_]{3,}\""` 排除 UI 文案 | P3 |
| 大量注释掉的死代码 | `rg "^\s*//.*\(|/\*"` 抽样 | P3 |

---

## 10. 质量门禁

| 检查项 | 检测方法 | 严重度 |
|---|---|---|
| analysis_options.yaml 是否启用 recommended lints | 读文件，看 include 与 rules | P2 |
| flutter analyze 是否零 error | 直接跑 | P0 |
| 是否有 CI 跑 analyze + test | 看 .github/workflows 或 .gitlab-ci.yml | P2 |
| 是否有 test 目录及覆盖核心逻辑 | 看 test/ 结构 | P2 |
| 是否启用 dart format 校验 | CI 里是否有 `--set-exit-if-changed` | P3 |

---

## 输出要求（配合主控 Prompt 的 Stage 2）

每条问题一行，字段固定：

```
| ID | 维度 | 严重度 | 文件:行 | 问题 | 证据 | 修法 | 收益 | 置信度 |
```

证据必须是仓库里真实存在的代码片段，不超过 3 行。若只是模式特征而无直接证据，置信度标"中"，并在修法里写清需要什么运行时数据来确认。
