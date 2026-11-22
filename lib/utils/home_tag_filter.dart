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

/// 一条笔记身上出现的全部标签：结构化 `tags` 与正文 `#标签` 的并集。
///
/// 少看一边都不行：同步来的笔记标签常只存在字段里，手写的常只在正文里。
Set<String> collectNoteTags(Note note) {
  final tags = <String>{};
  for (final tag in note.tags) {
    final normalized = normalizeHomeTag(tag);
    if (normalized.isNotEmpty) {
      tags.add(normalized);
    }
  }
  for (final tag in Note.extractTagsFromContent(note.content)) {
    final normalized = normalizeHomeTag(tag);
    if (normalized.isNotEmpty) {
      tags.add(normalized);
    }
  }
  return tags;
}

/// 这条笔记是否命中了任一被屏蔽的标签。
///
/// 层级标签按前缀算：屏蔽「读书」同时屏蔽「读书/笔记」，否则用户得把每
/// 一个子标签都勾一遍，还得随新增的子标签反复回来补。
bool isNoteHiddenByTags(Note note, Set<String> hiddenTags) {
  if (hiddenTags.isEmpty) {
    return false;
  }
  final tags = collectNoteTags(note);
  if (tags.isEmpty) {
    return false;
  }
  // 名单本身也归一化：来源可能是用户手输、旧版本存的带 `#` 的值，
  // 不归一化会出现「明明屏蔽了却还在首页」。
  final hidden = <String>{};
  for (final tag in hiddenTags) {
    final normalized = normalizeHomeTag(tag);
    if (normalized.isNotEmpty) {
      hidden.add(normalized);
    }
  }
  if (hidden.isEmpty) {
    return false;
  }
  for (final tag in tags) {
    for (final blocked in hidden) {
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
  return notes
      .where((note) => !isNoteHiddenByTags(note, hiddenTags))
      .toList(growable: false);
}
