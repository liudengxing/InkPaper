import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:inkpaper/services/update_download_service.dart';

/// 固定分块的假客户端：不碰网络，能精确控制每块大小与状态码。
class _FakeClient extends http.BaseClient {
  _FakeClient({
    this.chunks = const [],
    this.statusCode = 200,
    this.contentLength,
  });

  final List<List<int>> chunks;
  final int statusCode;
  final int? contentLength;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks),
      statusCode,
      contentLength: contentLength,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

/// 由测试手动喂数据的客户端，用来模拟「下载到一半取消」。
class _ManualClient extends http.BaseClient {
  _ManualClient(this.controller);

  final StreamController<List<int>> controller;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(controller.stream, 200, contentLength: 64);
  }

  @override
  void close() {
    // 真机上 close 会掐断 socket 让 stream 报错；这里由测试自己补一块数据
    // 触发循环里的取消检查，避免测试挂住。
  }
}

/// 按地址返回不同状态码，用来验证「主源缺包 → 换退路」。
class _RoutedClient extends http.BaseClient {
  _RoutedClient(this.statusByUrl);

  /// 成功时下发的固定 4 字节内容。
  static final List<List<int>> _chunks = <List<int>>[
    <int>[1, 2, 3, 4],
  ];

  final Map<String, int> statusByUrl;

  /// 实际被请求过的地址，顺序即尝试顺序。
  final List<String> requested = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    requested.add(url);
    final status = statusByUrl[url] ?? 404;
    if (status != 200) {
      return http.StreamedResponse(const Stream<List<int>>.empty(), status);
    }
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(_chunks),
      200,
      contentLength: _chunks.fold<int>(0, (sum, chunk) => sum + chunk.length),
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('inkpaper-download-test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  UpdateDownloadService buildService(http.Client client) {
    return UpdateDownloadService(
      client: client,
      directoryProvider: () async => tempDir,
    );
  }

  test('下载完成后落盘，进度按块递增且最终等于总量', () async {
    final client = _FakeClient(
      chunks: [
        List<int>.filled(10, 1),
        List<int>.filled(6, 2),
      ],
      contentLength: 16,
    );
    final service = buildService(client);
    final progress = <UpdateDownloadProgress>[];

    final file = await service.download(
      Uri.parse('https://example.com/InkPaper.apk'),
      fileName: 'InkPaper.apk',
      expectedBytes: 16,
      onProgress: progress.add,
    );

    expect(await file.length(), 16);
    expect(progress.map((p) => p.received).toList(), [10, 16]);
    expect(progress.last.fraction, 1.0);
    // 中间态不能提前报完成
    expect(progress.first.fraction, closeTo(10 / 16, 0.0001));
    // 先写 .part 再改名，不该有残留
    expect(await File('${file.path}.part').exists(), isFalse);
  });

  test('字节数与服务端声明不符时抛错，且不留残缺安装包', () async {
    final client = _FakeClient(
      chunks: [
        List<int>.filled(8, 1),
      ],
      contentLength: 8,
    );
    final service = buildService(client);

    await expectLater(
      service.download(
        Uri.parse('https://example.com/InkPaper.apk'),
        fileName: 'InkPaper.apk',
        expectedBytes: 100,
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.message,
          'message',
          contains('不完整'),
        ),
      ),
    );

    expect(tempDir.listSync(), isEmpty);
  });

  test('HTTP 非 200 直接失败并带状态码', () async {
    final service = buildService(_FakeClient(statusCode: 404));

    await expectLater(
      service.download(
        Uri.parse('https://example.com/InkPaper.apk'),
        fileName: 'InkPaper.apk',
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.message,
          'message',
          contains('HTTP 404'),
        ),
      ),
    );
    expect(tempDir.listSync(), isEmpty);
  });

  test('取消下载后抛错并清掉临时文件', () async {
    final controller = StreamController<List<int>>();
    final service = buildService(_ManualClient(controller));

    final future = service.download(
      Uri.parse('https://example.com/InkPaper.apk'),
      fileName: 'InkPaper.apk',
      onProgress: (progress) {
        if (progress.received >= 8) {
          service.cancel();
        }
      },
    );

    controller.add(List<int>.filled(8, 9));
    // close() 在真机上会掐断连接；这里补一块数据让循环撞上取消检查。
    controller.add(List<int>.filled(8, 9));

    await expectLater(
      future,
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.message,
          'message',
          contains('取消'),
        ),
      ),
    );
    await controller.close();
    expect(tempDir.listSync(), isEmpty);
  });

  test('服务端没给 Content-Length 时 fraction 为 null，UI 只显示已下载量', () async {
    final client = _FakeClient(
      chunks: [
        List<int>.filled(4, 1),
      ],
    );
    final service = buildService(client);
    final progress = <UpdateDownloadProgress>[];

    await service.download(
      Uri.parse('https://example.com/InkPaper.apk'),
      fileName: 'InkPaper.apk',
      onProgress: progress.add,
    );

    expect(progress.single.total, isNull);
    expect(progress.single.fraction, isNull);
    expect(progress.single.received, 4);
  });

  group('主源缺包时换退路', () {
    final primary = Uri.parse('https://gitee.com/ink-paper/latest.apk');
    final fallback = Uri.parse('https://github.com/InkPaper/latest.apk');

    test('主源 404 时改走退路地址并成功落盘', () async {
      final client = _RoutedClient({
        primary.toString(): 404,
        fallback.toString(): 200,
      });
      final service = buildService(client);

      final file = await service.download(
        primary,
        fileName: 'InkPaper.apk',
        fallbackUrls: [fallback],
      );

      expect(await file.length(), 4);
      expect(client.requested, [primary.toString(), fallback.toString()]);
    });

    test('没有退路时 404 直接失败，不多发请求', () async {
      final client = _RoutedClient({primary.toString(): 404});
      final service = buildService(client);

      await expectLater(
        service.download(primary, fileName: 'InkPaper.apk'),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 404'),
          ),
        ),
      );
      expect(client.requested, [primary.toString()]);
    });

    test('5xx 不换源：GitHub 在国内太慢，换过去只会从失败变成长时间等待', () async {
      final client = _RoutedClient({
        primary.toString(): 503,
        fallback.toString(): 200,
      });
      final service = buildService(client);

      await expectLater(
        service.download(
          primary,
          fileName: 'InkPaper.apk',
          fallbackUrls: [fallback],
        ),
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 503'),
          ),
        ),
      );
      expect(client.requested, [primary.toString()]);
    });

    test('退路也没有包时抛错，两个地址各试一次且不留残缺文件', () async {
      final client = _RoutedClient({
        primary.toString(): 404,
        fallback.toString(): 404,
      });
      final service = buildService(client);

      await expectLater(
        service.download(
          primary,
          fileName: 'InkPaper.apk',
          fallbackUrls: [fallback],
        ),
        throwsA(isA<UpdateDownloadException>()),
      );
      expect(client.requested, [primary.toString(), fallback.toString()]);
      expect(tempDir.listSync(), isEmpty);
    });
  });
}
