import 'package:flutter/material.dart';
import 'package:inkpaper/utils/insight_text_spans.dart';

/// 洞察报告顶部的「分析摘要」卡片。
///
/// 摘要是模型对本次发现的几点可核对结论，不是内部思维链——后者另有
/// 折叠的「推理过程」面板展示。摘要默认展开，因为它比正文短得多，
/// 又不像推理那样绕，是读者判断「这份报告值不值得往下读」的入口。
///
/// 和正文一样用 Text.rich 渲染 `[序号]` 角标（编辑控件的 recognizer 不参与
/// 点击分发），所以调用方要把同一套 recognizers 与 onTapRef 传进来。
class InsightSummaryCard extends StatelessWidget {
  const InsightSummaryCard({
    required this.summary,
    required this.style,
    this.recognizers,
    this.onTapRef,
    super.key,
  });

  final String summary;
  final TextStyle style;
  final InsightRefRecognizers? recognizers;
  final ValueChanged<int>? onTapRef;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final muted = colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.summarize_outlined,
                size: 14,
                color: colorScheme.primary.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 6),
              Text(
                '分析摘要',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.primary.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text.rich(
            TextSpan(
              children: buildInsightSpans(
                summary,
                style.copyWith(
                  fontSize: (style.fontSize ?? 15.5) - 1.5,
                  height: 1.65,
                  color: muted.withValues(alpha: 0.95),
                ),
                colorScheme,
                recognizers: recognizers,
                onTapRef: onTapRef,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
