import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/shared_payload_utils.dart';

/// 分享多图生成的内容曾经在每张图后面写两个换行，落到库里就是笔记尾部
/// 挂着一串空行。这里锁住「图之间空一行、末尾不留换行」。
void main() {
  group('分享内容尾部不产生空行', () {
    test('SP-01 多图分享末尾没有换行，图之间保留一个空行', () {
      final content = sharedPayloadToContent(<String, Object>{
        'type': 'images',
        'paths': <String>['/a.jpg', '/b.jpg', '/c.jpg'],
      });

      expect(content, isNotNull);
      expect(content!.endsWith('\n'), isFalse);
      expect(content, startsWith('来自分享的图片 (3张):\n\n'));
      expect(
        content,
        contains('![图片](file:///a.jpg)\n\n![图片](file:///b.jpg)'),
      );
      expect(content, endsWith('![图片](file:///c.jpg)'));
    });

    test('SP-02 单图分享末尾没有换行', () {
      final content = sharedPayloadToContent(<String, Object>{
        'type': 'image',
        'path': '/a.jpg',
      });

      expect(content, '来自分享的图片:\n\n![图片](file:///a.jpg)');
    });
  });
}
