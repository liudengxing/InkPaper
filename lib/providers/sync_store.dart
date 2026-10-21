/// 同步域的状态载体。
///
/// 从 `AppProvider`（4.4k 行单类）中拆出的第一步：先集中同步相关的可变状态，
/// 后续再把同步方法体迁入本类。当前只承载状态，业务方法仍由 AppProvider 持有，
/// 因此对外行为不变。
class SyncStore {
  /// 是否正在同步（用于顶部提示条）。
  bool isSyncing = false;

  /// 同步过程提示文案；null 表示无提示。
  String? message;

  /// 正在上传中的笔记 id，用于避免同一笔记并发上传。
  final Set<String> syncingNoteIds = <String>{};

  /// 更新同步 UI 状态，返回是否有实际变化（供调用方决定是否通知）。
  bool update({bool? syncing, String? message}) {
    var changed = false;
    if (syncing != null && syncing != isSyncing) {
      isSyncing = syncing;
      changed = true;
    }
    if (message != this.message) {
      this.message = message;
      changed = true;
    }
    return changed;
  }

  /// 清空同步状态（同步结束或退出登录时使用）。
  void reset() {
    isSyncing = false;
    message = null;
    syncingNoteIds.clear();
  }
}
