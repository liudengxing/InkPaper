import 'dart:io';
import 'dart:typed_data';

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

  group('动图解析', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('inkpaper_motion_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// 造一张「Container 目录」格式的动图（小米相机 MVIMG 就是这套）。
    Uint8List buildContainerMotionPhoto({int videoLength = 8192}) {
      final xmp = '<x:xmpmeta><rdf:Description GCamera:MotionPhoto="1" '
          'GCamera:MotionPhotoPresentationTimestampUs="1265856">'
          '<Container:Directory><rdf:Seq>'
          '<rdf:li><Container:Item Item:Mime="image/jpeg" '
          'Item:Semantic="Primary"/></rdf:li>'
          '<rdf:li><Container:Item Item:Mime="video/mp4" '
          'Item:Semantic="MotionPhoto" Item:Length="$videoLength" '
          'Item:Padding="0"/></rdf:li>'
          '</rdf:Seq></Container:Directory></rdf:Description></x:xmpmeta>';
      final video = Uint8List(videoLength);
      video[3] = 24; // box size
      video.setRange(4, 8, 'ftyp'.codeUnits);
      for (var i = 8; i < videoLength; i++) {
        video[i] = i & 0xFF;
      }
      final head = <int>[0xFF, 0xD8, ...xmp.codeUnits];
      final filler = List<int>.filled(2048, 0);
      return Uint8List.fromList([...head, ...filler, ...video]);
    }

    test('LP-05 Container 目录格式按 Item:Length 切出片段', () {
      final bytes = buildContainerMotionPhoto();
      final data = LivePhotoUtils.extractMotionPhoto(bytes);

      expect(data, isNotNull);
      expect(data!.videoBytes.length, 8192);
      expect(data.imageLength, bytes.length - 8192);
      expect(data.presentationTimestampUs, 1265856);
      // 片段首部必须是 ftyp box
      expect(String.fromCharCodes(data.videoBytes, 4, 8), 'ftyp');
    });

    test('LP-06 没有侧车时 ensureLiveVideo 会补抽出来', () async {
      final image = File('${tempDir.path}${Platform.pathSeparator}mv.jpg');
      await image.writeAsBytes(buildContainerMotionPhoto());

      expect(LivePhotoUtils.hasLiveVideo(image.path), isFalse);
      expect(await LivePhotoUtils.ensureLiveVideo(image.path), isTrue);

      final sidecar = File(LivePhotoUtils.videoPathFor(image.path));
      expect(sidecar.existsSync(), isTrue);
      expect(sidecar.lengthSync(), 8192);
      expect(LivePhotoUtils.hasLiveVideo(image.path), isTrue);
    });

    test('LP-07 普通静态图不会被当成动图，也不会落侧车', () async {
      final image = File('${tempDir.path}${Platform.pathSeparator}plain.jpg');
      await image.writeAsBytes(
        Uint8List.fromList([0xFF, 0xD8, ...List<int>.filled(6000, 7)]),
      );

      expect(
        LivePhotoUtils.extractMotionPhoto(image.readAsBytesSync()),
        isNull,
      );
      expect(await LivePhotoUtils.ensureLiveVideo(image.path), isFalse);
      expect(
        File(LivePhotoUtils.videoPathFor(image.path)).existsSync(),
        isFalse,
      );
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
