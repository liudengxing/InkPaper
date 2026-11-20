# 故障速查（Troubleshooting）

> 按症状查，一条一行。**详细原因与背景见 [踩坑与经验](LESSONS_LEARNED.md)**（`§` 是那里的章节号）。
> 本页只保留本项目真实发生过的问题；通用 Flutter 报错请查 [Flutter 官方文档](https://docs.flutter.dev/) 或 Stack Overflow。

---

## 构建 / 环境

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| Gradle `insufficient memory` / `Chunk::new` / Dart `Could not start thread DartWorker` | 矿机占满内存 | 提权跑 `F:/WaKuang/bin/pause-miner.bat`，构建完 `resume-miner.bat`（§1.1） |
| `flutter test` 报 `Invalid WebSocket upgrade request` | 本地代理拦截 tester 的 WebSocket | `NO_PROXY=127.0.0.1,localhost no_proxy=...` 前缀跑测试（§1.2） |
| CI `Android` job 红在下载 `gradle-8.14.3-all.zip` 504 | CDN 抖动 | 重跑 job，别改依赖（§1.3） |
| 改了 Kotlin 只想验编译 | — | `cd android && ./gradlew :app:compileReleaseKotlin -x compileFlutterBuildRelease`（§1.4） |
| `adb install -r` 说成功但版本没变 | streamed 安装静默失败 | 改 `adb push` + `pm install -r -d`（§1.5） |
| `dart format` 说 0 changed，analyze 报尾随逗号 | 两个检查互不相干 | 补 `,` 后重跑 `dart tool/inkpaper.dart analyze`（§2.1） |

---

## 测试

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| `pumpAndSettle timed out` | 页面有无限动画（查看器转圈） | 改定长 `pump(...)`（§2.5） |
| `A Timer is still pending` | 组件里有兜底 `Future.delayed` | 测试末尾 `pump(Duration(seconds: 5))`（§2.5） |
| 测试里构造中文响应体抛异常 | `http.Response(String)` 按 latin1 解码 | 用 `http.Response.bytes(utf8.encode(...), 200)`（§2.4） |
| 玻璃组件在测试里长得不对 | 测试环境是 FakeGlass，无 Impeller | 只验结构，观感上真机（§2.6） |

---

## 运行 / UI

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| 详情页正文点不进编辑态 | 用了 `SelectableText` / `SelectionArea` | 正文必须 `Text.rich`（§5.1） |
| 进编辑页闪一下 | 编辑页自定义了字号，与详情页不一致 | 共用 `AppTextStyles.bodyLarge(...)`（§5.3） |
| 编辑页九宫格点图没反应 | `_buildGridTile` 缺 `onTap` | 走 `ImageViewerScreen.open`（§5.4） |
| 撤销 SnackBar 样式改不动 | 视觉由玻璃层给，SnackBar 只是透明容器 | 改 `LiquidGlassLayer` 参数（§5.5） |
| 侧边栏选中块发灰 / 加 tint 也救不回 | 抽屉里玻璃采样到的是遮罩层，不是白底 | 改成手搓渐变胶囊，别调参（§5.5.1） |
| 点保存卡一下才关编辑器 | 保存路径全表加载 + 快照抢帧 | 引用重建短路、快照延后（§2.8） |
| 「有图片」只显示最近几张 | 扫了分页缓存而非全库 | 走 `getNotesByMedia` 全量查询（§5.6） |
| 切到「有图片」顶部还挂着那年今日 | 横幅不认筛选态 | 筛选激活时隐藏横幅（§5.6） |
| 侧边栏「全部笔记/有图片」同时高亮 | 三项共用 `/` 路由，只比了路径 | 选中态要带上当前筛选（§5.7） |

---

## 时间显示

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| 时间比实际晚 8 小时 | 多调了一次 `toLocal()` | 删掉，按 `createdAt` 原值格式化（§3.1） |
| 跨来源笔记排序在 8 小时窗口内错位 | 伪 UTC 的绝对时刻偏差，已知遗留问题 | 暂不修，动 `_parseTimestamp` 前先评估 WebDAV 冲突影响（§3.2） |

---

## 备份 / 媒体

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| WebDAV 上同一视频存了两份 | 流式哈希与整块哈希不一致 | 文件名必须用整块 sha1（§4.1） |
| 备份大文件时 OOM | 整块 `read()` 进内存 | 只走 `writeFromFile` / `read2File`（§4.2） |
| 服务端附件恢复后打不开 | `/o/r/<uid>` 无扩展名 | 用 resourceList 的 `filename` 补扩展名（§4.3） |
| 本地 ZIP 备份漏东西 / OOM | 单段超 150MB 或合计超 200MB | 超限跳过并计数，别赌（§4.4） |
| 视频被当成图片塞进 ZIP | `![alt](path)` 图片分支没排除视频 | 先过 `MediaPaths.isVideoMarkdown`（§4.4） |
| GIF / HEIC 缩略图黑图或取错帧 | 没传 `frame: 0`；HEIC 没设 SRGB | 见 §4.5 |
| 缩略图生成直接崩 | MethodChannel 被丢进 `compute()` | 只能在主 isolate 调（§4.5） |
| Live 图插入后没有动态部分 | `pickMultiImage()` 带了 quality/maxWidth | 去掉这两个参数（§4.6） |

---

## Android 小组件

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| 改了布局/背景毫无变化 | launcher 缓存 | `am force-stop com.miui.home` 再按 HOME（§6.1） |
| 新增的小组件不刷新 | 三处登记缺一处 | manifest + `inkPaperWidgetProviders` + `updateAllInkPaperWidgets()`（§6.2） |
| 小组件整块空白 | 快照字段缺失（曾缺 `todayIndex`） | 先核对 `widget_snapshot_service.dart` 字段（§6.3） |
| ListView 有深色背景块 | RemoteViews 缺透明属性 | 补 `cacheColorHint` / `listSelector`（§6.4） |
| 截图看着有重影 | 缩放插值造成的假象 | NEAREST 放大原始像素再看（§6.5） |

---

## 微信读书同步

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| 分页永远停在第一页 | 业务参数被包进了 `params` | 平铺到 body 顶层（§7） |
| 某接口一直报参数错 | `bookId` / `bookid` 大小写 | 按接口分别处理（§7） |
| 整次同步失败 | `skill_version` 落后官方 | 按 `upgrade_info.upgrade_url` 升级后重试（§7） |
| 读完的书没生成档案 | 用了 `markedStatus` / `finishReading` / `finish` | 只认 `getprogress` 的 `finishTime > 0`（§7） |
| 用户删掉的微信读书笔记又回来了 | 去重没查软删行 | 走 `getExistingNoteIds`（§7） |
| 周报时长差 60 倍 | `totalReadTime` 单位是秒 | 别当分钟用（§7） |

---

## 发版 / Git / 网络

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| `git push` 卡住或 502 | 代理形态变了 | 先探形态再选参数（§8.1） |
| curl 报 `CRYPT_E_NO_REVOCATION_CHECK` | schannel 走 Watt Toolkit 反代 | 加 `--ssl-no-revoke` / `http.schannelCheckRevoke=false`（§8.1） |
| Release 附件下载 0 字节 | 反代对大文件 GET 挂死 | 走 `https://ghfast.top/https://github.com/...`（§8.1） |
| API 调用报路径不存在 | Git Bash 把 `/rate_limit` 改写了 | `MSYS_NO_PATHCONV=1`（§8.8） |
| `release` 卡在 `git ls-remote` | 断网 | 本地打 tag + `push_tag.py`（§8.4） |
| Gitee `PATCH /releases/{id}` 失败 | 只带了 `tag_name` 或只带了 `name` | 两个都带（§8.5） |
| App 点检查更新 404 | Release 已建但 APK 还没传完 | 尽快补传，见 §8.5 的警告 |
| Gitee 上 APK 一直没有 | 指望 CI 上传 | CI 速率不允许，必须本地 `--sync-gitee` / `release-gitee`（§8.6） |
| 发版说明多出一条 `- ---` | 段落切分没去分隔线 | 见 §8.9 |
| 想看 CI 失败原因但没 token | job logs 需要鉴权 | 读 Checks annotation（`scripts/ci_annotate.sh`，§8.10） |

---

## 真机 / adb

| 症状 | 最可能原因 | 处理 |
| --- | --- | --- |
| `adb connect` 被拒 | 端口变了 / 没配对 | 先 `adb pair`，端口未知就扫 30000–65535（§9） |
| ping 不通但设备在线 | HyperOS 息屏丢 ICMP | 属正常，看 ARP 和 adb 状态（§9） |
| `adb pull` 路径被改写 | MSYS 路径转换 | 本地路径写 `Z:/Temp/x.png`，或关掉转换（§9） |
| `input text` 输入被吞 | 默认输入法是微信输入法插件 | 临时切搜狗 IME（§9） |
| 按返回键直接退出了页面 | 键盘没弹时 keyevent 4 就是返回 | 别用它收键盘（§9） |
| release 包读不到数据库 | 不可 `run-as` | 装 debug 包再查（§9） |

---

## 找不到答案时

1. 先跑 `dart tool/inkpaper.dart doctor`，排除环境问题。
2. 翻 [踩坑与经验](LESSONS_LEARNED.md) 对应章节，确认是不是已验证过的老问题。
3. 查 [未决问题](../../BLOCKERS.md)，可能是已知未修的。
4. 还没有就开 issue，附：Flutter 版本、完整报错、复现步骤、设备型号 / Android 版本。

<div align="center">

[返回文档索引](../README.md) · [踩坑与经验](LESSONS_LEARNED.md) · [调试指南](debugging.md)

</div>
