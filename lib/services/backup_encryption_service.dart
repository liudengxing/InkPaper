import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
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
///
/// **整条链路都不占住 UI isolate**：100000 次 PBKDF2 是没法拆的循环，送进后台
/// isolate 跑；AES 与 MAC 本来就能按块推进，攒够一帧的活就让出一次事件循环。
/// 40MB 的包以前会让界面（转圈动画、返回手势）连续冻 2 秒上下；信封解析改成
/// 字节扫描后，最长一次阻塞从 280–366ms 降到 180–190ms（加密侧是 80ms）。
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

  /// 信封里标记键的字节形态（含两侧引号），供 [looksEncrypted] 做字节级搜索。
  static final Uint8List _markerKeyBytes = Uint8List.fromList(
    utf8.encode('"$envelopeMarker"'),
  );

  /// 默认 PBKDF2 迭代次数（新导出的包都用它）。
  static const int defaultIterations = 100000;

  /// 低于这个迭代次数的包一律拒收，防止旧包或篡改后的参数把强度拉到无意义。
  static const int minIterations = 10000;

  /// 攒够这么多毫秒的活就让出一次事件循环。
  ///
  /// 每次让出要付约 1ms 的调度开销（本机实测 40MB 加密：一直不让 3379ms，按
  /// 时间让 3615ms），所以按时间攒而不要按字节硬切 —— 界面照样是一帧一让，开销
  /// 却只跟总耗时成正比，不随块变小而暴涨。取 16ms，正好一个 60Hz 帧。
  static const int _yieldSliceMs = 16;

  /// 分块处理时的块大小（16 的倍数）。
  static const int _ioChunkBytes = 256 * 1024;

  /// 加密整包字节，返回可直接写成 `.enc` 的 UTF-8 信封字节。
  ///
  /// [salt] / [iv] / [timestamp] 只为测试固定取值，生产一律留空由安全随机源生成。
  ///
  /// 整条链路是流式的：明文按 64KB 块做 CBC 加密 → 边喂 HMAC 边转 base64 →
  /// 直接写进输出缓冲。信封里的字段顺序与旧的 `jsonEncode` 完全一致，输出逐
  /// 字节相同，所以老版本仍能解开新导出的包。
  ///
  /// 密钥派生在后台 isolate 跑，对称加密与 base64 转换按时间让出事件循环，调用
  /// 方可以放心地把它当成普通异步操作（界面上的进度指示器不会冻住）。
  Future<Uint8List> encryptToBytes(
    Uint8List data,
    String password, {
    required String originalFormat,
    int iterations = defaultIterations,
    Uint8List? salt,
    Uint8List? iv,
    int? timestamp,
  }) async {
    final saltBytes = salt ?? _secureRandomBytes(16);
    final ivBytes = iv ?? _secureRandomBytes(16);
    final keys = await _deriveKeys(
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
    await _streamCbcEncrypt(
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
  ///
  /// 完整信封有几十 MB，为了认一个标记把整段 `utf8.decode` + `jsonDecode` 一遍
  /// 要多花约 150ms 与两份副本（40MB 包实测：多出 56MB 字符串和一张 Map），而
  /// 随后的 [decrypt] 还要再解一次。
  ///
  /// 写入方（含 v1 老版本）一律以 `{"InkPaperEncryptedBackup":true` 开头，所以先看
  /// 开头 512 字节；认不出再判断整段里有没有这个键（外部工具重排过字段时标记会
  /// 被推到 512 字节之后），命中才退回整段解析，保证判定结果与整段解析一致。
  ///
  /// 后两步都刻意避开整段 `utf8.decode`：没有这个键的普通 ZIP / 明文 JSON 只要
  /// 一次线性字节扫描就能否掉，40MB 的包不会为此多出 56MB 字符串。
  bool looksEncrypted(Uint8List input) {
    const probeBytes = 512;
    final end = input.length < probeBytes ? input.length : probeBytes;
    final head = utf8.decode(
      Uint8List.sublistView(input, 0, end),
      allowMalformed: true,
    );
    if (head.startsWith('{"$envelopeMarker":true')) {
      return true;
    }
    // 信封是一层 JSON 对象，去掉前导空白后必须以 `{` 开头。ZIP（`PK`）、纯文本、
    // 图片都在这里一步否掉，不必扫完整段。
    if (!_startsLikeJsonObject(input)) {
      return false;
    }
    if (!_containsMarkerKey(input)) {
      return false;
    }
    return _markerIsTrue(input);
  }

  /// 跳过开头的 UTF-8 BOM 与前导空白后是否以 `{` 开头（信封一定是 JSON 对象）。
  ///
  /// BOM 只可能在文件最开头出现一次（`EF BB BF`），有些编辑器另存、或经脚本搬运
  /// 后会写进去。这里必须显式跳过：`utf8.decode` 会自己吞掉 BOM，所以
  /// `{"InkPaperEncryptedBackup":true` 紧跟 BOM 时前缀快速路径照常命中；但 BOM
  /// 之后还有空格或换行时，解码结果以空白开头、快速路径失配，只能落到本方法，
  /// 而本方法看的是原始字节，首字节 `0xEF` 不是 `0x7B`，合法信封就被判成明文了。
  static bool _startsLikeJsonObject(Uint8List input) {
    var i = 0;
    if (input.length >= 3 &&
        input[0] == 0xEF &&
        input[1] == 0xBB &&
        input[2] == 0xBF) {
      i = 3;
    }
    for (; i < input.length; i++) {
      final byte = input[i];
      if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
        continue;
      }
      return byte == 0x7B;
    }
    return false;
  }

  /// 整段字节里是否出现 `"InkPaperEncryptedBackup"` 这个键（含两侧引号）。
  ///
  /// 用字节级子串搜索而不是 `head.contains`：后者只扫前 512 字节，字段重排过的
  /// 合法备份会在这里被误判成明文，导入时直接跳过密码与解密流程。搜索不分配
  /// 内存，且只对以 `{` 开头的输入才走到。
  static bool _containsMarkerKey(Uint8List input) {
    final needle = _markerKeyBytes;
    final last = input.length - needle.length;
    if (last < 0) {
      return false;
    }
    final first = needle[0];
    for (var i = 0; i <= last; i++) {
      if (input[i] != first) {
        continue;
      }
      var j = 1;
      while (j < needle.length && input[i + j] == needle[j]) {
        j++;
      }
      if (j == needle.length) {
        return true;
      }
    }
    return false;
  }

  bool _markerIsTrue(Uint8List input) {
    try {
      final decoded = jsonDecode(utf8.decode(input, allowMalformed: true));
      return decoded is Map && decoded[envelopeMarker] == true;
    } on Object {
      return false;
    }
  }

  /// 用密码解开信封，返回明文与原格式。
  ///
  /// 密码错、文件损坏、参数不安全都抛 [Exception]（消息直接给用户看）。
  ///
  /// v2 信封先走 [_scanV2Envelope] 的单趟字节扫描：只记下 `salt` / `iv` /
  /// `ciphertext` 在原始字节里的位置，密文直接从字节区间解 base64。认不出是
  /// v2 时（v1 老包、字段类型异常、JSON 有语法问题）才退回整段 `jsonDecode`，
  /// 那条路径给出的结果与改造前完全一致。
  /// 测试用：累计有多少次 v2 信封真的走了字节扫描的快速路径。
  ///
  /// 快速路径认不出时会静默退回整段解析，结果仍然正确 —— 光看结果无法判断
  /// 优化到底有没有生效，所以用计数把「有没有走快路」暴露出来。
  static int debugFastPathHits = 0;

  /// 测试用：把快速路径命中计数清零。
  static void debugResetFastPathHits() {
    debugFastPathHits = 0;
  }

  Future<DecryptedBackupContent> decrypt(
    Uint8List input,
    String password,
  ) async {
    final scan = _scanV2Envelope(input);
    if (scan != null) {
      final salt = _decodeBase64Slice(input, scan.salt);
      final iv = _decodeBase64Slice(input, scan.iv);
      final cipherText = _decodeBase64Slice(input, scan.cipherText);
      if (salt != null && iv != null && cipherText != null) {
        debugFastPathHits++;
        return _decryptV2Parts(
          salt: salt,
          iv: iv,
          cipherText: cipherText,
          mac: scan.mac,
          iterations: scan.iterations,
          originalFormat: scan.originalFormat,
          password: password,
        );
      }
    }

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

  /// 整段解析出来的 v2 信封，转成与快速路径同一份参数。
  Future<DecryptedBackupContent> _decryptV2(
    Map<String, dynamic> envelope,
    String password,
  ) {
    return _decryptV2Parts(
      salt: _decodeRequiredBase64(envelope, 'salt'),
      iv: _decodeRequiredBase64(envelope, 'iv'),
      cipherText: _decodeRequiredBase64(envelope, 'ciphertext'),
      mac: envelope['mac']?.toString() ?? '',
      iterations: int.tryParse(envelope['iterations']?.toString() ?? '') ??
          defaultIterations,
      originalFormat: envelope['originalFormat']?.toString(),
      password: password,
    );
  }

  /// v2 的公共解密流程：校验 MAC → CBC 解密。两条解析路径都汇到这里。
  Future<DecryptedBackupContent> _decryptV2Parts({
    required Uint8List salt,
    required Uint8List iv,
    required Uint8List cipherText,
    required String mac,
    required int iterations,
    required String? originalFormat,
    required String password,
  }) async {
    if (mac.isEmpty) {
      throw Exception('加密备份格式不完整');
    }

    final keys = await _deriveKeys(
      password: password,
      salt: salt,
      iterations: iterations,
    );
    final expectedMac = (await _macDigest(
      keys.macKey,
      salt,
      iv,
      cipherText,
    ))
        .toString();
    if (!_constantTimeEquals(expectedMac, mac)) {
      throw Exception('备份密码错误或文件已损坏');
    }

    final plainBytes = await _streamCbcDecrypt(
      cipherText,
      pc.CBCBlockCipher(pc.AESEngine())
        ..init(
          false,
          pc.ParametersWithIV(pc.KeyParameter(keys.encryptionKey), iv),
        ),
    );
    return DecryptedBackupContent(
      bytes: plainBytes,
      originalFormat: originalFormat,
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

  /// 单趟扫一遍 v2 信封，只记下大字段在原始字节里的区间。
  ///
  /// 40MB 的包整段 `utf8.decode` + `jsonDecode` 要 150ms、多占 107MB，密文再
  /// 转成 `String` 交给 `base64Decode` 又是 200ms、多占 80MB —— 而 `salt` /
  /// `iv` / `ciphertext` 其实只需要「从哪到哪」。这里按 JSON 语法逐键走一遍，
  /// 记下这三个字段的字节区间，小字段（版本、迭代次数、MAC、原格式）当场读成
  /// 值，密文全程不落地成字符串。
  ///
  /// 任何一处不符合预期（不是 v2、字段类型不对、JSON 结构有毛病、末尾还有
  /// 垃圾）都返回 null，由调用方退回整段 `jsonDecode`，错误行为与改造前一致。
  static _V2EnvelopeScan? _scanV2Envelope(Uint8List input) {
    var i = 0;
    if (input.length >= 3 &&
        input[0] == 0xEF &&
        input[1] == 0xBB &&
        input[2] == 0xBF) {
      i = 3;
    }
    i = _skipJsonWhitespace(input, i);
    if (i >= input.length || input[i] != 0x7B) {
      return null;
    }
    i++;

    var sawMarker = false;
    var sawVersion = false;
    var iterations = defaultIterations;
    String? originalFormat;
    String? mac;
    _ByteSlice? salt;
    _ByteSlice? iv;
    _ByteSlice? cipherText;

    while (true) {
      i = _skipJsonWhitespace(input, i);
      if (i >= input.length) {
        return null;
      }
      if (input[i] == 0x7D) {
        i++;
        break;
      }
      if (input[i] != 0x22) {
        return null;
      }
      final keyEnd = _jsonStringEnd(input, i);
      if (keyEnd < 0) {
        return null;
      }
      // 键名带转义（`\u006friginalFormat`）或非 ASCII 时，按原始字节比不出与
      // 标准解析相同的键，直接退回整段解析，别在这里猜。
      for (var k = i + 1; k < keyEnd; k++) {
        if (input[k] == 0x5C || input[k] >= 0x80) {
          return null;
        }
      }
      final key = String.fromCharCodes(input, i + 1, keyEnd);
      i = _skipJsonWhitespace(input, keyEnd + 1);
      if (i >= input.length || input[i] != 0x3A) {
        return null;
      }
      i = _skipJsonWhitespace(input, i + 1);
      if (i >= input.length) {
        return null;
      }

      switch (key) {
        case envelopeMarker:
          final valueEnd = _skipJsonValue(input, i);
          if (valueEnd < 0 || !_sliceEqualsAscii(input, i, valueEnd, 'true')) {
            return null;
          }
          sawMarker = true;
          i = valueEnd;
        case 'version':
          final slice = _readJsonString(input, i);
          if (slice == null ||
              !_sliceEqualsAscii(
                input,
                slice.start,
                slice.end,
                currentVersion,
              )) {
            return null;
          }
          sawVersion = true;
          i = slice.end + 1;
        case 'iterations':
          final valueEnd = _skipJsonValue(input, i);
          if (valueEnd < 0) {
            return null;
          }
          final parsed = int.tryParse(
            String.fromCharCodes(input, i, valueEnd),
          );
          if (parsed == null) {
            return null;
          }
          iterations = parsed;
          i = valueEnd;
        case 'originalFormat':
          final slice = _readJsonString(input, i);
          if (slice == null) {
            return null;
          }
          final format = _sliceToJsonString(input, slice);
          if (format == null) {
            return null;
          }
          originalFormat = format;
          i = slice.end + 1;
        case 'mac':
          final slice = _readJsonString(input, i);
          if (slice == null) {
            return null;
          }
          final digest = _sliceToJsonString(input, slice);
          if (digest == null) {
            return null;
          }
          mac = digest;
          i = slice.end + 1;
        case 'salt':
          final slice = _readJsonString(input, i);
          if (slice == null) {
            return null;
          }
          salt = slice;
          i = slice.end + 1;
        case 'iv':
          final slice = _readJsonString(input, i);
          if (slice == null) {
            return null;
          }
          iv = slice;
          i = slice.end + 1;
        case 'ciphertext':
          final slice = _readJsonString(input, i);
          if (slice == null) {
            return null;
          }
          cipherText = slice;
          i = slice.end + 1;
        default:
          final valueEnd = _skipJsonValue(input, i);
          if (valueEnd < 0) {
            return null;
          }
          i = valueEnd;
      }

      i = _skipJsonWhitespace(input, i);
      if (i >= input.length) {
        return null;
      }
      if (input[i] == 0x2C) {
        i++;
        continue;
      }
      if (input[i] == 0x7D) {
        i++;
        break;
      }
      return null;
    }

    // 顶层对象之后只允许空白；多出任何字节都交给整段解析去报错。
    if (_skipJsonWhitespace(input, i) != input.length) {
      return null;
    }
    if (!sawMarker ||
        !sawVersion ||
        salt == null ||
        iv == null ||
        cipherText == null ||
        mac == null ||
        mac.isEmpty) {
      return null;
    }
    return _V2EnvelopeScan(
      salt: salt,
      iv: iv,
      cipherText: cipherText,
      mac: mac,
      iterations: iterations,
      originalFormat: originalFormat,
    );
  }

  /// 把 [slice] 指向的 base64 字节直接解成字节，中间不经过 `String`。
  ///
  /// 任何不合规（长度不是 4 的倍数、有非法字符、`=` 位置不对）都返回 null，
  /// 让调用方退回 `base64Decode`，抛出的异常与改造前一致。
  static Uint8List? _decodeBase64Slice(Uint8List input, _ByteSlice slice) {
    final length = slice.end - slice.start;
    if (length <= 0 || length % 4 != 0) {
      return null;
    }

    // 56M 字符的内层循环，逐字符走区间判断比查表慢一截，这里用表。
    final table = _base64Lookup;
    final groups = length ~/ 4;
    final out = Uint8List(groups * 3);
    var offset = 0;
    for (var group = 0; group < groups; group++) {
      final base = slice.start + group * 4;
      final b0 = input[base];
      final b1 = input[base + 1];
      final b2 = input[base + 2];
      final b3 = input[base + 3];
      if (group != groups - 1) {
        // `=` 只允许出现在最后一组。
        if (b0 == 0x3D || b1 == 0x3D || b2 == 0x3D || b3 == 0x3D) {
          return null;
        }
        final v0 = table[b0];
        final v1 = table[b1];
        final v2 = table[b2];
        final v3 = table[b3];
        if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0) {
          return null;
        }
        final bits = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
        out[offset++] = (bits >> 16) & 0xFF;
        out[offset++] = (bits >> 8) & 0xFF;
        out[offset++] = bits & 0xFF;
        continue;
      }
      final v0 = table[b0];
      if (v0 < 0) {
        return null;
      }
      // `=` 最多两个，`x===` 不是合法 base64，交给回退路径去报错。
      if (b1 == 0x3D) {
        return null;
      }
      final v1 = table[b1];
      if (v1 < 0) {
        return null;
      }
      var padding = 0;
      var v2 = 0;
      var v3 = 0;
      if (b2 == 0x3D) {
        if (b3 != 0x3D) {
          return null;
        }
        padding = 2;
      } else {
        v2 = table[b2];
        if (v2 < 0) {
          return null;
        }
        if (b3 == 0x3D) {
          padding = 1;
        } else {
          v3 = table[b3];
          if (v3 < 0) {
            return null;
          }
        }
      }
      final bits = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
      out[offset++] = (bits >> 16) & 0xFF;
      if (padding < 2) {
        out[offset++] = (bits >> 8) & 0xFF;
      }
      if (padding < 1) {
        out[offset++] = bits & 0xFF;
      }
    }
    if (offset == out.length) {
      return out;
    }
    return Uint8List.sublistView(out, 0, offset);
  }

  /// base64 字母表查表：非法字符为 -1。
  static final Int8List _base64Lookup = _buildBase64Lookup();

  static Int8List _buildBase64Lookup() {
    final table = Int8List(256)..fillRange(0, 256, -1);
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    for (var i = 0; i < alphabet.length; i++) {
      table[alphabet.codeUnitAt(i)] = i;
    }
    return table;
  }

  static int _skipJsonWhitespace(Uint8List input, int start) {
    var i = start;
    while (i < input.length) {
      final byte = input[i];
      if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
        i++;
        continue;
      }
      break;
    }
    return i;
  }

  /// [start] 指向开引号，返回闭引号的位置；字符串没闭合返回 -1。
  static int _jsonStringEnd(Uint8List input, int start) {
    var i = start + 1;
    while (i < input.length) {
      final byte = input[i];
      if (byte == 0x5C) {
        i += 2;
        continue;
      }
      if (byte == 0x22) {
        return i;
      }
      i++;
    }
    return -1;
  }

  /// 读一个 JSON 字符串，返回不含两侧引号的区间；不是字符串返回 null。
  static _ByteSlice? _readJsonString(Uint8List input, int start) {
    if (start >= input.length || input[start] != 0x22) {
      return null;
    }
    final end = _jsonStringEnd(input, start);
    if (end < 0) {
      return null;
    }
    return _ByteSlice(start + 1, end);
  }

  /// 把 [slice] 里的 JSON 字符串内容按 UTF-8 解成 Dart 字符串。
  ///
  /// 返回 null 表示这段内容无法确认与整段 `jsonDecode` 等价，调用方必须退回
  /// 标准解析路径：
  /// - 含 `\` 转义（`\u4e2d`、`\"`、`\/` 之类），转义规则交给标准解析；
  /// - 含未转义的控制字符，标准 JSON 里本就是语法错误，快路不该悄悄收下。
  ///
  /// 注意不能写成 `String.fromCharCodes`：那是把 UTF-8 字节逐个当字符，
  /// `'笔记格式'` 会解成 `'ç¬\x94è®°æ ¼å¼'`。
  static String? _sliceToJsonString(Uint8List input, _ByteSlice slice) {
    for (var i = slice.start; i < slice.end; i++) {
      final byte = input[i];
      if (byte == 0x5C || byte < 0x20) {
        return null;
      }
    }
    return utf8.decode(
      Uint8List.sublistView(input, slice.start, slice.end),
      allowMalformed: true,
    );
  }

  /// 跳过一个 JSON 值，返回它之后的位置；结构坏了返回 -1。
  static int _skipJsonValue(Uint8List input, int start) {
    if (start >= input.length) {
      return -1;
    }
    final byte = input[start];
    if (byte == 0x22) {
      final end = _jsonStringEnd(input, start);
      return end < 0 ? -1 : end + 1;
    }
    if (byte == 0x7B || byte == 0x5B) {
      var depth = 0;
      var i = start;
      while (i < input.length) {
        final current = input[i];
        if (current == 0x22) {
          final end = _jsonStringEnd(input, i);
          if (end < 0) {
            return -1;
          }
          i = end + 1;
          continue;
        }
        if (current == 0x7B || current == 0x5B) {
          depth++;
        } else if (current == 0x7D || current == 0x5D) {
          depth--;
          if (depth == 0) {
            return i + 1;
          }
        }
        i++;
      }
      return -1;
    }

    var i = start;
    while (i < input.length) {
      final current = input[i];
      if (current == 0x2C ||
          current == 0x7D ||
          current == 0x20 ||
          current == 0x09 ||
          current == 0x0A ||
          current == 0x0D) {
        break;
      }
      i++;
    }
    return i > start ? i : -1;
  }

  static bool _sliceEqualsAscii(
    Uint8List input,
    int start,
    int end,
    String text,
  ) {
    if (end - start != text.length) {
      return false;
    }
    for (var i = 0; i < text.length; i++) {
      if (input[start + i] != text.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }

  Uint8List _secureRandomBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }

  /// 派生两把密钥。PBKDF2 送进后台 isolate 跑。
  ///
  /// 100000 次迭代本机 JIT 约 0.86s（手机更慢），这段循环没有任何可以拆的边界，
  /// 留在主 isolate 就是连续冻住整个界面 —— 实测占满期间 50ms 的定时器一次都跑
  /// 不到。跨 isolate 只传密码、16 字节 salt 与迭代次数，连开三次幂等验证下来
  /// 峰值内存没有可测量的增长。
  Future<BackupKeyMaterial> _deriveKeys({
    required String password,
    required Uint8List salt,
    required int iterations,
  }) async {
    if (iterations < minIterations) {
      throw Exception('加密备份参数不安全');
    }

    final derived = await Isolate.run(
      () => _pbkdf2KeyBytes(password, salt, iterations),
    );
    return BackupKeyMaterial(
      encryptionKey: Uint8List.sublistView(derived, 0, 32),
      macKey: Uint8List.sublistView(derived, 32, 64),
    );
  }

  /// MAC 覆盖「固定头 + salt + iv + 密文」，按块喂给 HMAC。
  ///
  /// 以前是 `Uint8List.fromList([...header, ...salt, ...iv, ...cipherText])`：
  /// spread 一个 `Uint8List` 会先展开成 growable `List<int>`（每个元素 8 字节），
  /// 40MB 密文光这一步就要 320MB，再拷进 `Uint8List` 又是一份。分块喂进去，
  /// 峰值只跟块大小有关；块之间同样让出事件循环。
  Future<Digest> _macDigest(
    Uint8List key,
    Uint8List salt,
    Uint8List iv,
    Uint8List cipherText,
  ) async {
    final digestSink = _DigestSink();
    final sink = Hmac(sha256, key).startChunkedConversion(digestSink);
    sink.add(utf8.encode(macHeader));
    sink.add(salt);
    sink.add(iv);

    var offset = 0;
    final since = Stopwatch()..start();
    while (offset < cipherText.length) {
      final end = min(offset + _ioChunkBytes, cipherText.length);
      sink.add(Uint8List.sublistView(cipherText, offset, end));
      offset = end;
      if (offset < cipherText.length &&
          since.elapsedMilliseconds >= _yieldSliceMs) {
        since.reset();
        await Future<void>.delayed(Duration.zero);
      }
    }
    sink.close();
    return digestSink.digest;
  }

  /// 逐块做 CBC 加密（PKCS7 补齐），每块交给 [emit]，不在内存里留整份密文。
  ///
  /// 攒够 [_yieldSliceMs] 就让出一次事件循环：40MB 的包一次算完要 1.3 秒，这
  /// 期间界面上的转圈动画与返回手势都是停的。
  Future<void> _streamCbcEncrypt(
    Uint8List input,
    pc.CBCBlockCipher cipher,
    void Function(Uint8List chunk) emit,
  ) async {
    const blockSize = 16;
    const chunkBytes = 64 * 1024;
    final out = Uint8List(chunkBytes + blockSize);
    final tail = Uint8List(blockSize);

    var offset = 0;
    final since = Stopwatch()..start();
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
      if (offset < input.length && since.elapsedMilliseconds >= _yieldSliceMs) {
        since.reset();
        await Future<void>.delayed(Duration.zero);
      }
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

  /// 逐块做 CBC 解密并去掉 PKCS7 补齐，写进预分配的整块缓冲。
  ///
  /// 与加密侧同构，块之间让出事件循环。没用 `PaddedBlockCipherImpl.process`：
  /// 它只能整段一次算完，40MB 实测要连续占住主线程 1.3 秒。
  Future<Uint8List> _streamCbcDecrypt(
    Uint8List cipherText,
    pc.CBCBlockCipher cipher,
  ) async {
    const blockSize = 16;
    if (cipherText.isEmpty || cipherText.length % blockSize != 0) {
      throw Exception('加密备份数据已损坏');
    }

    final out = Uint8List(cipherText.length);
    var offset = 0;
    final since = Stopwatch()..start();
    while (offset < cipherText.length) {
      var take = cipherText.length - offset;
      if (take > _ioChunkBytes) {
        take = _ioChunkBytes;
      }
      for (var i = 0; i < take; i += blockSize) {
        cipher.processBlock(cipherText, offset + i, out, offset + i);
      }
      offset += take;
      if (offset < cipherText.length &&
          since.elapsedMilliseconds >= _yieldSliceMs) {
        since.reset();
        await Future<void>.delayed(Duration.zero);
      }
    }

    final pad = out[out.length - 1];
    if (pad < 1 || pad > blockSize) {
      throw Exception('加密备份数据已损坏');
    }
    final plainLength = out.length - pad;
    for (var i = plainLength; i < out.length; i++) {
      if (out[i] != pad) {
        throw Exception('加密备份数据已损坏');
      }
    }
    return Uint8List.sublistView(out, 0, plainLength);
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

/// PBKDF2-HMAC-SHA256，连续导出 64 字节（前 32 加密、后 32 做 MAC）。
///
/// 放在顶层而不是实例方法：`Isolate.run` 送的闭包只捕获密码、salt 与迭代次数，
/// 不会把整个服务对象（里面有 `Random.secure()`，不能跨 isolate 发送）拖过去。
Uint8List _pbkdf2KeyBytes(String password, Uint8List salt, int iterations) {
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
  return Uint8List.fromList(output.sublist(0, 64));
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

/// 原始字节里的半开区间 `[start, end)`。
class _ByteSlice {
  const _ByteSlice(this.start, this.end);

  final int start;
  final int end;
}

/// v2 信封单趟扫描的结果：大字段只留区间，小字段已经读成值。
class _V2EnvelopeScan {
  const _V2EnvelopeScan({
    required this.salt,
    required this.iv,
    required this.cipherText,
    required this.mac,
    required this.iterations,
    required this.originalFormat,
  });

  final _ByteSlice salt;
  final _ByteSlice iv;
  final _ByteSlice cipherText;
  final String mac;
  final int iterations;
  final String? originalFormat;
}
