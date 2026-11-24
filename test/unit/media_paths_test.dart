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

    test('MC-04 一次提取与分开调用给同一份结果', () {
      final note = _note(
        content: '正文\n'
            '![图片](file:///tmp/a.jpg)\n'
            '![视频](file:///tmp/b.mp4)\n'
            '![图片](/o/r/img-res)\n'
            '![视频](/o/r/vid-res)',
        resources: <Map<String, dynamic>>[
          {'uid': 'img-res', 'type': 'image/png', 'filename': 'a.png'},
          {'uid': 'vid-res', 'type': 'video/mp4', 'filename': 'a.mp4'},
          // 正文没提到的资源图也要收进来：顺序是「资源在前、正文在后」
          {'uid': 'img-only', 'type': 'image/jpeg', 'filename': 'c.jpg'},
        ],
      );

      final media = MemosContentHelper.extractNoteMediaPaths(note);
      expect(media.images, [
        '/o/r/img-res',
        '/o/r/img-only',
        'file:///tmp/a.jpg',
      ]);
      expect(media.videos, ['/o/r/vid-res', 'file:///tmp/b.mp4']);
      expect(media.isEmpty, isFalse);

      // 两个旧入口现在都走合并实现，结果必须逐项相同
      expect(MemosContentHelper.extractNoteImagePaths(note), media.images);
      expect(MemosContentHelper.extractNoteVideoPaths(note), media.videos);
    });

    test('MC-05 图片分类与视频分类各去各的重，互不影响', () {
      // 资源说它是图片、正文却按视频写法引用：两套分类依据独立，
      // 两个列表各保留一次（卡片据此仍按视频渲染）
      final note = _note(
        content: '![视频](/o/r/same)',
        resources: <Map<String, dynamic>>[
          {'uid': 'same', 'type': 'image/png', 'filename': 'same.png'},
        ],
      );

      final media = MemosContentHelper.extractNoteMediaPaths(note);
      expect(media.images, ['/o/r/same']);
      expect(media.videos, ['/o/r/same']);
    });

    test('MC-06 合并提取对正文只扫一遍，分开取是两遍', () {
      final note = _note(
        content: '![a](file:///tmp/a.jpg)\n![b](file:///tmp/b.mp4)',
      );

      MemosContentHelper.debugMarkdownMediaScanCount = 0;
      MemosContentHelper.extractNoteMediaPaths(note);
      expect(
        MemosContentHelper.debugMarkdownMediaScanCount,
        1,
        reason: '卡片与详情页要同时拿图片和视频，必须一次扫完',
      );

      // 老入口各自扫一遍：调用方若同时需要两者，就该用合并入口
      MemosContentHelper.extractNoteImagePaths(note);
      MemosContentHelper.extractNoteVideoPaths(note);
      expect(MemosContentHelper.debugMarkdownMediaScanCount, 3);
    });
  });
}
