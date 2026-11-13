/// 把 Release 说明精简成适合弹窗展示的一小段 Markdown。
///
/// 发布说明在网页上要完整（下载入口、SHA-256 校验说明、AAB 去向），但弹窗只有
/// 400 宽、一屏高，那些区块纯属噪音 —— 表格在窄屏上还会挤成一条缝。所以这里按
/// 「只留这次改了什么」来裁：
///
/// 1. 砍掉 `### 下载` 及之后的区块（旧的发布说明会带表格与直链）
/// 2. 去掉孤立的分隔线（`---` / `***` / `___`）
/// 3. 连续空行压成一个
///
/// 裁剪放在 App 端而不是发布脚本，是为了让已经发出去的版本也自动变干净。
String compactReleaseNotes(String raw) {
  var text = raw.replaceAll('\r\n', '\n');
  if (text.trim().isEmpty) {
    return '';
  }

  for (final marker in const <String>['### 下载', '## 下载', '### Download']) {
    final index = text.indexOf(marker);
    if (index >= 0) {
      text = text.substring(0, index);
    }
  }

  final kept = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    final isRule = trimmed == '---' || trimmed == '***' || trimmed == '___';
    if (isRule) {
      continue;
    }
    if (trimmed.isEmpty && kept.isNotEmpty && kept.last.isEmpty) {
      continue;
    }
    kept.add(line.trimRight());
  }

  return kept.join('\n').trim();
}
