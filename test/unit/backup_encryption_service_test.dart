import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/backup_encryption_service.dart';

/// 改造前（页面内 `_encryptBytes` + `jsonEncode` 版）在固定
/// salt / iv / 迭代次数 / 时间戳 下产出的信封，逐字节留作兼容基线。
const String _goldenEnvelope =
    '{"InkPaperEncryptedBackup":true,"version":"2.0",'
    '"algorithm":"AES-256-CBC-HMAC-SHA256","kdf":"PBKDF2-HMAC-SHA256",'
    '"iterations":10000,"originalFormat":"ZIP",'
    '"salt":"AAECAwQFBgcICQoLDA0ODw==",'
    '"iv":"yMnKy8zNzs/Q0dLT1NXW1w==",'
    '"ciphertext":"4Vd6ZsgOrSu3HMaRXnzGHssJ8+V9facQokyvPZW45cV6AxUqTl0HpZYFiO6Z'
    'jywEhDbz78ozEAhGujriAPP4yAzZ8+LNoUKTOWy58XCjC9B65qfvTjWIVuh4qrVw/NI4TQ'
    'vJn7MQDHI8Jk3LpSKdwZxRH4+OR1BAg5w6dh5oFfGi9JOSuNLfI63/+NWw6PsAU6JaTva9'
    'jSAt5CJtF1snZVpDQWRE09/iLd4/ZY4aS0WLjH+Uq93JMzNQPUoRLyZMPnZsft39uBgT/S4'
    'HPIJVlUBEteJFI0r3aUYFx/R5fFuKO72FApP4N2WuxQjeJ3OErJqBWw2Pv3FckHw9hmslHg'
    '55OfDso4ev6KfN2Lrwa/gFpKIIEPErMlBM7TPrUnZFWrf8L9s0qJZl5t4z5WsvDA==",'
    '"mac":"ee7c74fa5e422b1bd1848a0ca0d88c8028eb53d94b2e2de84772704165f358e2",'
    '"timestamp":1700000000000}';

Uint8List _bytes(int length, {int seed = 7}) => Uint8List.fromList(
      List<int>.generate(length, (i) => (i * seed + 13) & 0xFF),
    );

void main() {
  late BackupEncryptionService service;
  final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));
  final iv = Uint8List.fromList(List<int>.generate(16, (i) => 200 + i));

  setUp(() {
    service = BackupEncryptionService();
  });

  /// 主 isolate 上每 3ms 走一次的定时器：被整段同步计算占住时一次都跑不到。
  Future<int> ticksDuring(Future<void> Function() body) async {
    var ticks = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 3), (_) => ticks++);
    try {
      await body();
    } finally {
      timer.cancel();
    }
    return ticks;
  }

  test('ENC-01 输出与改造前的 jsonEncode 版逐字节一致', () async {
    // 明文必须与生成基线时完全一致：0..255 循环 300 字节
    final sample = Uint8List.fromList(List<int>.generate(300, (i) => i & 0xFF));
    final envelope = await service.encryptToBytes(
      sample,
      'p@ss-中文',
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
      timestamp: 1700000000000,
    );

    expect(
      utf8.decode(envelope),
      _goldenEnvelope,
      reason: '字段顺序、base64 分块、PKCS7 补齐任何一处变了，老版本都解不开新包',
    );
  });

  test('ENC-02 往返拿回原文与格式', () async {
    final origin = _bytes(5000);
    final envelope = await service.encryptToBytes(
      origin,
      'correct horse',
      originalFormat: 'Markdown',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );

    final decoded = await service.decrypt(envelope, 'correct horse');
    expect(decoded.bytes, origin);
    expect(decoded.originalFormat, 'Markdown');
  });

  test('ENC-03 密码错误报固定文案', () async {
    final envelope = await service.encryptToBytes(
      _bytes(64),
      'right',
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );

    await expectLater(
      service.decrypt(envelope, 'wrong'),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('备份密码错误或文件已损坏'),
        ),
      ),
    );
  });

  test('ENC-04 密文被改动一个字节就校验失败', () async {
    final envelope = await service.encryptToBytes(
      _bytes(64),
      'pw',
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );
    final json = jsonDecode(utf8.decode(envelope)) as Map<String, dynamic>;
    final cipher = base64Decode(json['ciphertext'] as String);
    cipher[3] = cipher[3] ^ 0xFF;
    json['ciphertext'] = base64Encode(cipher);

    await expectLater(
      service.decrypt(
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
        'pw',
      ),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('备份密码错误或文件已损坏'),
        ),
      ),
    );
  });

  test('ENC-05 迭代次数低于下限直接拒收', () async {
    await expectLater(
      service.encryptToBytes(
        _bytes(32),
        'pw',
        originalFormat: 'ZIP',
        iterations: 1000,
        salt: salt,
        iv: iv,
      ),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('加密备份参数不安全'),
        ),
      ),
    );
  });

  test('ENC-06 v1 老包（只签 content）仍能解', () async {
    final plain = utf8.encode('老版本加密包');
    final envelope = jsonEncode({
      'InkPaperEncryptedBackup': true,
      'content': base64Encode(plain),
      'signature': Hmac(sha256, utf8.encode('pw')).convert(plain).toString(),
      'originalFormat': 'JSON',
    });

    final decoded = await service.decrypt(
      Uint8List.fromList(utf8.encode(envelope)),
      'pw',
    );
    expect(utf8.decode(decoded.bytes), '老版本加密包');
    expect(decoded.originalFormat, 'JSON');
  });

  test('ENC-07 looksEncrypted 只认外层标记', () async {
    final encrypted = await service.encryptToBytes(
      _bytes(16),
      'pw',
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );

    expect(service.looksEncrypted(encrypted), isTrue);
    expect(
      service.looksEncrypted(Uint8List.fromList([0x50, 0x4b, 3, 4])),
      isFalse,
    );
    expect(
      service.looksEncrypted(
        Uint8List.fromList(utf8.encode('{"InkPaperEncryptedBackup":false}')),
      ),
      isFalse,
    );
    expect(service.looksEncrypted(Uint8List(0)), isFalse);
  });

  test('ENC-08 跨多个 64KB 块的大样本往返一致', () async {
    // 200KB 会跨 4 个分块，且总长不是 3 的倍数：base64 的余数必须跨块带对
    final origin = _bytes(200 * 1024, seed: 17);
    final envelope = await service.encryptToBytes(
      origin,
      'pw',
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );

    expect((await service.decrypt(envelope, 'pw')).bytes, origin);
  });

  test('ENC-09 边界长度（0/1/15/16/17）补齐正确', () async {
    for (final length in [0, 1, 15, 16, 17, 63, 64, 65]) {
      final origin = _bytes(length);
      final envelope = await service.encryptToBytes(
        origin,
        'pw',
        originalFormat: 'TXT',
        iterations: 10000,
        salt: salt,
        iv: iv,
      );
      expect(
        (await service.decrypt(envelope, 'pw')).bytes,
        origin,
        reason: '长度 $length 的 PKCS7 补齐或去尾不对',
      );
    }
  });

  test('ENC-10 密钥派生不在主 isolate 跑（加密期间定时器照常触发）', () async {
    final ticks = await ticksDuring(() async {
      await service.encryptToBytes(
        _bytes(300),
        'pw',
        originalFormat: 'ZIP',
        iterations: 10000,
        salt: salt,
        iv: iv,
      );
    });

    expect(
      ticks,
      greaterThan(0),
      reason: '10000 次 PBKDF2 同步跑会整段占住主 isolate（本机约 100ms），'
          '这期间定时器一次都跑不到',
    );
  });

  test('ENC-11 解密同样不占住主 isolate', () async {
    final envelope = await service.encryptToBytes(
      _bytes(300),
      'pw',
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );

    final ticks = await ticksDuring(() async {
      await service.decrypt(envelope, 'pw');
    });

    expect(
      ticks,
      greaterThan(0),
      reason: '解密要先跑一遍同样的 PBKDF2，同样不能在主 isolate 上算',
    );
  });

  test('ENC-12 前缀探测与整段解析同结论，1MB 包跨块解密一致', () async {
    // 1MB 明文会跨 4 个 256KB 的解密块：分块 CBC 的链接与去尾都要对
    final origin = _bytes(1024 * 1024, seed: 3);
    final envelope = await service.encryptToBytes(
      origin,
      'pw',
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );
    expect(service.looksEncrypted(envelope), isTrue, reason: '自己写的信封');
    expect(
      (await service.decrypt(envelope, 'pw')).bytes,
      origin,
      reason: '分块解密跨了 4 个块',
    );

    // 标记不在开头（外部工具重排字段 / 多一个空白）：退回整段解析，结论不变
    for (final json in [
      '{"version":"2.0","InkPaperEncryptedBackup":true}',
      ' {"InkPaperEncryptedBackup":true}',
      '{\n  "InkPaperEncryptedBackup": true\n}',
    ]) {
      expect(
        service.looksEncrypted(Uint8List.fromList(utf8.encode(json))),
        isTrue,
        reason: json,
      );
    }

    expect(
      service.looksEncrypted(
        Uint8List.fromList(utf8.encode('{"InkPaperEncryptedBackup":false}')),
      ),
      isFalse,
      reason: '标记存在但值不是 true',
    );
  });
}
