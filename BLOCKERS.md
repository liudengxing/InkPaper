## STATE-CORE-001 子项 2 · 2026-10-21

**问题**：验收「`note_editor.dart` setState ≤ 25」严于实际目标「输入路径不触发整页 setState」。

**已尝试**：`_lineCount` 改 `ValueNotifier` + `ValueListenableBuilder`，输入派生状态不再 `setState`；`flutter analyze` 0 issue。

**实测**：`setState` 38（改前 39）、`ValueListenableBuilder` 1。

**要你决定**：

- A. 把验收改为「输入路径（`_updateLineCount` / `_detectTagInput`）内 setState 为 0」→ 本条可立即 done
- B. 维持 25，另开任务逐个把交互态改成局部 `setState`（约 13 处，风险中等，预计 1–2 轮）

**影响**：该子项 blocked，已跳过；不影响子项 3 的结论。
