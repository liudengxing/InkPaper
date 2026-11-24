import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;

/// 解密后的备份内容。
class DecryptedBackupContent {
  const DecryptedBackupContent({required this.bytes, this.originalFormat});

  /// 明文（ZIP 包或其他格式的原始字节）。
  final Uint8List bytes;

  /// 加密时记录的原格式（`ZIP` / `JSON` / `Markdown` / `TXT`）。
  final String? originalFormat;
}

/// PBKDF2 导出的两把密钥。
class BackupKeyMaterial {
  const BackupKeyMaterial({required this.encryptionKey, required this.macKey});

  final Uint8List encryptionKey;
  final Uint8List macKey;
}

/// 加密备份的信封编解码。
///
/// 当前格式（version 2.0）是一层 JSON 信封：`salt`、`iv`、`ciphertext`、
/// `mac` 全部 base64，正文用 AES-256-CBC 加密、HMAC-SHA256 做完整性校验。
/// 老版本（没有 `version` 字段）只对 base64 的 `content` 做一次 HMAC，仍要能读。
///
/// 这里只关心字节与密码，不碰文件选择和 UI；密码输入框留在页面。
class BackupEncryptionService {
  BackupEncryptionService({DateTime Function()? now, Random? random})
      : _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  final DateTime Function() _now;
  final Random _random;

  static const String envelopeMarker = 'InkPaperEncryptedBackup';
  static const String algorithm = 'AES-256-CBC-HMAC-SHA256';
  static const String kdfName = 'PBKDF2-HMAC-SHA256';
  static const String currentVersion = '2.0';
  static const String macHeader = 'InkPaperEncryptedBackupV2';

  /// 默认 PBKDF2 迭代次数（新导出的包都用它）。
  static const int defaultIterations = 100000;

  /// 低于这个迭代次数的包一律拒收，防止旧包或篡改后的参数把强度拉到无意义。
  static const int minIterations = 10000;

  /// 加密整包字节，返回可直接写成 `.enc` 的 UTF-8 信封字节。
  ///
  /// [salt] / [iv] / [timestamp] 只为测试固定取值，生产一律留空由安全随机源生成。
  ///
  /// 整条链路是流式的：明文按 64KB 块做 CBC 加密 → 边喂 HMAC 边转 base64 →
  /// 直接写进输出缓冲。信封里的字段顺序与旧的 `jsonEncode` 完全一致，输出逐
  /// 字节相同，所以老版本仍能解开新导出的包。
  Uint8List encryptToBytes(
    Uint8List data,
    String password, {
    required String originalFormat,
    int iterations = defaultIterations,
    Uint8List? salt,
    Uint8List? iv,
    int? timestamp,
  }) {
    final saltBytes = salt ?? _secureRandomBytes(16);
    final ivBytes = iv ?? _secureRandomBytes(16);
    final keys = _deriveKeys(
      password: password,
      salt: saltBytes,
      iterations: iterations,
    );

    final builder = BytesBuilder();
    builder.add(
      utf8.encode(
        '{"$envelopeMarker":true,"version":"$currentVersion",'
        '"algorithm":"$algorithm","kdf":"$kdfName",'
        '"iterations":$iterations,'
        '"originalFormat":${jsonEncode(originalFormat)},'
        '"salt":"',
      ),
    );
    builder.add(utf8.encode(base64Encode(saltBytes)));
    builder.add(utf8.encode('","iv":"'));
    builder.add(utf8.encode(base64Encode(ivBytes)));
    builder.add(utf8.encode('","ciphertext":"'));

    final digestSink = _DigestSink();
    final macSink =
        Hmac(sha256, keys.macKey).startChunkedConversion(digestSink);
    macSink.add(utf8.encode(macHeader));
    macSink.add(saltBytes);
    macSink.add(ivBytes);

    final base64Writer = _Base64StreamWriter(builder);
    _streamCbcEncrypt(
      data,
      pc.CBCBlockCipher(pc.AESEngine())
        ..init(
          true,
          pc.ParametersWithIV(pc.KeyParameter(keys.encryptionKey), ivBytes),
        ),
      (chunk) {
        macSink.add(chunk);
        base64Writer.add(chunk);
      },
    );
    base64Writer.close();
    macSink.close();

    builder.add(
      utf8.encode(
        '","mac":"${digestSink.digest}",'
        '"timestamp":${timestamp ?? _now().millisecondsSinceEpoch}}',
      ),
    );
    return builder.takeBytes();
  }

  /// 这段字节是不是加密信封（只看外层标记，不解密）。
  bool looksEncrypted(Uint8List input) {
    try {
      final decoded = jsonDecode(utf8.decode(input, allowMalformed: true));
      return decoded is Map && decoded[envelopeMarker] == true;
    } on Object {
      return false;
    }
  }

  /// 用 [password] 解开信封，返回明文与原格式。
  ///
  /// 密码错、文件损坏、参数不安全都抛 [Exception]（消息直接给用户看）。
  DecryptedBackupContent decrypt(Uint8List input, String password) {
    final decoded = jsonDecode(utf8.decode(input, allowMalformed: true));
    if (decoded is! Map<String, dynamic> || decoded[envelopeMarker] != true) {
      throw Exception('加密备份格式不完整');
    }

    final version = decoded['version']?.toString() ?? '1.0';
    if (version == currentVersion) {
      return _decryptV2(decoded, password);
    }
    return _decryptLegacy(decoded, password);
  }

  DecryptedBackupContent _decryptV2(
    Map<String, dynamic> envelope,
    String password,
  ) {
    final salt = _decodeRequiredBase64(envelope, 'salt');
    final iv = _decodeRequiredBase64(envelope, 'iv');
    final cipherText = _decodeRequiredBase64(envelope, 'ciphertext');
    final mac = envelope['mac']?.toString();
    final iterations = int.tryParse(envelope['iterations']?.toString() ?? '') ??
        defaultIterations;
    if (mac == null || mac.isEmpty) {
      throw Exception('加密备份格式不完整');
    }

    final keys = _deriveKeys(
      password: password,
      salt: salt,
      iterations: iterations,
    );
    final expectedMac = _macDigest(
      keys.macKey,
      salt,
      iv,
      cipherText,
    ).toString();
    if (!_constantTimeEquals(expectedMac, mac)) {
      throw Exception('备份密码错误或文件已损坏');
    }

    final plainBytes = _aesCbcCrypt(
      input: cipherText,
      key: keys.encryptionKey,
      iv: iv,
      encrypt: false,
    );
    return DecryptedBackupContent(
      bytes: plainBytes,
      originalFormat: envelope['originalFormat']?.toString(),
    );
  }

  /// 老包：只有 base64 的 `content` 与一个 HMAC(密码) 签名。
  DecryptedBackupContent _decryptLegacy(
    Map<String, dynamic> envelope,
    String password,
  ) {
    final encodedContent = envelope['content']?.toString();
    final signature = envelope['signature']?.toString();
    if (encodedContent == null || signature == null) {
      throw Exception('加密备份格式不完整');
    }

    final rawBytes = base64Decode(encodedContent);
    final expectedDigest =
        Hmac(sha256, utf8.encode(password)).convert(rawBytes);
    if (expectedDigest.toString() != signature) {
      throw Exception('备份密码错误或文件已损坏');
    }

    return DecryptedBackupContent(
      bytes: Uint8List.fromList(rawBytes),
      originalFormat: envelope['originalFormat']?.toString(),
    );
  }

  Uint8List _decodeRequiredBase64(Map<String, dynamic> envelope, String key) {
    final value = envelope[key]?.toString();
    if (value == null || value.isEmpty) {
      throw Exception('加密备份格式不完整');
    }
    return Uint8List.fromList(base64Decode(value));
  }

  Uint8List _secureRandomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }

  BackupKeyMaterial _deriveKeys({
    required String password,
    required Uint8List salt,
    required int iterations,
  }) {
    if (iterations < minIterations) {
      throw Exception('加密备份参数不安全');
    }

    final passwordBytes = utf8.encode(password);
    final output = <int>[];
    var blockIndex = 1;
    while (output.length < 64) {
      final block = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
      block[salt.length] = (blockIndex >> 24) & 0xff;
      block[salt.length + 1] = (blockIndex >> 16) & 0xff;
      block[salt.length + 2] = (blockIndex >> 8) & 0xff;
      block[salt.length + 3] = blockIndex & 0xff;

      var u = Hmac(sha256, passwordBytes).convert(block).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iterations; i++) {
        u = Hmac(sha256, passwordBytes).convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      output.addAll(t);
      blockIndex++;
    }

    return BackupKeyMaterial(
      encryptionKey: Uint8List.fromList(output.sublist(0, 32)),
      macKey: Uint8List.fromList(output.sublist(32, 64)),
    );
  }

  /// MAC 覆盖「固定头 + salt + iv + 密文」，按块喂给 HMAC。
  ///
  /// 以前是 `Uint8List.fromList([...header, ...salt, ...iv, ...cipherText])`：
  /// spread 一个 `Uint8List` 会先展开成 growable `List<int>`（每个元素 8 字节），
  /// 40MB 密文光这一步就要 320MB，再拷进 `Uint8List` 又是一份。分块喂进去，
  /// 峰值只跟块大小有关。
  Digest _macDigest(
    Uint8List key,
    Uint8List salt,
    Uint8List iv,
    Uint8List cipherText,
  ) {
    final digestSink = _DigestSink();
    final sink = Hmac(sha256, key).startChunkedConversion(digestSink);
    sink.add(utf8.encode(macHeader));
    sink.add(salt);
    sink.add(iv);
    sink.add(cipherText);
    sink.close();
    return digestSink.digest;
  }

  /// 逐块做 CBC 加密（PKCS7 补齐），每块交给 [emit]，不在内存里留整份密文。
  void _streamCbcEncrypt(
    Uint8List input,
    pc.CBCBlockCipher cipher,
    void Function(Uint8List chunk) emit,
  ) {
    const blockSize = 16;
    const chunkBytes = 64 * 1024;
    final out = Uint8List(chunkBytes + blockSize);
    final tail = Uint8List(blockSize);

    var offset = 0;
    while (input.length - offset >= blockSize) {
      var take = input.length - offset;
      if (take > chunkBytes) {
        take = chunkBytes;
      }
      take -= take % blockSize;
      for (var i = 0; i < take; i += blockSize) {
        cipher.processBlock(input, offset + i, out, i);
      }
      emit(Uint8List.sublistView(out, 0, take));
      offset += take;
    }

    // 末尾不足一块：PKCS7 补齐（正好整块时补一整块 0x10）
    final rest = input.length - offset;
    final pad = blockSize - rest;
    tail.fillRange(0, blockSize, pad);
    if (rest > 0) {
      tail.setRange(0, rest, input, offset);
    }
    cipher.processBlock(tail, 0, out, 0);
    emit(Uint8List.sublistView(out, 0, blockSize));
  }

  Uint8List _aesCbcCrypt({
    required Uint8List input,
    required Uint8List key,
    required Uint8List iv,
    required bool encrypt,
  }) {
    final cipher = pc.PaddedBlockCipherImpl(
      pc.PKCS7Padding(),
      pc.CBCBlockCipher(pc.AESEngine()),
    );
    cipher.init(
      encrypt,
      pc.PaddedBlockCipherParameters(
        pc.ParametersWithIV(pc.KeyParameter(key), iv),
        null,
      ),
    );
    return cipher.process(input);
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// 分块 base64：攒够 3 字节就编一段写出去，尾部余数留到 [close]。
///
/// `base64Encode` 只接受整段字节，直接对 40MB 密文调用会多出一份 53MB 的
/// String；按 3 的倍数切块编码，`=` 填充只会出现在最后一块，拼接结果与整段
/// 编码完全一致。
class _Base64StreamWriter {
  _Base64StreamWriter(this._sink);

  final BytesBuilder _sink;
  final Uint8List _carry = Uint8List(3);
  int _carryLength = 0;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    var start = 0;
    if (_carryLength > 0) {
      final need = 3 - _carryLength;
      if (chunk.length < need) {
        _carry.setRange(_carryLength, _carryLength + chunk.length, chunk);
        _carryLength += chunk.length;
        return;
      }
      _carry.setRange(_carryLength, 3, chunk, 0);
      _sink.add(utf8.encode(base64Encode(_carry)));
      start = need;
      _carryLength = 0;
    }

    final usable = ((chunk.length - start) ~/ 3) * 3;
    if (usable > 0) {
      _sink.add(
        utf8.encode(
          base64Encode(Uint8List.sublistView(chunk, start, start + usable)),
        ),
      );
      start += usable;
    }

    final rest = chunk.length - start;
    if (rest > 0) {
      _carry.setRange(0, rest, chunk, start);
      _carryLength = rest;
    }
  }

  void close() {
    if (_carryLength > 0) {
      _sink.add(
        utf8.encode(
          base64Encode(Uint8List.sublistView(_carry, 0, _carryLength)),
        ),
      );
      _carryLength = 0;
    }
  }
}

/// 接住分块 HMAC 的最后一次 `add`。
class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get digest => _value ?? (throw StateError('HMAC 没有产出摘要'));

  @override
  void add(Digest data) {
    _value = data;
  }

  @override
  void close() {}
}
