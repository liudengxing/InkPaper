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

  group('isServerBackedImagePath', () {
    test('相对附件路径算服务端图', () {
      expect(isServerBackedImagePath('/file/attachments/A/x.jpg'), isTrue);
      expect(isServerBackedImagePath('attachments/A/x.jpg'), isTrue);
      expect(isServerBackedImagePath('/api/v1/attachments/A/x.jpg'), isTrue);
    });

    test('指向本服务器的绝对 URL 也算服务端图', () {
      expect(
        isServerBackedImagePath(
          'http://192.168.0.169:5230/file/attachments/A/x.jpg',
        ),
        isTrue,
      );
      expect(
        isServerBackedImagePath(
          'https://memos.example.com/api/v1/attachments/A/x.png',
        ),
        isTrue,
      );
    });

    test('本地路径与外链图不算服务端图', () {
      expect(isServerBackedImagePath('images/a.jpg'), isFalse);
      expect(
        isServerBackedImagePath('file:///data/user/0/app/files/images/a.jpg'),
        isFalse,
      );
      expect(isServerBackedImagePath('https://example.com/a.jpg'), isFalse);
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

    test('服务端附件路径按 sha1 命名算在用（离线缓存不算孤儿）', () {
      const remote = '/file/attachments/A/x.jpg';
      final names = referencedLocalImageFiles([_note('![a]($remote)')]);

      expect(names, {localFileNameForAttachment(remote)});
    });

    test('资源列表里的 externalLink 也算在用', () {
      const remote = 'attachments/B/y.png';
      final names = referencedLocalImageFiles([
        _note(
          '无图正文',
          resourceList: [
            {'externalLink': 'images/c.jpg'},
            {'externalLink': remote},
          ],
        ),
      ]);

      expect(names, {'c.jpg', localFileNameForAttachment(remote)});
    });
  });

  group('contentAddressedAttachmentName', () {
    test('同一份内容得到同一个名字', () {
      final a = contentAddressedAttachmentName([1, 2, 3], 'jpg');
      final b = contentAddressedAttachmentName([1, 2, 3], 'jpg');

      expect(a, b);
      expect(a, matches(RegExp(r'^[0-9a-f]{40}\.jpg$')));
    });

    test('扩展名大小写不同不影响命名', () {
      expect(
        contentAddressedAttachmentName([9, 9], 'JPG'),
        contentAddressedAttachmentName([9, 9], 'jpg'),
      );
    });

    test('不同内容得到不同名字（增量判断不会误判）', () {
      expect(
        contentAddressedAttachmentName([1, 2, 3], 'jpg'),
        isNot(contentAddressedAttachmentName([1, 2, 4], 'jpg')),
      );
    });

    test('非法或空扩展名归一到 bin', () {
      expect(
        contentAddressedAttachmentName([7], ''),
        endsWith('.bin'),
      );
      expect(
        contentAddressedAttachmentName([7], '??'),
        endsWith('.bin'),
      );
    });
  });

  group('restoreActionFor', () {
    test('本服务器附件只写本地缓存，不改正文', () {
      const paths = [
        '/file/attachments/A/x.jpg',
        'attachments/A/x.jpg',
        '/o/r/abc123',
        '/api/v1/attachments/A/x.png',
        '/api/v1/resource/abc123',
        'https://memos.example.com/file/attachments/A/x.jpg',
        'http://192.168.0.169:5230/api/v1/attachments/A/x.png',
      ];

      for (final path in paths) {
        expect(
          restoreActionFor(path),
          RestoreAttachmentAction.cacheServerCopy,
          reason: '$path 应保持服务端路径',
        );
      }
    });

    test('第三方外链不下载也不落地', () {
      const paths = [
        'https://cdn.example.com/pic.jpg',
        'http://example.com/a.png',
      ];

      for (final path in paths) {
        expect(
          restoreActionFor(path),
          RestoreAttachmentAction.skipExternal,
          reason: '$path 应原样保留',
        );
      }
    });

    test('真正的本地图才落地', () {
      const paths = [
        'file:///data/user/0/com.didichou.inkpaper/app_flutter/images/a.jpg',
        'images/flomo_a.jpg',
        'images/webdav_IMG_001_abcdef123456_0.jpg',
      ];

      for (final path in paths) {
        expect(
          restoreActionFor(path),
          RestoreAttachmentAction.materialize,
          reason: '$path 应落地成本地文件',
        );
      }
    });
  });

  group('rewriteMarkdownImagePaths', () {
    test('服务端图片路径在多设备间保持不变', () {
      const remote = '/file/attachments/A/x.jpg';
      const content = '正文\n![图]($remote)';

      // 即使恢复流程误把服务端路径塞进映射表，也不允许改写正文
      final rewritten = rewriteMarkdownImagePaths(content, {
        remote: 'file:///data/user/0/app/files/images/webdav_x_0.jpg',
      });

      expect(rewritten, content);
    });

    test('外链同样不被改写', () {
      const remote = 'https://cdn.example.com/pic.jpg';
      const content = '![](https://cdn.example.com/pic.jpg)';

      final rewritten = rewriteMarkdownImagePaths(content, {
        remote: 'file:///data/user/0/app/files/images/pic.jpg',
      });

      expect(rewritten, content);
    });

    test('同一篇笔记里只改本地图，服务端图原样', () {
      const serverPath = '/file/attachments/A/server.jpg';
      const localPath = 'file:///data/user/0/app/files/images/local.jpg';
      const content = '![s]($serverPath)\n![l]($localPath)';

      final rewritten = rewriteMarkdownImagePaths(content, {
        serverPath: 'file:///data/user/0/app/files/images/should_not_use.jpg',
        localPath: 'file:///data/user/0/app/files/images/restored.jpg',
      });

      expect(rewritten, contains(']($serverPath)'));
      expect(
        rewritten,
        contains('![l](file:///data/user/0/app/files/images/restored.jpg)'),
      );
      expect(rewritten, isNot(contains('should_not_use')));
    });

    test('空映射表原样返回', () {
      const content = '![](/file/attachments/A/x.jpg)';
      expect(rewriteMarkdownImagePaths(content, {}), content);
    });
  });
}
