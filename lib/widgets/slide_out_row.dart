import 'package:flutter/material.dart';

/// 列表行「从右往左」退出。
///
/// 删除确认之后先播这个，再真正把行从数据里摘掉：直接摘会让下面整列往上
/// 硬跳一格，看上去就像卡了一下。三段动画走同一条控制器——
/// ① 整行向左滑出（位移满一屏宽）、② 同时淡出、③ 后段收起高度，
/// 高度收起让下面的行平滑补位。
///
/// [leaving] 由列表页控制：置 true 播退出，动效结束回调 [onExited]。
/// 若删除失败、行要留在列表里，把它改回 false 即可反向播回原位。
class SlideOutRow extends StatefulWidget {
  const SlideOutRow({
    required this.leaving,
    required this.onExited,
    required this.child,
    this.duration = const Duration(milliseconds: 260),
    super.key,
  });

  final bool leaving;
  final VoidCallback onExited;
  final Widget child;
  final Duration duration;

  @override
  State<SlideOutRow> createState() => _SlideOutRowState();
}

class _SlideOutRowState extends State<SlideOutRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  /// 位移用 easeInCubic：起步慢一点，让眼睛先看到「往左走」，
  /// 再加速离场；linear 会显得像被抽走。
  late final Animation<Offset> _offset = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-1, 0),
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInCubic));

  /// 淡出比位移早结束：滑到一半就基本看不见了，避免文字拖尾。
  late final Animation<double> _fade = Tween<double>(begin: 1, end: 0).animate(
    CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.72, curve: Curves.easeIn),
    ),
  );

  /// 高度后段才收：先滑出去，再让下面补位，两件事同时做会显得整页在抖。
  late final Animation<double> _size = Tween<double>(begin: 1, end: 0).animate(
    CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.3, 1, curve: Curves.easeInOutCubic),
    ),
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_onStatusChanged);
    if (widget.leaving) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(SlideOutRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.leaving && !oldWidget.leaving) {
      _controller.forward();
    } else if (!widget.leaving && oldWidget.leaving) {
      // 删除失败回滚：行滑回来，别留一条看不见的空行
      _controller.reverse();
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onExited();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatusChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      // 顶部对齐：行从下往上收，而不是整块居中塌陷
      alignment: const Alignment(-1, -1),
      sizeFactor: _size,
      child: SlideTransition(
        position: _offset,
        child: FadeTransition(opacity: _fade, child: widget.child),
      ),
    );
  }
}
