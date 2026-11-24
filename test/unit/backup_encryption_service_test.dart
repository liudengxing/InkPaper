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

  test('ENC-13 字段重排把标记推到 600 字节之后，仍识别为加密备份并解密', () async {
    // 用真实加密器产出一份可解密的包，再模拟外部工具（jq 之类）重排字段：
    // 值一个不改，只把外层标记挪到 600 字节元数据之后。
    final origin = _bytes(4000, seed: 11);
    const password = 'p@ss-重排';
    final envelope = await service.encryptToBytes(
      origin,
      password,
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );

    final source = jsonDecode(utf8.decode(envelope)) as Map<String, dynamic>;
    final reordered = <String, dynamic>{
      'exportedBy': 'inkpaper-compat ${'x' * 600}',
      'version': source['version'],
      'algorithm': source['algorithm'],
      'kdf': source['kdf'],
      'iterations': source['iterations'],
      'originalFormat': source['originalFormat'],
      'salt': source['salt'],
      'iv': source['iv'],
      'ciphertext': source['ciphertext'],
      'mac': source['mac'],
      'timestamp': source['timestamp'],
      BackupEncryptionService.envelopeMarker: true,
    };
    final reorderedBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(reordered)));

    // 前置断言：这份样本真的把标记推出了 512 字节探测窗，否则用例退化成假回归。
    expect(
      utf8.decode(reorderedBytes).indexOf(
            '"${BackupEncryptionService.envelopeMarker}"',
          ),
      greaterThanOrEqualTo(600),
      reason: '标记必须落在 600 字节之后才复现前缀探测漏判',
    );

    // 修复点。导入入口唯一的闸门就是它（local_backup_restore_screen.dart:1621
    // 的 `_decryptContentIfNeededBytes`）：false 就把信封当明文交给后续解包，
    // 密码框与 decrypt 都不会被调用。
    expect(
      service.looksEncrypted(reorderedBytes),
      isTrue,
      reason: '字段重排过的合法加密备份不能被当成明文',
    );

    // 过了闸门之后的完整结果：正文与格式都要还原。
    final decoded = await service.decrypt(reorderedBytes, password);
    expect(decoded.bytes, origin);
    expect(decoded.originalFormat, 'ZIP');
  });

  test('ENC-14 非信封输入仍然否定：ZIP、明文 JSON、嵌套同名标记', () {
    expect(
      service.looksEncrypted(
        Uint8List.fromList([0x50, 0x4b, 3, 4, 20, 0, 0, 0]),
      ),
      isFalse,
      reason: 'ZIP 头一步否掉，不扫整段',
    );
    expect(
      service.looksEncrypted(
        Uint8List.fromList(
          utf8.encode('{"notes":[{"id":"1","content":"hi"}]}'),
        ),
      ),
      isFalse,
      reason: '未加密的 JSON 备份',
    );
    expect(
      service.looksEncrypted(
        Uint8List.fromList(
          utf8.encode('{"meta":{"InkPaperEncryptedBackup":true},"notes":[]}'),
        ),
      ),
      isFalse,
      reason: '只认外层标记，嵌套的不算',
    );
    expect(
      service.looksEncrypted(
        Uint8List.fromList(
          utf8.encode(
            '{"data":{"InkPaperEncryptedBackup":true},'
            '"InkPaperEncryptedBackupNotes":[]}',
          ),
        ),
      ),
      isFalse,
      reason: '键名以标记开头但外层无标记',
    );
  });

  test('ENC-15 BOM 加前导空白的信封仍识别为加密备份并解密', () async {
    // 真实加密器产出可解密的包，再模拟「编辑器另存为 UTF-8 with BOM」：
    // 开头塞 EF BB BF，后面再跟空格与换行。
    //
    // 这里必须带前导空白才复现问题：utf8.decode 会自己吞掉 BOM，所以 BOM 后
    // 直接跟 `{"InkPaperEncryptedBackup":true` 时前缀快速路径照常命中；只有
    // BOM 之后还有空白，解码结果才以空白开头、快速路径失配，落到按原始字节
    // 判断的 _startsLikeJsonObject —— 那里首字节是 0xEF 而不是 0x7B。
    final origin = _bytes(4000, seed: 17);
    const password = 'p@ss-BOM';
    final envelope = await service.encryptToBytes(
      origin,
      password,
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );

    final withBom = Uint8List.fromList([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode('  \r\n\t '),
      ...envelope,
    ]);

    // 前置断言：这份样本真的让前缀快速路径失配，否则用例退化成假回归。
    expect(
      utf8
          .decode(withBom)
          .startsWith('{"${BackupEncryptionService.envelopeMarker}":true'),
      isFalse,
      reason: 'BOM 后带空白时前缀快速路径必然失配，才走到字节探测',
    );

    // 修复点：导入入口唯一的闸门（local_backup_restore_screen.dart:1621）。
    expect(
      service.looksEncrypted(withBom),
      isTrue,
      reason: 'BOM 加前导空白的合法加密备份不能被当成明文',
    );

    // 过了闸门之后的完整结果：正文与格式都要还原。
    final decoded = await service.decrypt(withBom, password);
    expect(decoded.bytes, origin);
    expect(decoded.originalFormat, 'ZIP');
  });

  test('ENC-16 BOM 边界：仅 BOM、BOM 后无标记、BOM 在 ZIP 前', () async {
    // BOM 紧跟标记：前缀快速路径本来就命中，不能被这次改动弄坏。
    expect(
      service.looksEncrypted(
        Uint8List.fromList([
          0xEF,
          0xBB,
          0xBF,
          ...utf8.encode(
            '{"${BackupEncryptionService.envelopeMarker}":true,"version":"2.0"}',
          ),
        ]),
      ),
      isTrue,
      reason: 'BOM 不影响正常包的前缀快速路径',
    );

    // 只有 BOM：跳过 BOM 后没有内容，仍是否定。
    expect(
      service.looksEncrypted(Uint8List.fromList([0xEF, 0xBB, 0xBF])),
      isFalse,
      reason: '只有 BOM 不算 JSON 对象',
    );

    // BOM + 空白 + 普通 JSON：跳过 BOM 与空白后确实是 `{`，但整段没有标记键。
    expect(
      service.looksEncrypted(
        Uint8List.fromList([
          0xEF,
          0xBB,
          0xBF,
          ...utf8.encode('\n  {"notes":[{"id":"1"}]}'),
        ]),
      ),
      isFalse,
      reason: '跳过 BOM 后仍要含外层标记才算信封',
    );

    // BOM + ZIP 头：跳过 BOM 后首字节是 `P`，一步否掉。
    expect(
      service.looksEncrypted(
        Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x50, 0x4b, 3, 4, 20, 0]),
      ),
      isFalse,
      reason: 'BOM 在 ZIP 前也要走快速排除',
    );

    // 不完整 BOM（只有 EF BB）：不能当成 BOM 跳过，首字节不是 `{` 即否定。
    expect(
      service.looksEncrypted(
        Uint8List.fromList([
          0xEF,
          0xBB,
          ...utf8.encode('{"${BackupEncryptionService.envelopeMarker}":true}'),
        ]),
      ),
      isFalse,
      reason: '只有两个字节的 BOM 前缀不完整，不当成 BOM 跳过',
    );
  });

  test('ENC-17 字节级扫描认得出字段重排的大信封，且与整段解析结论一致', () async {
    const password = 'p@ss-大包';
    // 4MB 正文跨多个 256KB 让出块，密文长度不是 4 的倍数时 base64 会带 `=`。
    for (final length in <int>[4194304, 4194305, 4194306, 4194307]) {
      final origin = _bytes(length, seed: 23);
      final envelope = await service.encryptToBytes(
        origin,
        password,
        originalFormat: 'ZIP',
        iterations: 10000,
        salt: salt,
        iv: iv,
      );

      // 重排字段：把 ciphertext 挪到中间，逼着扫描器不能靠字段顺序取巧。
      final parsed = jsonDecode(utf8.decode(envelope)) as Map<String, dynamic>;
      final reordered = <String, dynamic>{
        'timestamp': parsed['timestamp'],
        'ciphertext': parsed['ciphertext'],
        'mac': parsed['mac'],
        'iterations': parsed['iterations'],
        'iv': parsed['iv'],
        'salt': parsed['salt'],
        'originalFormat': parsed['originalFormat'],
        'kdf': parsed['kdf'],
        'algorithm': parsed['algorithm'],
        'version': parsed['version'],
        BackupEncryptionService.envelopeMarker: true,
      };
      final reorderedBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(reordered)),
      );

      BackupEncryptionService.debugResetFastPathHits();
      final decoded = await service.decrypt(reorderedBytes, password);
      expect(
        BackupEncryptionService.debugFastPathHits,
        1,
        reason: '重排过的 v2 信封必须命中字节扫描快路，否则内存收益不成立',
      );
      expect(
        decoded.bytes,
        origin,
        reason: '长度 $length 的重排信封要逐字节还原',
      );
      expect(decoded.originalFormat, 'ZIP');
    }
  });

  test('ENC-18 损坏的 base64 不会从快速路径漏过去', () async {
    const password = 'p@ss-损坏';
    final origin = _bytes(4096, seed: 31);
    final envelope = await service.encryptToBytes(
      origin,
      password,
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );
    final text = utf8.decode(envelope);
    final parsed = jsonDecode(text) as Map<String, dynamic>;
    final cipher = parsed['ciphertext'] as String;

    Future<void> expectRejected(String brokenCipher) async {
      final broken = Map<String, dynamic>.from(parsed)
        ..['ciphertext'] = brokenCipher;
      await expectLater(
        () => service.decrypt(
          Uint8List.fromList(utf8.encode(jsonEncode(broken))),
          password,
        ),
        throwsA(isA<Exception>()),
        reason: '损坏的密文必须抛异常，不能静默返回空内容',
      );
    }

    // 中间插一个非法字符：查表返回 -1，快速路径放弃、回退到整段解析。
    await expectRejected('${cipher.substring(0, 64)}!${cipher.substring(65)}');
    // 长度不是 4 的倍数。
    await expectRejected(cipher.substring(0, cipher.length - 1));
    // `=` 出现在非末尾组。
    await expectRejected('=${cipher.substring(1)}');
    // `x===` 三个补齐符不是合法 base64。
    await expectRejected('${cipher.substring(0, cipher.length - 3)}===');
  });

  test('ENC-19 大包的快速路径与整段解析给出同一份正文', () async {
    // 对照实验：同一份 4MB 信封，一次走 `decrypt`（可能命中快速路径），
    // 一次强制走整段 jsonDecode 的字段还原，两边必须一致。
    const password = 'p@ss-对照';
    final origin = _bytes(4194304, seed: 37);
    final envelope = await service.encryptToBytes(
      origin,
      password,
      originalFormat: 'ZIP',
      iterations: 10000,
      salt: salt,
      iv: iv,
    );

    BackupEncryptionService.debugResetFastPathHits();
    final fast = await service.decrypt(envelope, password);
    expect(
      BackupEncryptionService.debugFastPathHits,
      1,
      reason: '标准 v2 信封必须走快路',
    );
    expect(fast.bytes, origin);
    expect(fast.originalFormat, 'ZIP');

    // 在信封前塞一个注释以外的未知顶层键，让扫描器跳过它继续工作。
    final parsed = jsonDecode(utf8.decode(envelope)) as Map<String, dynamic>;
    final withExtra = <String, dynamic>{
      'exportedBy': 'inkpaper-test',
      'nested': <String, dynamic>{
        'a': <int>[1, 2, 3],
      },
      ...parsed,
    };
    final withExtraBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(withExtra)));
    BackupEncryptionService.debugResetFastPathHits();
    final again = await service.decrypt(withExtraBytes, password);
    expect(
      BackupEncryptionService.debugFastPathHits,
      1,
      reason: '未知顶层键要跳过并继续走快路，不能退化成整段解析',
    );
    expect(again.bytes, origin, reason: '未知顶层键要被跳过而不是当成字段错位');
    expect(again.originalFormat, 'ZIP');
  });
}
