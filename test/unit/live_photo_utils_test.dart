import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/live_photo_utils.dart';
import 'package:inkpaper/widgets/live_photo_badge.dart';

void main() {
  group('Live 图判定', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('inkpaper_live_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<File> touch(String name) async {
      final file = File('${tempDir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(const [0, 1, 2, 3]);
      return file;
    }

    test('LP-01 伴生片段命名是 <名字>.live.mp4', () {
      expect(
        LivePhotoUtils.videoPathFor('/a/b/image_123.jpg'),
        '/a/b/image_123.live.mp4',
      );
      expect(
        LivePhotoUtils.videoPathFor('file:///a/b/image_123.jpg'),
        '/a/b/image_123.live.mp4',
      );
      // 没有扩展名时直接拼后缀，别把整段路径吃掉
      expect(
        LivePhotoUtils.videoPathFor('/a/b/image_123'),
        '/a/b/image_123.live.mp4',
      );
    });

    test('LP-02 有伴生片段才算 Live 图', () async {
      final image = await touch('image_1.jpg');
      expect(LivePhotoUtils.hasLiveVideo('file://${image.path}'), isFalse);

      await touch('image_1.live.mp4');
      expect(LivePhotoUtils.hasLiveVideo('file://${image.path}'), isTrue);
      // 裸绝对路径同样认，别因为少了前缀就退化成静态图
      expect(LivePhotoUtils.hasLiveVideo(image.path), isTrue);
    });

    test('LP-03 网络与 content URI 一律不算 Live 图', () {
      expect(LivePhotoUtils.hasLiveVideo('https://x.com/a.jpg'), isFalse);
      expect(LivePhotoUtils.hasLiveVideo('http://x.com/a.jpg'), isFalse);
      expect(LivePhotoUtils.hasLiveVideo('content://media/a.jpg'), isFalse);
    });
  });

  group('LIVE 角标', () {
    testWidgets('LP-04 角标渲染出 LIVE 字样且不吃点击', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: LivePhotoBadge()),
          ),
        ),
      );

      expect(find.text('LIVE'), findsOneWidget);
      // 角标不该抢走图片的点击（框内 IgnorePointer 至少一层）
      expect(
        find.descendant(
          of: find.byType(LivePhotoBadge),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });
  });
}
