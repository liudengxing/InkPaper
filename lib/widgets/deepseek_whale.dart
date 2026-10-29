import 'package:flutter/material.dart';

/// DeepSeek 风格的胖鲸鱼图标。
///
/// 官方 logo 是矢量图形，这里用路径画一只圆润的鲸鱼剪影，好处是不用带着
/// 第三方品牌素材文件，深色/浅色、任意尺寸下都清晰。深蓝底由调用方给，
/// 图标本身是纯色剪影。
class DeepSeekWhale extends StatelessWidget {
  const DeepSeekWhale({
    required this.size,
    this.color = Colors.white,
    super.key,
  });

  /// DeepSeek 品牌蓝，气泡 / 入口按钮统一用它。
  static const Color brandBlue = Color(0xFF4D6BFE);
  static const Color brandBlueLight = Color(0xFF7C8CF8);

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WhalePainter(color),
      ),
    );
  }
}

class _WhalePainter extends CustomPainter {
  const _WhalePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    // 尾巴：左侧翘起的两个尖角
    final tail = Path()
      ..moveTo(0.21 * s, 0.54 * s)
      ..lineTo(0.03 * s, 0.38 * s)
      ..lineTo(0.10 * s, 0.54 * s)
      ..lineTo(0.03 * s, 0.70 * s)
      ..close();
    canvas.drawPath(tail, paint);

    // 背鳍
    final fin = Path()
      ..moveTo(0.44 * s, 0.32 * s)
      ..quadraticBezierTo(0.48 * s, 0.15 * s, 0.59 * s, 0.27 * s)
      ..close();
    canvas.drawPath(fin, paint);

    // 胖身体：背部略拱、腹部圆润，头在右
    final body = Path()
      ..moveTo(0.21 * s, 0.53 * s)
      ..cubicTo(
        0.24 * s, 0.31 * s, 0.45 * s, 0.24 * s, 0.63 * s, 0.29 * s,
      )
      ..cubicTo(
        0.84 * s, 0.34 * s, 0.92 * s, 0.47 * s, 0.86 * s, 0.59 * s,
      )
      ..cubicTo(
        0.79 * s, 0.75 * s, 0.50 * s, 0.81 * s, 0.33 * s, 0.71 * s,
      )
      ..cubicTo(
        0.25 * s, 0.67 * s, 0.21 * s, 0.62 * s, 0.21 * s, 0.53 * s,
      )
      ..close();
    canvas.drawPath(body, paint);
  }

  @override
  bool shouldRepaint(covariant _WhalePainter oldDelegate) =>
      oldDelegate.color != color;
}
