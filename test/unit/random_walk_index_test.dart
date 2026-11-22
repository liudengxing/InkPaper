import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sidebar_config.dart';
import 'package:inkpaper/services/random_walk_index.dart';

Note _note(
  String id,
  String content, {
  List<String> tags = const [],
  String? references,
}) {
  final time = DateTime(2024, 3);
  return Note(
    id: id,
    content: content,
    createdAt: time,
    updatedAt: time,
    tags: tags,
    relations: [
      if (references != null)
        {'type': 'REFERENCE', 'relatedMemoId': references},
    ],
  );
}

void main() {
  test('uses local references, tags and Chinese body evidence', () {
    final index = RandomWalkIndex([
      _note('root', '用卡片建立写作习惯 #创作', references: 'reference'),
      _note('reference', '![photo](attachment.jpg)'),
      _note('tagged', '每日复盘', tags: ['创作']),
      _note('text', '培养写作习惯，从灵感写起'),
      _note('unrelated', '汽车加油'),
      _note('dangling', '浇花', references: 'missing'),
    ]);

    final results = index.related('root', shown: {'root'}, excluded: {});
    expect(results.first, ('root', 'reference', WalkRelation.reference, ''));
    expect(results, contains(('root', 'tagged', WalkRelation.tag, '创作')));
    expect(
      results.where((entry) => entry.$3 == WalkRelation.text).single.$2,
      'text',
    );
    expect(results.map((entry) => entry.$2), isNot(contains('unrelated')));
    expect(
      index.related('reference', shown: {'root', 'reference'}, excluded: {}),
      [('reference', 'root', WalkRelation.backlink, '')],
    );
    expect(index.related('reference', shown: {}, excluded: {'root'}), isEmpty);
    expect(index.related('dangling', shown: {}, excluded: {}), isEmpty);
  });

  test('a shared import label and nearby dates do not make a branch', () {
    final index = RandomWalkIndex([
      _note('a', '天文学', tags: ['微信读书']),
      _note('b', '园艺设计', tags: ['微信读书']),
    ]);

    expect(index.related('a', shown: {'a'}, excluded: {}), isEmpty);
  });

  test('prioritizes body matches and allows just one tag-only branch', () {
    final index = RandomWalkIndex([
      _note('root', 'orchard terrace', tags: ['project', 'idea']),
      _note('tag-first', 'ceramics', tags: ['project', 'idea']),
      _note('tag-second', 'sailing', tags: ['idea']),
      _note('mixed', 'orchard terrace', tags: ['project']),
      _note('body', 'orchard terrace'),
    ]);

    final results = index.related('root', shown: {'root'}, excluded: {});
    expect(results.map((edge) => (edge.$2, edge.$3)), [
      ('mixed', WalkRelation.text),
      ('body', WalkRelation.text),
      ('tag-first', WalkRelation.tag),
    ]);
  });

  test('several shared tags do not outrank a stronger body match', () {
    final tags = List.generate(10, (index) => 'tag-$index');
    final index = RandomWalkIndex([
      _note('root', 'orchard terrace planter irrigation', tags: tags),
      _note('weak', 'orchard terrace', tags: tags),
      _note('strong', 'orchard terrace planter irrigation'),
      _note('other', 'ceramics wheel clay sculpture glaze firing pottery vase'),
    ]);

    final results = index.related('root', shown: {'root'}, excluded: {});
    expect(results.map((edge) => edge.$2), ['strong', 'weak']);
  });

  test('body retrieval finds more related notes across thirty short memos', () {
    const topics = [
      ['写作前先收集素材', '为写作整理素材', '写作素材放进卡片盒', '素材用标签分类，方便写作', '写作时从素材里找例子'],
      ['咖啡萃取时观察水温', '手冲咖啡的水温记录', '咖啡水温降低后更甜', '咖啡萃取太快就调细研磨', '用温度计控制咖啡水温'],
      ['阳台番茄需要充足日照', '阳台番茄开始开花', '番茄开花后要注意浇水', '给阳台番茄搭支架', '番茄日照不足会徒长'],
      ['地铁通勤顺便练听力', '通勤听力用短音频', '听力练习记录生词', '地铁通勤复习生词', '听力材料分成几段反复听'],
      ['用定投分散交易时机', '定投计划设置每月额度', '定投资产每年再平衡', '定投额度留出应急储备', '先算应急储备，再决定定投额度'],
      ['跑步训练先控制心率', '记录跑步训练的心率', '心率偏高时减少训练强度', '跑步训练结束做拉伸', '长距离跑步补水和控心率'],
    ];
    final notes = <Note>[];
    final topicById = <String, int>{};
    for (var topic = 0; topic < topics.length; topic++) {
      for (var i = 0; i < topics[topic].length; i++) {
        final id = '$topic/$i';
        topicById[id] = topic;
        notes.add(
          _note(id, topics[topic][i], tags: i < 2 ? ['topic-$topic'] : []),
        );
      }
    }

    final baseline = RandomWalkIndex([
      for (final note in notes) note.copyWith(content: ''),
    ]);
    final combined = RandomWalkIndex(notes);
    var baselineCoverage = 0;
    var combinedCoverage = 0;
    for (final note in notes) {
      final expected = topicById[note.id];
      final baselineResults =
          baseline.related(note.id, shown: {}, excluded: {}, limit: 3);
      final combinedResults =
          combined.related(note.id, shown: {}, excluded: {}, limit: 3);
      if (baselineResults.any((edge) => topicById[edge.$2] == expected)) {
        baselineCoverage++;
      }
      if (combinedResults.any((edge) => topicById[edge.$2] == expected)) {
        combinedCoverage++;
      }
      expect(
        combinedResults.every((edge) => topicById[edge.$2] == expected),
        isTrue,
        reason: 'Unexpected cross-topic branch for ${note.id}',
      );
    }
    expect(baselineCoverage, 12);
    expect(combinedCoverage, greaterThanOrEqualTo(26));
  });

  test('adds the new sidebar item without reviving hidden items', () {
    final original = SidebarConfig();
    final walk = SidebarMenuItem.randomWalk.id;
    final review = SidebarMenuItem.randomReview.id;
    final settings = SidebarMenuItem.settings.id;
    final old = original.toJson()
      ..['itemOrder'] = original.itemOrder.where((id) => id != walk).toList()
      ..['visibleItems'] = original.visibleItems
          .where((id) => id != walk && id != settings)
          .toList();
    final updated = SidebarConfig.fromJson(old);

    expect(updated.isItemVisible(walk), isTrue);
    expect(updated.isItemVisible(settings), isFalse);
    expect(updated.itemOrder[updated.itemOrder.indexOf(review) + 1], walk);
    final hidden = updated.copyWith(
      visibleItems: updated.visibleItems.where((id) => id != walk).toList(),
    );
    expect(
      SidebarConfig.fromJson(hidden.toJson()).isItemVisible(walk),
      isFalse,
    );
  });
}
