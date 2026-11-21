import 'package:flutter/material.dart';

/// 洞察报告里「推理过程」那一块折叠区。
///
/// 结果页和历史回看页都用它：思考过程一般比正文长好几倍，默认收起，想看
/// 再展开。展开状态由自己管，外层不需要再记一份。
class InsightReasoningPanel extends StatefulWidget {
  const InsightReasoningPanel({required this.reasoning, super.key});

  /// 模型的思考链原文，调用方负责判空（空就别挂了）。
  final String reasoning;

  @override
  State<InsightReasoningPanel> createState() => _InsightReasoningPanelState();
}

class _InsightReasoningPanelState extends State<InsightReasoningPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final muted = colorScheme.onSurfaceVariant;
    final expanded = _expanded;
    return Material(
      color: colorScheme.onSurface.withValues(alpha: 0.035),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _expanded = !expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.psychology_alt_outlined,
                    size: 15,
                    color: muted.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '推理过程',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: muted.withValues(alpha: 0.95),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${widget.reasoning.length} 字',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      color: muted.withValues(alpha: 0.55),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    expanded ? '收起' : '展开',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11.5,
                      color: muted.withValues(alpha: 0.7),
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: muted.withValues(alpha: 0.6),
                  ),
                ],
              ),
              if (expanded) ...[
                const SizedBox(height: 10),
                Text(
                  widget.reasoning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12.5,
                    height: 1.75,
                    color: muted.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
