import 'package:inkpaper/models/note_model.dart';
import 'package:uuid/uuid.dart';

/// 服务端笔记的 uid 归位成本地主键。
///
/// 服务端笔记的 `id` 是 memo uid，本地主键是本地 uuid。合并前必须统一：
///   1) 本地已有 `remoteId == uid` 的笔记 → 复用其 id（正常路径）
///   2) 旧数据里 id 本身就是 uid → 复用该 id，同时补写 remoteId
///   3) 都对不上 → 新建一个本地 uuid
///
/// 顺手把引用关系里的 uid 换成本地 id、补上 remoteId 并标记已同步。
/// 拉取路径都必须走这里：否则服务端笔记会以 uid 当主键重新落库，本地那条
/// （带真实创建时间 / 批注 / 置顶）会被剪掉，时间也被服务端时间顶替。
List<Note> bindServerNotesToLocalIds(
  List<Note> serverNotes,
  List<Note> localNotes,
) {
  final localIdByRemote = <String, String>{
    for (final local in localNotes)
      if (local.remoteId != null && local.remoteId!.isNotEmpty)
        local.remoteId!: local.id,
  };
  final localIds = localNotes.map((note) => note.id).toSet();

  // 先整批定好 uid → 本地 id，引用关系转换要用到别的笔记的 id
  final uidToLocalId = <String, String>{};
  for (final serverNote in serverNotes) {
    final uid = serverNote.id;
    final claimed =
        localIdByRemote[uid] ?? (localIds.contains(uid) ? uid : null);
    uidToLocalId[uid] = claimed ?? const Uuid().v4();
  }

  return serverNotes.map((note) {
    final uid = note.id;
    return note.copyWith(
      id: uidToLocalId[uid],
      remoteId: uid,
      isSynced: true,
      relations: note.relations.isEmpty
          ? note.relations
          : note.relations.map((relation) {
              final mapped = Map<String, dynamic>.from(relation);
              for (final key in const ['memoId', 'relatedMemoId']) {
                final raw = mapped[key]?.toString();
                final localId = raw == null ? null : uidToLocalId[raw];
                if (localId != null) {
                  mapped[key] = localId;
                }
              }
              return mapped;
            }).toList(),
    );
  }).toList();
}

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
