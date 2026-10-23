// ============================================================
// Note.remoteId：本地 uuid 与服务端 uid 解耦后的序列化契约
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';

Note _makeNote({String? remoteId}) => Note(
      id: 'local_1700000000000_1',
      content: '内容',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      remoteId: remoteId,
    );

void main() {
  group('Note.remoteId', () {
    test('REMOTE-01 toMap/fromMap 往返保留 remote_id', () {
      final note = _makeNote(remoteId: 'uid-abc');
      expect(note.toMap()['remote_id'], 'uid-abc');

      final restored = Note.fromMap(note.toMap());
      expect(restored.id, note.id);
      expect(restored.remoteId, 'uid-abc');
    });

    test('REMOTE-02 未绑定服务端时 remote_id 为 null', () {
      final note = _makeNote();
      expect(note.toMap()['remote_id'], isNull);
      expect(Note.fromMap(note.toMap()).remoteId, isNull);
    });

    test('REMOTE-03 toJson 写 remoteId，fromJson 兼容 remoteId 与 remote_id', () {
      final note = _makeNote(remoteId: 'uid-abc');
      expect(note.toJson()['remoteId'], 'uid-abc');

      expect(
        Note.fromJson({'id': 'a', 'content': 'x', 'remoteId': 'uid-1'}).remoteId,
        'uid-1',
      );
      expect(
        Note.fromJson(
          {'id': 'a', 'content': 'x', 'remote_id': 'uid-2'},
        ).remoteId,
        'uid-2',
      );
    });

    test('REMOTE-04 copyWith 可写入与清除 remoteId', () {
      final note = _makeNote(remoteId: 'uid-old');
      expect(note.copyWith(remoteId: 'uid-new').remoteId, 'uid-new');
      expect(note.copyWith(clearRemoteId: true).remoteId, isNull);
      // 不传参数时保持不变
      expect(note.copyWith(content: '新内容').remoteId, 'uid-old');
      // id 不因 remoteId 变化而变
      expect(note.copyWith(remoteId: 'uid-new').id, note.id);
    });
  });
}
