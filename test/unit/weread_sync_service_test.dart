// ============================================================
// 微信读书同步编排 · 增量、去重、节流
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/weread_models.dart';
import 'package:inkpaper/services/weread_api_service.dart';
import 'package:inkpaper/services/weread_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

WeReadNotebook _notebook({
  String bookId = 'b1',
  String title = '深度工作',
  int sort = 100,
  int highlights = 1,
  int reviews = 0,
}) =>
    WeReadNotebook(
      bookId: bookId,
      title: title,
      author: '作者',
      sort: sort,
      highlightCount: highlights,
      reviewCount: reviews,
    );

/// 可控的假网关：不发网络，只按预设回包。
class _FakeApi extends WeReadApiService {
  _FakeApi({
    this.notebooks = const [],
    this.details = const {},
  });

  final List<WeReadNotebook> notebooks;
  final Map<String, WeReadBookNotes> details;

  final List<String> detailRequests = [];

  @override
  Future<List<WeReadNotebook>> fetchNotebooks({
    int pageSize = 100,
    int maxPages = 50,
  }) async =>
      notebooks;

  @override
  Future<WeReadBookNotes> fetchBookNotes(String bookId) async {
    detailRequests.add(bookId);
    final detail = details[bookId];
    if (detail == null) {
      throw const WeReadApiException('拉取失败');
    }
    return detail;
  }
}

/// 把安全存储与数据库替换成内存实现。
class _TestSyncService extends WeReadSyncService {
  _TestSyncService({
    required this.apiKey,
    required this.existingIds,
    required _FakeApi api,
  }) : super(api: api);

  final String? apiKey;
  final Set<String> existingIds;

  @override
  Future<String?> getApiKey() async => apiKey;

  @override
  Future<Set<String>> existingNoteIds(Set<String> ids) async =>
      ids.where(existingIds.contains).toSet();
}

WeReadBookNotes _detail({
  String bookId = 'b1',
  List<String> bookmarkIds = const ['bm1'],
  List<WeReadReview> reviews = const [],
}) =>
    WeReadBookNotes(
      bookId: bookId,
      highlights: [
        for (final id in bookmarkIds)
          WeReadHighlight(
            bookmarkId: id,
            bookId: bookId,
            chapterUid: 1,
            text: '划线 $id',
            createTime: 1735689600,
            range: '1-2',
          ),
      ],
      reviews: reviews,
      chapters: const [
        WeReadChapter(chapterUid: 1, chapterIdx: 1, title: '第一章'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('WS 增量与去重', () {
    test('WS-01 首次同步把划线全部写入', () async {
      final api = _FakeApi(
        notebooks: [_notebook()],
        details: {
          'b1': _detail(bookmarkIds: ['bm1', 'bm2']),
        },
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      final written = <Note>[];
      final result = await service.sync(
        persist: (notes) async => written.addAll(notes),
      );

      expect(result.imported, 2);
      expect(result.booksFetched, 1);
      expect(result.booksSkipped, 0);
      expect(written.map((note) => note.id), [
        'local_wr_bm_bm1',
        'local_wr_bm_bm2',
      ]);
      expect(written.first.tags, contains('微信读书'));
    });

    test('WS-02 水位一致时整本跳过，不再请求明细', () async {
      final api = _FakeApi(
        notebooks: [_notebook()],
        details: {
          'b1': _detail(),
        },
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      await service.sync(persist: (notes) async {});
      final second = await service.sync(persist: (notes) async {});

      expect(second.booksSkipped, 1);
      expect(second.booksFetched, 0);
      // 只有第一次真正请求了明细接口
      expect(api.detailRequests, ['b1']);
    });

    test('WS-03 服务端有新笔记时重新拉取整本', () async {
      final first = _FakeApi(
        notebooks: [_notebook()],
        details: {
          'b1': _detail(),
        },
      );
      await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: first,
      ).sync(persist: (notes) async {});

      // 书侧多了一条笔记：sort 与总数都变
      final changed = _FakeApi(
        notebooks: [_notebook(sort: 200, highlights: 2)],
        details: {
          'b1': _detail(bookmarkIds: ['bm1', 'bm2']),
        },
      );
      final second = await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {'local_wr_bm_bm1'},
        api: changed,
      ).sync(persist: (notes) async {});

      expect(second.booksSkipped, 0);
      expect(changed.detailRequests, ['b1']);
      expect(second.imported, 1, reason: '已存在的那条要被去重掉');
      expect(second.skippedDuplicates, 1);
    });

    test('WS-04 库里已存在的 id 不重复写入（含被删除的）', () async {
      final api = _FakeApi(
        notebooks: [_notebook()],
        details: {
          'b1': _detail(bookmarkIds: ['bm1', 'bm2']),
        },
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {'local_wr_bm_bm2'},
        api: api,
      );

      final written = <Note>[];
      final result = await service.sync(
        persist: (notes) async => written.addAll(notes),
      );

      expect(result.imported, 1);
      expect(result.skippedDuplicates, 1);
      expect(written.single.id, 'local_wr_bm_bm1');
    });
  });

  group('WS 想法归属', () {
    test('WS-05 同章节同 range 的想法挂到划线上，不单独成条', () async {
      final api = _FakeApi(
        notebooks: [_notebook(reviews: 1)],
        details: {
          'b1': _detail(
            bookmarkIds: ['bm1'],
            reviews: [
              const WeReadReview(
                reviewId: 'rv1',
                content: '我的想法',
                createTime: 1735689700,
                range: '1-2',
                chapterUid: 1,
              ),
            ],
          ),
        },
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      final written = <Note>[];
      await service.sync(persist: (notes) async => written.addAll(notes));

      expect(written.length, 1);
      expect(written.single.content, contains('我的想法'));
      expect(written.single.content, contains('> 划线 bm1'));
    });

    test('WS-06 整本书评（无 range）单独成条', () async {
      final api = _FakeApi(
        notebooks: [_notebook(reviews: 1)],
        details: {
          'b1': _detail(
            bookmarkIds: ['bm1'],
            reviews: [
              const WeReadReview(
                reviewId: 'rv-book',
                content: '整本书读完的感想',
                createTime: 1735690000,
                star: 5,
              ),
            ],
          ),
        },
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      final written = <Note>[];
      await service.sync(persist: (notes) async => written.addAll(notes));

      expect(written.length, 2);
      final reviewNote = written.firstWhere(
        (note) => note.id == 'local_wr_rv_rv-book',
      );
      expect(reviewNote.content, contains('评分 5/5'));
    });
  });

  group('WS 容错', () {
    test('WS-07 单本失败不阻断其它书，失败书不推进水位', () async {
      final api = _FakeApi(
        notebooks: [_notebook(), _notebook(bookId: 'b2')],
        details: {
          'b2': _detail(bookId: 'b2', bookmarkIds: ['bm9']),
        },
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      final written = <Note>[];
      final result = await service.sync(
        persist: (notes) async => written.addAll(notes),
      );

      expect(result.imported, 1);
      expect(result.failures.length, 1);
      expect(result.booksFetched, 1);

      // b1 没有推进水位：下一轮还会重试
      final retryApi = _FakeApi(
        notebooks: [_notebook()],
        details: {
          'b1': _detail(),
        },
      );
      final retry = await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: retryApi,
      ).sync(persist: (notes) async {});
      expect(retry.booksSkipped, 0);
      expect(retryApi.detailRequests, ['b1']);
    });

    test('WS-08 没配 Key 直接抛错', () async {
      final service = _TestSyncService(
        apiKey: null,
        existingIds: {},
        api: _FakeApi(),
      );

      await expectLater(
        service.sync(persist: (notes) async {}),
        throwsA(isA<WeReadApiException>()),
      );
    });

    test('WS-09 服务端一本书都没有时不写库', () async {
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: _FakeApi(),
      );

      var persisted = false;
      final result = await service.sync(
        persist: (notes) async => persisted = true,
      );

      expect(result.imported, 0);
      expect(persisted, isFalse);
    });
  });

  group('WS 自动同步节流', () {
    test('WS-10 同步过一次后 6 小时内不再到期', () async {
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: _FakeApi(
          notebooks: [_notebook()],
          details: {
            'b1': _detail(),
          },
        ),
      );

      expect(await service.isAutoSyncDue(), isTrue, reason: '从没同步过');
      await service.sync(persist: (notes) async {});
      expect(await service.isAutoSyncDue(), isFalse);
      expect(await service.lastSyncAt(), isNotNull);
    });

    test('WS-11 开关关闭时自动同步直接跳过', () async {
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: _FakeApi(notebooks: [_notebook()]),
      );
      await service.setAutoSyncEnabled(false);

      expect(await service.autoSyncIfDue(persist: (notes) async {}), isNull);
    });

    test('WS-12 没配 Key 时自动同步直接跳过', () async {
      final service = _TestSyncService(
        apiKey: '',
        existingIds: {},
        api: _FakeApi(notebooks: [_notebook()]),
      );

      expect(await service.autoSyncIfDue(persist: (notes) async {}), isNull);
    });
  });
}
