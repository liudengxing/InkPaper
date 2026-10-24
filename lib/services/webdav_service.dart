import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inkpaper/models/webdav_config.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// WebDAV 请求失败。
///
/// webdav_client 底层是 dio，而 `DioException` 的 `toString()` 经常只有
/// 「DioException null」——类型、HTTP 状态码、内层错误全被丢掉，用户和日志
/// 都无从定位。这里把关键信息统一拼回来。
class WebDavException implements Exception {
  WebDavException(this.action, this.path, this.cause);

  final String action;
  final String path;
  final Object cause;

  @override
  String toString() {
    final details = _describeCause(cause);
    // 只留文件名：完整路径会把提示撑爆，手机上一行都显示不完。
    final name = path.split('/').last;
    return '$action $name 失败${details.isEmpty ? '' : '：$details'}';
  }
}

/// 是否是 gzip 内容（魔数 `1f 8b`）。用于兼容旧版明文备份。
bool isGzipPayload(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

String _describeCause(Object cause) {
  final parts = <String>[];
  try {
    // webdav_client 底层是 dio；这里用 dynamic 取字段，避免为一个日志
    // 描述新增 dio 直接依赖。
    final dynamic e = cause;
    // ignore: avoid_dynamic_calls
    final type = e.type?.toString();
    // ignore: avoid_dynamic_calls
    final status = e.response?.statusCode?.toString();
    // ignore: avoid_dynamic_calls
    final message = e.message?.toString();
    // ignore: avoid_dynamic_calls
    final inner = e.error?.toString();
    if (type != null && type.isNotEmpty) {
      parts.add(type.replaceFirst('DioExceptionType.', ''));
    }
    if (status != null) {
      parts.add('HTTP $status');
    }
    if (message != null && message.isNotEmpty) {
      parts.add(message);
    }
    if (inner != null && inner.isNotEmpty) {
      parts.add(inner);
    }
  } on Object {
    // 不是 dio 异常，或字段结构变了，退回原始描述
  }
  if (parts.isEmpty) {
    parts.add(cause.toString());
  }
  return parts.join('; ');
}

/// WebDAV 客户端服务
///
/// 提供与 WebDAV 服务器通信的基础功能
class WebDavService {
  webdav.Client? _client;
  WebDavConfig? _config;

  /// 本次会话里已确认存在的目录，避免每上传一个文件都 readDir 一次。
  /// 几十张图逐个检查目录会让备份在慢速 WebDAV 上卡死。
  final Set<String> _knownDirs = <String>{};

  /// 初始化客户端
  Future<void> initialize(WebDavConfig config) async {
    if (!config.isValid) {
      throw Exception('WebDAV 配置无效');
    }

    _config = config;
    _client = webdav.newClient(
      config.serverUrl,
      user: config.username,
      password: config.password,
    );

    // 设置超时：移动网络上行常见只有几 KB/s，几百 KB 的备份要传几分钟，
    // 30/60 秒会稳定触发 sendTimeout。连接超时保持 30 秒（无响应就该报错）。
    _client!.setConnectTimeout(30000);
    _client!.setSendTimeout(300000);
    _client!.setReceiveTimeout(300000);
  }

  /// 测试连接
  Future<bool> testConnection() async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }
      final config = _config;
      if (config == null) {
        throw Exception('WebDAV 配置缺失');
      }

      // 尝试列出根目录
      await _client!.readDir('/');
      final probePath =
          '${config.fullSyncPath}.InkPaper-connection-${DateTime.now().millisecondsSinceEpoch}.txt';
      await uploadFile(probePath, 'InkPaper WebDAV connection test');
      try {
        await deleteFile(probePath);
      } on Object {
        // 删除探测文件是清理动作；连接测试只要求目录可写。
      }

      return true;
    } on Object {
      return false;
    }
  }

  /// 创建文件夹
  Future<void> createFolder(String path) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      await _ensureDirectoryExists(path);
    } on Object catch (e) {
      // 如果文件夹已存在，不抛出异常
      if (!e.toString().contains('405') &&
          !e.toString().contains('already exists')) {
        rethrow;
      }
    }
  }

  /// 检查文件/文件夹是否存在
  Future<bool> exists(String path) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      // 🔧 大厂标准：使用 ping 方法检查文件是否存在（适用于文件和目录）
      // ping 方法会发送 HEAD 请求，比 readDir 更轻量且适用于文件
      await _client!.ping();

      // 尝试获取文件/目录的属性信息
      try {
        // 如果是目录（以 / 结尾），使用 readDir
        if (path.endsWith('/')) {
          await _client!.readDir(path);
        } else {
          // 如果是文件，尝试读取文件列表中是否包含该文件
          final parentPath = path.substring(0, path.lastIndexOf('/') + 1);
          final fileName = path.substring(path.lastIndexOf('/') + 1);
          final files = await _client!.readDir(parentPath);

          // 检查文件是否在列表中
          return files.any((file) => file.name == fileName);
        }
        return true;
      } on Object {
        return false;
      }
    } on Object {
      return false;
    }
  }

  /// 递归创建文件夹路径（已确认存在过的目录会被记住，不重复请求）
  Future<void> _ensureDirectoryExists(String path) async {
    if (path.isEmpty || path == '/') {
      return;
    }

    // 移除末尾的斜杠
    final cleanPath =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;

    if (_knownDirs.contains(cleanPath)) {
      return;
    }

    // 检查路径是否已存在
    if (await exists('$cleanPath/')) {
      _knownDirs.add(cleanPath);
      return;
    }

    // 分割路径
    final parts = cleanPath.split('/').where((p) => p.isNotEmpty).toList();
    var currentPath = '/';

    // 递归创建每一级目录
    for (final part in parts) {
      currentPath += '$part/';
      final key = currentPath.substring(0, currentPath.length - 1);
      if (_knownDirs.contains(key)) {
        continue;
      }
      try {
        // 检查目录是否存在
        if (!await exists(currentPath)) {
          await _client!.mkdir(currentPath);
        }
        _knownDirs.add(key);
      } on Object catch (e) {
        // 如果是405错误（目录已存在），忽略
        if (e.toString().contains('405') ||
            e.toString().contains('already exists')) {
          _knownDirs.add(key);
        } else {
          rethrow;
        }
      }
    }
  }

  /// 上传文件（文本）
  ///
  /// 内容先 gzip 再上传：笔记备份动辄几百 KB，移动网络上行只有几 KB/s 时
  /// 明文上传会直接撞发送超时。下载侧按文件头自动识别是否压缩，旧备份
  /// （明文 JSON）仍然可以正常读取。
  Future<void> uploadFile(String remotePath, String content) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      final bytes = Uint8List.fromList(gzip.encode(utf8.encode(content)));

      // 自动创建所有必需的父目录
      final parentDir = remotePath.substring(0, remotePath.lastIndexOf('/'));
      if (parentDir.isNotEmpty && parentDir != '/') {
        await _ensureDirectoryExists('$parentDir/');
      }

      await _client!.write(remotePath, bytes);
    } on Object catch (e) {
      throw WebDavException('上传', remotePath, e);
    }
  }

  /// 上传二进制文件（图片等）
  Future<void> uploadBinaryFile(String remotePath, List<int> bytes) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      // 自动创建所有必需的父目录
      final parentDir = remotePath.substring(0, remotePath.lastIndexOf('/'));
      if (parentDir.isNotEmpty && parentDir != '/') {
        await _ensureDirectoryExists('$parentDir/');
      }

      // 转换为 Uint8List
      final uint8List = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      await _client!.write(remotePath, uint8List);
    } on Object catch (e) {
      throw WebDavException('上传', remotePath, e);
    }
  }

  /// 下载文件（文本），自动识别 gzip 压缩内容
  Future<String> downloadFile(String remotePath) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      final bytes = await _client!.read(remotePath);
      final raw = isGzipPayload(bytes) ? gzip.decode(bytes) : bytes;

      return utf8.decode(raw);
    } on Object catch (e) {
      throw WebDavException('下载', remotePath, e);
    }
  }

  /// 下载二进制文件（图片等）
  Future<List<int>> downloadBinaryFile(String remotePath) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      final bytes = await _client!.read(remotePath);

      return bytes;
    } on Object catch (e) {
      throw WebDavException('下载', remotePath, e);
    }
  }

  /// 删除文件
  Future<void> deleteFile(String remotePath) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      await _client!.remove(remotePath);
    } on Object catch (e) {
      throw WebDavException('删除', remotePath, e);
    }
  }

  /// 列出文件夹内容
  Future<List<webdav.File>> listFiles(String path) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      final list = await _client!.readDir(path);

      return list;
    } on Object catch (e) {
      throw WebDavException('列出目录', path, e);
    }
  }

  /// 获取文件信息
  Future<webdav.File?> getFileInfo(String path) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      final list = await _client!.readDir(path);
      if (list.isNotEmpty) {
        return list.first;
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// 移动/重命名文件
  Future<void> moveFile(String fromPath, String toPath) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      await _client!.copy(fromPath, toPath, true);
      await _client!.remove(fromPath);
    } on Object {
      rethrow;
    }
  }

  /// 复制文件
  Future<void> copyFile(
    String fromPath,
    String toPath, {
    bool overwrite = false,
  }) async {
    try {
      if (_client == null) {
        throw Exception('客户端未初始化');
      }

      await _client!.copy(fromPath, toPath, overwrite);
    } on Object {
      rethrow;
    }
  }

  /// 获取当前配置
  WebDavConfig? get config => _config;

  /// 释放资源
  void dispose() {
    _client = null;
    _config = null;
    _knownDirs.clear();
  }
}
