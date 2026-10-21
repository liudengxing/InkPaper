import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/services/database_service.dart';
import 'package:inkpaper/utils/network_utils.dart';

void main() {
  group('A-06 NetworkUtils 共享客户端', () {
    test('NU-01 createOptimizedClient / createDirectClient 返回同一实例', () {
      final a = NetworkUtils.createOptimizedClient();
      final b = NetworkUtils.createDirectClient();

      expect(identical(a, b), isTrue);
      expect(identical(a, NetworkUtils.sharedClient), isTrue);
    });

    test('NU-02 close 后重新获取会新建实例', () {
      final before = NetworkUtils.sharedClient;
      NetworkUtils.close();
      final after = NetworkUtils.sharedClient;

      expect(identical(before, after), isFalse);

      NetworkUtils.close();
    });
  });

  group('A-07 备份 JSON 解码（compute 后台解析）', () {
    test('BD-01 正常备份：返回 notes 数组内的每个对象', () {
      final notes = decodeBackupNotesJson(
        '{"notes":[{"id":"a","content":"x"},{"id":"b","content":"y"}]}',
      );

      expect(notes, hasLength(2));
      expect(notes.first['id'], 'a');
      expect(notes.last['content'], 'y');
    });

    test('BD-02 缺少 notes 字段时抛 Invalid backup file format', () {
      expect(
        () => decodeBackupNotesJson('{"other":[]}'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Invalid backup file format'),
          ),
        ),
      );
    });

    test('BD-03 notes 不是数组时抛 Invalid backup file format', () {
      expect(
        () => decodeBackupNotesJson('{"notes":{}}'),
        throwsA(isA<Exception>()),
      );
    });

    test('BD-04 非对象元素被跳过，只保留 Map', () {
      final notes = decodeBackupNotesJson(
        '{"notes":[{"id":"a"},1,"x",null]}',
      );

      expect(notes, hasLength(1));
      expect(notes.single['id'], 'a');
    });

    test('BD-05 空数组返回空列表', () {
      expect(decodeBackupNotesJson('{"notes":[]}'), isEmpty);
    });
  });
}
