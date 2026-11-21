// ============================================================
// DeepSeek 接入 · 模型名与请求拼装回归
//
// 用户反馈「模型名是不是也不对」「API key 一直提示不对」。官方文档
// （api-docs.deepseek.com/zh-cn/）给的 model 只有两个：`deepseek-flash`
// 与 `deepseek-v4-pro`，鉴权头是 `Authorization: Bearer sk-...`。
//
// 这里锁三件事：① 模型常量与文档一致；② 粘贴污染的 key 会被清洗成
// 能直接放进请求头的形态；③ 真正发出去的请求头/体是文档要求的形状，
// 401 时把服务端的原文透传出来（它会回显 key 尾巴，能一眼看出是多了
// 引号还是少了 Bearer）。
// ============================================================

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inkpaper/models/app_config_model.dart';
import 'package:inkpaper/services/deepseek_api_service.dart';

/// DeepSeek 官方成功响应（只保留代码会读的字段）
http.Response _okResponse(String content) => http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': content},
              'finish_reason': 'stop',
            },
          ],
        }),
      ),
      200,
    );

http.Response _errorResponse(int status, String message) => http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'error': {'message': message, 'type': 'authentication_error'},
        }),
      ),
      status,
    );

void main() {
  group('模型名口径', () {
    test('DS-09 与官方文档一致：flash + v4-pro，只有这两个', () {
      expect(AppConfig.AI_MODEL_DEEPSEEK, 'deepseek-flash');
      expect(AppConfig.AI_MODEL_DEEPSEEK_REASONER, 'deepseek-v4-pro');
      expect(AppConfig.DEEPSEEK_MODELS, [
        AppConfig.AI_MODEL_DEEPSEEK,
        AppConfig.AI_MODEL_DEEPSEEK_REASONER,
      ]);
      // 弃用名与退役别名都要归一化到正式名，否则下拉框匹配不上
      for (final legacy in [
        'deepseek-chat',
        'deepseek-v4-flash',
        'deepseek-v4-flash-vision-exp',
      ]) {
        expect(AppConfig.normalizeAiModel(legacy), 'deepseek-flash');
      }
      expect(
        AppConfig.normalizeAiModel('deepseek-reasoner'),
        'deepseek-v4-pro',
      );
    });
  });

  group('API Key 粘贴清洗', () {
    test('DS-10 正常 key 原样返回', () {
      expect(
        AppConfig.sanitizeApiKey('sk-abcdef123456'),
        'sk-abcdef123456',
      );
    });

    test('DS-11 去掉空白、换行、不换行空格、全角空格与零宽字符', () {
      // trim() 不认 U+00A0 / U+200B / U+FEFF，这些正是粘贴重灾区
      const dirty = ' sk-ab\u00A0cd\u200Bef\uFEFFgh\u3000ij\n';
      expect(AppConfig.sanitizeApiKey(dirty), 'sk-abcdefghij');
    });

    test('DS-12 剥掉包裹的引号与误带的 Bearer 前缀', () {
      expect(AppConfig.sanitizeApiKey('"sk-abc123"'), 'sk-abc123');
      expect(AppConfig.sanitizeApiKey('“sk-abc123”'), 'sk-abc123');
      expect(AppConfig.sanitizeApiKey("'sk-abc123'"), 'sk-abc123');
      expect(AppConfig.sanitizeApiKey('Bearer sk-abc123'), 'sk-abc123');
      expect(AppConfig.sanitizeApiKey('bearer "sk-abc123"'), 'sk-abc123');
    });

    test('DS-13 null 与空串都归成空串', () {
      expect(AppConfig.sanitizeApiKey(null), '');
      expect(AppConfig.sanitizeApiKey(''), '');
      expect(AppConfig.sanitizeApiKey('   '), '');
    });
  });

  group('请求拼装', () {
    test('DS-14 头是 Bearer <清洗后的 key>，路径与模型照文档', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return _okResponse('ok');
      });
      final service = DeepSeekApiService(
        apiUrl: AppConfig.DEEPSEEK_API_URL,
        // 带引号 + 前后空格的粘贴形态
        apiKey: ' “sk-test-1234” ',
        client: client,
      );

      final (content, error) = await service.chat(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );

      expect(error, isNull);
      expect(content, 'ok');
      expect(
        captured.url.toString(),
        'https://api.deepseek.com/chat/completions',
      );
      expect(captured.headers['Authorization'], 'Bearer sk-test-1234');

      final body =
          jsonDecode(utf8.decode(captured.bodyBytes)) as Map<String, dynamic>;
      expect(body['model'], 'deepseek-flash');
      expect(body['stream'], isFalse);
      // 没显式要求开关思考时不下发该字段，交给服务端默认
      expect(body.containsKey('thinking'), isFalse);
    });

    test('DS-15 地址结尾带斜杠不会拼出 //chat/completions', () async {
      late Uri captured;
      final client = MockClient((request) async {
        captured = request.url;
        return _okResponse('ok');
      });
      final service = DeepSeekApiService(
        apiUrl: 'https://api.deepseek.com/',
        apiKey: 'sk-test-1234',
        client: client,
      );

      await service.chat(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );

      expect(captured.toString(), 'https://api.deepseek.com/chat/completions');
    });

    test('DS-16 401 时透传服务端原文（含被拒 key 的尾巴）', () async {
      final client = MockClient(
        (_) async => _errorResponse(
          401,
          'Authentication Fails, Your api key: ****123" is invalid',
        ),
      );
      final service = DeepSeekApiService(
        apiUrl: AppConfig.DEEPSEEK_API_URL,
        apiKey: 'sk-test-1234',
        client: client,
      );

      final (content, error) = await service.chat(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );

      expect(content, isNull);
      expect(error, startsWith('API 密钥无效：'));
      expect(error, contains('****123"'));
    });

    test('DS-17 非 ASCII 的 key 直接拦截，不发请求', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return _okResponse('ok');
      });
      final service = DeepSeekApiService(
        apiUrl: AppConfig.DEEPSEEK_API_URL,
        apiKey: 'sk-ab中文cd',
        client: client,
      );

      final (content, error) = await service.chat(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
      );

      expect(called, isFalse);
      expect(content, isNull);
      expect(error, contains('非 ASCII'));
    });

    test('DS-18 thinking 只对官方地址下发，自定义地址不带', () async {
      Map<String, dynamic>? officialBody;
      final official = DeepSeekApiService(
        apiUrl: AppConfig.DEEPSEEK_API_URL,
        apiKey: 'sk-test-1234',
        client: MockClient((request) async {
          officialBody = jsonDecode(utf8.decode(request.bodyBytes))
              as Map<String, dynamic>;
          return _okResponse('ok');
        }),
      );
      await official.chat(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        thinking: false,
      );
      expect(officialBody?['thinking'], {'type': 'disabled'});

      Map<String, dynamic>? customBody;
      final custom = DeepSeekApiService(
        apiUrl: 'https://example.com/v1',
        apiKey: 'sk-test-1234',
        client: MockClient((request) async {
          customBody = jsonDecode(utf8.decode(request.bodyBytes))
              as Map<String, dynamic>;
          return _okResponse('ok');
        }),
      );
      await custom.chat(
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        thinking: false,
      );
      expect(customBody?.containsKey('thinking'), isFalse);
    });
  });
}
