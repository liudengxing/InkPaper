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
  );
}

bool _isValidServerTimestamp(DateTime value) =>
    value.millisecondsSinceEpoch > 0;
