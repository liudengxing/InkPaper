import 'package:flutter/widgets.dart';

/// 把下拉这段位移放大，缩短触发刷新所需的行程。
///
/// `RefreshIndicator` 的触发阈值按「视口高度的四分之一」算，在大屏手机上
/// 要拉出去一大段才等到转圈，随机回顾这种「整批换一屏」的动作就会拖沓。
/// 这里只放大**顶部越界时向下的那一截**：正常滚动的位移原样返回，
/// 上拉和惯性都不受影响。
class PullRefreshPhysics extends ClampingScrollPhysics {
  const PullRefreshPhysics({
    this.multiplier = 1.5,
    super.parent,
  });

  /// 1.5 表示同样用手指拉 100dp，指示器收到 150dp，行程缩到 2/3。
  final double multiplier;

  @override
  PullRefreshPhysics applyTo(ScrollPhysics? ancestor) => PullRefreshPhysics(
        multiplier: multiplier,
        parent: buildParent(ancestor),
      );

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (offset < 0 && position.pixels <= position.minScrollExtent) {
      return offset * multiplier;
    }
    return super.applyPhysicsToUserOffset(position, offset);
  }
}
