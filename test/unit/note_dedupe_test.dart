import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/note_dedupe.dart';

Note _note(
  String id,
  String content, {
  bool isSynced = false,
  bool isPinned = false,
}) =>
    Note(
      id: id,
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      isSynced: isSynced,
      isPinned: isPinned,
    );

void main() {
  group('noteContentHash', () {
    test('内容相同则哈希相同，与 id 无关', () {
      expect(
        noteContentHash(_note('a', '同样内容')),
        noteContentHash(_note('b', '同样内容')),
      );
    });

    test('内容不同则哈希不同', () {
      expect(
        noteContentHash(_note('a', '内容 A')),
        isNot(noteContentHash(_note('a', '内容 B'))),
      );
    });

    test('空白差异会影响哈希', () {
      expect(
        noteContentHash(_note('a', '正文')),
        isNot(noteContentHash(_note('a', '正文 '))),
      );
    });

    test('附件资源 uid 不同、文件名相同 → 视为同一内容', () {
      // 双通道各上传一次时，同一张图会拿到两个附件目录 uid
      expect(
        noteContentHash(
          _note('a', '正文\n![图片](/file/attachments/AAA111/image_1790848653578.jpg)'),
        ),
        noteContentHash(
          _note('b', '正文\n![图片](/file/attachments/BBB222/image_1790848653578.jpg)'),
        ),
      );
    });

    test('附件文件名不同 → 仍是不同内容', () {
      expect(
        noteContentHash(
          _note('a', '正文\n![图片](/file/attachments/AAA111/image_1.jpg)'),
        ),
        isNot(
          noteContentHash(
            _note('b', '正文\n![图片](/file/attachments/AAA111/image_2.jpg)'),
          ),
        ),
      );
    });

    test('没有附件时归一化不改动正文', () {
      const text = '普通正文 #标签\n第二行';
      expect(normalizeNoteContentForDedupe(text), text);
    });
  });

  group('findDuplicateLocalCopies', () {
    test('识别同内容、不同 id 的未同步副本', () {
      final copies = findDuplicateLocalCopies(
        localNotes: [_note('old-id', '被重建过的正文')],
        serverNotes: [_note('new-id', '被重建过的正文', isSynced: true)],
      );

      expect(copies.keys, ['old-id']);
      expect(copies['old-id']!.id, 'new-id');
    });

    test('已同步的本地笔记不在此处理（由 deleteSyncedNotesNotIn 按 id 剪掉）', () {
      final copies = findDuplicateLocalCopies(
        localNotes: [_note('old-id', '正文', isSynced: true)],
        serverNotes: [_note('new-id', '正文', isSynced: true)],
      );

      expect(copies, isEmpty);
    });

    test('id 相同不算副本', () {
      final copies = findDuplicateLocalCopies(
        localNotes: [_note('same-id', '正文')],
        serverNotes: [_note('same-id', '正文', isSynced: true)],
      );

      expect(copies, isEmpty);
    });

    test('内容不同不算副本', () {
      final copies = findDuplicateLocalCopies(
        localNotes: [_note('old-id', '本地还在改的内容')],
        serverNotes: [_note('new-id', '服务端另一个版本', isSynced: true)],
      );

      expect(copies, isEmpty);
    });

    test('服务端为空时不产生副本', () {
      final copies = findDuplicateLocalCopies(
        localNotes: [_note('only-local', '正文')],
        serverNotes: const <Note>[],
      );

      expect(copies, isEmpty);
    });

    test('多个副本各自映射到对应的服务端笔记', () {
      final copies = findDuplicateLocalCopies(
        localNotes: [
          _note('old-1', '第一条'),
          _note('old-2', '第二条'),
          _note('unique', '只有本地有'),
        ],
        serverNotes: [
          _note('new-1', '第一条', isSynced: true),
          _note('new-2', '第二条', isSynced: true),
        ],
      );

      expect(copies.keys.toSet(), {'old-1', 'old-2'});
      expect(copies['old-1']!.id, 'new-1');
      expect(copies['old-2']!.id, 'new-2');
    });
  });

  group('findContentDuplicate（跨同步通道去重）', () {
    Note timed(String id, String content, DateTime createdAt) => Note(
          id: id,
          content: content,
          createdAt: createdAt,
          updatedAt: createdAt,
        );

    test('同内容、创建时间接近 → 认为是同一条（WebDAV 旧 id vs Memos uid）', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final pool = groupNotesByContentHash([timed('memos-uid', '同一段正文', t)]);

      final twin = findContentDuplicate(
        candidate: timed('old-uuid', '同一段正文', t.add(const Duration(seconds: 30))),
        poolByHash: pool,
      );

      expect(twin, isNotNull);
      expect(twin!.id, 'memos-uid');
    });

    test('同内容但创建时间相差超过容差 → 视为两条独立笔记', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final pool = groupNotesByContentHash([timed('a', '同一段正文', t)]);

      final twin = findContentDuplicate(
        candidate: timed('b', '同一段正文', t.add(const Duration(hours: 2))),
        poolByHash: pool,
      );

      expect(twin, isNull);
    });

    test('同 id 不走内容匹配（交给 id 匹配逻辑）', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final pool = groupNotesByContentHash([timed('same', '正文', t)]);

      expect(
        findContentDuplicate(candidate: timed('same', '正文', t), poolByHash: pool),
        isNull,
      );
    });

    test('内容不同 → 不命中', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final pool = groupNotesByContentHash([timed('a', '内容 A', t)]);

      expect(
        findContentDuplicate(candidate: timed('b', '内容 B', t), poolByHash: pool),
        isNull,
      );
    });
  });

  group('dedupeDuplicateNotes（库内合并副本）', () {
    Note at(
      String id,
      String content,
      DateTime createdAt, {
      bool isPinned = false,
      DateTime? reminderTime,
    }) =>
        Note(
          id: id,
          content: content,
          createdAt: createdAt,
          updatedAt: createdAt,
          isPinned: isPinned,
          reminderTime: reminderTime,
        );

    test('同内容 + 时间接近 → 合并为一条并给出待删 id', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final result = dedupeDuplicateNotes([
        at('memos-uid', '同一段正文', t),
        at('webdav-uuid', '同一段正文', t.add(const Duration(minutes: 2))),
      ]);

      expect(result.notes, hasLength(1));
      expect(result.notes.single.id, 'memos-uid'); // 保留创建时间最早的一条
      expect(result.removedIds, ['webdav-uuid']);
    });

    test('合并时元数据取并集（置顶 / 提醒）', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final result = dedupeDuplicateNotes([
        at('keep', '正文', t),
        at(
          'copy',
          '正文',
          t.add(const Duration(seconds: 40)),
          isPinned: true,
          reminderTime: DateTime(2026, 10, 21, 9),
        ),
      ]);

      final merged = result.notes.single;
      expect(merged.isPinned, isTrue);
      expect(merged.reminderTime, DateTime(2026, 10, 21, 9));
      expect(result.updatedNotes, hasLength(1));
    });

    test('同内容但创建时间相差很多 → 两条都保留', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final result = dedupeDuplicateNotes([
        at('a', '正文', t),
        at('b', '正文', t.add(const Duration(days: 3))),
      ]);

      expect(result.notes, hasLength(2));
      expect(result.removedIds, isEmpty);
    });

    test('内容不同 → 不动', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final result = dedupeDuplicateNotes([
        at('a', '正文 A', t),
        at('b', '正文 B', t),
      ]);

      expect(result.notes, hasLength(2));
      expect(result.removedIds, isEmpty);
    });

    test('创建时间完全相同 → 按 id 兜底，结果与输入顺序无关', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final first = dedupeDuplicateNotes([
        at('uid-zzz', '同一段正文', t),
        at('uid-aaa', '同一段正文', t),
      ]);
      final second = dedupeDuplicateNotes([
        at('uid-aaa', '同一段正文', t),
        at('uid-zzz', '同一段正文', t),
      ]);

      // 双通道重复的典型特征：createdAt 精确到微秒一致，只能靠 id 决胜负，
      // 否则每轮同步可能换一条，导致 id 反复漂移。
      expect(first.notes.single.id, 'uid-aaa');
      expect(first.removedIds, ['uid-zzz']);
      expect(second.notes.single.id, 'uid-aaa');
      expect(second.removedIds, ['uid-zzz']);
    });

    test('三条同内容同时刻 → 只留一条', () {
      final t = DateTime(2026, 10, 20, 7, 54);
      final result = dedupeDuplicateNotes([
        at('c', '正文', t),
        at('a', '正文', t),
        at('b', '正文', t),
      ]);

      expect(result.notes.single.id, 'a');
      expect(result.removedIds, hasLength(2));
    });

    test('matchContentOnly：跨天也要合并，保留最早那条', () {
      final t = DateTime(2026, 10, 1, 19, 31);
      final result = dedupeDuplicateNotes(
        [
          at('later', '梦境档案', t.add(const Duration(days: 19))),
          at('earlier', '梦境档案', t),
        ],
        matchContentOnly: true,
      );

      expect(result.notes.single.id, 'earlier');
      expect(result.removedIds, ['later']);
    });

    test('合并副本时时间线沿用保留条，不被副本时间推后', () {
      // 真机数据形态：原始记录 09-09，服务端 10-20 重建了一份同内容副本
      final original = DateTime(2026, 9, 9, 21, 49, 15);
      final recreated = DateTime(2026, 10, 20, 7, 53, 59);
      final result = dedupeDuplicateNotes(
        [
          at('recreated', '今天看完了蜘蛛侠英雄远征', recreated),
          at('original', '今天看完了蜘蛛侠英雄远征', original),
        ],
        matchContentOnly: true,
      );

      final merged = result.notes.single;
      expect(merged.id, 'original');
      expect(merged.createdAt, original);
      expect(merged.updatedAt, original, reason: '卡片显示 updatedAt，不能被副本推后');
      expect(merged.displayTime, original);
    });

    test('matchContentOnly 默认关闭：跨天同内容仍保留两条', () {
      final t = DateTime(2026, 10, 1, 19, 31);
      final result = dedupeDuplicateNotes([
        at('a', '梦境档案', t),
        at('b', '梦境档案', t.add(const Duration(days: 19))),
      ]);

      expect(result.notes, hasLength(2));
      expect(result.removedIds, isEmpty);
    });

    test('真实双通道形态：同一篇被写成两对副本 → 合并成两条', () {
      // 对应真机数据：10-04 一对、10-10 一对，每对 createdAt 精确相同。
      final d1 = DateTime(2026, 10, 4, 23, 36, 9);
      final d2 = DateTime(2026, 10, 10, 22, 47, 12);
      final result = dedupeDuplicateNotes([
        at('a1', '俯卧撑记录', d1),
        at('a2', '俯卧撑记录', d1),
        at('b1', '俯卧撑记录', d2),
        at('b2', '俯卧撑记录', d2),
      ]);

      expect(result.notes, hasLength(2));
      expect(result.removedIds, hasLength(2));
      expect(result.notes.map((n) => n.id), containsAll(['a1', 'b1']));
    });
  });
}
