import 'package:flutter/material.dart';

/// 把洞察正文里的 `[12]` 渲染成小一号的带色标记。
///
/// 结果页与历史回看共用同一套渲染，否则同一段文字在两处字号、颜色不一致，
/// 看起来像两份不同的东西。
List<InlineSpan> buildInsightSpans(
  String text,
  TextStyle base,
  ColorScheme colorScheme,
) {
  final spans = <InlineSpan>[];
  final regex = RegExp(r'\[(\d+)\]');
  var last = 0;
  for (final match in regex.allMatches(text)) {
    if (match.start > last) {
      spans.add(TextSpan(text: text.substring(last, match.start)));
    }
    spans.add(
      TextSpan(
        text: ' [${match.group(1)}]',
        style: base.copyWith(
          fontSize: (base.fontSize ?? 15.5) - 3,
          color: colorScheme.primary.withValues(alpha: 0.75),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    last = match.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last)));
  }
  return spans;
}
