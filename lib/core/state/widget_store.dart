/// 桌面小组件域状态（`STATE-CORE-005` 第六步）。
///
/// 桌面小组件快照是异步（350ms 防抖）生成的，期间若笔记再次变化，旧快照必须作废。
/// 用单调递增的序号做版本号：调度时记录 `++snapshotUpdateId`，真正写快照前比对，
/// 不一致就放弃这次写入。
///
/// 只做字段归属迁移，`AppProvider` 仅保留 `_widgetStore.` 转发。
class WidgetStore {
  /// 小组件快照的调度序号；每次调度自增，写入前比对以丢弃过期快照。
  int snapshotUpdateId = 0;
}
