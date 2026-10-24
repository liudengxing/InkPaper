import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/annotation_model.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/sync_merge_helper.dart';

Note _note({
  required String id,
  required String content,
  DateTime? createdAt,
  DateTime? updatedAt,
  List<Annotation>? annotations,
  bool isSynced = true,
}) =>
    Note(
      id: id,
      content: content,
      createdAt: createdAt ?? DateTime(2024),
      updatedAt: updatedAt ?? DateTime(2024),
      annotations: annotations ?? const [],
      isSynced: isSynced,
    );

void main() {
  group('bindServerNotesToLocalIds', () {
    Note localOnly(String id, {String? remoteId}) => Note(
          id: id,
          content: '正文',
          createdAt: DateTime(2024),
          updatedAt: DateTime(2024),
          remoteId: remoteId,
        );

    test('remoteId 命中时复用本地 id，并补写 remoteId', () {
      final bound = bindServerNotesToLocalIds(
        [_note(id: 'uid-1', content: '正文')],
        [localOnly('local-uuid', remoteId: 'uid-1')],
      );

      expect(bound.single.id, 'local-uuid');
      expect(bound.single.remoteId, 'uid-1');
      expect(bound.single.isSynced, isTrue);
    });

    test('旧数据 id 本身就是 uid 时原样复用', () {
      final bound = bindServerNotesToLocalIds(
        [_note(id: 'uid-2', content: '正文')],
        [localOnly('uid-2')],
      );

      expect(bound.single.id, 'uid-2');
      expect(bound.single.remoteId, 'uid-2');
    });

    test('都对不上时分配新的本地 uuid，不会用 uid 当主键', () {
      final bound = bindServerNotesToLocalIds(
        [_note(id: 'uid-3', content: '正文')],
        [localOnly('local-uuid', remoteId: 'uid-old')],
      );

      expect(bound.single.id, isNot('uid-3'));
      expect(bound.single.id.length, 36);
      expect(bound.single.remoteId, 'uid-3');
    });

    test('引用关系里的 uid 换成对应的本地 id', () {
      final serverA = _note(id: 'uid-a', content: '正文 A').copyWith(
        relations: [
          {'memoId': 'uid-b', 'relatedMemoId': 'uid-a'},
        ],
      );
      final serverB = _note(id: 'uid-b', content: '正文 B');

      final bound = bindServerNotesToLocalIds(
        [serverA, serverB],
        [
          localOnly('local-a', remoteId: 'uid-a'),
          localOnly('local-b', remoteId: 'uid-b'),
        ],
      );

      final boundA = bound.firstWhere((note) => note.remoteId == 'uid-a');
      expect(boundA.relations.single['memoId'], 'local-b');
      expect(boundA.relations.single['relatedMemoId'], 'local-a');
    });
  });

  test('SYNC-MERGE-03 preserves local historical timeline after upload refresh',
      () {
    final local = _note(
      id: 'server-1',
      content: 'old offline note',
      createdAt: DateTime(2021, 5, 1, 8),
      updatedAt: DateTime(2021, 5, 1, 9),
    );
    final server = _note(
      id: 'server-1',
      content: 'old offline note',
      createdAt: DateTime(2026, 6, 14, 10),
      updatedAt: DateTime(2026, 6, 14, 10),
    );

    final merged = mergeServerNoteWithLocalState(server, local);

    expect(merged.createdAt, local.createdAt);
    expect(merged.updatedAt, local.updatedAt);
  });

  test('SYNC-MERGE-03B uses server timeline on normal refresh', () {
    final local = _note(
      id: 'server-1',
      content: 'same content',
      createdAt: DateTime(2026, 6, 14, 10),
      updatedAt: DateTime(2026, 6, 14, 10),
    );
    final server = _note(
      id: 'server-1',
      content: 'same content',
      createdAt: DateTime(2022, 1, 1, 8),
      updatedAt: DateTime(2022, 1, 2, 9),
    );

    final merged = mergeServerNoteWithLocalState(server, local);

    expect(merged.createdAt, server.createdAt);
    expect(merged.updatedAt, server.updatedAt);
  });

  test('SYNC-MERGE-03C explicit upload refresh preserves local timeline', () {
    final local = _note(
      id: 'server-1',
      content: 'offline note',
      createdAt: DateTime(2021, 5, 1, 8),
      updatedAt: DateTime(2021, 5, 1, 9),
    );
    final server = _note(
      id: 'server-1',
      content: 'offline note',
      createdAt: DateTime(2026, 6, 14, 10),
      updatedAt: DateTime(2026, 6, 14, 10),
    );

    final merged = mergeServerNoteWithLocalState(
      server,
      local,
      preserveLocalTimeline: true,
    );

    expect(merged.createdAt, local.createdAt);
    expect(merged.updatedAt, local.updatedAt);
  });

  test('SYNC-MERGE-04 uses server updatedAt when server content really changed',
      () {
    final local = _note(
      id: 'server-2',
      content: 'old content',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024, 1, 2),
    );
    final server = _note(
      id: 'server-2',
      content: 'new remote content',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024, 2),
    );

    final merged = mergeServerNoteWithLocalState(server, local);

    expect(merged.createdAt, local.createdAt);
    expect(merged.updatedAt, server.updatedAt);
    expect(merged.content, server.content);
  });

  test('SYNC-MERGE-05 拉取时保留本地未上传的改动，不写回服务端旧内容', () {
    final local = _note(
      id: 'server-3',
      content: '本地刚编辑的内容',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024, 3),
      isSynced: false, // 上传失败，仍在待上传队列
    );
    final server = _note(
      id: 'server-3',
      content: '服务端旧内容',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024, 2),
    );

    final merged = mergeServerNoteWithLocalState(
      server,
      local,
      keepLocalPendingChanges: true,
    );

    expect(merged.content, local.content);
    expect(merged.isSynced, isFalse, reason: '仍应留在待上传队列，下次继续重试');
  });

  test('SYNC-MERGE-06 上传成功后的回写不受保护开关影响，标记为已同步', () {
    final local = _note(
      id: 'server-4',
      content: '刚上传成功的内容',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024, 3),
      isSynced: false,
    );
    final server = _note(
      id: 'server-4',
      content: '刚上传成功的内容',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024, 3),
    );

    final merged = mergeServerNoteWithLocalState(
      server,
      local,
      preserveLocalTimeline: true,
    );

    expect(merged.isSynced, isTrue);
    expect(merged.content, server.content);
  });
}
