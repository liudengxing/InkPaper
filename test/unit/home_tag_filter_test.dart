import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/home_tag_filter.dart';

Note _note(String id, String content, {List<String>? tags}) => Note(
      id: id,
      content: content,
      createdAt: DateTime(2026, 11, 2),
      updatedAt: DateTime(2026, 11, 2),
      tags: tags,
    );

void main() {
  group('normalizeHomeTag', () {
    test('去掉前导 # 与首尾空白', () {
      expect(normalizeHomeTag('#读书'), '读书');
      expect(normalizeHomeTag('  ##读书 '), '读书');
      expect(normalizeHomeTag('读书'), '读书');
      expect(normalizeHomeTag('   '), '');
    });
  });

  group('collectNoteTags', () {
    test('结构化 tags 与正文 #标签 取并集并去重', () {
      final note = _note(
        '1',
        '今天读完了 #读书 #读书/笔记',
        tags: const <String>['#读书', '同步来的'],
      );
      expect(
        collectNoteTags(note),
        <String>{'读书', '读书/笔记', '同步来的'},
      );
    });

    test('没有任何标签时返回空集', () {
      expect(collectNoteTags(_note('1', '一段普通的话，没有标签。')), isEmpty);
    });
  });

  group('isNoteHiddenByTags', () {
    test('屏蔽名单为空时一律不隐藏', () {
      final note = _note('1', '#读书', tags: const <String>['读书']);
      expect(isNoteHiddenByTags(note, const <String>{}), isFalse);
    });

    test('结构化 tags 命中即隐藏', () {
      final note = _note('1', '没有正文标签', tags: const <String>['微信读书']);
      expect(isNoteHiddenByTags(note, <String>{'微信读书'}), isTrue);
    });

    test('正文 #标签 命中即隐藏', () {
      final note = _note('1', '这段很长 #周报 内容');
      expect(isNoteHiddenByTags(note, <String>{'周报'}), isTrue);
    });

    test('层级标签按前缀隐藏：屏蔽父标签连带子标签', () {
      final note = _note('1', '记一笔 #读书/小说');
      expect(isNoteHiddenByTags(note, <String>{'读书'}), isTrue);
    });

    test('同名前缀但不是层级的不受影响', () {
      final note = _note('1', '#读书笔记');
      expect(isNoteHiddenByTags(note, <String>{'读书'}), isFalse);
    });

    test('屏蔽名单带 # 前缀也能命中', () {
      final note = _note('1', '#读书');
      expect(isNoteHiddenByTags(note, <String>{'#读书'}), isTrue);
    });

    test('无关标签不隐藏', () {
      final note = _note('1', '#工作 今天开会');
      expect(isNoteHiddenByTags(note, <String>{'读书'}), isFalse);
    });

    test('没有标签的笔记永远保留', () {
      final note = _note('1', '纯文字，一个标签都没有。');
      expect(isNoteHiddenByTags(note, <String>{'读书'}), isFalse);
    });
  });

  group('filterNotesByHiddenTags', () {
    test('屏蔽名单为空时原样返回同一个实例', () {
      final notes = <Note>[_note('1', '#读书')];
      expect(
        identical(filterNotesByHiddenTags(notes, const <String>{}), notes),
        isTrue,
      );
    });

    test('只滤掉命中的，顺序保持不变', () {
      final notes = <Note>[
        _note('1', '#工作 开会'),
        _note('2', '#读书 看完了'),
        _note('3', '没有标签'),
        _note('4', '#周报 本周'),
      ];

      final filtered = filterNotesByHiddenTags(notes, <String>{'读书', '周报'});

      expect(filtered.map((note) => note.id), <String>['1', '3']);
    });
  });
}
