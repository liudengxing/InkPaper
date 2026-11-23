// 待办事项解析和处理工具类

import 'package:flutter/foundation.dart';

/// 待办事项信息
class TodoItem {
  TodoItem({
    required this.checked,
    required this.text,
    required this.startIndex,
    required this.endIndex,
    required this.lineNumber,
  });
  final bool checked;
  final String text;
  final int startIndex; // 在原文中的起始位置
  final int endIndex; // 在原文中的结束位置
  final int lineNumber; // 行号（从0开始）

  @override
  String toString() =>
      'TodoItem(checked: $checked, text: "$text", line: $lineNumber)';
}

/// 待办事项解析器
class TodoParser {
  /// 待办行：`- [ ] 文本` / `- [x] 文本`。
  ///
  /// 提成常量是因为它原先写在 `parseTodos` 的逐行循环里，**每行都 new 一次**
  /// 正则（60 行的笔记一次统计就编译 60 次）。正则无状态，复用不影响语义。
  static final RegExp _todoLine = RegExp(r'^(\s*)-\s+\[([ xX])\]\s+(.+)$');

  /// 从内容中提取所有待办事项
  static List<TodoItem> parseTodos(String content) {
    final todos = <TodoItem>[];
    final lines = content.split('\n');

    var currentIndex = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lineStartIndex = currentIndex;
      currentIndex += line.length + 1; // +1 for newline

      // 匹配待办事项：- [ ] 或 - [x] 或 - [X]
      final match = _todoLine.firstMatch(line);

      if (match != null) {
        final indent = match.group(1)!;
        final checkStatus = match.group(2)!;
        final text = match.group(3)!;
        final checked = checkStatus.toLowerCase() == 'x';

        final checkboxStartIndex =
            lineStartIndex + indent.length; // "- [ ] " 的起始位置
        final checkboxEndIndex = currentIndex - 1;

        todos.add(
          TodoItem(
            checked: checked,
            text: text,
            startIndex: checkboxStartIndex,
            endIndex: checkboxEndIndex,
            lineNumber: i,
          ),
        );
      }
    }

    return todos;
  }

  /// 切换指定行的待办事项状态
  static String toggleTodoAtLine(String content, int lineNumber) {
    final lines = content.split('\n');
    if (lineNumber < 0 || lineNumber >= lines.length) {
      if (kDebugMode) {
        debugPrint('TodoParser: 行号越界 $lineNumber');
      }
      return content;
    }

    final line = lines[lineNumber];
    final todoRegex = RegExp(r'^(\s*-\s+)\[([ xX])\](\s+.+)$');
    final match = todoRegex.firstMatch(line);

    if (match != null) {
      final prefix = match.group(1)!; // "- "
      final checkStatus = match.group(2)!;
      final suffix = match.group(3)!; // " text"

      // 切换状态
      final newStatus = checkStatus.trim().isEmpty ? 'x' : ' ';
      lines[lineNumber] = '$prefix[$newStatus]$suffix';

      if (kDebugMode) {
        debugPrint(
          'TodoParser: 切换待办事项 $lineNumber: "${checkStatus.isEmpty ? "未完成" : "已完成"}" -> "${newStatus == "x" ? "已完成" : "未完成"}"',
        );
      }
    }

    return lines.join('\n');
  }

  /// 切换指定位置的待办事项状态（通过startIndex查找）
  static String toggleTodoAtIndex(String content, int startIndex) {
    // 找到这个index对应的行号
    var currentIndex = 0;
    var lineNumber = 0;
    final lines = content.split('\n');

    for (var i = 0; i < lines.length; i++) {
      final lineStartIndex = currentIndex;
      final lineEndIndex = currentIndex + lines[i].length;

      if (startIndex >= lineStartIndex && startIndex <= lineEndIndex) {
        lineNumber = i;
        break;
      }

      currentIndex = lineEndIndex + 1; // +1 for newline
    }

    return toggleTodoAtLine(content, lineNumber);
  }

  /// 统计待办事项。
  ///
  /// 口径与 [parseTodos] 一致，但不构造 `TodoItem`：桌面小组件每次重建快照
  /// 都要过整库（千条量级），只为了加两个计数就逐条建对象纯属浪费。
  /// 正文里没有 `[` 的直接返回——待办一定要有方括号，这一步能挡掉绝大多数
  /// 笔记。本机 1500 条 × 60 行的样本：29~48ms → 6~8ms。
  static Map<String, int> countTodos(String content) {
    if (!content.contains('[')) {
      return <String, int>{'total': 0, 'completed': 0, 'pending': 0};
    }
    var total = 0;
    var completed = 0;
    for (final line in content.split('\n')) {
      final match = _todoLine.firstMatch(line);
      if (match == null) {
        continue;
      }
      total++;
      if (match.group(2)!.toLowerCase() == 'x') {
        completed++;
      }
    }
    return <String, int>{
      'total': total,
      'completed': completed,
      'pending': total - completed,
    };
  }
}
