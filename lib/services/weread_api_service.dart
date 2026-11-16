import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:inkpaper/models/weread_models.dart';
import 'package:inkpaper/utils/logger.dart';

/// 微信读书 Agent 网关错误。
class WeReadApiException implements Exception {
  const WeReadApiException(this.message, {this.errcode});

  final String message;
  final int? errcode;

  @override
  String toString() => message;
}

/// 服务端要求升级 skill 版本。
///
/// 回包里出现 `upgrade_info` 时必须让用户看到提示，不能当成普通错误吞掉，
/// 否则表现是「同步一直没数据」而毫无线索。
class WeReadUpgradeRequiredException extends WeReadApiException {
  const WeReadUpgradeRequiredException(super.message);
}

/// 微信读书 Agent 网关客户端。
///
/// 所有接口都是 `POST https://i.weread.qq.com/api/agent/gateway`，靠 body 里
/// 的 `api_name` 区分，业务参数必须**平铺**在 body 顶层（包进 `params` 会被
/// 后端忽略，表现成「分页失效、永远第一页」）。鉴权走 `Authorization: Bearer`
/// ，API Key 与用户 vid 绑定，因此不需要手动传任何身份参数。
class WeReadApiService {
  WeReadApiService({
    http.Client? client,
    this.apiKey,
    this.timeout = const Duration(seconds: 25),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static const String gatewayUrl = 'https://i.weread.qq.com/api/agent/gateway';

  /// 与服务端约定的 skill 版本，每次请求都要上报，用于服务端判断是否要升级。
  static const String skillVersion = '1.0.5';

  /// 网络读取超时。网关正常在 1 秒内返回，25 秒足够兜住偶发慢请求。
  final Duration timeout;

  final http.Client _client;
  final bool _ownsClient;

  /// `wrk-` 开头的 API Key，由调用方在每次同步前注入。
  String? apiKey;

  final Logger _logger = const Logger('WeReadApi');

  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }

  /// 校验 API Key 是否可用：能拉到一页笔记本即视为有效。
  Future<int> verifyApiKey() async {
    final notebooks = await fetchNotebooks(pageSize: 1, maxPages: 1);
    return notebooks.length;
  }

  /// 拉取「有笔记的书」列表，按游标翻页直到 `hasMore` 为 0。
  ///
  /// 分页只认顶层平铺的 `count` + `lastSort`；`offset`/`limit` 后端不读。
  Future<List<WeReadNotebook>> fetchNotebooks({
    int pageSize = 100,
    int maxPages = 50,
  }) async {
    final books = <WeReadNotebook>[];
    final seenBookIds = <String>{};
    var lastSort = 0;
    var page = 0;

    while (page < maxPages) {
      final body = <String, dynamic>{'count': pageSize};
      if (lastSort > 0) {
        body['lastSort'] = lastSort;
      }
      final data = await _post('/user/notebooks', body);
      final rawBooks = data['books'];
      if (rawBooks is! List || rawBooks.isEmpty) {
        break;
      }

      for (final raw in rawBooks) {
        if (raw is! Map) {
          continue;
        }
        final notebook = WeReadNotebook.fromJson(
          Map<String, dynamic>.from(raw),
        );
        if (notebook.bookId.isEmpty || !seenBookIds.add(notebook.bookId)) {
          continue;
        }
        books.add(notebook);
      }

      page++;
      final hasMore = _asInt(data['hasMore']) == 1;
      final nextSort = books.isEmpty ? 0 : books.last.sort;
      // 游标没前进就停，否则会在同一页上无限打转。
      if (!hasMore || nextSort <= 0 || nextSort == lastSort) {
        break;
      }
      lastSort = nextSort;
    }

    _logger.debug('笔记本列表拉取完成', data: {'books': books.length});
    return books;
  }

  /// 拉取单本书的划线 + 想法 + 章节。
  ///
  /// 两个接口各管一半：`/book/bookmarklist` 给划线内容和章节表，`/review/list/mine`
  /// 给个人想法/点评。任何一半失败都整体抛错 —— 若吞掉失败返回半份数据，
  /// sync 会照常推进书侧水位，这本书永远不会再重试，缺的那半就永久丢了
  /// （读完档案独立走 getprogress，照常生成，于是出现「档案写有 3 条笔记，
  /// 点标签一条都没有」）。抛错后 sync 记 failure、不推水位，下一轮整本重试；
  /// 已导入的部分靠笔记 id 幂等去重，不会重复。
  Future<WeReadBookNotes> fetchBookNotes(String bookId) async {
    final highlights = <WeReadHighlight>[];
    final reviews = <WeReadReview>[];
    final chapters = <WeReadChapter>[];

    try {
      final data = await _post('/book/bookmarklist', {'bookId': bookId});
      final rawUpdated = data['updated'];
      if (rawUpdated is List) {
        for (final raw in rawUpdated) {
          if (raw is! Map) {
            continue;
          }
          final highlight = WeReadHighlight.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (highlight.bookmarkId.isEmpty || highlight.text.trim().isEmpty) {
            continue;
          }
          highlights.add(highlight);
        }
      }
      final rawChapters = data['chapters'];
      if (rawChapters is List) {
        for (final raw in rawChapters) {
          if (raw is! Map) {
            continue;
          }
          chapters.add(
            WeReadChapter.fromJson(Map<String, dynamic>.from(raw)),
          );
        }
      }
    } on WeReadUpgradeRequiredException {
      rethrow;
    } on Object catch (error) {
      _logger.warning('划线与章节拉取失败: $bookId', data: {'error': '$error'});
      // 不吞：半份数据 + 推进水位 = 永久丢数据，见方法注释。
      rethrow;
    }

    try {
      reviews.addAll(await _fetchBookReviews(bookId));
    } on WeReadUpgradeRequiredException {
      rethrow;
    } on Object catch (error) {
      _logger.warning('想法拉取失败: $bookId', data: {'error': '$error'});
      rethrow;
    }

    return WeReadBookNotes(
      bookId: bookId,
      highlights: highlights,
      reviews: reviews,
      chapters: chapters,
    );
  }

  /// 拉取单本书的阅读进度。
  ///
  /// 这是「读完」与「读完时间」的唯一可靠来源：书架只给一个 finishReading
  /// 布尔量，笔记本列表的 markedStatus 含义与文档不符。一次约 0.2 秒，
  /// 只对候选书调用。
  Future<WeReadBookProgress?> fetchProgress(String bookId) async {
    if (bookId.trim().isEmpty) {
      return null;
    }
    final data = await _post('/book/getprogress', {'bookId': bookId});
    final progress = WeReadBookProgress.fromJson({
      'bookId': bookId,
      ...data,
    });
    return progress.bookId.isEmpty ? null : progress;
  }

  /// 拉取书架，用于补「没有划线但已读完」的书。
  ///
  /// 书架里有 `finishReading`（是否读完）与书名/作者/封面，一次请求拿全，
  /// 不会像逐本查详情那样放大请求数。
  Future<List<WeReadShelfBook>> fetchShelfBooks() async {
    final data = await _post('/shelf/sync');
    final rawBooks = data['books'];
    if (rawBooks is! List) {
      return const [];
    }
    final books = <WeReadShelfBook>[];
    final seen = <String>{};
    for (final raw in rawBooks) {
      if (raw is! Map) {
        continue;
      }
      final book = WeReadShelfBook.fromJson(Map<String, dynamic>.from(raw));
      if (book.bookId.isEmpty || !seen.add(book.bookId)) {
        continue;
      }
      books.add(book);
    }
    _logger.debug('书架拉取完成', data: {'books': books.length});
    return books;
  }

  /// 拉取单本书的全部个人想法/点评。
  ///
  /// 参数名是 `bookid`（小写 d），和 `/book/bookmarklist` 的 `bookId` 不一致，
  /// 拼错会静默返回空列表。
  Future<List<WeReadReview>> _fetchBookReviews(
    String bookId, {
    int pageSize = 20,
    int maxPages = 30,
  }) async {
    final reviews = <WeReadReview>[];
    final seenIds = <String>{};
    var synckey = 0;
    var page = 0;

    while (page < maxPages) {
      final body = <String, dynamic>{'bookid': bookId, 'count': pageSize};
      if (synckey > 0) {
        body['synckey'] = synckey;
      }
      final data = await _post('/review/list/mine', body);
      final rawReviews = data['reviews'];
      if (rawReviews is! List || rawReviews.isEmpty) {
        break;
      }
      for (final raw in rawReviews) {
        if (raw is! Map) {
          continue;
        }
        final review = WeReadReview.fromJson(Map<String, dynamic>.from(raw));
        if (review.reviewId.isEmpty || !seenIds.add(review.reviewId)) {
          continue;
        }
        if (review.content.trim().isEmpty) {
          continue;
        }
        reviews.add(review);
      }

      page++;
      final nextKey = _asInt(data['synckey']);
      if (_asInt(data['hasMore']) != 1 || nextKey <= 0 || nextKey == synckey) {
        break;
      }
      synckey = nextKey;
    }

    return reviews;
  }

  /// 统一 POST 网关。返回已经过服务端裁剪的业务数据。
  Future<Map<String, dynamic>> _post(
    String apiName, [
    Map<String, dynamic> params = const {},
  ]) async {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) {
      throw const WeReadApiException('还没有填写微信读书 API Key');
    }

    final body = <String, dynamic>{
      'api_name': apiName,
      ...params,
      'skill_version': skillVersion,
    };

    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(gatewayUrl),
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const WeReadApiException('微信读书接口超时，请检查网络后重试');
    } on SocketException catch (error) {
      throw WeReadApiException('连不上微信读书：${error.message}');
    } on http.ClientException catch (error) {
      throw WeReadApiException('网络请求失败：${error.message}');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const WeReadApiException('API Key 无效或已过期，请重新获取');
    }
    if (response.statusCode != 200) {
      throw WeReadApiException('微信读书接口返回 ${response.statusCode}');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const WeReadApiException('微信读书返回了无法解析的内容');
    }
    if (decoded is! Map) {
      throw const WeReadApiException('微信读书返回结构异常');
    }
    final data = Map<String, dynamic>.from(decoded);

    final upgradeInfo = data['upgrade_info'];
    if (upgradeInfo is Map) {
      final message = upgradeInfo['message']?.toString();
      throw WeReadUpgradeRequiredException(
        message == null || message.isEmpty
            ? '微信读书要求升级同步组件，请稍后再试'
            : '微信读书要求升级同步组件：$message',
      );
    }

    final errcode = _asInt(data['errcode']);
    if (errcode != 0) {
      final rawMessage = data['errmsg'] ?? data['err_msg'] ?? data['message'];
      final message = rawMessage?.toString().trim();
      throw WeReadApiException(
        message == null || message.isEmpty ? '微信读书返回错误（$errcode）' : message,
        errcode: errcode,
      );
    }

    return data;
  }

  static int _asInt(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value.toString().trim()) ?? 0;
  }
}
