import 'package:intl/intl.dart';

/// flomo 风格的缩减时间格式，首页卡片与详情页共用。
///
/// `DateFormat` 的构造会解析 pattern 并查 locale，放在 build 里等于每张卡片
/// 每次重建都重新解析一遍，所以三个格式器都预构在顶层。
final DateFormat _noteYearFormat = DateFormat('yyyy-MM-dd HH:mm');
final DateFormat _noteMonthDayFormat = DateFormat('MM-dd HH:mm');
final DateFormat _noteTimeOnlyFormat = DateFormat('HH:mm');

/// 缩减时间：今天只留时间，今年省掉年份，往年显示完整日期与时间。
///
/// ⚠️ 这里**不能** `toLocal()`。Memos 服务端返回的 `createdAt` 形如
/// `2021-08-09T19:53:00Z`，但那个 19:53 本来就是发布者的本地挂钟时间
/// （部署时把北京时间当 UTC 存了），解析成 UTC 实例后「字段值」才是对的，
/// 再 toLocal 会平白多加 8 小时。本地新建与 flomo 导入的笔记是不带时区的
/// 本地 DateTime，两者的字段值都等于挂钟时间 —— 所以统一按字段值格式化，
/// 全库口径一致。
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
