import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/widgets/note_editor.dart';

void main() {
  group('gridSwapSteps 网格让位', () {
    // 3 列网格，index 0-2 第一行、3-5 第二行、6-8 第三行
    const columns = 3;

    Offset? steps(int index, int from, int to) => gridSwapSteps(
          index: index,
          from: from,
          to: to,
          columns: columns,
        );

    test('同一行往后拖，中间的格子依次左移一格', () {
      // 0 → 2：1 和 2 各退一格
      expect(steps(1, 0, 2), const Offset(-1, 0));
      expect(steps(2, 0, 2), const Offset(-1, 0));
      // 起拖的那格自己不动，区间外也不动
      expect(steps(0, 0, 2), isNull);
      expect(steps(3, 0, 2), isNull);
    });

    test('同一行往前拖，被越过的格子依次右移一格', () {
      // 2 → 0：0 和 1 各进一格
      expect(steps(0, 2, 0), const Offset(1, 0));
      expect(steps(1, 2, 0), const Offset(1, 0));
      expect(steps(2, 2, 0), isNull);
      expect(steps(3, 2, 0), isNull);
    });

    test('跨行拖动时斜着挪，不会只横移', () {
      // 5 → 1：区间 [1,5) 即 1,2,3,4 各进一格
      expect(steps(1, 5, 1), const Offset(1, 0));
      // 2 是第 0 行第 2 列 → 目标 3 是第 1 行第 0 列，横移 -2、下移 1
      expect(steps(2, 5, 1), const Offset(-2, 1));
      expect(steps(3, 5, 1), const Offset(1, 0));
      expect(steps(4, 5, 1), const Offset(1, 0));
      expect(steps(5, 5, 1), isNull);
    });

    test('跨行往前拖同样按行优先展开计算', () {
      // 1 → 7：区间 (1,7] 即 2..7 各退一格
      expect(steps(2, 1, 7), const Offset(-1, 0));
      // 3 是第 1 行第 0 列 → 目标 2 是第 0 行第 2 列，横移 2、上移 -1
      expect(steps(3, 1, 7), const Offset(2, -1));
      expect(steps(6, 1, 7), const Offset(2, -1));
      expect(steps(7, 1, 7), const Offset(-1, 0));
      expect(steps(8, 1, 7), isNull);
    });

    test('原地或自身不产生位移', () {
      expect(steps(1, 1, 1), isNull);
      expect(steps(0, 0, 0), isNull);
    });

    test('列数非法时安全返回', () {
      expect(
        gridSwapSteps(index: 1, from: 0, to: 2, columns: 0),
        isNull,
      );
    });
  });
}
