import 'package:flutter/material.dart';

/// DeepSeek 风格的胖鲸鱼图标。
///
/// 按官方 logo 的轮廓拟合成的矢量剪影：身体外轮廓 + 嘴部镂空 + 眼睛镂空，
/// 用 even-odd 填充规则挖空。好处是不必带着位图素材，深色/浅色、任意尺寸
/// 下都清晰；默认是透明底的蓝色鲸鱼，需要反白时传 [color]。
class DeepSeekWhale extends StatelessWidget {
  const DeepSeekWhale({
    required this.size,
    this.color = brandBlue,
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

  /// 轮廓原始坐标系：27 x 20，横向铺满、纵向居中。
  static const double _artWidth = 27;
  static const double _artHeight = 20;

  /// 身体外轮廓：从头顶起，顺时针绕过背鳍 / 尾鳍 / 腹部回到起点。
  static const List<double> _outline = <double>[
    6.8, 0.65, 10.8, 0.35, 13.5, 1.0, // 头顶弧
    14.2, 1.8, 14.8, 3.5, 16.1, 5.1, // 头右侧下行
    17.1, 6.4, 18.6, 7.1, 20.0, 7.35, // 收进尾根
    19.7, 6.2, 18.6, 4.3, 18.2, 2.7, // 尾根左侧上行
    18.05, 1.6, 18.35, 0.65, 19.2, 0.55, // 上尾梢
    20.2, 0.55, 21.3, 1.7, 21.9, 3.35, // 两尾梢之间的凹口
    23.0, 2.2, 25.0, 1.85, 26.3, 2.5, // 右侧尾梢
    26.5, 3.5, 25.7, 5.0, 23.4, 5.95, // 尾梢下沿
    22.7, 6.8, 22.5, 8.7, 22.0, 10.7, // 背脊右侧
    21.6, 12.3, 20.6, 13.9, 20.1, 15.5, // 尾根下行
    19.9, 16.6, 20.15, 17.35, 20.55, 17.85, // 右下角
    20.2, 18.3, 18.4, 18.6, 16.2, 18.62, // 腹部右段
    13.9, 18.9, 13.6, 19.6, 12.6, 19.75, // 腹部最低点
    11.6, 19.9, 9.4, 19.9, 8.4, 19.6,
    7.1, 19.3, 5.6, 18.6, 4.6, 17.8, // 腹部左段回收
    3.7, 17.0, 2.7, 15.8, 1.9, 14.4, // 左侧下段
    1.1, 13.0, 0.35, 11.3, 0.25, 9.4, // 最左端
    0.1, 7.6, 0.75, 5.3, 1.7, 3.7, // 左侧上段
    2.5, 2.5, 3.2, 1.85, 4.0, 1.5, // 回到头顶
  ];

  /// 嘴部镂空：从左上开口斜向下，底部被一枚小鳍切开。
  static const List<double> _mouth = <double>[
    3.2, 7.15, 4.2, 7.2, 4.75, 7.35,
    6.5, 7.75, 8.5, 8.7, 10.0, 9.9,
    11.8, 11.3, 13.2, 13.2, 13.9, 14.9,
    14.25, 15.8, 14.5, 16.3, 14.35, 16.55,
    13.4, 16.8, 12.3, 16.8, 11.6, 16.7, // 底部右段
    11.5, 15.8, 11.2, 14.8, 10.6, 14.4, // 小鳍右侧
    10.0, 14.05, 9.5, 14.6, 9.4, 15.5, // 小鳍顶部
    9.35, 16.1, 9.2, 16.5, 8.9, 16.7, // 小鳍左侧
    7.6, 16.75, 6.5, 16.35, 5.6, 15.6, // 底部左段
    4.5, 14.7, 3.6, 13.2, 3.0, 11.6, // 左下沿
    2.5, 10.2, 2.15, 8.7, 2.1, 7.3, // 左上闭合
  ];

  /// 眼睛镂空：细长的水滴形，上窄下宽。
  static const List<double> _eye = <double>[
    15.9, 7.6, 16.5, 8.5, 16.75, 9.6,
    17.0, 10.6, 16.95, 11.3, 16.6, 11.4,
    16.2, 11.5, 15.7, 11.0, 15.5, 10.2,
    15.35, 9.4, 15.25, 8.3, 15.35, 7.75,
  ];

  final Color color;

  static final Path _path = _buildPath();

  static Path _buildPath() {
    final path = Path()..fillType = PathFillType.evenOdd;
    _addSubpath(path, 4.0, 1.5, _outline);
    _addSubpath(path, 2.1, 7.3, _mouth);
    _addSubpath(path, 15.35, 7.75, _eye);
    return path;
  }

  /// [segments] 每 6 个数一段三次贝塞尔：控制点 1、控制点 2、终点。
  static void _addSubpath(
    Path path,
    double startX,
    double startY,
    List<double> segments,
  ) {
    path.moveTo(startX, startY);
    for (var i = 0; i + 5 < segments.length; i += 6) {
      path.cubicTo(
        segments[i],
        segments[i + 1],
        segments[i + 2],
        segments[i + 3],
        segments[i + 4],
        segments[i + 5],
      );
    }
    path.close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / _artWidth;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    canvas.save();
    canvas.translate(0, (size.height - _artHeight * scale) / 2);
    canvas.scale(scale, scale);
    canvas.drawPath(_path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WhalePainter oldDelegate) =>
      oldDelegate.color != color;
}
