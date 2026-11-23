import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/random_walk_index.dart';
import 'package:inkpaper/widgets/note_actions_ui.dart';
import 'package:provider/provider.dart';

void main() {
  test('direct references and backlinks are first, including remote IDs', () {
    final index = RandomWalkIndex([
      _note(
        'current',
        '星轨摄影参数 [[legacy?text=旧笔记]]',
        relations: [
          {'type': 'REFERENCE', 'relatedMemoId': 'remote-123'},
        ],
      ),
      _note('remote-local', '', remoteId: 'remote-123'),
      _note('legacy', '旧笔记'),
      _note(
        'backlink',
        '项目记录',
        relations: [
          {'type': 'REFERENCE', 'relatedMemoId': 'current'},
        ],
      ),
      _note('text', '星轨摄影参数与曝光'),
    ]);

    final results = index.rankRelatedNotes('current');

    expect(
      results.map((match) => (match.id, match.kind)),
      [
        ('backlink', RelatedNoteEvidence.backlink),
        ('legacy', RelatedNoteEvidence.reference),
        ('remote-local', RelatedNoteEvidence.reference),
        ('text', RelatedNoteEvidence.text),
      ],
    );
    expect(results.last.evidence, contains('星轨摄影'));
  });

  test('strong text wins over broad and rare tag-only matches', () {
    final index = RandomWalkIndex([
      _note('current', '排查 滚动 丢帧', tags: ['日记', '#安卓/性能']),
      _note('text', '安卓 滚动 丢帧 原因'),
      _note('rare', '性能复盘', tags: ['安卓/性能']),
      for (var i = 0; i < 9; i++) _note('diary$i', '今天买菜', tags: ['日记']),
    ]);

    final results = index.rankRelatedNotes('current');

    expect(
      results.map((match) => (match.id, match.kind)),
      [('text', RelatedNoteEvidence.text), ('rare', RelatedNoteEvidence.tag)],
    );
  });

  test('exact webpage matches across fragments, different paths do not', () {
    final index = RandomWalkIndex([
      _note('current', '[来源](https://example.com/article#intro)'),
      _note('same', 'https://example.com/article#details'),
      _note('different', 'https://example.com/another-path'),
      _note('attachment', '![图片](https://example.com/article)'),
    ]);

    expect(index.rankRelatedNotes('current'), [
      (
        id: 'same',
        kind: RelatedNoteEvidence.source,
        evidence: 'https://example.com/article'
      ),
    ]);
  });

  test('near-identical content occupies one result with a stable winner', () {
    final notes = [
      _note('z', 'Flutter profile frame latency build raster'),
      _note('current', 'Flutter profile frame latency'),
      _note('a', 'Flutter profile frame latency build raster'),
    ];
    for (final input in [notes, notes.reversed.toList()]) {
      expect(
        RandomWalkIndex(input).rankRelatedNotes('current').map((r) => r.id),
        ['a'],
      );
    }
  });

  test('shared full index is lazy, reused and refreshed after a change',
      () async {
    final provider = _LibraryProvider();
    addTearDown(provider.dispose);

    expect(provider.reads, 0);
    final first = await provider.loadNoteDiscoveryIndex();
    expect(first.rankRelatedNotes('current').single.id, 'older');
    expect(await provider.loadNoteDiscoveryIndex(), same(first));
    expect(provider.reads, 1);

    // 切排序、翻页这类只是列表视图状态：通知了也不该让语料索引失效。
    provider.notifyListeners();
    expect(await provider.loadNoteDiscoveryIndex(), same(first));
    expect(provider.reads, 1);

    // 真正的语料变化（这里用版本号模拟写库）才重建。
    provider.library = [_note('current', '一条记录')];
    provider.revision++;

    final updated = await provider.loadNoteDiscoveryIndex();
    expect(updated.rankRelatedNotes('current'), isEmpty);
    expect(provider.reads, 2);
  });

  testWidgets('related sheet finds and explains a note outside the feed',
      (tester) async {
    final provider = _SheetProvider();
    addTearDown(provider.dispose);
    expect(provider.notes, isEmpty);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => NoteActionsUi.showRelatedNotes(
                  context: context,
                  note: provider.library.first,
                ),
                child: const Text('Open related'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open related'));
    await tester.pumpAndSettle();

    final l10n = AppLocalizationsSimple(const Locale('en'));
    expect(find.text('早期记录'), findsOneWidget);
    expect(find.text(l10n.randomWalkReference), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });
}

class _LibraryProvider extends AppProvider {
  int reads = 0;
  int revision = 0;
  List<Note> library = [
    _note('current', '一条记录 [[older]]'),
    _note('older', '早期记录'),
  ];

  @override
  int get noteDiscoveryRevision => revision;

  @override
  Future<List<Note>> loadRandomWalkNotes() async {
    reads++;
    return library;
  }
}

class _SheetProvider extends _LibraryProvider {
  @override
  Future<RandomWalkIndex> loadNoteDiscoveryIndex() async =>
      RandomWalkIndex(library);

  @override
  Future<Note?> loadRandomWalkNote(String id) async =>
      library.firstWhere((note) => note.id == id);
}

Note _note(
  String id,
  String content, {
  List<String> tags = const [],
  List<Map<String, dynamic>> relations = const [],
  String? remoteId,
}) =>
    Note(
      id: id,
      content: content,
      tags: tags,
      relations: relations,
      remoteId: remoteId,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
