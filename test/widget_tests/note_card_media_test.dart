// ============================================================
// OPT-09B · 卡片媒体提取合并成一次扫描后的行为回归
//
// 卡片原来分别调 extractNoteImagePaths / extractNoteVideoPaths，等于把
// resourceList 遍历两遍、正文正则扫两遍。合并成 extractNoteMediaPaths 之后，
// 「视频优先于图片」这条渲染口径必须原样保留 —— 这里从组件层咬住它，
// 免得以后为了实现方便把两段分支调换顺序。
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/widgets/note_card.dart';
import 'package:inkpaper/widgets/note_video_card.dart';
import 'package:provider/provider.dart';

Widget _wrap(Widget child) => ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 390, child: child),
        ),
      ),
    );

Note _note({
  required String content,
  List<Map<String, dynamic>> resources = const <Map<String, dynamic>>[],
}) =>
    Note(
      id: 'media-card',
      content: content,
      createdAt: DateTime(2026, 11, 20, 9),
      updatedAt: DateTime(2026, 11, 20, 9),
      resourceList: resources,
    );

void main() {
  group('NoteCard 媒体互斥', () {
    testWidgets('NCM-01 正文有视频时只渲染视频，资源里的图片不抢位置', (tester) async {
      final note = _note(
        content: '今天的日落\n![视频](file:///tmp/sunset.mp4)',
        resources: <Map<String, dynamic>>[
          {'uid': 'res-1', 'type': 'image/png', 'filename': 'cover.png'},
        ],
      );

      await tester.pumpWidget(
        _wrap(
          NoteCard(
            note: note,
            onEdit: () {},
            onDelete: () {},
            onPin: () {},
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byType(NoteVideoCard),
        findsOneWidget,
        reason: '视频分支优先，合并提取不能把顺序弄反',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('NCM-02 视频来自 resourceList 时同样走视频分支', (tester) async {
      final note = _note(
        content: '没有正文媒体',
        resources: <Map<String, dynamic>>[
          {'uid': 'vid-1', 'type': 'video/mp4', 'filename': 'clip.mp4'},
          {'uid': 'img-1', 'type': 'image/png', 'filename': 'shot.png'},
        ],
      );

      await tester.pumpWidget(
        _wrap(
          NoteCard(
            note: note,
            onEdit: () {},
            onDelete: () {},
            onPin: () {},
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byType(NoteVideoCard),
        findsOneWidget,
        reason: '资源分类仍按 type/filename 判视频',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('NCM-03 纯图片笔记不出现视频卡片', (tester) async {
      final note = _note(
        content: '两张截图',
        resources: <Map<String, dynamic>>[
          {'uid': 'img-1', 'type': 'image/png', 'filename': 'a.png'},
          {'uid': 'img-2', 'type': 'image/png', 'filename': 'b.png'},
        ],
      );

      await tester.pumpWidget(
        _wrap(
          NoteCard(
            note: note,
            onEdit: () {},
            onDelete: () {},
            onPin: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(NoteVideoCard), findsNothing);
    });
  });
}
