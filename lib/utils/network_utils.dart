import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 网络工具类，针对不同平台优化网络请求。
///
/// `ARCH-LAYER-002 / A-06`：全进程复用同一个 [http.Client] 实例。
/// 每次请求新建客户端会重新走 DNS + TLS 握手，且旧实现里
/// 每次请求结束后 `close()` 会丢掉连接池；改为共享客户端后
/// 连接可复用（keep-alive），也不再需要在每个请求里 close。
///
/// 生命周期：进程级单例，应用退出或测试 teardown 时调用 [close]。
class NetworkUtils {
  NetworkUtils._();

  static http.Client? _sharedClient;

  /// 进程级共享客户端（懒加载）。
  ///
  /// 调用方**不要**自行 `close()`，否则后续请求会拿到已关闭的客户端。
  static http.Client get sharedClient => _sharedClient ??= http.Client();

  /// 获取适合当前平台的HTTP客户端（共享实例）。
  static http.Client createOptimizedClient() => sharedClient;

  /// 创建标准HTTP客户端（允许代理，共享实例）。
  ///
  /// 使用标准客户端，允许通过代理连接，这样服务器端的代理设置可以正常工作。
  static http.Client createDirectClient() => sharedClient;

  /// 关闭并释放共享客户端。
  ///
  /// 仅在应用退出或测试 teardown 时调用；下次请求会重新创建。
  static void close() {
    _sharedClient?.close();
    _sharedClient = null;
  }

  /// 获取适合当前平台的超时时长
  static Duration getOptimalTimeout() {
    if (Platform.isAndroid) {
      // Android需要更长的超时时间，因为网络栈可能较慢
      return const Duration(seconds: 20);
    } else if (Platform.isIOS) {
      // iOS网络栈更高效，可以使用较短超时
      return const Duration(seconds: 10);
    } else {
      // 其他平台使用中等超时
      return const Duration(seconds: 15);
    }
  }

  /// 获取适合当前平台的重试次数
  static int getOptimalRetries() {
    if (Platform.isAndroid) {
      // Android可能需要更多重试
      return 3;
    } else {
      return 2;
    }
  }

  /// 针对平台优化的GET请求
  static Future<http.Response> optimizedGet(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final client = sharedClient;
    final timeout = getOptimalTimeout();

    if (kDebugMode && Platform.isAndroid) {
      debugPrint('NetworkUtils: Android优化请求 - $uri');
      debugPrint('NetworkUtils: 超时设置 - ${timeout.inSeconds}秒');
    }

    final response = await client.get(uri, headers: headers).timeout(timeout);

    if (kDebugMode && Platform.isAndroid) {
      debugPrint('NetworkUtils: 请求完成 - 状态码: ${response.statusCode}');
    }

    return response;
  }

  /// 针对平台优化的POST请求
  static Future<http.Response> optimizedPost(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    if (kDebugMode && Platform.isAndroid) {
      debugPrint('NetworkUtils: Android优化POST请求 - $uri');
    }

    return sharedClient
        .post(
          uri,
          headers: headers,
          body: body,
          encoding: encoding,
        )
        .timeout(getOptimalTimeout());
  }

  /// 专门用于引用关系的POST请求（允许代理）
  static Future<http.Response> directPost(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) =>
      sharedClient
          .post(
            uri,
            headers: headers,
            body: body,
            encoding: encoding,
          )
          .timeout(getOptimalTimeout());

  /// 标准DELETE请求（允许代理）
  static Future<http.Response> directDelete(
    Uri uri, {
    Map<String, String>? headers,
  }) =>
      sharedClient
          .delete(
            uri,
            headers: headers,
          )
          .timeout(getOptimalTimeout());
}
