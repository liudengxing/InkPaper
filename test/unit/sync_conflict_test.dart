import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/sync_merge_helper.dart';

Note _note(
  String id,
  String content, {
  bool isSynced = false,
  DateTime? updatedAt,
  DateTime? deletedAt,
}) =>
    Note(
      id: id,
      content: content,
      createdAt: DateTime(2026),
      updatedAt: updatedAt ?? DateTime(2026),
      isSynced: isSynced,
      deletedAt: deletedAt,
    );

void main() {
  group('isMergeConflict', () {
    test('本地未同步且与服务端内容不同 → 冲突', () {
      expect(
        isMergeConflict(
          _note('a', '服务端版本', isSynced: true),
          _note('a', '本地版本'),
        ),
        isTrue,
      );
    });

    test('本地已同步时不视为冲突（本机没有待上传改动）', () {
      expect(
        isMergeConflict(
          _note('a', '服务端版本', isSynced: true),
          _note('a', '本地版本', isSynced: true),
        ),
        isFalse,
      );
    });

    test('内容一致时不冲突', () {
      expect(
        isMergeConflict(
          _note('a', '同样的内容', isSynced: true),
          _note('a', '同样的内容'),
        ),
        isFalse,
      );
    });

    test('服务端内容为空时不判冲突，避免把解析失败当成覆盖', () {
      expect(
        isMergeConflict(
          _note('a', '', isSynced: true),
          _note('a', '本地版本'),
        ),
        isFalse,
      );
    });
  });

}
