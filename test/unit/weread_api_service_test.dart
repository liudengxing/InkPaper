// ============================================================
// 微信读书网关客户端 · 请求格式与错误处理
// ============================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inkpaper/services/weread_api_service.dart';

/// 构造 UTF-8 回包。`http.Response(String, int)` 默认按 latin1 编码，
/// 直接塞中文会抛「Contains invalid characters」。
http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// 记录每次请求的 body，便于断言「参数平铺」「游标分页」这类格式要求。
class _Recorder {
  final List<Map<String, dynamic>> bodies = [];
  final List<http.Request> requests = [];

  Map<String, dynamic> get last => bodies.last;
}

void main() {
  group('WA 请求格式', () {
    test('WA-01 业务参数平铺在 body 顶层，且带 skill_version', () async {
      final recorder = _Recorder();
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          recorder.bodies.add(body);
          recorder.requests.add(request);
          return _json({
            'books': [
              {
                'bookId': 'b1',
                'sort': 100,
                'book': {'title': '三体', 'author': '刘慈欣'},
              },
            ],
            'hasMore': 0,
          });
        }),
      );

      await api.fetchNotebooks(pageSize: 50);

      final body = recorder.last;
      expect(body['api_name'], '/user/notebooks');
      expect(body['skill_version'], WeReadApiService.skillVersion);
      expect(body['count'], 50);
      expect(body.containsKey('params'), isFalse);
      // 鉴权走 Bearer，不塞进 body
      expect(
        recorder.requests.last.headers['Authorization'],
        'Bearer wrk-test',
      );
      expect(body.containsKey('vid'), isFalse);
    });

    test('WA-02 没填 Key 直接报错，不发请求', () async {
      var called = false;
      final api = WeReadApiService(
        client: MockClient((request) async {
          called = true;
          return _json({});
        }),
      );

      await expectLater(
        api.fetchNotebooks(),
        throwsA(
          isA<WeReadApiException>().having(
            (error) => error.message,
            'message',
            contains('API Key'),
          ),
        ),
      );
      expect(called, isFalse);
    });
  });

  group('WA 分页', () {
    test('WA-03 笔记本用 lastSort 游标翻页，hasMore=0 停止', () async {
      final recorder = _Recorder();
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          recorder.bodies.add(body);
          if (!body.containsKey('lastSort')) {
            return _json({
              'books': [
                {
                  'bookId': 'a',
                  'sort': 100,
                  'book': {'title': 'A'},
                },
                {
                  'bookId': 'b',
                  'sort': 90,
                  'book': {'title': 'B'},
                },
              ],
              'hasMore': 1,
            });
          }
          return _json({
            'books': [
              {
                'bookId': 'c',
                'sort': 80,
                'book': {'title': 'C'},
              },
            ],
            'hasMore': 0,
          });
        }),
      );

      final books = await api.fetchNotebooks(pageSize: 2);

      expect(books.map((book) => book.bookId), ['a', 'b', 'c']);
      expect(recorder.bodies.length, 2);
      // 游标必须取上一页最后一条的 sort
      expect(recorder.bodies[1]['lastSort'], 90);
      expect(recorder.bodies[1].containsKey('offset'), isFalse);
    });

    test('WA-04 同一条书重复返回不会导入两次', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient((request) async {
          return _json({
            'books': [
              {
                'bookId': 'a',
                'sort': 100,
                'book': {'title': 'A'},
              },
              {
                'bookId': 'a',
                'sort': 99,
                'book': {'title': 'A'},
              },
            ],
            'hasMore': 0,
          });
        }),
      );

      final books = await api.fetchNotebooks();
      expect(books.length, 1);
    });
  });

  group('WA 明细接口', () {
    test('WA-05 划线取 markText 与章节表', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['api_name'] == '/book/bookmarklist') {
            expect(body['bookId'], 'b1');
            return _json({
              'updated': [
                {
                  'bookmarkId': 'bm1',
                  'chapterUid': 11,
                  'markText': '原文',
                  'createTime': 1700000000,
                  'range': '1-3',
                },
                {'bookmarkId': 'bm2', 'markText': '   '},
              ],
              'chapters': [
                {'chapterUid': 11, 'chapterIdx': 1, 'title': '第一章'},
              ],
            });
          }
          return _json({'reviews': []});
        }),
      );

      final notes = await api.fetchBookNotes('b1');

      expect(notes.highlights.length, 1, reason: '空白划线要被丢掉');
      expect(notes.highlights.first.text, '原文');
      expect(notes.chapterTitles[11], '第一章');
    });

    test('WA-06 想法接口用 bookid（小写 d）并做 synckey 翻页', () async {
      final recorder = _Recorder();
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['api_name'] == '/book/bookmarklist') {
            return _json({'updated': []});
          }
          recorder.bodies.add(body);
          if (!body.containsKey('synckey')) {
            return _json({
              'reviews': [
                {
                  'review': {
                    'reviewId': 'r1',
                    'content': '想法一',
                    'createTime': 100,
                  },
                },
              ],
              'hasMore': 1,
              'synckey': 555,
            });
          }
          return _json({
            'reviews': [
              {
                'review': {
                  'reviewId': 'r2',
                  'content': '想法二',
                  'createTime': 200,
                  'star': 5,
                },
              },
            ],
            'hasMore': 0,
            'synckey': 999,
          });
        }),
      );

      final notes = await api.fetchBookNotes('b1');

      expect(notes.reviews.map((review) => review.reviewId), ['r1', 'r2']);
      expect(recorder.bodies.first.containsKey('bookid'), isTrue);
      expect(recorder.bodies.first.containsKey('bookId'), isFalse);
      expect(recorder.bodies[1]['synckey'], 555);
      expect(notes.reviews.last.star, 5);
    });

    test('WA-07 想法接口失败整体抛错，不再吞成半份数据', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['api_name'] == '/book/bookmarklist') {
            return _json({
              'updated': [
                {'bookmarkId': 'bm1', 'markText': '原文'},
              ],
            });
          }
          return _json({'errcode': -1, 'errmsg': '炸了'});
        }),
      );

      // 吞掉失败会让 sync 推进水位、这本书永远不再重试（读完档案却照常
      // 生成，出现「档案说有 N 条划线，点标签一条没有」）。必须抛出去。
      await expectLater(
        api.fetchBookNotes('b1'),
        throwsA(
          isA<WeReadApiException>().having(
            (error) => error.message,
            'message',
            '炸了',
          ),
        ),
      );
    });
  });

  group('WA 错误映射', () {
    test('WA-08 errcode 非 0 抛带服务端文案的异常', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient(
          (request) async => _json({'errcode': 30001, 'errmsg': '参数不对'}),
        ),
      );

      await expectLater(
        api.fetchNotebooks(),
        throwsA(
          isA<WeReadApiException>()
              .having((error) => error.message, 'message', '参数不对')
              .having((error) => error.errcode, 'errcode', 30001),
        ),
      );
    });

    test('WA-09 401 提示 Key 无效', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-bad',
        client: MockClient((request) async => http.Response('', 401)),
      );

      await expectLater(
        api.fetchNotebooks(),
        throwsA(
          isA<WeReadApiException>().having(
            (error) => error.message,
            'message',
            contains('Key'),
          ),
        ),
      );
    });

    test('WA-10 upgrade_info 单独抛升级异常', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient(
          (request) async => _json({
            'upgrade_info': {'message': '请升级到 2.0.0'},
          }),
        ),
      );

      await expectLater(
        api.fetchNotebooks(),
        throwsA(isA<WeReadUpgradeRequiredException>()),
      );
    });

    test('WA-11 非 JSON 回包不会把异常露成 FormatException', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient((request) async => http.Response('<html>', 200)),
      );

      await expectLater(
        api.fetchNotebooks(),
        throwsA(isA<WeReadApiException>()),
      );
    });
  });

  group('WA 阅读统计', () {
    test('WA-12 readdata 传 mode 与 baseTime，回包解析成周期统计', () async {
      final recorder = _Recorder();
      final weekStart = DateTime(2026, 11, 9);
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient((request) async {
          recorder.bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _json({
            'baseTime': weekStart.millisecondsSinceEpoch ~/ 1000,
            'totalReadTime': 7200,
            'readDays': 3,
            'readLongest': [
              {
                'book': {'title': '长安的荔枝', 'author': '马伯庸'},
                'readTime': 3600,
              },
              {
                'albumInfo': {'name': '某有声专辑', 'author': '某主播'},
                'readTime': 1200,
              },
              {
                'book': {'title': '没读多久的书'},
                'readTime': 60,
              },
            ],
            'readStat': [
              {'stat': '读过', 'counts': '2本'},
              {'stat': '读完', 'counts': '1本'},
              {'stat': '笔记', 'counts': '12条'},
            ],
          });
        }),
      );

      final stats = await api.fetchPeriodStats(
        mode: 'weekly',
        baseTime: DateTime(2026, 11, 12, 9),
      );

      expect(recorder.last['api_name'], '/readdata/detail');
      expect(recorder.last['mode'], 'weekly');
      expect(
        recorder.last['baseTime'],
        DateTime(2026, 11, 12, 9).millisecondsSinceEpoch ~/ 1000,
      );
      expect(stats.start, weekStart);
      expect(stats.end.difference(stats.start).inDays, 7);
      expect(stats.totalReadTime, 7200);
      expect(stats.readDays, 3);
      expect(stats.books.first.title, '长安的荔枝');
      expect(stats.books[1].title, '某有声专辑');
      expect(stats.stats['读完'], '1本');
      expect(stats.isEmpty, isFalse);
    });

    test('WA-13 月报终点是下个月 1 日，跨年也不会错位', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient(
          (request) async => _json({
            'baseTime': DateTime(2026, 12).millisecondsSinceEpoch ~/ 1000,
            'totalReadTime': 600,
            'readDays': 1,
          }),
        ),
      );

      final stats = await api.fetchPeriodStats(
        mode: 'monthly',
        baseTime: DateTime(2026, 12, 20),
      );

      expect(stats.start, DateTime(2026, 12));
      expect(stats.end, DateTime(2027));
    });

    test('WA-14 时长为 0 视为空周期，不生成回顾', () async {
      final api = WeReadApiService(
        apiKey: 'wrk-test',
        client: MockClient(
          (request) async => _json({
            'baseTime': DateTime(2026, 11, 9).millisecondsSinceEpoch ~/ 1000,
            'totalReadTime': 0,
            'readDays': 0,
          }),
        ),
      );

      final stats = await api.fetchPeriodStats(
        mode: 'weekly',
        baseTime: DateTime(2026, 11, 9),
      );

      expect(stats.isEmpty, isTrue);
      expect(stats.books, isEmpty);
    });
  });
}
