import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';

/// 笔记列表的媒体筛选口径。
///
/// 参考 flomo：「有图片」不是一个独立的相册页，而是「全部笔记」上的一个
/// 筛选参数，筛完产出的仍然是笔记列表 —— 能接着点开、编辑、分享。
///
/// 判定走 [MemosContentHelper.extractNoteImagePaths] /
/// [MemosContentHelper.extractNoteVideoPaths]，与卡片九宫格、详情页用的是
/// 同一套解析，图片和视频在那里已经互斥（视频也写成 `![](…)`，靠扩展名和
/// alt 约定分流），所以这里不用再排一遍。
enum NoteMediaFilter {
  all('all_notes'),
  images('image_gallery'),
  videos('video_gallery');

  const NoteMediaFilter(this.labelKey);

  /// 侧边栏 / 标题栏复用的文案 key，避免再维护一份中英文。
  final String labelKey;

  static NoteMediaFilter fromId(String? id) {
    if (id == null || id.isEmpty) {
      return NoteMediaFilter.all;
    }
    for (final filter in values) {
      if (filter.name == id || filter.labelKey == id) {
        return filter;
      }
    }
    return NoteMediaFilter.all;
  }

  /// 这条笔记是否落在当前筛选口径里。
  bool matches(Note note) => switch (this) {
        NoteMediaFilter.all => true,
        NoteMediaFilter.images =>
          MemosContentHelper.extractNoteImagePaths(note).isNotEmpty,
        NoteMediaFilter.videos =>
          MemosContentHelper.extractNoteVideoPaths(note).isNotEmpty,
      };
}
