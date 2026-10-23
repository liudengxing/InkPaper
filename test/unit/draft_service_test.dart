// ============================================================
// DraftService：编辑器草稿的存取、过期与旧数据迁移
// ============================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/draft_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('DraftService', () {
    test('DRAFT-01 保存后可按槽位读回', () async {
      final service = DraftService();
      await service.save(
        draftId: 'note-1',
        noteId: 'note-1',
        content: '写了一半的内容',
      );

      final draft = await service.load('note-1');
      expect(draft, isNotNull);
      expect(draft!.content, '写了一半的内容');
      expect(draft.noteId, 'note-1');
      expect(draft.isNewNote, isFalse);
    });

    test('DRAFT-02 新建笔记草稿与已有笔记草稿互不覆盖', () async {
      final service = DraftService();
      await service.save(
        draftId: DraftService.newNoteDraftId,
        content: '新笔记草稿',
      );
      await service.save(
        draftId: 'note-1',
        noteId: 'note-1',
        content: '旧笔记草稿',
      );

      expect(
        (await service.load(DraftService.newNoteDraftId))?.content,
        '新笔记草稿',
      );
      expect((await service.load('note-1'))?.content, '旧笔记草稿');

      final drafts = await service.list();
      expect(drafts.length, 2);
      expect(
        drafts.first.updatedAt.isAfter(drafts.last.updatedAt) ||
            drafts.first.updatedAt.isAtSameMomentAs(drafts.last.updatedAt),
        isTrue,
      );
    });

    test('DRAFT-03 空内容等于删除，不留空壳', () async {
      final service = DraftService();
      await service.save(draftId: 'note-1', content: '内容');
      await service.save(draftId: 'note-1', content: '   ');

      expect(await service.load('note-1'), isNull);
      expect(await service.list(), isEmpty);
    });

    test('DRAFT-04 超过保留期的草稿会被丢弃', () async {
      final expired = DateTime.now().subtract(DraftService.retention * 2);
      SharedPreferences.setMockInitialValues({
        DraftService.prefsKey: jsonEncode({
          'note-old': {
            'noteId': 'note-old',
            'content': '过期内容',
            'updatedAt': expired.toIso8601String(),
          },
          'note-new': {
            'noteId': 'note-new',
            'content': '新鲜内容',
            'updatedAt': DateTime.now().toIso8601String(),
          },
        }),
      });

      final service = DraftService();
      expect(await service.load('note-old'), isNull);

      final drafts = await service.list();
      expect(drafts.map((d) => d.draftId), ['note-new']);
    });

    test('DRAFT-05 旧版本单条草稿会迁移到新槽位', () async {
      SharedPreferences.setMockInitialValues({
        DraftService.legacyNewNoteKey: '旧版本留下的草稿',
      });

      final service = DraftService();
      final draft = await service.load(DraftService.newNoteDraftId);
      expect(draft?.content, '旧版本留下的草稿');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DraftService.legacyNewNoteKey), isNull);
      // 迁移后换新 key 存着，重复读取仍能拿到
      expect(
        (await service.load(DraftService.newNoteDraftId))?.content,
        '旧版本留下的草稿',
      );
    });

    test('DRAFT-06 clear 只删指定槽位', () async {
      final service = DraftService();
      await service.save(draftId: 'a', content: 'A');
      await service.save(draftId: 'b', content: 'B');

      await service.clear('a');
      expect(await service.load('a'), isNull);
      expect((await service.load('b'))?.content, 'B');
    });
  });
}
