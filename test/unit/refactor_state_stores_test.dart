import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/core/state/auth_store.dart';
import 'package:inkpaper/core/state/notes_store.dart';
import 'package:inkpaper/core/state/notion_store.dart';
import 'package:inkpaper/core/state/reminder_store.dart';
import 'package:inkpaper/core/state/webdav_store.dart';
import 'package:inkpaper/models/sort_order.dart';

void main() {
  group('STATE-CORE-005 各域 Store 初始状态', () {
    test('ST-01 AuthStore：未登录时 isLoggedIn 为 false，clear 幂等', () {
      final store = AuthStore();

      expect(store.user, isNull);
      expect(store.apiService, isNull);
      expect(store.isLoggedIn, isFalse);

      store.clear();
      expect(store.isLoggedIn, isFalse);
    });

    test('ST-02 NotesStore：集合/加载/分页/删除队列均为空默认值', () {
      final store = NotesStore();

      expect(store.notes, isEmpty);
      expect(store.isLoading, isFalse);
      expect(store.isInitialized, isFalse);
      expect(store.loadMoreCompleter, isNull);
      expect(store.totalNotesCount, 0);
      expect(store.lastLoadTime, isNull);
      expect(store.sortOrder, SortOrder.newest);
      expect(store.visibleNotesCache, isNull);
      expect(store.deleteQueue, isEmpty);
      expect(store.pendingDeleteIds, isEmpty);
      expect(store.isProcessingDelete, isFalse);
      expect(store.lastDeletedNote, isNull);
      expect(store.lastDeletedIndex, isNull);
    });

    test('ST-03 NotesStore：stopwatch 可重复读取同一实例', () {
      final store = NotesStore();

      expect(identical(store.loadStopwatch, store.loadStopwatch), isTrue);
      store.loadStopwatch.start();
      store.loadStopwatch.stop();
      expect(store.loadStopwatch.elapsed, isNotNull);
    });

    test('ST-04 WebDavStore：默认未配置服务与引擎，启动备份标记为 false', () {
      final store = WebDavStore();

      expect(store.service, isNull);
      expect(store.syncEngine, isNull);
      expect(store.backupTimer, isNull);
      expect(store.hasPerformedStartupBackup, isFalse);
      expect(store.config.serverUrl, isEmpty);
      expect(store.config.enabled, isFalse);
    });

    test('ST-05 NotionStore：服务实例非空且同步标记默认 false', () {
      final store = NotionStore();

      expect(store.syncService, isNotNull);
      expect(store.isSyncing, isFalse);
    });

    test('ST-06 ReminderStore：两个服务实例非空，未读公告数为 0', () {
      final store = ReminderStore();

      expect(store.reminderService, isNotNull);
      expect(store.appNotificationService, isNotNull);
      expect(store.appNotificationInitialized, isFalse);
      expect(store.unreadAnnouncementsCount, 0);
    });
  });
}
