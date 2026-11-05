import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/note_dedupe.dart';
import 'package:uuid/uuid.dart';

/// 服务端笔记的 uid 归位成本地主键。
///
/// 服务端笔记的 `id` 是 memo uid，本地主键是本地 uuid。合并前必须统一：
///   1) 本地已有 `remoteId == uid` 的笔记 → 复用其 id（正常路径）
///   2) 旧数据里 id 本身就是 uid → 复用该 id，同时补写 remoteId
///   3) 本地有条「远端 uid 已经不在服务端、正文完全相同」的更早记录 → 认领它
///      （服务端那条其实是这条笔记被删后重建出来的副本，时间是新造的）
///   4) 都对不上 → 新建一个本地 uuid
///
/// 顺手把引用关系里的 uid 换成本地 id、补上 remoteId 并标记已同步。
/// 拉取路径都必须走这里：否则服务端笔记会以 uid 当主键重新落库，本地那条
/// （带真实创建时间 / 批注 / 置顶）会被剪掉，时间也被服务端时间顶替。
///
/// [allowContentClaim] 只在确认拿到了完整服务端列表时开启：列表不全时，
/// 「远端 uid 不在列表里」不等于「远端已删」，认领会把两条独立笔记并成一条。
List<Note> bindServerNotesToLocalIds(
  List<Note> serverNotes,
  List<Note> localNotes, {
  bool allowContentClaim = false,
}) {
  final localIdByRemote = <String, String>{
    for (final local in localNotes)
      if (local.remoteId != null && local.remoteId!.isNotEmpty)
        local.remoteId!: local.id,
  };
  final localIds = localNotes.map((note) => note.id).toSet();

  final matched = <String, String>{}; // uid -> 本地 id
  final claimedLocalIds = <String>{};
  for (final serverNote in serverNotes) {
    final uid = serverNote.id;
    final localId =
        localIdByRemote[uid] ?? (localIds.contains(uid) ? uid : null);
    if (localId != null) {
      matched[uid] = localId;
      claimedLocalIds.add(localId);
    }
  }

  if (allowContentClaim && matched.length < serverNotes.length) {
    final serverUids = serverNotes.map((note) => note.id).toSet();
    final orphanByHash = <String, List<Note>>{};
    for (final local in localNotes) {
      if (claimedLocalIds.contains(local.id)) {
        continue;
      }
      final remote = local.remoteId;
      // 服务端还认这条 → 它对应的 memo 还在，不能当成被重建的副本
      if (remote != null && remote.isNotEmpty && serverUids.contains(remote)) {
        continue;
      }
      orphanByHash.putIfAbsent(noteContentHash(local), () => []).add(local);
    }
    for (final bucket in orphanByHash.values) {
      bucket.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    for (final serverNote in serverNotes) {
      if (matched.containsKey(serverNote.id)) {
        continue;
      }
      final bucket = orphanByHash[noteContentHash(serverNote)];
      if (bucket == null) {
        continue;
      }
      for (final candidate in bucket) {
        // 同内容的服务端副本可以都绑到这条更早的本地记录上，多出来的那条
        // 会在下面按本地 id 去重掉。
        if (!candidate.createdAt.isBefore(serverNote.createdAt)) {
          continue;
        }
        matched[serverNote.id] = candidate.id;
        break;
      }
    }
  }

  final uidToLocalId = <String, String>{};
  for (final serverNote in serverNotes) {
    uidToLocalId[serverNote.id] = matched[serverNote.id] ?? const Uuid().v4();
  }

  // 一条本地笔记可能对上多条服务端记录（历史上被重复重建过）：只留一条，
  // 否则写库时同一个 id 会被覆盖成最后一条。
  final seenLocalIds = <String>{};
  final bound = <Note>[];
  for (final note in serverNotes) {
    final uid = note.id;
    final localId = uidToLocalId[uid]!;
    if (!seenLocalIds.add(localId)) {
      continue;
    }
    bound.add(
      note.copyWith(
        id: localId,
        remoteId: uid,
        isSynced: true,
        relations: note.relations.isEmpty
            ? note.relations
            : note.relations.map((relation) {
                final mapped = Map<String, dynamic>.from(relation);
                for (final key in const ['memoId', 'relatedMemoId']) {
                  final raw = mapped[key]?.toString();
                  final target = raw == null ? null : uidToLocalId[raw];
                  if (target != null) {
                    mapped[key] = target;
                  }
                }
                return mapped;
              }).toList(),
      ),
    );
  }
  return bound;
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

  // 只差附件 uid 时算「同一篇」：同一条带图笔记被两条通道各传一次，图片会
  // 拿到不同的附件目录 uid。若按原文比较会当成服务端有改动，时间线被服务端
  // 重建的时间顶掉。
  final serverHasDifferentContent =
      normalizeNoteContentForDedupe(serverNote.content) !=
          normalizeNoteContentForDedupe(localNote.content);
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
