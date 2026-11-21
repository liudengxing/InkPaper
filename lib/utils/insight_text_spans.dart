import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// `[12]` 这类角标的点击回调容器。
///
/// `TextSpan.recognizer` 不会随 widget 树自动释放，必须手动 dispose；而这里
/// 的 span 每次重建都会重新生成，若每次都 new 一个 recognizer，重建一次就漏
/// 一个。所以按编号缓存复用——编号到笔记的映射在一次生成内是不变的。
class InsightRefRecognizers {
  final Map<int, TapGestureRecognizer> _byIndex = <int, TapGestureRecognizer>{};

  TapGestureRecognizer of(int index, ValueChanged<int> onTap) {
    return _byIndex.putIfAbsent(
      index,
      () => TapGestureRecognizer()..onTap = () => onTap(index),
    );
  }

  /// 换了一批笔记（重新生成）时调用：旧编号的含义已经变了。
  void clear() {
    for (final recognizer in _byIndex.values) {
      recognizer.dispose();
    }
    _byIndex.clear();
  }

  void dispose() => clear();
}

/// 把洞察正文里的 `[12]` 渲染成小一号的带色角标。
///
/// 结果页与历史回看共用同一套渲染，否则同一段文字在两处字号、颜色不一致，
/// 看起来像两份不同的东西。
///
/// 传了 [recognizers] 与 [onTapRef] 时角标可点：编号在他眼前，笔记却不在他
/// 手里，这是让「洞察有没有依据」可被当场检验的唯一入口。
List<InlineSpan> buildInsightSpans(
  String text,
  TextStyle base,
  ColorScheme colorScheme, {
  InsightRefRecognizers? recognizers,
  ValueChanged<int>? onTapRef,
}) {
  final spans = <InlineSpan>[];
  final regex = RegExp(r'\[(\d+)\]');
  final tappable = recognizers != null && onTapRef != null;
  var last = 0;
  for (final match in regex.allMatches(text)) {
    if (match.start > last) {
      spans.add(TextSpan(text: text.substring(last, match.start)));
    }
    final index = int.tryParse(match.group(1) ?? '') ?? 0;
    final style = base.copyWith(
      fontSize: (base.fontSize ?? 15.5) - 3.5,
      height: 1.2,
      color: colorScheme.primary.withValues(alpha: tappable ? 0.95 : 0.75),
      fontWeight: FontWeight.w600,
      // 极淡的底色顶替「圆形角标」：TextStyle 没法画圆角，但一层浅色底已经
      // 足够把编号从正文里摘出来，又不至于像纯文字那样被读成句子的一部分。
      background: tappable
          ? (Paint()..color = colorScheme.primary.withValues(alpha: 0.09))
          : null,
    );
    spans.add(
      TextSpan(
        text: ' [${match.group(1)}]',
        style: style,
        recognizer:
            tappable && index > 0 ? recognizers.of(index, onTapRef) : null,
      ),
    );
    last = match.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last)));
  }
  return spans;
}
