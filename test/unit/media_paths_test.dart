import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/media_paths.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';

Note _note({
  required String content,
  List<Map<String, dynamic>> resources = const <Map<String, dynamic>>[],
}) =>
    Note(
      id: 'n1',
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      resourceList: resources,
    );

void main() {
  group('MediaPaths', () {
    test('MP-01 按扩展名识别视频，带查询串也认', () {
      for (final path in <String>[
        '/tmp/a.mp4',
        'file:///tmp/a.MOV',
        '/tmp/a.m4v',
        'https://x/y.webm?t=1',
        '/o/r/abc.mkv',
      ]) {
        expect(MediaPaths.isVideoPath(path), isTrue, reason: path);
      }

      for (final path in <String>[
        '/tmp/a.jpg',
        '/tmp/a.heic',
        '/tmp/a.gif',
        // 服务端资源路径没有扩展名，不能当视频
        '/o/r/6c1f0d2e',
        '/file/attachments/xx/yy.png',
      ]) {
        expect(MediaPaths.isVideoPath(path), isFalse, reason: path);
      }
    });

    test('MP-02 服务端路径靠 alt 约定识别视频', () {
      expect(
        MediaPaths.isVideoMarkdown(path: '/o/r/abc123', alt: '视频'),
        isTrue,
        reason: '上传后路径没扩展名，只有 alt 能表达类型',
      );
      expect(
        MediaPaths.isVideoMarkdown(path: '/o/r/abc123', alt: '图片'),
        isFalse,
      );
      expect(
        MediaPaths.isVideoMarkdown(path: 'file:///a.mp4', alt: ''),
        isTrue,
        reason: 'alt 缺失时退回扩展名判断',
      );
    });

    test('MP-03 32MB 是 Memos 的上传上限', () {
      expect(MediaPaths.maxUploadBytes, 32 * 1024 * 1024);
    });

    test('MP-04 备份清单里的视频判定：标记优先，旧记录退回扩展名', () {
      // 服务端资源路径没有扩展名，只能靠清单里的显式标记
      expect(
        MediaPaths.isVideoAttachment(
          path: '/o/r/6c1f0d2e',
          markedVideo: true,
        ),
        isTrue,
      );
      // 旧备份没有标记：文件名/路径里的扩展名兜底
      expect(
        MediaPaths.isVideoAttachment(
          path: '/o/r/6c1f0d2e',
          filename: 'video_1712.mov',
        ),
        isTrue,
      );
      expect(MediaPaths.isVideoAttachment(path: 'file:///tmp/a.webm'), isTrue);
      // 图片与无扩展名又无标记的资源都不算视频
      expect(
        MediaPaths.isVideoAttachment(
          path: '/o/r/6c1f0d2e',
          filename: 'image_1712.jpg',
        ),
        isFalse,
      );
      expect(MediaPaths.isVideoAttachment(path: '/o/r/6c1f0d2e'), isFalse);
    });
  });

  group('MemosContentHelper 资源类型判定', () {
    test('MC-04 type 字段与扩展名都能认出视频，覆盖 3gp/m4v', () {
      expect(
        MemosContentHelper.isVideoResource(<String, dynamic>{
          'type': 'video/mp4',
          'filename': 'a.mp4',
        }),
        isTrue,
      );
      // 旧实现只列了 mov/mp4/avi/mkv/webm/flv，3gp 与 m4v 会漏
      expect(
        MemosContentHelper.isVideoResource(<String, dynamic>{
          'filename': 'clip.3gp',
        }),
        isTrue,
      );
      expect(
        MemosContentHelper.isVideoResource(<String, dynamic>{
          'filename': 'clip.m4v',
        }),
        isTrue,
      );
      expect(
        MemosContentHelper.isVideoResource(<String, dynamic>{
          'type': 'image/png',
          'filename': 'shot.png',
        }),
        isFalse,
      );
      expect(
        MemosContentHelper.isVideoResource(<String, dynamic>{'uid': 'x'}),
        isFalse,
      );
    });
  });

  group('MemosContentHelper 媒体分流', () {
    test('MC-01 markdown 里的视频不进图片列表', () {
      const content = '''
正文
![图片](file:///tmp/a.jpg)
![视频](file:///tmp/b.mp4)
![](/o/r/abc123)
![视频](/o/r/vid999)
''';

      expect(
        MemosContentHelper.extractMarkdownImagePaths(content),
        ['file:///tmp/a.jpg', '/o/r/abc123'],
      );
      expect(
        MemosContentHelper.extractMarkdownVideoPaths(content),
        ['file:///tmp/b.mp4', '/o/r/vid999'],
      );
    });

    test('MC-02 笔记层视频路径合并 resource 与 markdown 并去重', () {
      final note = _note(
        content: '文字\n![视频](/o/r/v1)\n![视频](file:///tmp/b.mp4)',
        resources: <Map<String, dynamic>>[
          {'uid': 'v1', 'type': 'video/mp4', 'filename': 'a.mp4'},
          {'uid': 'img1', 'type': 'image/png', 'filename': 'a.png'},
        ],
      );

      expect(
        MemosContentHelper.extractNoteVideoPaths(note),
        ['/o/r/v1', 'file:///tmp/b.mp4'],
      );
      expect(
        MemosContentHelper.extractNoteImagePaths(note),
        ['/o/r/img1'],
      );
    });

    test('MC-03 摘要不会把视频 markdown 当正文露出来', () {
      expect(
        MemosContentHelper.previewVisibleText(
          '今天去海边\n![视频](file:///tmp/a.mp4)',
        ),
        '今天去海边',
      );
    });
  });
}
