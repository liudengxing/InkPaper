import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/webdav_service.dart';

void main() {
  group('isGzipPayload', () {
    test('gzip 压缩后的备份能被识别', () {
      final payload = gzip.encode(utf8.encode('{"notes":[]}'));
      expect(isGzipPayload(payload), isTrue);
    });

    test('旧版明文 JSON 不会被误判', () {
      expect(isGzipPayload(utf8.encode('{"notes":[]}')), isFalse);
    });

    test('过短或只有一个魔数字节时不算 gzip', () {
      expect(isGzipPayload(const []), isFalse);
      expect(isGzipPayload(const [0x1f]), isFalse);
      expect(isGzipPayload(const [0x1f, 0x00]), isFalse);
    });
  });
}
