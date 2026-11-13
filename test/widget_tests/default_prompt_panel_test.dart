import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/ai_insight_engine.dart';
import 'package:inkpaper/services/ai_review_service.dart';
import 'package:inkpaper/services/periodic_review_service.dart';
import 'package:inkpaper/widgets/default_prompt_panel.dart';

/// 折叠面板与默认提示词的回归测试。
///
/// 重点不是「面板能展开」，而是**展示的文本必须就是服务层真正发出去的那一份**：
/// 一旦有人改了服务里的默认提示词却忘了同步设置页，或反过来，这里会先红。
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('DefaultPromptPanel — 默认提示词展示', () {
    const prompt = '你是测试用的默认提示词。\n第二行。';
    const replaced = '填了自定义提示词会替换上面整段。';

    testWidgets('DP-01 默认收起，只露出入口，不显示正文', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DefaultPromptPanel(prompt: prompt, replacedBy: replaced),
        ),
      );

      expect(find.text('查看系统默认提示词'), findsOneWidget);
      expect(find.text(prompt), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('DP-02 点开后正文与说明一起露出，再点收起', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DefaultPromptPanel(prompt: prompt, replacedBy: replaced),
        ),
      );

      await tester.tap(find.text('查看系统默认提示词'));
      await tester.pumpAndSettle();

      expect(find.text(prompt), findsOneWidget);
      expect(find.text(replaced), findsOneWidget);

      await tester.tap(find.text('查看系统默认提示词'));
      await tester.pumpAndSettle();
      expect(find.text(prompt), findsNothing);
    });

    testWidgets('DP-03 有补充说明时才显示那一行', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DefaultPromptPanel(
            prompt: prompt,
            replacedBy: replaced,
            note: '括号里是占位符。',
          ),
        ),
      );

      await tester.tap(find.text('查看系统默认提示词'));
      await tester.pumpAndSettle();

      expect(find.text('括号里是占位符。'), findsOneWidget);
    });
  });

  group('默认提示词常量 — 与实现同源', () {
    test('DP-04 点评默认提示词有角色、有硬性要求、有输出结构', () {
      const p = AiReviewService.defaultSystemPrompt;
      expect(p, contains('笔记点评顾问'));
      expect(p, contains('硬性要求'));
      expect(p, contains('输出结构'));
      // 自定义提示词后固定追加的格式要求，也必须能在设置页展示出来
      expect(AiReviewService.customPromptHardRequirements, isNotEmpty);
      expect(p.trim(), isNotEmpty);
    });

    test('DP-05 续写默认提示词包含实际发送时的分段标题与任务正文', () {
      const p = AIInsightEngine.defaultContinuationPrompt;
      expect(p, contains('角色：学习伙伴（不是分析工具）'));
      expect(p, contains('【笔记内容】'));
      expect(p, contains('【任务】'));
      expect(p, contains('在原文后面续写 80-160 字'));
      // 占位符要说清楚是占位，别让人以为是固定文案
      expect(p, contains('（当前笔记正文）'));
    });

    test('DP-06 周回顾与月回顾只差时间跨度这一处', () {
      final week = PeriodicReviewService.defaultSystemPrompt(
        ReviewPeriod.week,
      );
      final month = PeriodicReviewService.defaultSystemPrompt(
        ReviewPeriod.month,
      );

      expect(week, contains('最近7 天里'));
      expect(month, contains('最近30 天里'));
      expect(week, isNot(equals(month)));
      // 把差异点换掉之后两份应该完全一致，避免两边各写一套文案
      expect(week.replaceAll('7 天', '30 天'), equals(month));
      expect(PeriodicReviewService.customPromptHardRequirements, isNotEmpty);
    });
  });
}
