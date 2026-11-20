import 'dart:convert';

import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/models/insight_lens.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/deepseek_api_service.dart';
import 'package:inkpaper/utils/notes_context_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一次洞察的结果。
class AiInsightResult {
  const AiInsightResult({
    required this.text,
    required this.noteCount,
    this.totalCandidates = 0,
    this.truncated = false,
    this.error,
  });

  factory AiInsightResult.error(String message) => AiInsightResult(
        text: '',
        noteCount: 0,
        error: message,
      );

  final String text;
  final int noteCount;
  final int totalCandidates;
  final bool truncated;
  final String? error;

  bool get isError => error != null;
}

/// AI 洞察：拿一批笔记 + 一个视角，产出针对「这个人」的分析。
///
/// 和「问笔记」的区别是它不回答问题，而是主动给判断；和单条笔记的 AI 点评
/// 的区别是它看的是跨时间的一整批记录。实现上完全复用现有的 AI 配置
/// （[AppConfig] 的地址/密钥/模型）和 [NotesContextBuilder] 的上下文拼装，
/// 不引入新的网络依赖。
class AiInsightService {
  const AiInsightService();

  /// 洞察要铺开讲，比点评需要更多输出空间。
  static const int maxOutputTokens = 2200;

  /// 所有视角共用的规则。
  ///
  /// 「编号 1 权重最高」不是随手写的：少楠在访谈里明确说过官方提示词里专门
  /// 强调「第一条笔记最重要」，理由是用户主动点开查看的那条，往往就是他
  /// 心里最重要的那条。我们按时间倒序喂笔记，编号 1 即最新一条。
  ///
  /// 字数压到 500 左右是有意的：这个产品要的是「一句话被击中」，不是一篇
  /// 长报告。写满 900 字必然掺水，宁可少说一个点。
  static const String systemPrompt = '''
你是 InkPaper 的洞察助手。用户会把一批自己写的笔记按时间倒序交给你，编号从 1 开始，并指定一个分析视角。

通用规则：
1. 只依据给出的笔记，不补充笔记之外的事实，不编造日期、人物、事件。
2. 每个判断后面用 [序号] 标注依据，序号必须是上面真实存在的编号；找不到依据的判断就不要写。
3. 不复述原文，不写「这篇笔记讲了」，直接给结论。第一句就要是判断，不要铺垫，不要用「我读完了」「从这些笔记中可以看到」「这是一段很真诚的记录」开头。
4. 不做医学或心理诊断，不说「你有某种人格障碍」，不替用户下人生结论。
5. 中文，纯文本。用「一、二、三」分段，段内用短句，不要 Markdown 标题、代码块、表格。
6. 允许尖锐，但不要攻击；不要用「亲爱的」「加油」「相信自己」这类安慰话术。
7. 全文 480-560 字，按视角给出的段落分配写，不要额外加成总结段。
8. 证据只有一条就说只有一条；笔记里确实看不出就明说看不出，不要为了凑满结构硬编。
9. 编号 1 的笔记权重最高：它是用户最近主动记录的，做判断时优先从它出发。''';

  /// 生成一次洞察。
  ///
  /// [scopeLabel] 只用于告诉模型「这批笔记的范围是什么」，例如「全部笔记」
  /// 或「最近 30 天」，会影响它说话的口径。
  Future<AiInsightResult> generate({
    required AppConfig config,
    required InsightLens lens,
    required List<Note> notes,
    String scopeLabel = '全部笔记',
  }) async {
    final configError = _validateConfig(config);
    if (configError != null) {
      return AiInsightResult.error(configError);
    }

    final context = NotesContextBuilder.build(notes);
    if (context.noteCount == 0) {
      return AiInsightResult.error('当前范围内没有可用的文字笔记（图片和音视频不会发给 AI）。');
    }

    final service = DeepSeekApiService(
      apiUrl: config.aiApiUrl!.trim(),
      apiKey: config.aiApiKey!.trim(),
      model: config.aiModel,
    );

    final (content, error) = await service.chat(
      messages: [
        DeepSeekApiService.buildSystemMessage(
          '$systemPrompt\n\n${lens.prompt.trim()}',
        ),
        DeepSeekApiService.buildUserMessage(
          buildUserMessage(context: context, scopeLabel: scopeLabel),
        ),
      ],
      // 洞察需要一点发散，但不能飘；0.6 是「有判断又不太随机」的折中。
      temperature: 0.6,
      maxTokens: maxOutputTokens,
    );

    if (content == null || content.trim().isEmpty) {
      return AiInsightResult.error(error ?? 'AI 没有返回内容，请稍后重试');
    }

    return AiInsightResult(
      text: cleanOutput(content),
      noteCount: context.noteCount,
      totalCandidates: context.totalCandidates,
      truncated: context.truncated,
    );
  }

  String? _validateConfig(AppConfig config) {
    if (!config.aiEnabled) {
      return 'AI 功能还没开启：请到「设置 → AI 设置」打开开关并填写 API 地址和密钥。';
    }
    if (config.aiApiUrl?.trim().isEmpty ?? true) {
      return '还没有配置 AI 接口地址，请到「设置 → AI 设置」填写。';
    }
    if (config.aiApiKey?.trim().isEmpty ?? true) {
      return '还没有配置 AI 密钥，请到「设置 → AI 设置」填写。';
    }
    return null;
  }

  /// 拼用户消息。公开出来是为了让测试能直接断言「编号与范围都交代清楚了」。
  static String buildUserMessage({
    required NotesContext context,
    required String scopeLabel,
  }) {
    final coverage = context.truncated
        ? '，共 ${context.totalCandidates} 条有文字内容的笔记，更早的未附上'
        : '';
    return '''
洞察范围：$scopeLabel
纳入分析：${context.noteCount} 条$coverage
编号说明：1 是最近一条，编号越大时间越早。

笔记如下：
${context.text}
''';
  }

  /// 清掉 Markdown 痕迹，但保留分段。
  ///
  /// 洞察是长文，不能像短点评那样把编号和短横线全删掉——那样会糊成一坨。
  static String cleanOutput(String text) {
    var cleaned = text;
    cleaned = cleaned.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    cleaned = cleaned.replaceAll(RegExp(r'^#+\s*', multiLine: true), '');
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'\*\*(.*?)\*\*'),
      (match) => match.group(1) ?? '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'^>\s*', multiLine: true), '');
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return cleaned.trim();
  }
}

/// 视角的读取与保存。
///
/// 内置六个视角写死在代码里，但提示词允许改：改动量和自定义视角都存
/// SharedPreferences，不碰数据库——视角是配置，不是用户数据，没必要时时同步。
class InsightLensStore {
  const InsightLensStore();

  static const String overridesKey = 'ai_insight_lens_overrides';
  static const String customKey = 'ai_insight_custom_lenses';

  /// 内置视角 + 用户自定义视角，内置的提示词已套用改动。
  Future<List<InsightLens>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final overrides = _readOverrides(prefs);
    final builtIns = builtInInsightLenses.map((lens) {
      final override = overrides[lens.id];
      if (override == null || override.trim().isEmpty) {
        return lens;
      }
      return lens.copyWith(prompt: override, edited: true);
    }).toList();
    return [...builtIns, ..._readCustom(prefs)];
  }

  /// 改动内置视角的提示词。传空字符串等于恢复默认。
  Future<void> saveBuiltInPrompt(String id, String prompt) async {
    final prefs = await SharedPreferences.getInstance();
    final overrides = _readOverrides(prefs);
    if (prompt.trim().isEmpty) {
      overrides.remove(id);
    } else {
      overrides[id] = prompt;
    }
    await prefs.setString(overridesKey, jsonEncode(overrides));
  }

  Future<InsightLens> addCustom({
    required String name,
    required String description,
    required String prompt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final custom = _readCustom(prefs);
    final lens = InsightLens(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      description: description.trim(),
      prompt: prompt,
      icon: InsightLensIcon.custom,
      author: '我',
    );
    await _writeCustom(prefs, [...custom, lens]);
    return lens;
  }

  Future<void> updateCustom(InsightLens lens) async {
    final prefs = await SharedPreferences.getInstance();
    final custom = _readCustom(prefs);
    final index = custom.indexWhere((item) => item.id == lens.id);
    if (index == -1) {
      return;
    }
    custom[index] = lens;
    await _writeCustom(prefs, custom);
  }

  Future<void> deleteCustom(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final custom = _readCustom(prefs)..removeWhere((item) => item.id == id);
    await _writeCustom(prefs, custom);
  }

  Map<String, String> _readOverrides(SharedPreferences prefs) {
    final raw = prefs.getString(overridesKey);
    if (raw == null || raw.isEmpty) {
      return <String, String>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return <String, String>{};
      }
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } on Object {
      return <String, String>{};
    }
  }

  List<InsightLens> _readCustom(SharedPreferences prefs) {
    final raw = prefs.getString(customKey);
    if (raw == null || raw.isEmpty) {
      return <InsightLens>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return <InsightLens>[];
      }
      return decoded
          .whereType<Map>()
          .map((item) => InsightLens.fromJson(item.cast<String, dynamic>()))
          .where((lens) => lens.id.isNotEmpty)
          .toList();
    } on Object {
      return <InsightLens>[];
    }
  }

  Future<void> _writeCustom(
    SharedPreferences prefs,
    List<InsightLens> lenses,
  ) async {
    await prefs.setString(
      customKey,
      jsonEncode(lenses.map((lens) => lens.toJson()).toList()),
    );
  }
}
