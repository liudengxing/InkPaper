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
    });

    test('系统提示词强调第一条笔记权重最高', () {
      expect(AiInsightService.systemPrompt, contains('编号 1 的笔记权重最高'));
      expect(AiInsightService.systemPrompt, contains('[序号]'));
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
