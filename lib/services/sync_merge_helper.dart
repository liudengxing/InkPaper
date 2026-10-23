import 'package:inkpaper/models/note_model.dart';

/// Merge server data into an existing local note without destroying local-only
/// state. Server timestamps win for normal refreshes so backup/restore mistakes
/// can be corrected; local timeline is kept only for offline-created notes that
/// are being acknowledged by the server.
Note mergeServerNoteWithLocalState(
  Note serverNote,
  Note localNote, {
  bool preserveLocalTimeline = false,
  bool keepLocalPendingChanges = false,
}) {
  // 拉取合并时，本地仍有「未上传成功」的改动 → 服务端拿到的是旧内容。
  // 此时保留本地版本并继续留在待上传队列，否则「上传失败 + 随后拉取」会把
  // 本地改动静默覆盖成服务端旧内容（用户表现为编辑丢失）。
  // 上传成功后的回写不能启用该开关，否则笔记永远不会被标记为已同步。
  if (keepLocalPendingChanges && !localNote.isSynced) {
    return localNote;
  }

  final serverHasDifferentContent = serverNote.content != localNote.content;
  final serverCreatedAt = _isValidServerTimestamp(serverNote.createdAt)
      ? serverNote.createdAt
      : localNote.createdAt;
  final localPredatesServerCreate = localNote.createdAt.isBefore(
    serverCreatedAt.subtract(const Duration(minutes: 1)),
  );
  final shouldPreserveLocalTimeline = preserveLocalTimeline ||
      (!serverHasDifferentContent &&
          localPredatesServerCreate &&
          localNote.updatedAt.isBefore(
            serverNote.updatedAt.add(const Duration(minutes: 1)),
          ));

  final mergedCreatedAt =
      shouldPreserveLocalTimeline ? localNote.createdAt : serverCreatedAt;
  final serverUpdatedAt = _isValidServerTimestamp(serverNote.updatedAt)
      ? serverNote.updatedAt
      : localNote.updatedAt;
  final mergedUpdatedAt =
      shouldPreserveLocalTimeline ? localNote.updatedAt : serverUpdatedAt;

  return serverNote.copyWith(
    createdAt: mergedCreatedAt,
    updatedAt: mergedUpdatedAt,
    displayTime: shouldPreserveLocalTimeline
        ? localNote.displayTime
        : (serverNote.displayTime == serverNote.updatedAt
            ? mergedUpdatedAt
            : serverNote.displayTime),
    isSynced: true,
    tags: serverHasDifferentContent
        ? serverNote.tags
        : (localNote.tags.isNotEmpty ? localNote.tags : serverNote.tags),
    isPinned: localNote.isPinned,
    relations: localNote.relations.isNotEmpty
        ? localNote.relations
        : serverNote.relations,
    annotations: localNote.annotations,
    reminderTime: localNote.reminderTime,
    // 服务端响应里没有 remote_id（直接解析 Memos 时 id 才是 uid），
    // 这里保底沿用本地已记录的 uid，调用方仍可用 serverNote.id 覆盖修正。
    remoteId: serverNote.remoteId ?? localNote.remoteId,
  );
}

bool _isValidServerTimestamp(DateTime value) =>
    value.millisecondsSinceEpoch > 0;

/// 判断一次「拉取合并」会不会丢掉一侧的改动。
///
/// 冲突定义：本地有未上传的改动（`is_synced = 0`），同时服务端内容与本地不同。
/// 也就是说两边自上次同步后都改过，单靠时间戳无法判断谁更新，合并必然要丢弃
/// 一侧。当前策略是以服务端为准（本地未同步但内容不同时会被覆盖），所以这个
/// 判断只用于计数和提示，不改变合并结果。
///
/// 注意不要用它判断「上传成功后的回写」：那条路径上的 localNote 本来就还是
/// `is_synced = 0`，会被误判成冲突。
bool isMergeConflict(Note serverNote, Note localNote) =>
    !localNote.isSynced &&
    serverNote.content.isNotEmpty &&
    serverNote.content != localNote.content;
