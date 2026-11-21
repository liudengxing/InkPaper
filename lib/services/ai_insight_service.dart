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
    this.reasoning = '',
    this.title = '',
    this.sources = const <InsightSource>[],
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

  /// 模型的思考过程（推理型模型才有，可能为空）。
  final String reasoning;

  /// 从正文首行剥出来的标题（模型没给就是空串，界面退回视角名）。
  final String title;

  /// 本次喂给模型的笔记，下标 0 即正文里的编号 1——角标靠它取原文。
  final List<InsightSource> sources;

  bool get isError => error != null;

  /// 按正文里的编号取来源（1 起算），越界返回 null。
  InsightSource? sourceAt(int index) {
    if (index < 1 || index > sources.length) {
      return null;
    }
    return sources[index - 1];
  }
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
  ///
  /// 推理型模型（deepseek-flash 默认开思考）会把「思考 + 正文」算进同一个
  /// 额度：2200 时思考一长，正文直接空掉，用户只看到「输出被 max_tokens
  /// 截断」。官方 chat 接口单次上限 8192，这里就顶到 8192；真被截断时还会
  /// 自动关掉思考重试一次（见 [_retry]）。
  static const int maxOutputTokens = 8192;

  /// 内置视角的正文下限。
  ///
  /// 最短的 CBT 也要求 650 字。几十个字收尾、或停在两百多字，都不是「写得
  /// 克制」，是模型提前结束了——偶发过一次（逆向思考只写到两百多字就断），
  /// 所以低于这个量就补一次，而不是把它当成品交给用户。
  static const int minBuiltInChars = 350;

  /// 所有视角共用的规则。
  ///
  /// 「编号 1 权重最高」不是随手写的：少楠在访谈里明确说过官方提示词里专门
  /// 强调「第一条笔记最重要」，理由是用户主动点开查看的那条，往往就是他
  /// 心里最重要的那条。我们按时间倒序喂笔记，编号 1 即最新一条。
  ///
  /// 字数交给各视角自己定：默认视角是 900-1100 字的连续长文（对齐 flomo
  /// 默认洞察的实际产出），其余方法论视角保持 500 字左右的骨架式输出。
  static const String systemPrompt = '''
你是 InkPaper 的洞察助手。用户会交给你一批自己写的笔记（按时间倒序，编号从 1 开始）和一个分析视角。你的任务不是总结这批记录，而是读出一个连他自己都还没说出口的结论。

通用规则：
1. 只依据给出的笔记，不补充笔记之外的事实，不编造日期、人物、事件、关系。
2. 支撑判断的具体证据后面用 [序号] 标注，一句最多挂两个，如 [12]；不要求每句都挂，但每一段至少得有一处能核对的。序号必须是真实存在的编号，找不到依据的判断整句删掉。
3. 不复述原文，不写「这篇笔记讲了」「从这些记录可以看出」。第一句就要是判断，不要铺垫，不要用「我读完了」「这是一段很真诚的记录」开头。
4. 不做医学或心理诊断，不给人格下判决，不预测未来，不说「你应该」。
5. 第二人称「你」，像当面说话。引用他的原话用「」，不要改字。
6. 中文，纯文本。不要 Markdown 标题、加粗、表格、emoji、破折号（用逗号或句号断句）。段落结构听所在视角的：视角要求分条时用「一、二、三」起行，没要求就用自然段落、段与段之间空一行。
7. 不要用「亲爱的」「加油」「相信自己」这类安慰话术，也不要用「成长」「复盘」「闭环」「赋能」「情绪价值」「底层逻辑」这类空词。
8. 允许尖锐，但尖锐要落在具体的事上（他哪天写了什么），不是给他贴标签（「你是完美主义者」）。
9. 证据只有一条就说只有一条；笔记里确实看不出就明说看不出，不要为了凑满结构硬编。
10. 字数按视角要求；宁可少说一个点，也不要掺水。
11. 编号 1 的笔记权重最高：它是用户最近主动记录的，做判断时优先从它出发。
12. 写任何时间之前先核对该条笔记的日期。写「今年 6 月」「2024 年初」，日期就必须对得上；对不上就只写事、不写时间。
13. 他的动机拿不准就不要替他判定（是裁员还是主动辞职、有没有后悔），用中性说法，把判断留空好过说错。
14. 写成长文时，开篇要点明这批笔记覆盖的时间范围（用户消息里已经给了），别让报告读起来像一次随机抽样。
15. 输出第一行固定写「标题：」加一句话（12-22 字），是这篇里最核心的那个判断，可以直接取自正文最有劲的那句。标题不要用视角名、不要用「洞察报告」「笔记分析」这类词，不要书名号或引号。第二行开始才是正文。
16. 全文最后一句必须是完整的一句话，以句号结束。不要停在半句、省略号或问句上；写不完就压缩前面的段落，宁可少一个判断，也不能交一份没有收尾的报告。''';

  /// 生成一次洞察。
  ///
  /// [scopeLabel] 只用于告诉模型「这批笔记的范围是什么」，例如「全部笔记」
  /// 或「最近 30 天」，会影响它说话的口径。
  Future<AiInsightResult> generate({
    required AppConfig config,
    required InsightLens lens,
    required List<Note> notes,
    String scopeLabel = '全部笔记',
    void Function(String delta, {required bool reasoning})? onProgress,

    /// 补救重试这类「不在吐字但也没结束」的阶段，用来换掉界面的等待文案。
    void Function(String message)? onStatus,
  }) async {
    final configError = _validateConfig(config);
    if (configError != null) {
      return AiInsightResult.error(configError);
    }

    // 洞察用「跨时间分层」而不是「最近 N 条」：写了两三年的人，最近 200
    // 条可能只有几个月，模型就写不出「这几年你在变什么」。
    final context = NotesContextBuilder.buildForInsight(notes);
    if (context.noteCount == 0) {
      return AiInsightResult.error('当前范围内没有可用的文字笔记（图片和音视频不会发给 AI）。');
    }

    final service = DeepSeekApiService(
      apiUrl: config.aiApiUrl!.trim(),
      apiKey: config.aiApiKey!.trim(),
      model: config.aiModel,
    );

    final messages = <Map<String, String>>[
      DeepSeekApiService.buildSystemMessage(
        '$systemPrompt\n\n${lens.prompt.trim()}',
      ),
      DeepSeekApiService.buildUserMessage(
        buildUserMessage(context: context, scopeLabel: scopeLabel),
      ),
    ];

    // 先走流式：思考过程可以边想边显示，用户不用对着转圈干等。
    var reply = await service.chatStreamed(
      messages: messages,
      // 洞察需要一点发散，但不能飘；0.6 是「有判断又不太随机」的折中。
      temperature: 0.6,
      maxTokens: maxOutputTokens,
      onDelta: onProgress,
    );

    // 正文为空、被 max_tokens 截在半句（finish_reason=length），或流没正常
    // 收尾（网关掐了连接，但 await for 是正常结束的），都值得补救一次。
    // 最后一种最隐蔽：正文停在一句话中间，看着像模型水平就这样。
    final tooShort =
        lens.builtIn && (reply.content ?? '').trim().length < minBuiltInChars;
    if (!reply.hasContent ||
        reply.finishReason == 'length' ||
        reply.incomplete ||
        tooShort) {
      reply = await _retry(service, messages, reply, onStatus: onStatus);
    }

    if (!reply.hasContent) {
      return AiInsightResult.error(reply.error ?? 'AI 没有返回内容，请稍后重试');
    }

    final cleaned = cleanOutput(reply.content!);
    final split = splitTitle(cleaned);
    return AiInsightResult(
      text: split.body,
      title: split.title,
      noteCount: context.noteCount,
      totalCandidates: context.totalCandidates,
      truncated: context.truncated,
      reasoning: reply.reasoning.trim(),
      sources: context.sources,
    );
  }

  /// 模型自报的标题上限。超过这个长度基本是它把首段整段搬下来了，
  /// 与其在标题位置塞一段正文、不如退回视角名。
  static const int maxTitleLength = 40;

  /// 把首行的「标题：xxx」拆出来当标题。
  ///
  /// 必须是显式前缀才认——不然模型偶尔漏写这一行，正文第一句（洞察最关键
  /// 的那句判断）就会被当成标题吞掉，正文从第二句开始，读起来莫名其妙。
  /// 认不出来时 title 返回空串，界面退回视角名，正文一字不动。
  static ({String title, String body}) splitTitle(String text) {
    final lines = text.split('\n');
    if (lines.length < 2) {
      return (title: '', body: text);
    }
    final first = lines.first.trim();
    final match = RegExp(
      r'^(?:标题|题目|title)\s*[:：]\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(first);
    if (match == null) {
      return (title: '', body: text);
    }
    final title = _cleanTitle(match.group(1) ?? '');
    final body = lines.skip(1).join('\n').trim();
    // 只有标题行、或标题后面没正文：当成没给标题，整段原样当正文。
    if (title.isEmpty || body.isEmpty) {
      return (title: '', body: text);
    }
    return (title: title, body: body);
  }

  static String _cleanTitle(String raw) {
    var title = raw.trim();
    // 模型偶尔还套着加粗、书名号、句号，一并剥掉
    title = title.replaceAll(RegExp(r'^[#>*\-\s]+'), '');
    title = title.replaceAll(RegExp(r'^[「『“"《【\[]+'), '');
    title = title.replaceAll(RegExp(r'[」』”"》】\]]+$'), '');
    title = title.replaceAll(RegExp(r'[。．.！!，,]+$'), '');
    title = title.trim();
    if (title.isEmpty || title.length > maxTitleLength) {
      return '';
    }
    return title;
  }

  /// 流式拿不到正文时的一次补救。
  ///
  /// 三种常见原因分别对应两条路：
  /// - 网关不支持 SSE（流里没有数据）→ 退回普通请求，思考照旧开着；
  /// - 思考把 max_tokens 吃光（`finish_reason=length` / 只有思考）→ 关掉
  ///   思考再来一次，正文才有额度；
  /// - 密钥 / 网络错误 → 重试也没用，直接把原错误带回去。
  Future<AiChatReply> _retry(
    DeepSeekApiService service,
    List<Map<String, String>> messages,
    AiChatReply first, {
    void Function(String message)? onStatus,
  }) async {
    final error = first.error ?? '';
    final worthRetrying = !first.hasContent ||
        first.finishReason == 'length' ||
        first.incomplete ||
        first.reasoning.isNotEmpty ||
        error.contains('流式') ||
        error.contains('空内容');
    if (!worthRetrying) {
      return first;
    }

    // 重试是非流式的，界面这时收不到任何 delta：不给一句话，用户看到的就是
    // 「思考完了、正文停在两百字、再也不动」。
    onStatus?.call('上一段没写完，正在重新生成…');
    final plain = await service.chatDetailed(
      messages: messages,
      temperature: 0.6,
      maxTokens: maxOutputTokens,
    );
    // 有正文、且不是被截断的，直接用；但两次都完整时取更长的那次——
    // 关思考重来有可能写得更短，用短换长等于白花一次额度。
    if (plain.hasContent && plain.finishReason != 'length') {
      return _preferLonger(
        first,
        AiChatReply(
          content: plain.content,
          reasoning:
              plain.reasoning.isEmpty ? first.reasoning : plain.reasoning,
          finishReason: plain.finishReason,
        ),
      );
    }

    onStatus?.call('换个更省额度的写法再试一次…');
    final noThinking = await service.chatDetailed(
      messages: messages,
      temperature: 0.6,
      maxTokens: maxOutputTokens,
      thinking: false,
    );
    if (noThinking.hasContent) {
      return _preferLonger(
        first,
        AiChatReply(
          content: noThinking.content,
          reasoning: first.reasoning.isEmpty && plain.reasoning.isNotEmpty
              ? plain.reasoning
              : first.reasoning,
          finishReason: noThinking.finishReason,
        ),
      );
    }

    // 两次都没拿到完整正文：如果普通请求至少给了（截断的）正文，也比报错好
    if (plain.hasContent) {
      return _preferLonger(first, plain);
    }

    return AiChatReply(
      reasoning: first.reasoning.isEmpty
          ? (plain.reasoning.isEmpty ? noThinking.reasoning : plain.reasoning)
          : first.reasoning,
      finishReason: noThinking.finishReason ?? plain.finishReason,
      error: noThinking.error ?? plain.error ?? first.error,
    );
  }

  /// 两份回复取正文更长的那份，思考过程也各取更长的一段。
  static AiChatReply _preferLonger(AiChatReply first, AiChatReply second) {
    final firstLength = (first.content ?? '').trim().length;
    final secondLength = (second.content ?? '').trim().length;
    final content = secondLength >= firstLength ? second : first;
    final reasoning =
        second.reasoning.trim().length >= first.reasoning.trim().length
            ? second.reasoning
            : first.reasoning;
    return AiChatReply(
      content: content.content,
      reasoning: reasoning,
      finishReason: content.finishReason,
      error: content.error,
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
    // 如实说明取样规模与口径（去掉了过短笔记、按时间加权抽取）。
    final coverage = context.truncated
        ? '（库内共 ${context.totalCandidates} 条可分析的笔记，按时间加权抽取了其中 ${context.noteCount} 条）'
        : '';
    final span = describeSpan(context.earliest, context.latest);
    return '''
洞察范围：$scopeLabel
纳入分析：${context.noteCount} 条$coverage
${span.isEmpty ? '' : '$span\n'}编号说明：1 是最近一条，编号越大时间越早。

笔记如下：
${context.text}
''';
  }

  /// 「时间跨度：2021-03-24 至 2026-01-12，跨 4 年 10 个月」。
  ///
  /// 洞察报告的开篇要先把跨度交代清楚（flomo 的默认洞察就是这么开头的），
  /// 这件事让模型自己从两百行日期里数，数错比不算更糟。
  static String describeSpan(DateTime? earliest, DateTime? latest) {
    if (earliest == null || latest == null) {
      return '';
    }
    String ymd(DateTime date) => '${date.year}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';

    var months =
        (latest.year - earliest.year) * 12 + (latest.month - earliest.month);
    if (latest.day < earliest.day) {
      months -= 1;
    }
    if (months < 0) {
      months = 0;
    }
    final years = months ~/ 12;
    final rest = months % 12;
    final length = switch ((years, rest)) {
      (0, 0) => '不足一个月',
      (0, final m) => '$m 个月',
      (final y, 0) => '$y 年',
      (final y, final m) => '$y 年 $m 个月',
    };
    return '时间跨度：${ymd(earliest)} 至 ${ymd(latest)}，跨 $length';
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
