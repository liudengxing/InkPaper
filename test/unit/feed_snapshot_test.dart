import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Note buildNote() => Note(
        id: 'note-1',
        content: '第一段\n\n第二段 #标签',
        createdAt: DateTime(2026, 10, 20, 9),
        updatedAt: DateTime(2026, 10, 21, 10, 30),
        tags: const ['标签'],
        isPinned: true,
        isSynced: true,
        resourceList: const [
          {'uid': 'res-1', 'type': 'image/png', 'filename': 'cover.png'},
        ],
      );

  test('首屏快照 JSON 往返保留卡片需要的字段', () {
    final note = buildNote();
    final encoded = jsonEncode(note.toMap());
    final restored = Note.fromMap(
      Map<String, dynamic>.from(jsonDecode(encoded) as Map),
    );

    expect(restored.id, note.id);
    expect(restored.content, note.content);
    expect(restored.createdAt, note.createdAt);
    expect(restored.updatedAt, note.updatedAt);
    expect(restored.tags, note.tags);
    expect(restored.isPinned, isTrue);
    expect(restored.isSynced, isTrue);
    expect(restored.resourceList, hasLength(1));
    expect(restored.resourceList.first['filename'], 'cover.png');
  });

  test('注入快照后首帧就有笔记，但初始化状态仍为未完成', () {
    final provider = AppProvider(initialFeed: [buildNote()]);

    expect(provider.notes, hasLength(1));
    expect(provider.notes.first.id, 'note-1');
    expect(provider.totalNotesCount, 1);
    // 快照只做展示预填，真实数据加载完成后才会置为 true
    expect(provider.isInitialized, isFalse);
  });
}
