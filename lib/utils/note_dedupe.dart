import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:inkpaper/models/note_model.dart';

/// 附件路径里的资源 uid：`/file/attachments/<uid>/<文件名>`。
///
/// 同一条带图笔记被两个同步通道各上传一次时，图片会被传成两份、
/// 拿到两个不同的附件目录 uid，但文件名（`image_<时间戳>.jpg`）一致。
/// 直接比正文会把这些当成两条不同笔记。
final _attachmentPathPattern = RegExp(r'(/(?:file|api/v1)/attachments/)[^/\s)]+/');

/// 归一化正文：抹掉附件路径里的资源 uid，只保留文件名。
String normalizeNoteContentForDedupe(String content) =>
    content.replaceAllMapped(_attachmentPathPattern, (match) => match[1]!);

/// 笔记正文的内容指纹（不含时间戳、置顶、标签等元数据）。
///
/// 用途是识别「同一条笔记的两种 id」：远端被删后重建、本地导入重复、
/// 双端各自新建同一段内容等。附件 uid 会被归一化掉，见上。
String noteContentHash(Note note) => sha256
    .convert(utf8.encode(normalizeNoteContentForDedupe(note.content)))
    .toString();

/// 按内容哈希分组，避免在批量匹配时对同一条笔记反复做 sha256。
Map<String, List<Note>> groupNotesByContentHash(Iterable<Note> notes) {
  final groups = <String, List<Note>>{};
  for (final note in notes) {
    groups.putIfAbsent(noteContentHash(note), () => <Note>[]).add(note);
  }
  return groups;
}

/// 在候选池里找「内容一致、创建时间接近」的同一条笔记。
///
/// 场景：同一条笔记在不同同步通道里拿到了不同 id —— WebDAV 快照里是上一个
/// 本地 uuid，Memos 重新签发后是服务端 uid。只按 id 匹配会把它当成新笔记
/// 再插一份，于是同一段内容在列表里出现两条。
///
/// 用「内容哈希 + 创建时间容差」而不是只比内容：用户完全可能在两个时间点
/// 写两段一模一样的正文，那种情况必须保留两条。
Note? findContentDuplicate({
  required Note candidate,
  required Map<String, List<Note>> poolByHash,
  Duration tolerance = const Duration(minutes: 5),
}) {
  final bucket = poolByHash[noteContentHash(candidate)];
  if (bucket == null || bucket.isEmpty) {
    return null;
  }
  for (final other in bucket) {
    if (other.id == candidate.id) {
      return null; // 同 id 不在这里处理，交给 id 匹配逻辑
    }
    if (candidate.createdAt.difference(other.createdAt).abs() <= tolerance) {
      return other;
    }
  }
  return null;
}

/// 合并重复笔记的结果。
class DuplicateMergeReport {
  const DuplicateMergeReport({
    required this.removed,
    this.remoteDeleted = 0,
    this.remoteFailed = 0,
  });

  /// 本地删除的副本条数。
  final int removed;

  /// 服务端同时删除的副本条数。
  final int remoteDeleted;

  /// 服务端删除失败的条数（失败的下次同步会再冒出来）。
  final int remoteFailed;

  bool get hasRemoteFailure => remoteFailed > 0;
}

/// 库内自去重的结果：保留的笔记 + 需要删除的副本 id + 被合并改动过的保留条。
class DedupeResult {
  const DedupeResult({
    required this.notes,
    required this.removedIds,
    required this.updatedNotes,
  });

  final List<Note> notes;
  final List<String> removedIds;

  /// 元数据被并入过、需要回写的保留条。
  final List<Note> updatedNotes;
}

/// 把同一段内容、创建时间接近的多条笔记合并成一条。
///
/// 解决「Memos 同步 + WebDAV 同步同时开启」后同一笔记在列表里出现两份：
/// 两条的 id 不同（一条是 WebDAV 快照里的本地 uuid，一条是 Memos 服务端 uid），
/// 只按 id 合并永远碰不到一起。
///
/// 保留哪条：创建时间最早的那条（通常是最初写入的原始记录），元数据取并集。
/// 默认只合并「内容完全一致且创建时间相差 ≤ 5 分钟」的组合，用户在两个时间点写的
/// 相同正文不会被误删。
///
/// [matchContentOnly] 为 true 时忽略创建时间差，只按正文逐字相同判定。
/// 用于清理「同一篇笔记被导入/恢复过两次」的残留：那种情况下两份的
/// createdAt 可能隔着好几天（服务端重建时套用了自己的时间）。
DedupeResult dedupeDuplicateNotes(
  List<Note> notes, {
  Duration tolerance = const Duration(minutes: 5),
  bool matchContentOnly = false,
}) {
  final removedIds = <String>[];
  final updatedNotes = <Note>[];
  final kept = <Note>[];

  final groups = groupNotesByContentHash(notes);
  for (final bucket in groups.values) {
    if (bucket.length < 2) {
      kept.addAll(bucket);
      continue;
    }

    // 排序必须完全确定：createdAt 相同（双通道重复的典型特征，精确到微秒一致）
    // 时用 id 兜底，否则同一批数据每次跑可能留下不同的那条，
    // 导致同步每轮换一次 id、WebDAV 的 remoteId 反复漂移。
    final sorted = [...bucket]..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    final survivors = <Note>[];
    for (final note in sorted) {
      Note? mergedInto;
      var mergedIndex = -1;
      for (var i = 0; i < survivors.length; i++) {
        final withinWindow = matchContentOnly ||
            note.createdAt.difference(survivors[i].createdAt).abs() <=
                tolerance;
        if (withinWindow) {
          mergedInto = survivors[i];
          mergedIndex = i;
          break;
        }
      }

      if (mergedInto == null) {
        survivors.add(note);
        continue;
      }

      final merged = mergedInto.copyWith(
        isPinned: mergedInto.isPinned || note.isPinned,
        annotations: mergedInto.annotations.isNotEmpty
            ? mergedInto.annotations
            : note.annotations,
        reminderTime: mergedInto.reminderTime ?? note.reminderTime,
        relations: mergedInto.relations.isNotEmpty
            ? mergedInto.relations
            : note.relations,
        tags: {...mergedInto.tags, ...note.tags}.toList(),
        // 时间线必须沿用保留条，不能取两者的 max：副本经常是「服务端重新
        // 创建出来的同内容记录」，它的 createdAt/updatedAt 是重建那一刻
        // 的时间。一旦把副本的 updatedAt 提上来，卡片（显示 updatedAt）就会
        // 显示重建时间——用户看到的就是「一堆笔记的时间都变成同一分钟」。
        isSynced: mergedInto.isSynced && note.isSynced,
      );
      survivors[mergedIndex] = merged;
      updatedNotes.add(merged);
      removedIds.add(note.id);
    }
    kept.addAll(survivors);
  }

  return DedupeResult(
    notes: kept,
    removedIds: removedIds,
    updatedNotes: updatedNotes,
  );
}

/// 找出「内容与服务端某条完全一致、但 id 不同」的本地未同步副本。
///
/// 典型来源：另一台设备删掉笔记后重建（拿到新 id），本机这条旧 id 还有未上传
/// 改动。同步剪枝只处理 `is_synced = 1` 的行，会跳过它，于是库里同时留下两条
/// 内容相同的笔记。
///
/// 只返回未同步的副本 —— 已同步的由 `deleteSyncedNotesNotIn` 按 id 剪掉。
/// 调用方负责把本地增强数据（置顶、批注、引用）并到服务端那条上，再删副本。
///
/// 返回：本地副本 id -> 对应的服务端笔记。
Map<String, Note> findDuplicateLocalCopies({
  required List<Note> localNotes,
  required List<Note> serverNotes,
}) {
  final serverIds = serverNotes.map((note) => note.id).toSet();
  final serverByHash = <String, Note>{
    for (final note in serverNotes) noteContentHash(note): note,
  };

  final copies = <String, Note>{};
  for (final note in localNotes) {
    if (note.isSynced || serverIds.contains(note.id)) {
      continue;
    }
    final target = serverByHash[noteContentHash(note)];
    if (target != null) {
      copies[note.id] = target;
    }
  }
  return copies;
}
