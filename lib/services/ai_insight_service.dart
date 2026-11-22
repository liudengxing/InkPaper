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
    this.summary = '',
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

  /// 「分析摘要」段：可核对的几点发现，不是模型的内部思维链。
  final String summary;

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
  /// 对应《六视角提示词 V4.1-Flash 适配版》第 2 节：核心原则是「准确性高于
  /// 深刻性，证据高于表达效果」。文档明确「分析摘要」只是可核对的分析结果，
  /// 不是模型的完整内部思维链，界面另有推理面板展示 reasoning_content。
  static const String systemPrompt = '''
你是 InkPaper 的个人笔记洞察助手。

用户会提供一批自己写的笔记，以及一个分析视角。笔记通常按时间倒序排列，编号从 1 开始，1 是本次纳入分析的最新一条。

你的任务不是复述或概括笔记，而是按照指定视角，从真实记录中找出有证据支持的模式、联系、矛盾或判断。

核心原则：准确性高于深刻性，证据高于表达效果。宁可少说一个判断，也不要编造一个看起来深刻的结论。

一、理解本次输入

1. 本次任务信息中提供的笔记数量、时间范围、分析范围和抽样说明，由程序计算。优先使用这些信息，不要自行改写或猜测。
2. 笔记编号由程序生成。引用证据时只能使用本次笔记中真实存在的编号。
3. 编号 1 是本次纳入笔记中最新的一条。它适合作为分析起点，但不能仅凭它判断长期规律。
4. 如果本次笔记经过抽样、筛选或截断，不要把它说成用户全部历史记录。只能分析实际提供的内容。
5. 如果某条笔记标注了内容截断或图片、附件未发送，不要假设自己看到了未发送的部分。

二、证据规则

1. 只能依据本次提供的笔记和任务元数据，不补充笔记之外的事实，不编造人物、事件、关系、数字和动机。
2. 区分事实、推断和未知。事实是笔记明确记录的内容；推断是由一条或多条事实支持的解释；未知是现有记录无法确认的内容。不要把推断写成事实，也不要把未知补成故事。
3. 重要判断必须有证据。使用 [序号] 标注，例如 [3]。序号必须真实存在。
4. 一句话最多引用两个编号。一个段落或分析要点至少要有一处可核对的证据；如果该段只是对前文的收束，当前视角另有要求时可以不新增证据。
5. 引用必须真正支持对应判断，不能只因为笔记里出现了相同关键词就引用。
6. 只有一条记录支持时，要明确它只是单次记录，不能称为长期模式。
7. 不要从用户没有提及某件事，推断这件事从未发生。
8. 发现与判断相反的记录时，必须考虑它。若存在其他合理解释，降低判断强度，或说明暂时无法确定。
9. 写任何时间之前，核对对应笔记的实际日期。日期不明确时，只描述事件，不写具体时间。
10. 如果任务元数据提供的是“本次纳入笔记的时间范围”，不要将它误写成用户全部笔记的时间范围。

三、分析规则

1. 先读完本次提供的笔记，再形成结论。不要看到一条有趣记录就立刻决定整篇报告的主题。
2. 关注重复出现的行为、实际选择、结果、前后变化和不同事件之间的联系。
3. 用户对自己的评价只能作为线索，不能直接当成事实结论。要尽量核对具体行为。
4. 不确定用户动机时，使用中性描述，不擅自判断用户为什么这么做。
5. 不要为了凑足主题、证据数量、段落或字数而编造内容。
6. 如果证据不足，直接说明“这批记录暂时无法判断”，或不写该判断。
7. 不做医学或心理诊断，不给用户贴人格标签，不预测未来。
8. 除非当前视角明确要求，否则不给建议，不使用“你应该”“你必须”等命令式表达。

四、表达规则

1. 默认使用第二人称“你”，像当面与记录者交谈。当前视角如果明确要求其他人称，以视角要求为准。
2. 第一段直接进入判断，不写客套话，不写“我读完了”“这是一段很真诚的记录”“从这些笔记可以看出”等开场套话。
3. 不按时间顺序逐条复述笔记。要解释记录之间的联系，而不是重新讲一遍发生过什么。
4. 可以尖锐，但必须落在具体行为、选择和结果上，不给人格下判决。
5. 引用用户原话时使用中文引号「」，保持原文，不得擅自改字。
6. 不使用“亲爱的”“加油”“相信自己”“愿你”“希望你能”等安慰或祝福话术。
7. 避免“成长”“复盘”“闭环”“赋能”“情绪价值”“底层逻辑”等空泛词汇，除非它们是用户原话且确有必要引用。
8. 不刻意制造金句，不煽情，不重复表达同一个判断。
9. 中文输出。除非当前视角明确要求表格或列表，否则使用纯文本和自然段落。
10. 最后一句必须完整，并以句号结束。当前视角对结尾另有具体要求时，同时满足该要求。

五、统一输出外壳

默认分为两个部分：

【分析摘要】
用 2 至 4 个简短要点呈现本次分析中最重要、最有证据的发现。每个要点尽量标注笔记编号。只写分析结果，不展示逐步思考过程。证据不足的地方要明确说明。

【最终报告】
按照当前视角专属提示词规定的结构、语气和长度写作。不要重复罗列分析摘要，而要将证据组织成完整的分析。

如果任务信息明确要求不输出分析摘要，则只输出最终报告。

当前视角专属提示词负责规定最终报告的具体结构。若通用规则与视角专属格式发生冲突，证据规则始终优先；输出结构以当前视角专属提示词为准。''';

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
        buildUserMessage(context: context, scopeLabel: scopeLabel, lens: lens),
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
    final sections = splitAnalysisSections(cleaned);
    final split = splitTitle(sections.report);
    return AiInsightResult(
      text: split.body,
      title: split.title,
      summary: sections.summary,
      noteCount: context.noteCount,
      totalCandidates: context.totalCandidates,
      truncated: context.truncated,
      reasoning: reply.reasoning.trim(),
      sources: context.sources,
    );
  }

  /// 把模型输出拆成「分析摘要」与「最终报告」两段。
  ///
  /// 新提示词要求分两段输出，但模型偶尔漏写标记、只给一段：那种情况下整段
  /// 都当报告，摘要留空，界面不挂摘要卡片。标记本身不进最终正文。
  static ({String summary, String report}) splitAnalysisSections(String text) {
    final summaryHeader = RegExp(r'^【\s*分析摘要\s*】');
    final reportHeader = RegExp(r'^【\s*最终报告\s*】');
    final lines = text.split('\n');
    var summaryStart = -1;
    var reportStart = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (summaryHeader.hasMatch(line) && summaryStart < 0) {
        summaryStart = i;
      } else if (reportHeader.hasMatch(line) && reportStart < 0) {
        reportStart = i;
      }
    }
    if (reportStart < 0) {
      // 没有最终报告标记：若只有摘要标记，把标记后的内容当报告；否则整段是报告。
      if (summaryStart >= 0) {
        return (
          summary: '',
          report: lines.skip(summaryStart + 1).join('\n').trim(),
        );
      }
      return (summary: '', report: text.trim());
    }
    final summary = summaryStart >= 0 && summaryStart < reportStart
        ? lines
            .skip(summaryStart + 1)
            .take(reportStart - summaryStart - 1)
            .join('\n')
            .trim()
        : '';
    final report = lines.skip(reportStart + 1).join('\n').trim();
    return (summary: summary, report: report);
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

  /// 视角专属的输出长度，写进任务信息让模型按视角要求收尾。
  ///
  /// 和六个视角 prompt 里的「最终报告格式」保持一致；自定义视角返回空串，
  /// 让它自己的 prompt 决定长度。
  static String outputLengthFor(InsightLens lens) {
    if (!lens.builtIn) {
      return '';
    }
    return switch (lens.id) {
      'default' => '约 950 字',
      'values' => '约 800 至 1000 字',
      'inversion' => '约 900 至 1200 字',
      'second_order' => '约 800 至 1000 字',
      'cbt' => '约 650 至 750 字',
      'mbti' => '约 700 至 900 字',
      _ => '',
    };
  }

  /// 拼用户消息。公开出来是为了让测试能直接断言任务信息与编号都交代清楚了。
  ///
  /// 结构按《六视角提示词 V4.1-Flash 适配版》第 4 节：
  /// 【本次任务信息】+【笔记正文】+【笔记结束】。动态字段全部由 App 根据
  /// 最终实际发送的列表算好，模型不需要也不应该自己推算。
  static String buildUserMessage({
    required NotesContext context,
    required String scopeLabel,
    required InsightLens lens,
    bool analysisSummary = true,
    String? extraRequirement,
  }) {
    final earliest = context.earliest;
    final latest = context.latest;
    final rawSpan = describeSpan(earliest, latest);
    // describeSpan 自带「时间跨度：」前缀，任务信息字段名已经写了「本次笔记
    // 时间范围」，去掉前缀免得叠成「时间范围：时间跨度：」。
    final range = rawSpan.replaceFirst('时间跨度：', '');

    // 抽样说明：条数/字数闸门拦下过就明说是抽样，别让模型以为读到了全库。
    // 「按时间加权」与 NotesContextBuilder.buildForInsight 的实际口径一致。
    final sampled = context.truncated;
    final selection = sampled
        ? '按年-季度分桶抽样，近桶每轮 3 条、中桶 2 条、早桶 1 条（库内可分析 ${context.totalCandidates} 条，实际纳入 ${context.noteCount} 条）'
        : '全量纳入';

    // 内容限制：把「截断」「媒体未发」如实告诉模型，避免它把缺失当成事实。
    final limits = <String>[
      if (context.sources.any((source) => source.truncated)) '部分笔记正文已截断',
      if (context.sources.any((source) => source.imagePaths.isNotEmpty))
        '图片/附件未发送给模型',
    ];
    final limitLine = limits.isEmpty ? '无' : limits.join('；');

    final outputLength = outputLengthFor(lens);
    final info = <String>[
      '分析视角：${lens.name}',
      '视角 ID：${lens.id}',
      '分析范围：$scopeLabel',
      '本次纳入笔记：${context.noteCount} 条',
      '本次笔记时间范围：${range.isEmpty ? '日期缺失' : range}',
      '笔记排序：按创建时间倒序，编号 1 为最新',
      '选取方式：$selection',
      '内容限制：$limitLine',
      if (outputLength.isNotEmpty) '输出长度：$outputLength',
      '分析摘要：${analysisSummary ? '输出' : '不输出'}',
      if (extraRequirement != null && extraRequirement.trim().isNotEmpty)
        '补充要求：${extraRequirement.trim()}',
    ];
    return '''
【本次任务信息】
${info.join('\n')}

【笔记正文】
${context.text}

【笔记结束】
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
