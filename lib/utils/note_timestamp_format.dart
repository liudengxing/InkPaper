import 'package:intl/intl.dart';

/// flomo 风格的缩减时间格式，首页卡片与详情页共用。
///
/// `DateFormat` 的构造会解析 pattern 并查 locale，放在 build 里等于每张卡片
/// 每次重建都重新解析一遍，所以三个格式器都预构在顶层。
final DateFormat _noteYearFormat = DateFormat('yyyy-MM-dd');
final DateFormat _noteMonthDayFormat = DateFormat('MM-dd HH:mm');
final DateFormat _noteTimeOnlyFormat = DateFormat('HH:mm');

/// 缩减时间：今天只留时间，今年省掉年份，往年才显示完整日期。
String formatNoteTimestamp(DateTime ts) {
  final now = DateTime.now();
  if (ts.year != now.year) {
    return _noteYearFormat.format(ts);
  }
  if (ts.month == now.month && ts.day == now.day) {
    return _noteTimeOnlyFormat.format(ts);
  }
  return _noteMonthDayFormat.format(ts);
}
