import 'package:flutter/material.dart';
import 'package:inkpaper/widgets/note_editor.dart';

/// 编辑已有笔记的统一入口：全屏编辑器。
///
/// 底部那套 flomo 式玻璃卡片只留给「新建」——从底下一滑就能写、高度随内容
/// 长、写完就走。改一条已有笔记是重活：正文可能几十行、要调图片顺序、补标签，
/// 220px 高的卡片撑不住，所以一律进全屏。
///
/// 全屏与卡片共用同一个 [NoteEditor]，只切 `fullScreen`；复制一份编辑器出来
/// 维护是这套代码里最容易腐烂的做法。
class NoteEditorPage {
  const NoteEditorPage._();

  /// 打开编辑态，返回的 Future 在编辑器关闭（保存或取消）后完成。
  static Future<void> open(
    BuildContext context, {
    required String noteId,
    required String initialContent,
    required Future<void> Function(String content) onSave,
  }) {
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => NoteEditor(
          fullScreen: true,
          currentNoteId: noteId,
          initialContent: initialContent,
          onSave: onSave,
        ),
        // 同一篇笔记换个状态，不是跳到别处：淡入比整页滑入更像「就地展开编辑」
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }
}
