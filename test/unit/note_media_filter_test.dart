// ============================================================
// 「有图片 / 有视频」筛选：判定口径 + 数据库粗筛
// 背景：这两个入口是「全部笔记」的筛选参数（参考 flomo），
// 产出必须是全量笔记列表，不能只覆盖首页那 50 条分页缓存。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_media_filter.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: DatabaseService.schemaVersion,
      singleInstance: false,
      onCreate: (db, version) async {
        await DatabaseService.createSchema(db);
      },
    ),
  );
}

Note _note({
  required String id,
  required String content,
  List<Map<String, dynamic>> resourceList = const [],
  DateTime? createdAt,
}) {
  final time = createdAt ?? DateTime(2026, 11, 20, 10);
  return Note(
    id: id,
    content: content,
    createdAt: time,
    updatedAt: time,
    resourceList: resourceList,
  );
}

void main() {
  group('NoteMediaFilter.matches', () {
    test('all 命中任何笔记', () {
      final note = _note(id: 'n1', content: '纯文字');
      expect(NoteMediaFilter.all.matches(note), isTrue);
    });

    test('images 命中 markdown 图片，且不含纯文字笔记', () {
      final withImage = _note(id: 'n1', content: '正文\n\n![图片](file:///a.jpg)');
      final plain = _note(id: 'n2', content: '正文');

      expect(NoteMediaFilter.images.matches(withImage), isTrue);
      expect(NoteMediaFilter.images.matches(plain), isFalse);
    });

    test('images 不把视频算进来（视频共用 ![]() 写法）', () {
      final withVideo = _note(id: 'n1', content: '![视频](file:///a.mp4)');

      expect(NoteMediaFilter.images.matches(withVideo), isFalse);
      expect(NoteMediaFilter.videos.matches(withVideo), isTrue);
    });

    test('videos 认扩展名，也认 alt 约定（服务端资源没有扩展名）', () {
      final byExt = _note(id: 'n1', content: '![图片](file:///a.mov)');
      final byAlt = _note(id: 'n2', content: '![视频](/o/r/abc123)');

      expect(NoteMediaFilter.videos.matches(byExt), isTrue);
      expect(NoteMediaFilter.videos.matches(byAlt), isTrue);
      expect(NoteMediaFilter.images.matches(byAlt), isFalse);
    });

    test('resourceList 里的图片也算「有图片」', () {
      final note = _note(
        id: 'n1',
        content: '正文没有图片语法',
        resourceList: [
          {'uid': 'res-1', 'type': 'image/png', 'name': 'resources/res-1'},
        ],
      );

      expect(NoteMediaFilter.images.matches(note), isTrue);
    });

    test('fromId 兼容筛选名与侧边栏 id', () {
      expect(NoteMediaFilter.fromId('images'), NoteMediaFilter.images);
      expect(NoteMediaFilter.fromId('image_gallery'), NoteMediaFilter.images);
      expect(NoteMediaFilter.fromId('video_gallery'), NoteMediaFilter.videos);
      expect(NoteMediaFilter.fromId(null), NoteMediaFilter.all);
      expect(NoteMediaFilter.fromId('unknown'), NoteMediaFilter.all);
    });
  });

  group('DatabaseService.getNotesByMedia', () {
    late Database db;

    setUp(() async {
      db = await _openTestDb();
      await DatabaseService.upsertNote(
        db,
        _note(id: 'img-1', content: '带图\n![图片](file:///a.jpg)'),
      );
      await DatabaseService.upsertNote(
        db,
        _note(id: 'vid-1', content: '带视频\n![视频](file:///a.mp4)'),
      );
      await DatabaseService.upsertNote(
        db,
        _note(id: 'plain-1', content: '纯文字笔记'),
      );
      // 服务端资源路径没有扩展名，只有 resourceList 能判出来
      await DatabaseService.upsertNote(
        db,
        _note(
          id: 'res-1',
          content: '服务端图片',
          resourceList: [
            {'uid': 'res-1', 'type': 'image/jpeg', 'name': 'resources/res-1'},
          ],
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('images 只返回带图笔记（含 resourceList 图片），不含视频与纯文字', () async {
      final notes = await DatabaseService().getNotesByMedia(
        NoteMediaFilter.images,
        executor: db,
      );

      expect(notes.map((n) => n.id).toSet(), {'img-1', 'res-1'});
    });

    test('videos 只返回带视频笔记', () async {
      final notes = await DatabaseService().getNotesByMedia(
        NoteMediaFilter.videos,
        executor: db,
      );

      expect(notes.map((n) => n.id).toList(), ['vid-1']);
    });

    test('all 返回全部笔记', () async {
      final notes = await DatabaseService().getNotesByMedia(
        NoteMediaFilter.all,
        executor: db,
      );

      expect(notes.length, 4);
    });
  });
}
