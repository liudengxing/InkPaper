import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:inkpaper/config/app_config.dart' as Config;
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/utils/logger.dart';

/// 一次聊天调用的完整结果。
///
/// 除了正文，还带上思考过程和结束原因：推理型模型（deepseek-flash /
/// v4-pro）会先写 `reasoning_content`，`max_tokens` 不够时正文是空的，
/// 只靠 `(content, error)` 二元组既没法展示思考，也说不清是被截断还是
/// 服务端抽风。
class AiChatReply {
  const AiChatReply({
    this.content,
    this.reasoning = '',
    this.finishReason,
    this.error,
    this.incomplete = false,
  });

  final String? content;

  /// 思考过程（没有就是空串）。
  final String reasoning;
  final String? finishReason;
  final String? error;

  /// 流式响应没有正常收尾：既没收到 `[DONE]`，也没有 `finish_reason`。
  ///
  /// 网关掐连接时 `await for` 是正常结束的，不抛异常，`finish_reason`
  /// 停在 null、正文停在断开的那一句——看起来像「模型就写了这么多」。
  /// 调用方据此决定要不要补一次。
  final bool incomplete;

  bool get hasContent => (content ?? '').trim().isNotEmpty;
  bool get isError => error != null;
}

/// DeepSeek API服务
/// 负责与DeepSeek API进行通信
class DeepSeekApiService {
  DeepSeekApiService({
    required this.apiUrl,
    required this.apiKey,
    this.model = AppConfig.AI_MODEL_DEEPSEEK,
    http.Client? client,
  }) : _client = client;

  final String apiUrl;
  final String apiKey;
  final String model;

  /// 测试用的注入点：为 null 时每次请求自建一个 client 并在结束时关掉。
  final http.Client? _client;

  /// 发送聊天消息。
  ///
  /// 只关心「有没有正文」的调用方用这个，错误语义与 [chatDetailed] 一致。
  Future<(String?, String?)> chat({
    required List<Map<String, String>> messages,
    double temperature = 1.0,
    int? maxTokens,
    bool? thinking,
  }) async {
    final reply = await chatDetailed(
      messages: messages,
      temperature: temperature,
      maxTokens: maxTokens,
      thinking: thinking,
    );
    if (reply.hasContent) {
      return (reply.content, null);
    }
    return (null, reply.error ?? 'AI 返回空内容');
  }

  /// 发送聊天消息，同时把正文、思考过程和结束原因一起返回。
  ///
  /// [maxTokens] 是「思考 + 正文」的总额度；推理型模型思考吃掉太多时，
  /// 正文会是空的，[AiChatReply.finishReason] 会是 `length`，调用方可以
  /// 据此关掉思考再重试一次。
  ///
  /// [thinking] 显式开关思考模式，null 表示不下发（服务端默认打开）。
  /// 只有 DeepSeek 官方地址才带这个字段：自定义的 OpenAI 兼容服务多数
  /// 不认它，发了会被判成非法参数。
  Future<AiChatReply> chatDetailed({
    required List<Map<String, String>> messages,
    double temperature = 1.0,
    int? maxTokens,
    bool? thinking,
  }) async {
    // 从网页/聊天工具拷来的 key 常夹着零宽字符、引号或 `Bearer ` 前缀，
    // 服务端只会回一句「密钥无效」，用户完全看不出多了个字符。
    final key = AppConfig.sanitizeApiKey(apiKey);
    if (key.isEmpty) {
      return const AiChatReply(error: '未填写 API 密钥');
    }
    // 非 ASCII 进不了 HTTP 头（http 包会直接抛 FormatException），
    // 提前给一句能看懂的提示，而不是「网络请求失败」。
    if (key.runes.any((rune) => rune > 127)) {
      return const AiChatReply(
        error: 'API 密钥里有非 ASCII 字符（可能粘进了中文或全角字符），请重新复制',
      );
    }

    // 结尾斜杠会拼出 `//chat/completions`：官方网关认，别的网关不一定
    final endpoint =
        '${apiUrl.trim().replaceAll(RegExp(r'/+$'), '')}/chat/completions';

    final requestBody = <String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': temperature,
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (thinking != null && AppConfig.isDeepSeekApiUrl(apiUrl))
        'thinking': {'type': thinking ? 'enabled' : 'disabled'},
      'stream': false,
    };

    final client = _client ?? http.Client();
    try {
      // 必须设超时：周/月回顾这类长 prompt 一旦服务端不返回，没有超时的话
      // 请求会一直挂着，用户只能看到"生成中"转圈。
      final response = await client
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode(requestBody),
          )
          .timeout(
            const Duration(seconds: Config.AppConfig.aiRequestTimeoutSeconds),
          );

      if (response.statusCode == 200) {
        return _parseReply(response);
      }
      return AiChatReply(error: _errorFor(response, key: key));
    } on TimeoutException {
      return const AiChatReply(error: 'AI服务响应超时，请稍后重试');
    } on Object catch (e) {
      return AiChatReply(error: '网络请求失败: $e');
    } finally {
      if (_client == null) {
        client.close();
      }
    }
  }

  /// 流式聊天：边生成边回调。
  ///
  /// 推理型模型要思考几十秒才出正文，干转圈没有任何信息；这里把
  /// `reasoning_content` 的增量也回调出去，界面可以边想边显示。
  /// [onDelta] 的 `reasoning` 为 true 表示这一段是思考过程。
  ///
  /// 返回的 [AiChatReply] 里是拼好的完整正文与思考。网关不支持 SSE
  /// （返回的是普通 JSON、或流里一条数据都没有）时返回 error，调用方
  /// 应该退回 [chatDetailed] 重试一次。
  Future<AiChatReply> chatStreamed({
    required List<Map<String, String>> messages,
    double temperature = 1.0,
    int? maxTokens,
    bool? thinking,
    void Function(String delta, {required bool reasoning})? onDelta,
  }) async {
    final key = AppConfig.sanitizeApiKey(apiKey);
    if (key.isEmpty) {
      return const AiChatReply(error: '未填写 API 密钥');
    }
    if (key.runes.any((rune) => rune > 127)) {
      return const AiChatReply(
        error: 'API 密钥里有非 ASCII 字符（可能粘进了中文或全角字符），请重新复制',
      );
    }

    final endpoint =
        '${apiUrl.trim().replaceAll(RegExp(r'/+$'), '')}/chat/completions';
    final requestBody = <String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': temperature,
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (thinking != null && AppConfig.isDeepSeekApiUrl(apiUrl))
        'thinking': {'type': thinking ? 'enabled' : 'disabled'},
      'stream': true,
    };

    final client = _client ?? http.Client();
    try {
      final request = http.Request('POST', Uri.parse(endpoint))
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $key',
          'Accept': 'text/event-stream',
        })
        ..body = jsonEncode(requestBody);

      final streamed = await client.send(request).timeout(
            const Duration(seconds: Config.AppConfig.aiRequestTimeoutSeconds),
          );

      if (streamed.statusCode != 200) {
        final response = await http.Response.fromStream(streamed);
        return AiChatReply(error: _errorFor(response, key: key));
      }

      final content = StringBuffer();
      final reasoning = StringBuffer();
      String? finishReason;
      var chunks = 0;
      // 网关给 `[DONE]` 就算这条流走完了；两者都没有时说明连接被掐断，
      // 正文只是断在半句，不能当成完整结果交出去。
      var sawDone = false;

      // 60 秒没有任何新数据就当作断流，否则 await for 会一直挂着
      final lines = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 60));

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || !trimmed.startsWith('data:')) {
          continue;
        }
        final payload = trimmed.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') {
          if (payload == '[DONE]') {
            sawDone = true;
            break;
          }
          continue;
        }

        Map<String, dynamic>? data;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map<String, dynamic>) {
            data = decoded;
          }
        } on Object {
          // 心跳、注释行、半截 JSON 都直接跳过，别让一行坏数据毁掉整次生成
        }
        if (data == null) {
          continue;
        }

        final choices = data['choices'];
        if (choices is! List || choices.isEmpty) {
          continue;
        }
        final choice = choices.first;
        if (choice is! Map<String, dynamic>) {
          continue;
        }
        finishReason = (choice['finish_reason'] as String?) ?? finishReason;

        final delta = choice['delta'];
        if (delta is! Map<String, dynamic>) {
          continue;
        }
        final reasoningDelta = delta['reasoning_content'] as String?;
        if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
          reasoning.write(reasoningDelta);
          chunks++;
          onDelta?.call(reasoningDelta, reasoning: true);
        }
        final contentDelta = delta['content'] as String?;
        if (contentDelta != null && contentDelta.isNotEmpty) {
          content.write(contentDelta);
          chunks++;
          onDelta?.call(contentDelta, reasoning: false);
        }
      }

      return _finishReply(
        content: content.toString(),
        reasoning: reasoning.toString(),
        finishReason: finishReason,
        chunks: chunks,
        incomplete: !sawDone && finishReason == null,
      );
    } on TimeoutException {
      return const AiChatReply(error: 'AI服务响应超时，请稍后重试');
    } on Object catch (e) {
      return AiChatReply(error: '网络请求失败: $e');
    } finally {
      if (_client == null) {
        client.close();
      }
    }
  }

  /// 非流式响应体 → [AiChatReply]。
  AiChatReply _parseReply(http.Response response) {
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>?;
    final choice = choices?.isNotEmpty ?? false
        ? choices!.first as Map<String, dynamic>
        : null;
    final message = choice?['message'] as Map<String, dynamic>?;
    final content = message?['content'] as String?;
    final finishReason = choice?['finish_reason'] as String?;
    final reasoning = (message?['reasoning_content'] as String?)?.trim() ?? '';

    return _finishReply(
      content: content ?? '',
      reasoning: reasoning,
      finishReason: finishReason,
      chunks: content == null ? 0 : 1,
      hasChoices: choice != null,
    );
  }

  /// 空正文要区分原因，否则界面只能看到含糊的「返回内容为空」：
  /// 推理型模型会先写 reasoning_content，max_tokens 不够时正文就是空的。
  AiChatReply _finishReply({
    required String content,
    required String reasoning,
    required String? finishReason,
    required int chunks,
    bool hasChoices = true,
    bool incomplete = false,
  }) {
    if (content.trim().isNotEmpty) {
      return AiChatReply(
        content: content,
        reasoning: reasoning,
        finishReason: finishReason,
        incomplete: incomplete,
      );
    }
    if (finishReason == 'length') {
      return AiChatReply(
        reasoning: reasoning,
        finishReason: finishReason,
        error: '输出被 max_tokens 截断（finish_reason=length），请调大输出上限或换非推理模型',
      );
    }
    if (reasoning.isNotEmpty) {
      return AiChatReply(
        reasoning: reasoning,
        finishReason: finishReason,
        error: '模型只返回了思考过程、没有正文（reasoning ${reasoning.length} 字），请换用非推理模型',
      );
    }
    if (!hasChoices) {
      return const AiChatReply(
        error: 'AI 响应里没有 choices 字段，接口可能不是 OpenAI 兼容格式',
      );
    }
    if (chunks == 0) {
      return const AiChatReply(
        error: 'AI 返回空内容（流式响应里一条数据都没有，接口可能不支持 stream）',
      );
    }
    return AiChatReply(
      finishReason: finishReason,
      error: 'AI 返回空内容（finish_reason=${finishReason ?? 'unknown'}）',
    );
  }

  /// 非 200 的统一错误文案（401/403 会带上服务端原文）。
  String _errorFor(http.Response response, {required String key}) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      // 服务端会把被拒的 key 尾巴回显出来（`****abcd`），原样透传：
      // 少了 Bearer、多了引号、key 被截断，这几种情况一眼能对上。
      final detail = _parseErrorMessage(response);
      Log.custom('DeepSeekApi').warning(
        'auth rejected',
        data: {
          'status': response.statusCode,
          'model': model,
          'keyLength': key.length,
          'keyTail': _maskKey(key),
          'detail': detail,
        },
      );
      return detail == null || detail.isEmpty
          ? 'API 密钥无效（HTTP ${response.statusCode}）'
          : 'API 密钥无效：$detail';
    }
    if (response.statusCode == 429) {
      return '请求过于频繁，请稍后再试';
    }
    final errorMessage = _parseErrorMessage(response);
    return errorMessage ?? 'AI服务错误: ${response.statusCode}';
  }

  /// 解析错误消息
  ///
  /// 走 bodyBytes + utf8：http 包对没写 charset 的 JSON 默认按 latin1 解，
  /// 服务端回中文时会变乱码。allowMalformed 用来兼容非 UTF-8 的第三方网关。
  String? _parseErrorMessage(http.Response response) {
    try {
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      final data = jsonDecode(body) as Map<String, dynamic>;
      final error = data['error'] as Map<String, dynamic>?;
      final message = error?['message'] ?? data['message'];
      return message is String && message.trim().isNotEmpty
          ? message.trim()
          : null;
    } on Object {
      return null;
    }
  }

  /// 日志里只留长度和尾部四位：够判断「key 是不是被截断」，
  /// 又不至于把完整密钥写进日志。
  static String _maskKey(String key) {
    if (key.length <= 4) {
      return '****';
    }
    return '****${key.substring(key.length - 4)}';
  }

  /// 测试API连接
  ///
  /// 返回 (是否成功, 错误消息)
  Future<(bool, String?)> testConnection() async {
    try {
      final (response, error) = await chat(
        messages: [
          {'role': 'user', 'content': 'Hello'},
        ],
        // 连通性测试只关心「能不能通」：显式关掉思考。思考模式默认打开且
        // effort=high，会把 max_tokens 先花在思考上，正文空掉之后明明 key
        // 有效也会报「输出被截断」。
        maxTokens: 16,
        thinking: false,
      );

      if (error != null) {
        return (false, error);
      }

      if (response != null) {
        return (true, null);
      }

      return (false, 'API响应为空');
    } on Object catch (e) {
      return (false, '连接测试失败: $e');
    }
  }

  /// 获取当前模型的信息。
  ///
  /// 官方只提供 `GET /models`（模型列表），没有 `/models/{id}`，
  /// 所以拉列表后自己挑出当前模型那一条。取不到一律返回 null。
  Future<Map<String, dynamic>?> getModelInfo() async {
    try {
      final key = AppConfig.sanitizeApiKey(apiKey);
      if (key.isEmpty) {
        return null;
      }
      final base = apiUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final url = Uri.parse('$base/models');

      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $key',
        },
      );

      if (response.statusCode != 200) {
        return null;
      }

      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, dynamic>) {
        return null;
      }
      final data = body['data'];
      if (data is! List) {
        return null;
      }
      for (final item in data) {
        if (item is Map<String, dynamic> && item['id'] == model) {
          return item;
        }
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// 构建系统提示词
  ///
  /// 用于为AI设置角色和行为规范
  static Map<String, String> buildSystemMessage(String systemPrompt) => {
        'role': 'system',
        'content': systemPrompt,
      };

  /// 构建用户消息
  static Map<String, String> buildUserMessage(String content) => {
        'role': 'user',
        'content': content,
      };

  /// 构建助手消息
  static Map<String, String> buildAssistantMessage(String content) => {
        'role': 'assistant',
        'content': content,
      };

  /// 🚀 使用统一配置管理的提示词模板
  static String get defaultSystemPrompt => Config.AppConfig.aiDefaultPrompt;
  static String get summarySystemPrompt => Config.AppConfig.aiSummaryPrompt;
  static String get expandSystemPrompt => Config.AppConfig.aiExpandPrompt;
  static String get improveSystemPrompt => Config.AppConfig.aiImprovePrompt;
}

/// AI对话历史管理器
class AiConversationManager {
  AiConversationManager({this.maxHistoryLength = 20});
  final List<Map<String, String>> _messages = [];
  final int maxHistoryLength;

  /// 添加系统消息
  void addSystemMessage(String content) {
    _messages.add(DeepSeekApiService.buildSystemMessage(content));
  }

  /// 添加用户消息
  void addUserMessage(String content) {
    _messages.add(DeepSeekApiService.buildUserMessage(content));
  }

  /// 添加助手消息
  void addAssistantMessage(String content) {
    _messages.add(DeepSeekApiService.buildAssistantMessage(content));
  }

  /// 获取所有消息
  List<Map<String, String>> getMessages() {
    // 保留系统消息 + 最近的N条对话
    final systemMessages =
        _messages.where((m) => m['role'] == 'system').toList();
    final conversationMessages =
        _messages.where((m) => m['role'] != 'system').toList();

    if (conversationMessages.length > maxHistoryLength) {
      return [
        ...systemMessages,
        ...conversationMessages
            .sublist(conversationMessages.length - maxHistoryLength),
      ];
    }

    return _messages;
  }

  /// 清空历史
  void clear() {
    _messages.clear();
  }

  /// 获取消息数量
  int get length => _messages.length;
}
