import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/models/insight_lens.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/ai_insight_service.dart';
import 'package:inkpaper/utils/notes_context_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';

Note _note(String id, String content, DateTime time) => Note(
      id: id,
      content: content,
      createdAt: time,
      updatedAt: time,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内置视角', () {
    test('六个视角齐全且 id 不重复', () {
      expect(builtInInsightLenses, hasLength(6));
      final ids = builtInInsightLenses.map((lens) => lens.id).toSet();
      expect(ids, hasLength(6));
      expect(
        ids,
        containsAll(<String>[
          'default',
          'values',
          'inversion',
          'second_order',
          'cbt',
          'mbti',
        ]),
      );
    });

    test('每个视角都有可用的名称、描述和足够长的提示词', () {
      for (final lens in builtInInsightLenses) {
        expect(lens.name.trim(), isNotEmpty, reason: lens.id);
        expect(lens.description.trim(), isNotEmpty, reason: lens.id);
        expect(
          lens.prompt.trim().length,
          greaterThan(80),
          reason: '${lens.id} 的提示词太短，反推不完整',
        );
        expect(lens.builtIn, isTrue, reason: lens.id);
      }
    });

    test('V4.1 版每个视角都写全分析步骤、质量要求与最终报告格式', () {
      for (final lens in builtInInsightLenses) {
        // MBTI 在步骤前多了一节「参考框架」，其余视角都是「一、分析步骤」。
        final steps = lens.id == 'mbti' ? '三、分析步骤' : '一、分析步骤';
        final quality = lens.id == 'mbti' ? '四、质量要求' : '二、质量要求';
        final format = lens.id == 'mbti' ? '五、最终报告格式' : '三、最终报告格式';
        for (final section in <String>[
          '当前分析视角：',
          steps,
          quality,
          format,
          '标题：一句 12 至 22 个字的核心判断',
        ]) {
          expect(
            lens.prompt,
            contains(section),
            reason: '${lens.id} 缺少「$section」',
          );
        }
      }
    });

    test('MBTI 与 CBT 的界面名跟提示词自称一致', () {
      final cbt = builtInInsightLenses.firstWhere((lens) => lens.id == 'cbt');
      final mbti = builtInInsightLenses.firstWhere((lens) => lens.id == 'mbti');
      expect(cbt.name, 'CBT 自我观察');
      expect(cbt.prompt, contains('当前分析视角：CBT 自我观察'));
      expect(mbti.name, 'MBTI 探索');
      expect(mbti.prompt, contains('当前分析视角：MBTI 探索'));
    });

    test('通用规则强调准确高于深刻、证据优先、两段输出外壳', () {
      const prompt = AiInsightService.systemPrompt;
      expect(prompt, contains('准确性高于深刻性'));
      expect(prompt, contains('证据高于表达效果'));
      expect(prompt, contains('区分事实、推断和未知'));
      expect(prompt, contains('不要从用户没有提及某件事，推断这件事从未发生'));
      expect(prompt, contains('【分析摘要】'));
      expect(prompt, contains('【最终报告】'));
      expect(prompt, contains('不展示逐步思考过程'));
      expect(prompt, contains('默认使用第二人称“你”'));
      expect(prompt, contains('不刻意制造金句'));
    });

    test('逆向思考改为反向压力测试，明确假设不等于预测', () {
      final lens = builtInInsightLenses.firstWhere(
        (lens) => lens.id == 'inversion',
      );
      expect(lens.prompt, contains('反向压力测试者'));
      expect(lens.prompt, contains('找支撑条件'));
      expect(lens.prompt, contains('这些是压力测试情境，不是对未来的预测'));
      expect(lens.prompt, contains('现在说反转。'));
      expect(lens.prompt, contains('2 至 3 条最有证据的失败路径'));
      // 旧版「扮演摧毁者」的四板块骨架已替换
      expect(lens.prompt, isNot(contains('角色：你用芒格的逆向思维')));
    });

    test('其余视角各自保留了最关键的方法论约束', () {
      InsightLens byId(String id) =>
          builtInInsightLenses.firstWhere((lens) => lens.id == id);

      expect(byId('values').prompt, contains('没有真实取舍现场，就不能给价值排先后'));
      expect(byId('values').prompt, contains('目标，不自动等于'));

      expect(byId('second_order').prompt, contains('隐含前提'));
      expect(byId('second_order').prompt, contains('二阶后果'));

      expect(byId('cbt').prompt, contains('反复出现的想法'));
      expect(byId('cbt').prompt, contains('反向证据'));
      expect(byId('cbt').prompt, contains('不是心理治疗或诊断'));

      expect(byId('mbti').prompt, contains('探索性假设'));
      expect(byId('mbti').prompt, contains('不能声称已经测出用户真实的 MBTI 类型'));
    });

    test('默认视角以行为模式、张力和边界为核心，写成长文', () {
      final lens = builtInInsightLenses.first;
      expect(lens.id, 'default');
      expect(lens.prompt, contains('触发条件 → 用户采取的行动 → 实际结果或代价'));
      expect(lens.prompt, contains('找张力'));
      expect(lens.prompt, contains('拧一下'));
      expect(lens.prompt, contains('正文约 900 至 1000 字'));
      expect(lens.prompt, contains('不加正文小标题'));
    });

    test('每个内置视角都有对应的输出长度', () {
      for (final lens in builtInInsightLenses) {
        expect(
          AiInsightService.outputLengthFor(lens),
          isNotEmpty,
          reason: '${lens.id} 缺少输出长度',
        );
      }
      expect(
        AiInsightService.outputLengthFor(
          const InsightLens(
            id: 'custom',
            name: '自定义',
            description: '',
            prompt: '',
            icon: InsightLensIcon.custom,
          ),
        ),
        isEmpty,
      );
    });

    test('图标 key 可以往返，未知 key 落到 custom', () {
      expect(InsightLensIcon.fromKey('values'), InsightLensIcon.clarify);
      expect(InsightLensIcon.fromKey('什么也不是'), InsightLensIcon.custom);
      expect(InsightLensIcon.fromKey(null), InsightLensIcon.custom);
    });
  });

  group('InsightLens 序列化', () {
    test('自定义视角可以 JSON 往返', () {
      const lens = InsightLens(
        id: 'custom_1',
        name: '教练视角',
        description: '像教练一样追问',
        prompt: '请你像教练一样，指出我反复回避的问题，并给一个下周可执行的动作。',
        icon: InsightLensIcon.custom,
        author: '我',
      );

      final restored = InsightLens.fromJson(lens.toJson());

      expect(restored.id, lens.id);
      expect(restored.name, lens.name);
      expect(restored.prompt, lens.prompt);
      expect(restored.icon, InsightLensIcon.custom);
      expect(restored.builtIn, isFalse);
    });
  });

  group('AiInsightService', () {
    test('AI 未开启时直接报配置错误，不发起请求', () async {
      final result = await const AiInsightService().generate(
        config: AppConfig(),
        lens: builtInInsightLenses.first,
        notes: [_note('1', '今天写了一篇笔记', DateTime(2026, 11, 20))],
      );

      expect(result.isError, isTrue);
      expect(result.error, contains('AI 功能还没开启'));
      expect(result.text, isEmpty);
    });

    test('缺少密钥时报错', () async {
      final config = AppConfig(
        aiEnabled: true,
        aiApiUrl: 'https://api.example.com/v1',
      );
      final result = await const AiInsightService().generate(
        config: config,
        lens: builtInInsightLenses.first,
        notes: [_note('1', '有内容', DateTime(2026, 11, 20))],
      );

      expect(result.isError, isTrue);
      expect(result.error, contains('密钥'));
    });

    test('没有可分析的文字笔记时报错', () async {
      final config = AppConfig(
        aiEnabled: true,
        aiApiUrl: 'https://api.example.com/v1',
        aiApiKey: 'sk-test',
      );
      final result = await const AiInsightService().generate(
        config: config,
        lens: builtInInsightLenses.first,
        notes: [_note('1', '![图](a.png)', DateTime(2026, 11, 20))],
      );

      expect(result.isError, isTrue);
      expect(result.error, contains('没有可用的文字笔记'));
    });

    test('用户消息交代了视角、范围、条数、编号方向与两段式结构', () {
      final context = NotesContextBuilder.build([
        _note('1', '最新的想法，记一笔当下的感受。', DateTime(2026, 11, 20)),
        _note('2', '更早的想法，记一笔当时的感受。', DateTime(2026, 11, 10)),
      ]);

      final message = AiInsightService.buildUserMessage(
        context: context,
        scopeLabel: '最近 30 天',
        lens: builtInInsightLenses.first,
      );

      expect(message, contains('【本次任务信息】'));
      expect(message, contains('【笔记正文】'));
      expect(message, contains('【笔记结束】'));
      expect(message, contains('分析视角：深度挖掘'));
      expect(message, contains('视角 ID：default'));
      expect(message, contains('分析范围：最近 30 天'));
      expect(message, contains('本次纳入笔记：2 条'));
      expect(message, contains('编号 1 为最新'));
      expect(message, contains('选取方式：全量纳入'));
      expect(message, contains('分析摘要：输出'));
      expect(message, contains('输出长度：约 950 字'));
      expect(message, contains('最新的想法'));
      // 报告开篇要交代跨度，模型自己数日期不可靠，得直接告诉它
      expect(message, contains('本次笔记时间范围：2026-11-10 至 2026-11-20'));
    });

    test('抽样时如实写明口径，不让模型以为读到了全库', () {
      final notes = [
        for (var i = 0; i < 120; i++)
          _note(
            'n$i',
            '第 $i 条想法，写下当时的一点感受和判断。',
            DateTime(2024).add(Duration(days: i)),
          ),
      ];
      final context = NotesContextBuilder.buildForInsight(notes);
      final message = AiInsightService.buildUserMessage(
        context: context,
        scopeLabel: '全部笔记',
        lens: builtInInsightLenses.first,
      );
      expect(message, contains('按年-季度分桶抽样'));
      expect(message, contains('实际纳入 ${context.noteCount} 条'));
    });

    test('内容限制如实写明截断与媒体未发送', () {
      final context = NotesContextBuilder.build([
        _note('1', '${'很' * 500}，这是一条超长的笔记。', DateTime(2026, 11, 20)),
        Note(
          id: '2',
          content: '带图片的一条记录，写点文字说明一下。![](images/a.png)',
          createdAt: DateTime(2026, 11, 10),
          updatedAt: DateTime(2026, 11, 10),
        ),
      ]);
      final message = AiInsightService.buildUserMessage(
        context: context,
        scopeLabel: '全部笔记',
        lens: builtInInsightLenses.first,
      );
      expect(message, contains('部分笔记正文已截断'));
      expect(message, contains('图片/附件未发送给模型'));
    });

    test('分析摘要开关与补充要求进入任务信息', () {
      final context = NotesContextBuilder.build([
        _note('1', '最新的一条想法，写够十几个字。', DateTime(2026, 11, 20)),
      ]);
      final message = AiInsightService.buildUserMessage(
        context: context,
        scopeLabel: '全部笔记',
        lens: builtInInsightLenses.first,
        analysisSummary: false,
        extraRequirement: '多用原文',
      );
      expect(message, contains('分析摘要：不输出'));
      expect(message, contains('补充要求：多用原文'));
    });

    test('时间跨度按月算，不足一个月单独说明', () {
      expect(
        AiInsightService.describeSpan(
          DateTime(2021, 3, 24),
          DateTime(2026, 1, 12),
        ),
        contains('跨 4 年 9 个月'),
      );
      expect(
        AiInsightService.describeSpan(
          DateTime(2026, 11),
          DateTime(2026, 11, 20),
        ),
        contains('不足一个月'),
      );
      expect(AiInsightService.describeSpan(null, null), isEmpty);
    });

    test('系统提示词强调编号可信、事实与推断分开', () {
      expect(AiInsightService.systemPrompt, contains('编号 1 是本次纳入笔记中最新的一条'));
      expect(AiInsightService.systemPrompt, contains('[序号]'));
      expect(AiInsightService.systemPrompt, contains('不要把推断写成事实'));
    });

    test('两段式输出能拆开，标记不留在正文里', () {
      final parsed = AiInsightService.splitAnalysisSections(
        '【分析摘要】\n- 一条发现 [1]\n- 另一条发现 [2]\n\n【最终报告】\n标题：拿住是一种资格\n正文第一段。',
      );
      expect(parsed.summary, contains('一条发现 [1]'));
      expect(parsed.summary, isNot(contains('【分析摘要】')));
      expect(parsed.report, contains('标题：拿住是一种资格'));
      expect(parsed.report, isNot(contains('【最终报告】')));
    });

    test('模型漏写标记时整段当报告，摘要留空', () {
      final parsed =
          AiInsightService.splitAnalysisSections('标题：直接给了正文\n下面就是报告。');
      expect(parsed.summary, isEmpty);
      expect(parsed.report, contains('标题：直接给了正文'));
    });

    test('只有摘要标记时，标记后的内容仍当报告', () {
      final parsed = AiInsightService.splitAnalysisSections('【分析摘要】\n报告正文在这里。');
      expect(parsed.summary, isEmpty);
      expect(parsed.report, '报告正文在这里。');
    });

    test('两段式输出下标题仍从报告首行剥出', () {
      final sections = AiInsightService.splitAnalysisSections(
        '【分析摘要】\n- 发现 [1]\n\n【最终报告】\n标题：拿住是一种资格\n\n这批笔记从 2021 年开始……',
      );
      final split = AiInsightService.splitTitle(sections.report);
      expect(split.title, '拿住是一种资格');
      expect(split.body, '这批笔记从 2021 年开始……');
    });

    test('标题只在有显式前缀时才认，正文一句不动', () {
      final parsed = AiInsightService.splitTitle(
        '标题：拿住是一种资格\n\n这批笔记从 2021 年开始……',
      );
      expect(parsed.title, '拿住是一种资格');
      expect(parsed.body, '这批笔记从 2021 年开始……');
    });

    test('没有标题行时整段都算正文，不能吞掉第一句判断', () {
      const raw = '你其实一直在用防守换安全。\n\n第二段。';
      final parsed = AiInsightService.splitTitle(raw);
      expect(parsed.title, isEmpty);
      expect(parsed.body, raw);
    });

    test('标题过长、或只有标题没有正文时退回无标题', () {
      final tooLong = AiInsightService.splitTitle('标题：${'很' * 50}\n正文');
      expect(tooLong.title, isEmpty);
      final onlyTitle = AiInsightService.splitTitle('标题：只有标题');
      expect(onlyTitle.title, isEmpty);
      expect(onlyTitle.body, '标题：只有标题');
    });

    test('标题上的引号、书名号、句号会剥掉', () {
      final parsed = AiInsightService.splitTitle('标题：「拿住是一种资格。」\n正文');
      expect(parsed.title, '拿住是一种资格');
    });

    test('编号与来源笔记一一对应，跨时间抽样后也不串号', () {
      final notes = [
        for (var i = 0; i < 40; i++)
          _note(
            'n$i',
            '第 $i 条内容，长度要够进上下文。',
            DateTime(2026).subtract(Duration(days: i * 37)),
          ),
      ];
      final context = NotesContextBuilder.buildForInsight(notes);
      expect(context.sources.length, context.noteCount);
      expect(
        [for (final source in context.sources) source.index],
        [for (var i = 1; i <= context.noteCount; i++) i],
      );
      // 编号 1 必须是最新那条，否则正文里的 [1] 会指到旧笔记
      expect(context.sources.first.noteId, 'n0');
    });

    test('清理输出时保留分段与短横线，只去掉代码围栏和标题', () {
      final cleaned = AiInsightService.cleanOutput(
        '## 核心矛盾\n\n- 第一条[1]\n- 第二条[2]\n\n```\ncode\n```\n',
      );

      expect(cleaned, isNot(contains('##')));
      expect(cleaned, isNot(contains('```')));
      expect(cleaned, contains('- 第一条[1]'));
      expect(cleaned, contains('核心矛盾'));
    });
  });

  group('InsightLensStore', () {
    test('默认只有六个内置视角', () async {
      SharedPreferences.setMockInitialValues({});
      final lenses = await const InsightLensStore().load();

      expect(lenses, hasLength(6));
      expect(lenses.every((lens) => lens.builtIn), isTrue);
      expect(lenses.any((lens) => lens.edited), isFalse);
    });

    test('改动内置提示词后标记为已改，传空可以恢复默认', () async {
      SharedPreferences.setMockInitialValues({});
      const store = InsightLensStore();

      await store.saveBuiltInPrompt('cbt', '这是我改过的提示词，用来做认知自查。');
      var lenses = await store.load();
      var cbt = lenses.firstWhere((lens) => lens.id == 'cbt');
      expect(cbt.edited, isTrue);
      expect(cbt.prompt, contains('我改过'));

      await store.saveBuiltInPrompt('cbt', '');
      lenses = await store.load();
      cbt = lenses.firstWhere((lens) => lens.id == 'cbt');
      expect(cbt.edited, isFalse);
      expect(cbt.prompt, contains('当前分析视角：CBT 自我观察'));
    });

    test('自定义视角可以新增、修改、删除', () async {
      SharedPreferences.setMockInitialValues({});
      const store = InsightLensStore();

      final created = await store.addCustom(
        name: '教练视角',
        description: '像教练一样追问',
        prompt: '请你像教练一样，指出我反复回避的问题，并给一个下周可执行的动作。',
      );
      var lenses = await store.load();
      expect(lenses, hasLength(7));
      expect(lenses.last.builtIn, isFalse);

      await store.updateCustom(created.copyWith(name: '教练视角 2'));
      lenses = await store.load();
      expect(
        lenses.firstWhere((lens) => lens.id == created.id).name,
        '教练视角 2',
      );

      await store.deleteCustom(created.id);
      lenses = await store.load();
      expect(lenses, hasLength(6));
    });

    test('本地数据损坏时退回内置视角，不抛异常', () async {
      SharedPreferences.setMockInitialValues({
        InsightLensStore.customKey: '不是 json',
        InsightLensStore.overridesKey: '也不是 json',
      });

      final lenses = await const InsightLensStore().load();

      expect(lenses, hasLength(6));
    });
  });
}
