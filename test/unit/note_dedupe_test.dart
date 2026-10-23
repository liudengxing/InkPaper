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
  });
}
