import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inkpaper/services/update_check_service.dart';

Map<String, dynamic> _releasePayload({
  String tag = 'v1.1.69',
  String name = 'InkPaper v1.1.69',
  String body = '### 新增\n- 检查更新',
  String publishedAt = '2026-11-10T08:00:00Z',
  List<Map<String, dynamic>>? assets,
}) =>
    {
      'tag_name': tag,
      'name': name,
      'body': body,
      'html_url': 'https://github.com/liudengxing/InkPaper/releases/tag/$tag',
      'published_at': publishedAt,
      'assets': assets ??
          [
            {
              'name': 'InkPaper-v1.1.69-android.apk',
              'browser_download_url':
                  'https://github.com/liudengxing/InkPaper/releases/download/'
                      '$tag/InkPaper-$tag-android.apk',
              'size': 52428800,
            },
            {
              'name': 'InkPaper-v1.1.69-macos.zip',
              'browser_download_url':
                  'https://github.com/liudengxing/InkPaper/releases/download/'
                      '$tag/InkPaper-$tag-macos.zip',
              'size': 104857600,
            },
          ],
    };

void main() {
  group('compareVersions', () {
    test('detects a newer patch version', () {
      expect(compareVersions('1.1.69', '1.1.68'), greaterThan(0));
      expect(compareVersions('1.1.68', '1.1.69'), lessThan(0));
    });

    test('treats equal versions as equal', () {
      expect(compareVersions('1.1.68', '1.1.68'), 0);
      expect(compareVersions('v1.1.68', '1.1.68'), 0);
      expect(compareVersions('1.2', '1.2.0'), 0);
    });

    test('ignores build number and prerelease suffix', () {
      expect(compareVersions('1.1.68+10164', '1.1.68'), 0);
      expect(compareVersions('1.1.69-rc1', '1.1.68'), greaterThan(0));
    });

    test('compares numerically, not lexically', () {
      expect(compareVersions('1.1.10', '1.1.9'), greaterThan(0));
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    });
  });

  group('parseLatestRelease', () {
    test('picks the apk asset and strips the v prefix', () {
      final result = parseLatestRelease(
        _releasePayload(),
        currentVersion: '1.1.68',
      );

      expect(result.latestVersion, '1.1.69');
      expect(result.hasUpdate, isTrue);
      expect(result.apkSizeBytes, 52428800);
      expect(result.apkDownloadUrl.toString(), endsWith('-android.apk'));
      expect(result.downloadUrl, result.apkDownloadUrl);
      expect(result.releaseNotes, contains('检查更新'));
      expect(result.publishedAt?.toUtc().hour, 8);
    });

    test('reports no update when the release is the same version', () {
      final result = parseLatestRelease(
        _releasePayload(tag: 'v1.1.68'),
        currentVersion: '1.1.68',
      );

      expect(result.hasUpdate, isFalse);
    });

    test('falls back to the release page without an apk asset', () {
      final result = parseLatestRelease(
        _releasePayload(
          assets: [
            {
              'name': 'InkPaper-v1.1.69-macos.zip',
              'browser_download_url': 'https://example.com/macos.zip',
              'size': 1,
            },
          ],
        ),
        currentVersion: '1.1.68',
      );

      expect(result.apkDownloadUrl, isNull);
      expect(result.apkSizeBytes, isNull);
      expect(result.downloadUrl, result.releasePageUrl);
    });

    test('rejects a payload without tag_name', () {
      expect(
        () => parseLatestRelease({'name': 'x'}, currentVersion: '1.1.68'),
        throwsA(isA<UpdateCheckException>()),
      );
    });
  });

  group('UpdateCheckService', () {
    test('parses a successful response', () async {
      final client = MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(jsonEncode(_releasePayload())),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      final service = UpdateCheckService(client: client);
      addTearDown(service.dispose);

      final result = await service.check();

      expect(result.latestVersion, '1.1.69');
      expect(result.apkDownloadUrl, isNotNull);
    });

    test('sends a user agent so GitHub accepts the call', () async {
      String? userAgent;
      final client = MockClient((request) async {
        userAgent = request.headers['User-Agent'];
        return http.Response('{}', 404);
      });
      final service = UpdateCheckService(client: client);
      addTearDown(service.dispose);

      await expectLater(
        service.check(),
        throwsA(
          isA<UpdateCheckException>().having(
            (e) => e.message,
            'message',
            contains('正式版本'),
          ),
        ),
      );
      expect(userAgent, isNotNull);
      expect(userAgent, isNotEmpty);
    });

    test('maps rate limiting to a readable message', () async {
      final client = MockClient((request) async => http.Response('', 403));
      final service = UpdateCheckService(client: client);
      addTearDown(service.dispose);

      await expectLater(
        service.check(),
        throwsA(
          isA<UpdateCheckException>().having(
            (e) => e.message,
            'message',
            contains('频繁'),
          ),
        ),
      );
    });

    test('maps network failures to a readable message', () async {
      final client = MockClient(
        (request) async => throw const FormatException('boom'),
      );
      final service = UpdateCheckService(client: client);
      addTearDown(service.dispose);

      await expectLater(
        service.check(),
        throwsA(
          isA<UpdateCheckException>().having(
            (e) => e.message,
            'message',
            contains('网络'),
          ),
        ),
      );
    });
  });

  group('多数据源', () {
    test('Gitee 缺字段时用模板兜底', () {
      final result = parseLatestRelease(
        {
          'tag_name': 'v1.1.75',
          'name': 'InkPaper v1.1.75',
          'body': '### 移除\n- 找回密码入口',
          'created_at': '2026-11-11T22:30:00+08:00',
          'assets': [
            {
              'name': 'v1.1.75.zip',
              'browser_download_url':
                  'https://gitee.com/liudengxing/InkPaper/archive/refs/tags/'
                      'v1.1.75.zip',
            },
          ],
        },
        currentVersion: '1.1.74',
        source: UpdateSource.gitee,
      );

      expect(result.sourceId, 'gitee');
      expect(
        result.releasePageUrl.toString(),
        'https://gitee.com/liudengxing/InkPaper/releases/tag/v1.1.75',
      );
      expect(
        result.apkDownloadUrl.toString(),
        'https://gitee.com/liudengxing/InkPaper/releases/download/'
        'v1.1.75/InkPaper-v1.1.75-android.apk',
      );
      expect(result.apkSizeBytes, isNull);
      expect(result.publishedAt, isNotNull);
      expect(result.hasUpdate, isTrue);
    });

    test('Gitee 挂了会回落到 GitHub', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.host);
        if (request.url.host == 'gitee.com') {
          return http.Response('{"message":"404 Not Found"}', 404);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(_releasePayload())),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = UpdateCheckService(client: client);
      addTearDown(service.dispose);

      final result = await service.check();

      expect(requested, ['gitee.com', 'api.github.com']);
      expect(result.sourceId, 'github');
      expect(result.latestVersion, '1.1.69');
    });

    test('Gitee 命中就不再请求 GitHub', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.host);
        return http.Response.bytes(
          utf8.encode(jsonEncode(_releasePayload())),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final service = UpdateCheckService(client: client);
      addTearDown(service.dispose);

      final result = await service.check();

      expect(requested, ['gitee.com']);
      expect(result.sourceId, 'gitee');
    });
  });
}
