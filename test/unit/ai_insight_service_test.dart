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

    test('每个视角都写全内核、步骤、输出骨架与质量红线', () {
      for (final lens in builtInInsightLenses) {
        for (final section in <String>[
          '这个视角的内核',
          '分析步骤',
          '输出（约',
          '质量红线',
        ]) {
          expect(
            lens.prompt,
            contains(section),
            reason: '${lens.id} 缺少「$section」',
          );
        }
      }
    });

    test('统一规则要求开头给判断、字数交给视角、禁掉空词与 Markdown', () {
      expect(AiInsightService.systemPrompt, contains('第一句就要是判断'));
      expect(AiInsightService.systemPrompt, contains('字数按视角要求'));
      expect(AiInsightService.systemPrompt, contains('第二人称「你」'));
      expect(AiInsightService.systemPrompt, contains('emoji'));
    });

    test('逆向思考演出来：先合成组合目标，再用人称扮演摧毁者，最后反转成原则', () {
      final lens = builtInInsightLenses.firstWhere(
        (lens) => lens.id == 'inversion',
      );
      expect(lens.prompt, contains('第一人称'));
      expect(lens.prompt, contains('抽走'));
      expect(lens.prompt, contains('现在说反转'));
      expect(lens.prompt, contains('不是「坚持」'));
      expect(lens.prompt, contains('与其问 A，不如问 B'));
      // 曾经是四个编号板块的 500 字骨架，现在必须是连续散文
      expect(lens.prompt, contains('不要列表'));
      expect(lens.prompt, isNot(contains('输出（约 500 字）')));
    });

    test('其余四个视角各自换掉了最弱的一环', () {
      InsightLens byId(String id) =>
          builtInInsightLenses.firstWhere((lens) => lens.id == id);

      // 价值澄清：排序证据必须来自取舍现场，不能从表态里推
      expect(byId('values').prompt, contains('取舍现场'));
      expect(byId('values').prompt, contains('最累的那天'));

      // 二阶思考：补上「问题在为他服务」和「解法的二阶后果」两条
      expect(byId('second_order').prompt, contains('在为他服务'));
      expect(byId('second_order').prompt, contains('二阶后果'));

      // CBT：选材从「情绪最浓」改成「重复出现」，并往核心信念推一层
      expect(byId('cbt').prompt, contains('看重复'));
      expect(byId('cbt').prompt, contains('核心信念'));
      expect(byId('cbt').prompt, contains('行为实验'));

      // MBTI：判定之外要写功能怎么运转、在哪耗电、判错会错在哪
      expect(byId('mbti').prompt, contains('耗电'));
      expect(byId('mbti').prompt, contains('如果判错'));
    });

    test('默认视角写成长文：交代时间跨度、三段主题带张力、结尾落小动作', () {
      final lens = builtInInsightLenses.first;
      expect(lens.id, 'default');
      expect(lens.prompt, contains('时间跨度'));
      expect(lens.prompt, contains('张力'));
      expect(lens.prompt, contains('拧一下'));
      expect(lens.prompt, contains('约 950 字'));
      expect(lens.prompt, contains('不要小标题'));
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

    test('用户消息交代了范围、条数和编号方向', () {
      final context = NotesContextBuilder.build([
        _note('1', '最新的想法', DateTime(2026, 11, 20)),
        _note('2', '更早的想法', DateTime(2026, 11, 10)),
      ]);

      final message = AiInsightService.buildUserMessage(
        context: context,
        scopeLabel: '最近 30 天',
      );

      expect(message, contains('最近 30 天'));
      expect(message, contains('纳入分析：2 条'));
      expect(message, contains('1 是最近一条'));
      expect(message, contains('最新的想法'));
      // 报告开篇要交代跨度，模型自己数日期不可靠，得直接告诉它
      expect(message, contains('时间跨度：2026-11-10 至 2026-11-20'));
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

    test('系统提示词强调第一条笔记权重最高', () {
      expect(AiInsightService.systemPrompt, contains('编号 1 的笔记权重最高'));
      expect(AiInsightService.systemPrompt, contains('[序号]'));
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
      expect(cbt.prompt, contains('认知行为疗法'));
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
