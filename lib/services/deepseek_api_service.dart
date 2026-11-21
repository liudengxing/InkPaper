import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:inkpaper/config/app_config.dart' as Config;
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/utils/logger.dart';

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

  /// 发送聊天消息
  ///
  /// [messages] - 对话消息列表，格式：[{'role': 'user', 'content': '消息内容'}]
  /// [temperature] - 温度参数，控制回复的随机性 (0.0-2.0)
  /// [maxTokens] - 最大 token 数；思考模式下思考内容也算在里面
  /// [thinking] - 显式开关思考模式，null 表示不下发（服务端默认打开）。
  ///   只有 DeepSeek 官方地址才带这个字段：自定义的 OpenAI 兼容服务多数
  ///   不认它，发了会被判成非法参数。
  Future<(String?, String?)> chat({
    required List<Map<String, String>> messages,
    double temperature = 1.0,
    int? maxTokens,
    bool? thinking,
  }) async {
    // 从网页/聊天工具拷来的 key 常夹着零宽字符、引号或 `Bearer ` 前缀，
    // 服务端只会回一句「密钥无效」，用户完全看不出多了个字符。
    final key = AppConfig.sanitizeApiKey(apiKey);
    if (key.isEmpty) {
      return (null, '未填写 API 密钥');
    }
    // 非 ASCII 进不了 HTTP 头（http 包会直接抛 FormatException），
    // 提前给一句能看懂的提示，而不是「网络请求失败」。
    if (key.runes.any((rune) => rune > 127)) {
      return (null, 'API 密钥里有非 ASCII 字符（可能粘进了中文或全角字符），请重新复制');
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
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>?;
        final choice = choices?.isNotEmpty ?? false
            ? choices!.first as Map<String, dynamic>
            : null;
        final message = choice?['message'] as Map<String, dynamic>?;
        final content = message?['content'] as String?;
        final finishReason = choice?['finish_reason'] as String?;
        final reasoning =
            (message?['reasoning_content'] as String?)?.trim() ?? '';

        if (content != null && content.trim().isNotEmpty) {
          return (content, null);
        }

        // 空正文要区分原因，否则界面只能看到含糊的"返回内容为空"：
        // 推理型模型会先写 reasoning_content，max_tokens 不够时正文就是空的。
        if (finishReason == 'length') {
          return (
            null,
            '输出被 max_tokens 截断（finish_reason=length），请调大输出上限或换非推理模型',
          );
        }
        if (reasoning.isNotEmpty) {
          return (
            null,
            '模型只返回了思考过程、没有正文（reasoning ${reasoning.length} 字），请换用非推理模型',
          );
        }
        if (choice == null) {
          return (null, 'AI 响应里没有 choices 字段，接口可能不是 OpenAI 兼容格式');
        }
        return (null, 'AI 返回空内容（finish_reason=${finishReason ?? 'unknown'}）');
      } else if (response.statusCode == 401 || response.statusCode == 403) {
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
        return (
          null,
          detail == null || detail.isEmpty
              ? 'API 密钥无效（HTTP ${response.statusCode}）'
              : 'API 密钥无效：$detail',
        );
      } else if (response.statusCode == 429) {
        return (null, '请求过于频繁，请稍后再试');
      } else {
        final errorMessage = _parseErrorMessage(response);
        return (null, errorMessage ?? 'AI服务错误: ${response.statusCode}');
      }
    } on TimeoutException {
      return (null, 'AI服务响应超时，请稍后重试');
    } on Object catch (e) {
      return (null, '网络请求失败: $e');
    } finally {
      if (_client == null) {
        client.close();
      }
    }
  }

  /// 流式聊天（暂未实现）
  ///
  /// 用于实时显示AI回复内容
  Stream<String> chatStream({
    required List<Map<String, String>> messages,
    double temperature = 1.0,
    int? maxTokens,
  }) async* {
    // 流式响应暂未接入，当前保留占位输出。
    yield '流式响应功能待实现';
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
