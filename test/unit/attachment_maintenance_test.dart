import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/attachment_maintenance.dart';

Note _note(String content, {List<Map<String, dynamic>>? resourceList}) => Note(
      id: 'n1',
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      resourceList: resourceList,
    );

void main() {
  group('extractImageRefs', () {
    test('提取 markdown 图片路径并去重', () {
      const content = '正文\n'
          '![图片](/file/attachments/A/image_1.jpg)\n'
          '中间文字\n'
          '![图片](/file/attachments/A/image_1.jpg)\n'
          '![图二](images/local.jpg)';

      expect(
        extractImageRefs(content),
        ['/file/attachments/A/image_1.jpg', 'images/local.jpg'],
      );
    });

    test('没有图片时返回空', () {
      expect(extractImageRefs('纯文本笔记 #标签'), isEmpty);
    });
  });

  group('isRemoteAttachmentPath', () {
    test('识别服务器路径', () {
      expect(isRemoteAttachmentPath('/file/attachments/A/x.jpg'), isTrue);
      expect(isRemoteAttachmentPath('attachments/A/x.jpg'), isTrue);
      expect(isRemoteAttachmentPath('/o/r/abc'), isTrue);
    });

    test('本地与网络地址不算', () {
      expect(isRemoteAttachmentPath('images/x.jpg'), isFalse);
      expect(isRemoteAttachmentPath('https://example.com/x.jpg'), isFalse);
    });
  });

  group('localFileNameForAttachment', () {
    test('同路径稳定，不同 uid 得到不同文件名', () {
      const a = '/file/attachments/AAA111/image_1.jpg';
      const b = '/file/attachments/BBB222/image_1.jpg';

      expect(localFileNameForAttachment(a), localFileNameForAttachment(a));
      expect(localFileNameForAttachment(a), isNot(localFileNameForAttachment(b)));
      expect(localFileNameForAttachment(a).endsWith('.jpg'), isTrue);
      expect(localFileNameForAttachment(a).startsWith('memos_'), isTrue);
    });
  });

  group('rewriteImageRefs', () {
    test('只替换映射中命中的路径', () {
      const content = '![a](/file/attachments/A/x.jpg)\n![b](/file/attachments/B/y.jpg)';
      final result = rewriteImageRefs(content, {
        '/file/attachments/A/x.jpg': 'images/memos_x_1.jpg',
      });

      expect(result, contains('![a](images/memos_x_1.jpg)'));
      expect(result, contains('![b](/file/attachments/B/y.jpg)'));
    });

    test('空映射不改动正文', () {
      const content = '![a](/file/attachments/A/x.jpg)';
      expect(rewriteImageRefs(content, const {}), content);
    });
  });

  group('referencedLocalImageFiles', () {
    test('认 images/ 相对路径与 file:// 绝对路径', () {
      final names = referencedLocalImageFiles([
        _note('![a](images/a.jpg)'),
        _note('![b](file:///data/user/0/app/files/images/b.jpg)'),
        _note('纯文本'),
      ]);

      expect(names, {'a.jpg', 'b.jpg'});
    });

    test('远程引用不算本地在用', () {
      final names = referencedLocalImageFiles([
        _note('![a](/file/attachments/A/x.jpg)'),
      ]);

      expect(names, isEmpty);
    });

    test('资源列表里的 externalLink 也算在用', () {
      final names = referencedLocalImageFiles([
        _note(
          '无图正文',
          resourceList: [
            {'externalLink': 'images/c.jpg'},
          ],
        ),
      ]);

      expect(names, {'c.jpg'});
    });
  });
}
