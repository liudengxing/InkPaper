/// 首页标签屏蔽的纯计算。
///
/// 只做「这条笔记该不该出现在首页信息流」的判断，不碰 Provider、不碰
/// SharedPreferences，方便直接单测。真正的开关状态存在
/// `PreferencesService`，由 `AppProvider` 读进内存后调用这里。
library;

import 'package:inkpaper/models/note_model.dart';

/// 去掉标签前导的 `#` 与首尾空白，统一成可比较的形式。
///
/// 两个来源的标签格式并不一致：结构化 `tags` 字段有时带 `#`（Memos 同步
/// 过来的数据），正文提取出来的不带。不归一化会导致「屏蔽了却还在」。
String normalizeHomeTag(String tag) {
  var value = tag.trim();
  while (value.startsWith('#')) {
    value = value.substring(1);
  }
  return value.trim();
}

Set<String> _normalizeTags(Iterable<String> values) {
  final tags = <String>{};
  for (final tag in values) {
    final normalized = normalizeHomeTag(tag);
    if (normalized.isNotEmpty) {
      tags.add(normalized);
    }
  }
  return tags;
}

// 正文在 Note 实例内不可变。分页复用旧实例时跳过正文扫描，笔记离开内存后
// 缓存也能随实例回收。结构化 tags 是列表，每次读取当前值。
final _bodyTagsByNote = Expando<Set<String>>();

/// 一条笔记身上出现的全部标签：结构化 `tags` 与正文 `#标签` 的并集。
Set<String> collectNoteTags(Note note) {
  final bodyTags = _bodyTagsByNote[note] ??=
      _normalizeTags(Note.extractTagsFromContent(note.content));
  return _normalizeTags(note.tags)..addAll(bodyTags);
}

/// 这条笔记是否命中了任一被屏蔽的标签。
///
/// 层级标签按前缀算：屏蔽「读书」同时屏蔽「读书/笔记」，否则用户得把每
/// 一个子标签都勾一遍，还得随新增的子标签反复回来补。
bool isNoteHiddenByTags(Note note, Set<String> hiddenTags) =>
    _matchesHiddenTags(note, _normalizeTags(hiddenTags));

bool _matchesHiddenTags(Note note, Set<String> hiddenTags) {
  if (hiddenTags.isEmpty) {
    return false;
  }
  for (final tag in collectNoteTags(note)) {
    for (final blocked in hiddenTags) {
      if (tag == blocked || tag.startsWith('$blocked/')) {
        return true;
      }
    }
  }
  return false;
}

/// 过滤掉命中屏蔽标签的笔记。屏蔽为空时原样返回同一个实例，零开销。
List<Note> filterNotesByHiddenTags(List<Note> notes, Set<String> hiddenTags) {
  if (hiddenTags.isEmpty) {
    return notes;
  }
  final normalizedHiddenTags = _normalizeTags(hiddenTags);
  if (normalizedHiddenTags.isEmpty) {
    return notes;
  }
  return notes
      .where((note) => !_matchesHiddenTags(note, normalizedHiddenTags))
      .toList(growable: false);
}
