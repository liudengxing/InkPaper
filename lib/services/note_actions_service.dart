import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';

/// 📦 笔记操作数据层（ARCH-LAYER-002 / A-05）
///
/// 只做 `AppProvider` 的写操作：更新内容、删除、撤销删除、置顶、可见性。
/// **不涉及** `BuildContext`、弹窗、页面跳转与 SnackBar —— 这些界面编排在
/// `widgets/note_actions_ui.dart`（`NoteActionsUi`）。
///
/// 这样服务层可以脱离 Widget 树单测，UI 层也不再直接调 `AppProvider` 写接口。
class NoteActionsService {
  const NoteActionsService._();

  /// 更新笔记正文。
  static Future<bool> updateContent(
    AppProvider provider,
    Note note,
    String content,
  ) =>
      provider.updateNote(note, content);

  /// 删除笔记（撤销窗口等交互由 UI 层负责）。
  static Future<bool> delete(AppProvider provider, String noteId) =>
      provider.deleteNote(noteId);

  /// 撤销删除：按原内容与时间戳重新创建笔记。
  static Future<Note> restore(AppProvider provider, Note note) =>
      provider.createNote(
        note.content,
        createdAt: note.createdAt,
        updatedAt: note.updatedAt,
      );

  /// 置顶 / 取消置顶。
  static Future<bool> togglePin(AppProvider provider, Note note) =>
      provider.togglePinStatus(note);

  /// 设置笔记可见性（PUBLIC / PRIVATE）。
  static Future<Note?> setVisibility(
    AppProvider provider,
    Note note,
    String visibility,
  ) =>
      provider.setNoteVisibility(note, visibility);
}
