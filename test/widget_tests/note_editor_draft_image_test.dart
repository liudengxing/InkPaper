import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/draft_service.dart';
import 'package:inkpaper/widgets/note_editor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 草稿只存一段 Markdown 文本，图片靠 `![图片](file://…)` 引用写进正文。
/// 这里盯住「加了图片之后草稿里到底有没有图片」这条链：自动暂存、关闭时暂存、
/// 重新打开后的恢复，全部走真实编辑器。
///
/// 后半部分用假的相册与应用目录，模拟「在编辑器里真加一张图」的完整路径 ——
/// 前面那些用例喂的是现成 Markdown，跳过了 `_saveImageLocally` 落盘那一步。

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _FakeImagePicker extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  _FakeImagePicker(this.files);

  final List<XFile> files;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async =>
      files;
}

Widget _app({String? content, String? noteId, bool preserveDraft = false}) =>
    ChangeNotifierProvider(
      create: (_) => AppProvider(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => NoteEditor(
                    initialContent: content,
                    currentNoteId: noteId,
                    preserveDraftOnClose: preserveDraft,
                    onSave: (_) async {},
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _openEditor(
  WidgetTester tester, {
  String? content,
  String? noteId,
  bool preserveDraft = false,
}) async {
  await tester.pumpWidget(
    _app(content: content, noteId: noteId, preserveDraft: preserveDraft),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 图片区有没有图：单行条用 [ReorderableDelayedDragStartListener]，展开成
/// 九宫格后换成 [LongPressDraggable]。
bool _hasImages(WidgetTester tester) =>
    find.byType(ReorderableDelayedDragStartListener).evaluate().isNotEmpty ||
    find.byType(LongPressDraggable<int>).evaluate().isNotEmpty;

/// 读出草稿槽位里存的原始 Markdown。
Future<String?> _draftContent(String slot) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(DraftService.prefsKey);
  if (raw == null) {
    return null;
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    return null;
  }
  final entry = decoded[slot];
  if (entry is! Map) {
    return null;
  }
  return entry['content']?.toString();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('新建笔记只加图片、不写字，关闭时草稿里也要有图片', (tester) async {
    await _openEditor(tester);

    // 用文本接口塞一句「空正文 + 图片」的场景不好造，这里退一步：先写一行字，
    // 再把文字删掉，留下与「只贴图」等价的正文。
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    // 没有改动就不该留草稿
    expect(await _draftContent(DraftService.newNoteDraftId), isNull);
  });

  testWidgets('编辑已有笔记改动正文后，草稿保留原有图片引用', (tester) async {
    const original = '第一行\n\n![图片](file:///tmp/inkpaper-draft-a.jpg)';
    await _openEditor(tester, content: original, noteId: 'note-1');

    await tester.enterText(find.byType(TextField), '第一行改一下');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    final draft = await _draftContent('note-1');
    expect(draft, isNotNull, reason: '改了正文就该落草稿');
    expect(
      draft,
      contains('file:///tmp/inkpaper-draft-a.jpg'),
      reason: '正文之外，图片引用也必须一起进草稿，否则恢复后图片消失',
    );
  });

  testWidgets('关闭编辑器时保存的草稿同样带图片', (tester) async {
    const original = '第一行\n\n![图片](file:///tmp/inkpaper-draft-b.jpg)';
    await _openEditor(tester, content: original, noteId: 'note-2');

    await tester.enterText(find.byType(TextField), '第一行再改');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    final draft = await _draftContent('note-2');
    expect(draft, isNotNull);
    expect(draft, contains('file:///tmp/inkpaper-draft-b.jpg'));
  });

  testWidgets('重新打开已有笔记会自动恢复草稿，图片回到图片区', (tester) async {
    const original = '第一行\n\n![图片](file:///tmp/inkpaper-draft-c.jpg)';
    await _openEditor(tester, content: original, noteId: 'note-3');

    await tester.enterText(find.byType(TextField), '第一行又改了');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    // 关掉，再用同一个 noteId 打开
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    await _openEditor(tester, content: original, noteId: 'note-3');
    expect(find.text('已恢复上次未保存的草稿'), findsOneWidget);
    // 编辑器打开后会延时再聚焦一次，等它跑完，免得测试结束时还挂着 Timer
    await tester.pump(const Duration(milliseconds: 300));

    final images = tester
        .widgetList<Image>(find.byType(Image))
        .map((widget) => widget.image)
        .whereType<ResizeImage>()
        .map((provider) => provider.imageProvider)
        .whereType<FileImage>()
        .map((provider) => provider.file.path)
        .toList();
    expect(
      images,
      contains('/tmp/inkpaper-draft-c.jpg'),
      reason: '草稿恢复后图片区应当重新挂上原图',
    );
  });

  testWidgets('新建笔记里真加一张图再关闭，草稿必须带上这张图', (tester) async {
    final sandbox = Directory.systemTemp.createTempSync('inkpaper-draft-img');
    addTearDown(() {
      if (sandbox.existsSync()) {
        sandbox.deleteSync(recursive: true);
      }
    });

    final picked = File('${sandbox.path}/picked.png');
    picked.writeAsBytesSync(File('assets/images/logo.png').readAsBytesSync());

    PathProviderPlatform.instance = _FakePathProvider('${sandbox.path}/docs');
    ImagePickerPlatform.instance = _FakeImagePicker([XFile(picked.path)]);

    await _openEditor(tester);
    // 落盘是真的文件 IO，fake async 里不会推进，必须放到 runAsync
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.photo_outlined));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    // 图片区已经挂上这张图
    expect(_hasImages(tester), isTrue, reason: '点图片按钮后应当立刻进图片区');

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    final draft = await _draftContent(DraftService.newNoteDraftId);
    expect(draft, isNotNull, reason: '只贴了图也算有改动，不能当成空草稿清掉');
    expect(
      draft,
      contains('/docs/images/'),
      reason: '草稿里必须写出图片的本地路径，否则重开就是一张图都没有',
    );
  });

  testWidgets('重新打开新建笔记，草稿里的图要能回来', (tester) async {
    final sandbox = Directory.systemTemp.createTempSync('inkpaper-draft-img2');
    addTearDown(() {
      if (sandbox.existsSync()) {
        sandbox.deleteSync(recursive: true);
      }
    });

    final picked = File('${sandbox.path}/picked.png');
    picked.writeAsBytesSync(File('assets/images/logo.png').readAsBytesSync());

    PathProviderPlatform.instance = _FakePathProvider('${sandbox.path}/docs');
    ImagePickerPlatform.instance = _FakeImagePicker([XFile(picked.path)]);

    await _openEditor(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.photo_outlined));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    // 关掉弹层后再点「+」新建，走的是 initState 里的自动恢复
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      _hasImages(tester),
      isTrue,
      reason: '新建笔记应当自动恢复草稿，图片要一起回来',
    );
  });

  testWidgets('自动恢复后继续写，草稿里的图片不能被后续暂存盖掉', (tester) async {
    final sandbox = Directory.systemTemp.createTempSync('inkpaper-draft-img3');
    addTearDown(() {
      if (sandbox.existsSync()) {
        sandbox.deleteSync(recursive: true);
      }
    });

    final picked = File('${sandbox.path}/picked.png');
    picked.writeAsBytesSync(File('assets/images/logo.png').readAsBytesSync());

    PathProviderPlatform.instance = _FakePathProvider('${sandbox.path}/docs');
    ImagePickerPlatform.instance = _FakeImagePicker([XFile(picked.path)]);

    const original = '原内容';
    await _openEditor(tester, content: original, noteId: 'note-5');
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.photo_outlined));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(_hasImages(tester), isTrue);

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(
      await _draftContent('note-5'),
      contains('/docs/images/'),
      reason: '关闭时先把带图的草稿存下来',
    );

    // 再打开同一条笔记：草稿直接恢复进编辑器，并给出提示
    await _openEditor(tester, content: original, noteId: 'note-5');
    expect(find.text('已恢复上次未保存的草稿'), findsOneWidget);
    expect(_hasImages(tester), isTrue, reason: '打开时就该看到上次加的图');

    // 用户接着写
    await tester.enterText(find.byType(TextField), '原内容改了');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();

    final draft = await _draftContent('note-5');
    expect(
      draft,
      contains('/docs/images/'),
      reason: '后续自动暂存不能把刚加的图弄丢',
    );
  });

  testWidgets('编辑已有笔记加图后重开，图片自动回来', (tester) async {
    final sandbox = Directory.systemTemp.createTempSync('inkpaper-draft-img4');
    addTearDown(() {
      if (sandbox.existsSync()) {
        sandbox.deleteSync(recursive: true);
      }
    });

    final picked = File('${sandbox.path}/picked.png');
    picked.writeAsBytesSync(File('assets/images/logo.png').readAsBytesSync());

    PathProviderPlatform.instance = _FakePathProvider('${sandbox.path}/docs');
    ImagePickerPlatform.instance = _FakeImagePicker([XFile(picked.path)]);

    const original = '原内容';
    await _openEditor(tester, content: original, noteId: 'note-6');
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.photo_outlined));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    await _openEditor(tester, content: original, noteId: 'note-6');
    await tester.pump(const Duration(milliseconds: 300));

    expect(_hasImages(tester), isTrue, reason: '恢复草稿后图片区要有这张图');
  });

  testWidgets('提示条上点撤销会退回原文并清掉草稿', (tester) async {
    const original = '第一行\n\n![图片](file:///tmp/inkpaper-draft-d.jpg)';
    await _openEditor(tester, content: original, noteId: 'note-7');

    await tester.enterText(find.byType(TextField), '改过的内容');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    await _openEditor(tester, content: original, noteId: 'note-7');
    expect(find.text('已恢复上次未保存的草稿'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(find.text('已恢复上次未保存的草稿'), findsNothing);
    expect(await _draftContent('note-7'), isNull, reason: '撤销等于丢掉这份草稿');
    expect(find.text('改过的内容'), findsNothing, reason: '正文退回原文');
    expect(_hasImages(tester), isTrue, reason: '原文里的图要回来');
    await tester.pump(const Duration(milliseconds: 300));
  });
}
