import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';

Note _note({DateTime? deletedAt}) => Note(
      id: 'note-1',
      content: '正文',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      deletedAt: deletedAt,
    );

void main() {
  group('Note 序列化保留软删时间', () {
    test('toJson 输出 deletedAt', () {
      final note = _note(deletedAt: DateTime(2026, 3, 5, 10, 30));

      expect(note.toJson()['deletedAt'], isNotNull);
      expect(
        DateTime.parse(note.toJson()['deletedAt']! as String),
        DateTime(2026, 3, 5, 10, 30),
      );
    });

    test('未删除的笔记 deletedAt 为 null', () {
      expect(_note().toJson()['deletedAt'], isNull);
    });

    test('toJson → fromJson 往返后软删时间不丢', () {
      final restored = Note.fromJson(
        _note(deletedAt: DateTime(2026, 3, 5)).toJson(),
      );

      expect(restored.deletedAt, DateTime(2026, 3, 5));
    });
  });
}
