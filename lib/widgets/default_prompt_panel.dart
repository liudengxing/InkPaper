import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/themes/app_theme.dart';

/// 「查看系统默认提示词」折叠面板。
///
/// 展示的文本直接取自服务层常量，用户看到的就是实际发给模型的那一份，
/// 不是另写一遍的说明文字 —— 避免文档与实现各说一套。
class DefaultPromptPanel extends StatefulWidget {
  const DefaultPromptPanel({
    required this.prompt,
    required this.replacedBy,
    this.note,
    super.key,
  });

  /// 默认提示词正文。
  final String prompt;

  /// 填了自定义提示词之后，默认提示词会怎样被替换。
  final String replacedBy;

  /// 补充说明（例如占位符的含义）。
  final String? note;

  @override
  State<DefaultPromptPanel> createState() => _DefaultPromptPanelState();
}

class _DefaultPromptPanelState extends State<DefaultPromptPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkMode = theme.brightness == Brightness.dark;
    final textColor = isDarkMode ? Colors.grey[300]! : Colors.grey[800]!;
    final secondaryColor = isDarkMode ? Colors.grey[500]! : Colors.grey[600]!;
    final borderColor = isDarkMode ? Colors.grey[800]! : Colors.grey[300]!;
    final fillColor = isDarkMode ? Colors.grey[900] : Colors.grey[100];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: AppTheme.primaryColor,
                ),
                const SizedBox(width: 4),
                Text(
                  AppLocalizationsSimple.of(context)?.defaultSystemPrompt ??
                      '查看系统默认提示词',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.primaryColor,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  widget.prompt.trim(),
                  style:
                      TextStyle(fontSize: 12, height: 1.55, color: textColor),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.replacedBy,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: secondaryColor,
                  ),
                ),
                if (widget.note != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.note!,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: secondaryColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
