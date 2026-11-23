import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/screens/note_edit_history_screen.dart';
import 'package:inkpaper/widgets/note_image_grid.dart';
import 'package:inkpaper/widgets/note_video_card.dart';
import 'package:provider/provider.dart';

/// 历史版本正文的渲染口径。
///
/// 快照里只存 markdown，图片/视频都是 `![](path)` 引用。曾经这里直接把
/// `entry.content` 丢进 SelectableText，用户只能看到一串 `![](...)`，
/// 图片永远出不来；现在与详情页同源：正文剥掉图片语法，媒体单独渲染。
Widget _wrap(String content) => ChangeNotifierProvider<AppProvider>(
      create: (_) => AppProvider(initialConfig: AppConfig()),
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NoteHistorySnapshotView(
              content: content,
              textColor: Colors.black87,
              accentColor: Colors.teal,
              serverUrl: null,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('HIS-01 图片快照走九宫格，正文不再露出 ![]( 语法', (tester) async {
    await tester.pumpWidget(_wrap('周末去爬山\n\n![](images/hike.jpg)'));
    // 网格会延后 90ms 再挂真正的图片，先把这段延时走完
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('![', findRichText: true), findsNothing);
    expect(find.byType(NoteImageGrid), findsOneWidget);
    expect(find.byType(NoteVideoCard), findsNothing);
  });

  testWidgets('HIS-02 视频快照走视频卡片，不与图片网格同时出现', (tester) async {
    await tester.pumpWidget(_wrap('![](images/clip.mp4)'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(NoteVideoCard), findsOneWidget);
    expect(find.byType(NoteImageGrid), findsNothing);
    expect(find.textContaining('![', findRichText: true), findsNothing);
  });

  testWidgets('HIS-03 纯文字快照不挂多余的媒体块', (tester) async {
    await tester.pumpWidget(_wrap('只有文字的一条笔记。'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(NoteImageGrid), findsNothing);
    expect(find.byType(NoteVideoCard), findsNothing);
  });
}
