import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/deepseek_api_service.dart';
import 'package:inkpaper/services/notes_context_builder.dart';

/// 一轮对话。
class QaTurn {
  const QaTurn({required this.question, required this.answer});

  final String question;
  final String answer;
}

/// 问答结果。
class QaAnswer {
  const QaAnswer({
    required this.answer,
    required this.context,
    this.error,
  });

  final String answer;
  final NotesContext context;
  final String? error;

  bool get isError => error != null;
}

/// 「问笔记」：把全库笔记当资料，回答用户的问题。
///
/// 每次提问都把笔记上下文重新拼一遍放进 system prompt：笔记随时会变，
/// 靠一次性的会话缓存很容易答出过时内容。多轮历史只保留最近几轮，
/// 避免把 token 全花在寒暄上。
class NotesQaService {
  NotesQaService({this.maxHistoryTurns = 5});

  final int maxHistoryTurns;

  Future<QaAnswer> ask({
    required AppConfig config,
    required List<Note> notes,
    required List<QaTurn> history,
    required String question,
  }) async {
    final context = NotesContextBuilder.build(notes);

    if (!config.aiEnabled ||
        (config.aiApiUrl?.trim().isEmpty ?? true) ||
        (config.aiApiKey?.trim().isEmpty ?? true)) {
      return QaAnswer(
        answer: '',
        context: context,
        error: '还没有配置 AI：请到「设置 → AI 设置」填写 API 地址和密钥后再提问。',
      );
    }

    if (context.noteCount == 0) {
      return QaAnswer(
        answer: '',
        context: context,
        error: '当前没有可用的笔记内容（图片不会被发送给 AI）。',
      );
    }

    final service = DeepSeekApiService(
      apiUrl: config.aiApiUrl!.trim(),
      apiKey: config.aiApiKey!.trim(),
      model: config.aiModel,
    );

    final recent = history.length > maxHistoryTurns
        ? history.sublist(history.length - maxHistoryTurns)
        : history;

    final messages = <Map<String, String>>[
      DeepSeekApiService.buildSystemMessage(_systemPrompt(context)),
      for (final turn in recent) ...[
        DeepSeekApiService.buildUserMessage(turn.question),
        DeepSeekApiService.buildAssistantMessage(turn.answer),
      ],
      DeepSeekApiService.buildUserMessage(question),
    ];

    final (content, error) = await service.chat(
      messages: messages,
      temperature: 0.5,
      maxTokens: 1600,
    );

    if (content == null || content.trim().isEmpty) {
      return QaAnswer(
        answer: '',
        context: context,
        error: error ?? 'AI 没有返回内容，请稍后重试',
      );
    }

    return QaAnswer(
      answer: content.trim(),
      context: context,
    );
  }

  String _systemPrompt(NotesContext context) {
    final coverage = context.truncated
        ? '下面是其中最近 ${context.noteCount} 条（共 ${context.totalCandidates} 条有文字内容的笔记，更早的未附上）'
        : '下面是全部 ${context.noteCount} 条笔记';
    return '''
你是 InkPaper 的笔记助手，帮用户回顾和理解他自己的笔记。

$coverage 的内容（按时间倒序，图片、音频等附件已省略，只保留文字）。

回答规则：
1. 只依据下面给出的笔记内容回答，笔记里没有的信息就直接说"你的笔记里没有提到"，不要用常识或想象补足；
2. 先给结论，再给依据；引用时用「10-25」这样的日期或笔记序号，不要编造日期、数字和原文；
3. 中文回答，纯文本分段，可以用短横线列出 2-4 条要点，不要 Markdown 标题或代码块；
4. 涉及"多少条""几次""进展"这类问题时，尽量给出可在笔记中核对的数字；
5. 回答控制在 300 字以内，除非用户明确要求展开。

笔记内容：
${context.text}
''';
  }
}
