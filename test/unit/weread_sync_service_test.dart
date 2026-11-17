// ============================================================
// 微信读书同步编排 · 增量、去重、节流
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/weread_models.dart';
import 'package:inkpaper/services/weread_api_service.dart';
import 'package:inkpaper/services/weread_note_builder.dart';
import 'package:inkpaper/services/weread_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

WeReadNotebook _notebook({
  String bookId = 'b1',
  String title = '深度工作',
  int sort = 100,
  int highlights = 1,
  int reviews = 0,
  int markedStatus = 0,
  double progress = 0,
}) =>
    WeReadNotebook(
      bookId: bookId,
      title: title,
      author: '作者',
      sort: sort,
      highlightCount: highlights,
      reviewCount: reviews,
      markedStatus: markedStatus,
      readingProgress: progress,
    );

/// 可控的假网关：不发网络，只按预设回包。
class _FakeApi extends WeReadApiService {
  _FakeApi({
    this.notebooks = const [],
    this.details = const {},
    this.shelf = const [],
    this.progresses = const {},
    this.periodHandler,
  });

  final List<WeReadNotebook> notebooks;
  final Map<String, WeReadBookNotes> details;
  final List<WeReadShelfBook> shelf;
  final Map<String, WeReadBookProgress> progresses;

  /// 周期统计回包。不传时一律回「阅读 0 秒」，等价于这一期没读书。
  final WeReadPeriodStats Function(String mode, DateTime baseTime)?
      periodHandler;

  final List<String> detailRequests = [];
  final List<String> progressRequests = [];
  final List<({String mode, DateTime baseTime})> periodRequests = [];

  int notebookRequests = 0;

  @override
  Future<List<WeReadNotebook>> fetchNotebooks({
    int pageSize = 100,
    int maxPages = 50,
  }) async {
    notebookRequests++;
    return notebooks;
  }

  @override
  Future<WeReadBookNotes> fetchBookNotes(String bookId) async {
    detailRequests.add(bookId);
    final detail = details[bookId];
    if (detail == null) {
      throw const WeReadApiException('拉取失败');
    }
    return detail;
  }

  @override
  Future<List<WeReadShelfBook>> fetchShelfBooks() async => shelf;

  @override
  Future<WeReadBookProgress?> fetchProgress(String bookId) async {
    progressRequests.add(bookId);
    return progresses[bookId];
  }

  @override
  Future<WeReadPeriodStats> fetchPeriodStats({
    required String mode,
    required DateTime baseTime,
  }) async {
    periodRequests.add((mode: mode, baseTime: baseTime));
    final end = mode == 'weekly'
        ? DateTime(baseTime.year, baseTime.month, baseTime.day + 7)
        : DateTime(baseTime.year, baseTime.month + 1);
    final handler = periodHandler;
    if (handler == null) {
      return WeReadPeriodStats(
        start: baseTime,
        end: end,
        totalReadTime: 0,
        readDays: 0,
      );
    }
    return handler(mode, baseTime);
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

  group('WS 读完档案', () {
    WeReadBookProgress progressOf({
      String bookId = 'b1',
      int finishTime = 1761500000,
    }) =>
        WeReadBookProgress(
          bookId: bookId,
          finishTime: finishTime,
          startReadingTime: 1760000000,
          readingTime: 3600,
          progress: 99,
        );

    test('WS-13 标记读完的书会查进度并生成档案', () async {
      final api = _FakeApi(
        notebooks: [_notebook(markedStatus: 4, progress: 99)],
        details: {'b1': _detail()},
        progresses: {'b1': progressOf()},
      );
      final notes = <Note>[];
      final result = await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      ).sync(persist: (list) async => notes.addAll(list));

      expect(api.progressRequests, ['b1']);
      expect(result.finishedImported, 1);
      expect(result.summary, contains('读完档案'));
      final archive = notes.firstWhere(
        (note) => note.id.startsWith(WeReadNoteBuilder.finishedIdPrefix),
      );
      expect(archive.content, contains('读完时间'));
      expect(archive.tags, contains('读完'));
    });

    test('WS-14 已建过档案的书不再查进度', () async {
      final api = _FakeApi(
        notebooks: [_notebook(markedStatus: 4, progress: 99)],
        details: {'b1': _detail()},
        progresses: {'b1': progressOf()},
      );
      final result = await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {'local_wr_fin_b1'},
        api: api,
      ).sync(persist: (notes) async {});

      expect(api.progressRequests, isEmpty);
      expect(result.finishedImported, 0);
    });

    test('WS-15 进度里没有 finishTime 就不建档，下一轮同版本不再查', () async {
      final api = _FakeApi(
        notebooks: [_notebook(markedStatus: 4, progress: 99)],
        details: {'b1': _detail()},
        progresses: {'b1': progressOf(finishTime: 0)},
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      final first = await service.sync(persist: (notes) async {});
      expect(first.finishedImported, 0);
      expect(api.progressRequests, ['b1']);

      // 元信息没变：第二轮直接跳过，不再打进度接口
      final second = await service.sync(persist: (notes) async {});
      expect(second.finishedImported, 0);
      expect(api.progressRequests, ['b1'], reason: '确认没读完的书不该反复查');
    });

    test('WS-16 书架里读完但没有任何笔记的书也建档案', () async {
      final api = _FakeApi(
        shelf: const [
          WeReadShelfBook(
            bookId: 'shelf-1',
            title: '超越百岁',
            author: '彼得·阿提亚',
            isFinished: true,
            readUpdateTime: 1786019869,
          ),
          WeReadShelfBook(
            bookId: 'shelf-2',
            title: '没读完的书',
            author: '',
          ),
        ],
        progresses: {'shelf-1': progressOf(bookId: 'shelf-1')},
      );
      final notes = <Note>[];

      await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      ).sync(persist: (list) async => notes.addAll(list));

      expect(api.progressRequests, ['shelf-1']);
      expect(notes.single.id, 'local_wr_fin_shelf-1');
      expect(notes.single.content, contains('《超越百岁》'));
    });

    test('WS-17 开关关掉时不查进度也不建档案', () async {
      final api = _FakeApi(
        notebooks: [_notebook(markedStatus: 4, progress: 99)],
        details: {'b1': _detail()},
        progresses: {'b1': progressOf()},
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );
      await service.setFinishedSyncEnabled(false);

      final result = await service.sync(persist: (notes) async {});

      expect(api.progressRequests, isEmpty);
      expect(result.finishedImported, 0);
    });

    test('WS-18 没读完标记的书不进候选，省掉进度请求', () async {
      final api = _FakeApi(
        notebooks: [_notebook(markedStatus: 2, progress: 61)],
        details: {'b1': _detail()},
        progresses: {'b1': progressOf()},
      );

      await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      ).sync(persist: (notes) async {});

      expect(api.progressRequests, isEmpty);
    });
  });

  group('WS 阅读回顾', () {
    /// 上个自然周的周一、上个自然月的 1 号 —— 与服务的口径一致。
    DateTime lastWeekStart() {
      final today = DateTime.now();
      final monday = DateTime(today.year, today.month, today.day)
          .subtract(Duration(days: today.weekday - 1));
      return monday.subtract(const Duration(days: 7));
    }

    DateTime lastMonthStart() {
      final today = DateTime.now();
      return DateTime(today.year, today.month - 1);
    }

    WeReadPeriodStats statsOf(
      String mode,
      DateTime baseTime, {
      required int totalReadTime,
    }) {
      final end = mode == 'weekly'
          ? DateTime(baseTime.year, baseTime.month, baseTime.day + 7)
          : DateTime(baseTime.year, baseTime.month + 1);
      return WeReadPeriodStats(
        start: baseTime,
        end: end,
        totalReadTime: totalReadTime,
        readDays: totalReadTime > 0 ? 3 : 0,
        books: totalReadTime > 0
            ? const [
                WeReadPeriodBook(title: '长安的荔枝', author: '马伯庸', readTime: 1800),
              ]
            : const [],
        stats: totalReadTime > 0 ? const {'读过': '2本'} : const {},
      );
    }

    test('WS-19 首次同步生成上周周报与上月月报', () async {
      final api = _FakeApi(
        periodHandler: (mode, baseTime) =>
            statsOf(mode, baseTime, totalReadTime: 3600),
      );

      final written = <Note>[];
      final result = await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      ).sync(persist: (notes) async => written.addAll(notes));

      expect(api.periodRequests.map((r) => r.mode), ['weekly', 'monthly']);
      expect(api.periodRequests.first.baseTime, lastWeekStart());
      expect(api.periodRequests.last.baseTime, lastMonthStart());
      expect(
        written.map((note) => note.id),
        [
          WeReadNoteBuilder.weeklyNoteId(lastWeekStart()),
          WeReadNoteBuilder.monthlyNoteId(lastMonthStart()),
        ],
      );
      expect(result.periodImported, 2);
      expect(result.summary, contains('2 条阅读回顾'));
    });

    test('WS-20 阅读时长为 0 不建笔记，但水位前进不再重复查', () async {
      final api = _FakeApi(
        periodHandler: (mode, baseTime) =>
            statsOf(mode, baseTime, totalReadTime: 0),
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      final written = <Note>[];
      final first =
          await service.sync(persist: (notes) async => written.addAll(notes));
      expect(first.periodImported, 0);
      expect(written, isEmpty);
      expect(api.periodRequests, hasLength(2));

      await service.sync(persist: (notes) async {});
      // 水位已推到最新周期，第二次同步不再请求统计接口。
      expect(api.periodRequests, hasLength(2));
    });

    test('WS-21 库里已有该期回顾时跳过请求，只推进水位', () async {
      final weekId = WeReadNoteBuilder.weeklyNoteId(lastWeekStart());
      final monthId = WeReadNoteBuilder.monthlyNoteId(lastMonthStart());
      final api = _FakeApi(
        periodHandler: (mode, baseTime) =>
            statsOf(mode, baseTime, totalReadTime: 3600),
      );

      final result = await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {weekId, monthId},
        api: api,
      ).sync(persist: (notes) async {});

      expect(api.periodRequests, isEmpty);
      expect(result.periodImported, 0);
    });
  });

  group('WS 生成项开关', () {
    /// 直接改偏好值，模拟用户在设置页拨开关。
    Future<void> setSwitch(String key, bool value) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    }

    WeReadReview inlineReview({String id = 'rv1', String content = '这段说得好'}) =>
        WeReadReview(
          reviewId: id,
          content: content,
          createTime: 1735689600,
          abstractText: '划线原文',
          range: '1-2',
          chapterUid: 1,
        );

    test('WS-22 只开划线：想法不生成', () async {
      final api = _FakeApi(
        notebooks: [_notebook(reviews: 1)],
        details: {
          'b1': _detail(reviews: [inlineReview()]),
        },
      );
      await setSwitch('weread_sync_reviews', false);

      final written = <Note>[];
      await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      ).sync(persist: (notes) async => written.addAll(notes));

      expect(written.map((note) => note.id), ['local_wr_bm_bm1']);
      expect(written.single.content, isNot(contains('这段说得好')));
    });

    test('WS-23 只开想法：划线不生成，挂不上划线的想法单独成条', () async {
      final api = _FakeApi(
        notebooks: [_notebook(reviews: 1)],
        details: {
          'b1': _detail(reviews: [inlineReview()]),
        },
      );
      await setSwitch('weread_sync_highlights', false);

      final written = <Note>[];
      await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      ).sync(persist: (notes) async => written.addAll(notes));

      expect(written.map((note) => note.id), ['local_wr_rv_rv1']);
      expect(written.single.content, contains('这段说得好'));
    });

    test('WS-24 生成项全关：手动同步报错，开屏自动同步直接跳过', () async {
      await setSwitch('weread_sync_highlights', false);
      await setSwitch('weread_sync_reviews', false);
      await setSwitch('weread_sync_finished', false);
      await setSwitch('weread_period_review', false);

      final api = _FakeApi(notebooks: [_notebook()]);
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      await expectLater(
        service.sync(persist: (notes) async {}),
        throwsA(isA<WeReadApiException>()),
      );
      final auto = await service.autoSyncIfDue(
        persist: (notes) async {},
      );
      expect(auto, isNull);
      // 什么都没请求出去。
      expect(api.notebookRequests, 0);
      expect(api.detailRequests, isEmpty);
    });

    test('WS-25 开关组合变了要清掉水位重扫', () async {
      final api = _FakeApi(
        notebooks: [_notebook(reviews: 1)],
        details: {
          'b1': _detail(reviews: [inlineReview()]),
        },
      );
      final service = _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      );

      await setSwitch('weread_sync_reviews', false);
      await service.sync(persist: (notes) async {});
      expect(api.detailRequests, ['b1']);

      // 开关没变时第二次同步沿用旧水位，不重复拉。
      await service.sync(persist: (notes) async {});
      expect(api.detailRequests, ['b1']);

      // 打开想法 = 要拿的内容种类变了，水位作废，整本重扫一次。
      await setSwitch('weread_sync_reviews', true);
      await service.sync(persist: (notes) async {});
      expect(api.detailRequests, ['b1', 'b1']);
    });

    test('WS-26 只开阅读回顾：不拉笔记本列表，只打统计接口', () async {
      await setSwitch('weread_sync_highlights', false);
      await setSwitch('weread_sync_reviews', false);
      await setSwitch('weread_sync_finished', false);

      final api = _FakeApi(notebooks: [_notebook()]);
      final result = await _TestSyncService(
        apiKey: 'wrk-test',
        existingIds: {},
        api: api,
      ).sync(persist: (notes) async {});

      expect(api.notebookRequests, 0);
      expect(api.detailRequests, isEmpty);
      expect(api.periodRequests, hasLength(2));
      expect(result.booksTotal, 0);
    });
  });
}
