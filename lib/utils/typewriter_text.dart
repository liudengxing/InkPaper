import 'package:flutter/widgets.dart' show StringCharacters;

/// 只重排正在输入的一小段，已经完成的段落供列表按需渲染。
class TypewriterText {
  static const _blockLimit = 224;

  final _blocks = <String>[];
  String _tail = '';
  String _pending = '';

  bool get hasPending => _pending.isNotEmpty;
  bool get hasText => _blocks.isNotEmpty || _tail.isNotEmpty;
  int get blockCount => _blocks.length + 1;
  String blockAt(int index) => index < _blocks.length ? _blocks[index] : _tail;

  void append(String delta) => _pending += delta;

  bool advance({bool allowTail = false}) {
    if (_pending.isEmpty) {
      return false;
    }
    // 小批逐字出现。突发长块以有上限的速度追赶，避免一次跳出一段。
    final budget = (1 + _pending.length ~/ 32).clamp(1, 12);
    var consumed = 0;
    var count = 0;
    for (final glyph in _pending.characters) {
      if (count == budget) {
        break;
      }
      // 同一个可见字符可能被分到两个流块。保留队尾，等下一块补齐。
      if (consumed + glyph.length == _pending.length &&
          (!allowTail || _endsInHighSurrogate(glyph))) {
        break;
      }
      consumed += glyph.length;
      count++;
      _tail += glyph;
      if (glyph.endsWith('\n') || _tail.length >= _blockLimit) {
        _blocks.add(_tail);
        _tail = '';
      }
    }
    _pending = _pending.substring(consumed);
    return consumed != 0;
  }

  static bool _endsInHighSurrogate(String glyph) {
    final unit = glyph.codeUnitAt(glyph.length - 1);
    return unit >= 0xd800 && unit <= 0xdbff;
  }
}
