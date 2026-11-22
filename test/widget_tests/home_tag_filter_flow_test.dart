import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/config/app_config.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/screens/home_screen.dart';
import 'package:inkpaper/screens/home_tag_filter_screen.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Note _note(String id, String content, String tag) {
  final date = DateTime(2024);
  return Note(
    id: id,
    content: content,
    tags: [tag],
    createdAt: date,
    updatedAt: date,
  );
}

class _PageProvider extends AppProvider {
  _PageProvider(this.pages) : _loaded = pages.first;

  final List<List<Note>> pages;
  List<Note> _loaded;
  int fetched = 0;
  bool failNextPage = false;

  @override
  bool get isInitialized => true;

  @override
  List<Note> get notes => _loaded;

  @override
  int get loadedNotesCount => _loaded.length;

  @override
  int get totalNotesCount =>
      pages.fold(0, (count, page) => count + page.length);

  @override
  bool get hasMoreData => fetched + 1 < pages.length;

  @override
  Future<void> loadMoreNotes() async {
    if (failNextPage) {
      failNextPage = false;
      throw StateError('temporary page read failure');
    }
    _loaded = [..._loaded, ...pages[++fetched]];
    notifyListeners();
  }

  @override
  Future<List<Note>> loadNotesOnThisDay({
    DateTime? today,
    bool forceRefresh = false,
  }) async =>
      [];
}

class _TagDatabase implements DatabaseService {
  @override
  Future<List<Note>> getNotes() async => [
        _note('root', '读书目录', '读书'),
        _note('fiction', '小说笔记', '读书/小说'),
        _note('history', '历史笔记', '读书/历史'),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TagProvider extends AppProvider {
  @override
  final DatabaseService databaseService = _TagDatabase();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConfig.prefKeyFirstLaunch: false,
    });
  });

  testWidgets('被屏蔽的首页会补页直到有足够的笔记或查完', (tester) async {
    final provider = _PageProvider([
      for (var page = 0; page < 2; page++)
        List.generate(
          50,
          (index) => _note('${page}_$index', '被屏蔽的笔记', '读书'),
        ),
      [_note('visible-one', '第一页以外的正文', '日记')],
      [_note('visible-two', '最后一页的正文', '日记')],
    ])
      ..failNextPage = true;
    addTearDown(provider.dispose);
    await provider.setHomeHiddenTags(['读书']);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(provider.fetched, 0);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(provider.fetched, 3);
    expect(find.text('第一页以外的正文', findRichText: true), findsOneWidget);
    expect(find.text('最后一页的正文', findRichText: true), findsOneWidget);
    expect(find.text('首页暂时没有可显示的笔记'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('继承屏蔽的子标签不会取消父级或影响其他子标签', (tester) async {
    final provider = _TagProvider();
    addTearDown(provider.dispose);
    await provider.setHomeHiddenTags(['读书']);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: HomeTagFilterScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hidden by #读书'), findsNWidgets(2));
    await tester.tap(find.text('#读书/小说'));
    await tester.pumpAndSettle();
    expect(provider.hiddenHomeTags, {'读书'});

    await tester.tap(find.text('#读书'));
    await tester.pumpAndSettle();
    expect(provider.hiddenHomeTags, isEmpty);
    expect(find.text('Hidden by #读书'), findsNothing);
  });
}
