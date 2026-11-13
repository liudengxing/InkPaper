// ============================================================
// 单元测试 · Release 说明精简
// 弹窗只有 400 宽、一屏高，网页版说明里的下载表格与直链属于噪音
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/release_notes_formatter.dart';

void main() {
  group('compactReleaseNotes', () {
    test('RNF-01 空说明返回空串', () {
      expect(compactReleaseNotes(''), '');
      expect(compactReleaseNotes('   \n\n  '), '');
    });

    test('RNF-02 保留正文与原样 Markdown 标记', () {
      const raw = '### 修复\n\n- 下载完不弹安装\n- 空白处双击不出工具栏';

      expect(
        compactReleaseNotes(raw),
        '### 修复\n\n- 下载完不弹安装\n- 空白处双击不出工具栏',
      );
    });

    test('RNF-03 砍掉末尾的「### 下载」区块', () {
      const raw = '### 修复\n\n- 改了下载退路\n\n---\n\n'
          '### 下载\n\n| 源 | 地址 |\n'
          '| --- | --- |\n'
          '| 国内 | [Gitee 发行版 v1.1.84](https://gitee.com/x) |\n';

      final compact = compactReleaseNotes(raw);

      expect(compact, '### 修复\n\n- 改了下载退路');
      expect(compact.contains('Gitee 发行版'), isFalse);
      expect(compact.contains('|'), isFalse);
    });

    test('RNF-04 也认「## 下载」与英文标题', () {
      expect(
        compactReleaseNotes('### Fixed\n\n- x\n\n## 下载\n\n链接'),
        '### Fixed\n\n- x',
      );
      expect(
        compactReleaseNotes('### Fixed\n\n- x\n\n### Download\n\nlink'),
        '### Fixed\n\n- x',
      );
    });

    test('RNF-05 去掉孤立分隔线，保留正文里的破折号开头', () {
      const raw = '第一段\n\n---\n\n第二段\n\n***\n\n___\n';

      final compact = compactReleaseNotes(raw);

      expect(compact, '第一段\n\n第二段');
      // 「- 列表项」不是分隔线，不能被吃掉
      expect(compactReleaseNotes('- 项目一\n- 项目二'), '- 项目一\n- 项目二');
    });

    test('RNF-06 连续空行压成一个、CRLF 归一', () {
      const raw = '第一段\r\n\r\n\r\n\r\n第二段\r\n';

      expect(compactReleaseNotes(raw), '第一段\n\n第二段');
    });

    test('RNF-07 说明一开始就是下载区块时整段清空', () {
      // index == 0 的情况：没有正文可留，返回空串让弹窗不渲染空盒子
      expect(compactReleaseNotes('### 下载\n\n| 源 | 地址 |'), '');
    });
  });
}
