## STATE-CORE-001 子项 1 · 2026-10-21

**问题**：验收阈值「`app_provider.dart` ≤ 3500 行、`notifyListeners` ≤ 42」与「只拆同步域」的作用域不匹配。

**已尝试**：抽出 `SyncStore` 承载同步 UI 状态（`isSyncing` / `message` / `syncingNoteIds`），`AppProvider` 以 getter/setter 转发；`flutter analyze` 0 issue、`test/unit` 328 项通过。

**实测**：`app_provider.dart` 4475 行（拆分前 4434，转发代码抵消了搬迁收益）；`notifyListeners` 58。

**要你决定**：

- A. 放宽为「≤ 4400 行 + notify ≤ 55」，要求仅为「同步状态先抽出」（本轮已完成）
- B. 扩大作用域到认证域（`registerWithPassword` / `loginWithPassword` / `loginWithToken` / `logout`，约 490 行）或允许迁出 `updateNote` / 删除队列，才有机会降到 3500
- C. 保持阈值，把该子项改写为「完整拆出 SyncStore + AuthStore」，分 3–4 轮执行

**影响**：该子项 blocked，已跳过；子项 3 已完成，子项 4 未开始。

---

## STATE-CORE-001 子项 2 · 2026-10-21

**问题**：验收「`note_editor.dart` setState ≤ 25」严于实际目标「输入路径不触发整页 setState」。

**已尝试**：`_lineCount` 改 `ValueNotifier` + `ValueListenableBuilder`，输入派生状态不再 `setState`；`flutter analyze` 0 issue。

**实测**：`setState` 38（改前 39）、`ValueListenableBuilder` 1。

**要你决定**：

- A. 把验收改为「输入路径（`_updateLineCount` / `_detectTagInput`）内 setState 为 0」→ 本条可立即 done
- B. 维持 25，另开任务逐个把交互态改成局部 `setState`（约 13 处，风险中等，预计 1–2 轮）

**影响**：该子项 blocked，已跳过；不影响子项 3 的结论。
