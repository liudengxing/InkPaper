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
}
