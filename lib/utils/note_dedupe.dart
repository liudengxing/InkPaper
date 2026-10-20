import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:inkpaper/models/note_model.dart';

/// 笔记正文的内容哈希（不含时间戳、置顶、标签等元数据）。
///
/// 用途是识别「同一条笔记的两种 id」：远端被删后重建、本地导入重复、
/// 双端各自新建同一段内容等。
String noteContentHash(Note note) =>
    sha256.convert(utf8.encode(note.content)).toString();

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
