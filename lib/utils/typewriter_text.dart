/// 把已显示文本往目标文本推进一步。
///
/// 流式生成时模型是一小段一小段往回吐的，收到就整段贴上去，屏幕上会一块
/// 一块地跳；这里每次只放一点点，慢的时候逐字浮现，积压多了按比例加速，
/// 观感就是「一个字一个字打出来，模型快了打字也跟着快」。
///
/// [shown] 必须是 [target] 的前缀，否则视为换了一批内容，直接对齐。
String typewriteStep(String target, String shown) {
  if (shown == target) {
    return shown;
  }
  if (!target.startsWith(shown)) {
    return target;
  }
  final backlog = target.length - shown.length;
  // 积压 4 个字以内一帧一个字；再往上每多 4 个字多吐一个，这样模型全速
  // 输出时文字不会越落越远。
  final step = 1 + (backlog - 1) ~/ 4;
  var end = shown.length + step;
  if (end >= target.length) {
    return target;
  }
  // 落点正好卡在 emoji 的代理对中间（下一个单元是低代理）：连同它前面的
  // 高代理一起吐出去。这里不能往回退一格——退到高代理之前就等于这一帧
  // 原地不动，之后每一帧都会卡在同一个位置。
  final codeUnit = target.codeUnitAt(end);
  if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
    end += 1;
  }
  return target.substring(0, end);
}
