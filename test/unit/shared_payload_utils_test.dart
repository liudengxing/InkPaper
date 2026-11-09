import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/shared_payload_utils.dart';

void main() {
  group('sharedPayloadToContent', () {
    test('keeps shared text content unchanged', () {
      expect(
        sharedPayloadToContent({
          'type': 'text',
          'content': '摘录内容\nhttps://inkpaper.cn',
        }),
        '摘录内容\nhttps://inkpaper.cn',
      );
    });

    test('turns one shared image into markdown image content', () {
      expect(
        sharedPayloadToContent({
          'type': 'image',
          'path': '/tmp/shared.jpg',
        }),
        contains('![图片](file:///tmp/shared.jpg)'),
      );
    });

    test('turns multiple shared images into markdown image content', () {
      final content = sharedPayloadToContent({
        'type': 'images',
        'paths': ['/tmp/a.jpg', '/tmp/b.png'],
      });

      expect(content, contains('2张'));
      expect(content, contains('file:///tmp/a.jpg'));
      expect(content, contains('file:///tmp/b.png'));
    });

    test('tolerates non-string path values from platform channels', () {
      final content = sharedPayloadToContent({
        'type': 'images',
        'paths': ['/tmp/a.jpg', 42, null],
      });

      expect(content, contains('file:///tmp/a.jpg'));
      expect(content, contains('file://42'));
    });

    test('turns shared file into readable file placeholder', () {
      final content = sharedPayloadToContent({
        'type': 'file',
        'path': '/tmp/report.pdf',
      });

      expect(content, contains('report.pdf'));
      expect(content, contains('/tmp/report.pdf'));
    });

    test('returns null for empty or unsupported payload', () {
      expect(sharedPayloadToContent({'type': 'image'}), isNull);
      expect(sharedPayloadToContent({'type': 'images', 'paths': []}), isNull);
      expect(sharedPayloadToContent({'type': 'unknown'}), isNull);
      expect(sharedPayloadToContent(null), isNull);
    });
  });

  group('分享来源标签', () {
    test('微信分享自动打 #微信', () {
      expect(
        sharedPayloadToContent({
          'type': 'text',
          'content': '这段话不错',
          'source': 'wechat',
        }),
        '#微信 这段话不错',
      );
    });

    test('微信读书分享自动打 #微信读书', () {
      expect(
        sharedPayloadToContent({
          'type': 'text',
          'content': '《活着》里的一句话',
          'source': 'weread',
        }),
        '#微信读书 《活着》里的一句话',
      );
    });

    test('认不出的来源不打标签', () {
      expect(
        sharedPayloadToContent({
          'type': 'text',
          'content': '来自文件管理器',
          'source': 'com.miui.filemanager',
        }),
        '来自文件管理器',
      );
      expect(
        sharedPayloadToContent({'type': 'text', 'content': '无来源'}),
        '无来源',
      );
      expect(
        sharedPayloadToContent({
          'type': 'text',
          'content': '空来源',
          'source': ' ',
        }),
        '空来源',
      );
    });

    test('正文已有同一标签时不重复添加', () {
      expect(
        sharedPayloadToContent({
          'type': 'text',
          'content': '#微信 已经标过了',
          'source': 'wechat',
        }),
        '#微信 已经标过了',
      );
    });

    test('#微信 不会因为正文里有 #微信读书 就误判为已标注', () {
      expect(
        sharedPayloadToContent({
          'type': 'text',
          'content': '#微信读书 书名\n划线内容',
          'source': 'wechat',
        }),
        '#微信 #微信读书 书名\n划线内容',
      );
    });

    test('图片分享同样带来源标签', () {
      final content = sharedPayloadToContent({
        'type': 'image',
        'path': '/tmp/shared.jpg',
        'source': 'wechat',
      });

      expect(content, startsWith('#微信 '));
      expect(content, contains('![图片](file:///tmp/shared.jpg)'));
    });

    test('sharedPayloadSourceTag 对未知来源返回 null', () {
      expect(sharedPayloadSourceTag({'source': 'wechat'}), '微信');
      expect(sharedPayloadSourceTag({'source': 'weread'}), '微信读书');
      expect(sharedPayloadSourceTag({'source': 'com.android.shell'}), isNull);
      expect(sharedPayloadSourceTag({'source': 'unknown'}), isNull);
      expect(sharedPayloadSourceTag(null), isNull);
    });
  });
}
