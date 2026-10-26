import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/webdav_config.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'read') {
        return 'secret';
      }
      if (call.method == 'readAll') {
        return <String, String>{};
      }
      return null;
    });
  });

  test('保存后重新加载仍保留自动备份开关与时机', () async {
    final first = AppProvider();
    await first.updateWebDavConfig(
      const WebDavConfig(
        serverUrl: 'https://dav.jianguoyun.com/dav/',
        username: 'u',
        password: 'secret',
        syncPath: '/inkpaper/',
        autoSync: true,
        autoSyncInterval: 0,
      ),
      skipInitialize: true,
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('webdav_config');
    expect(raw, isNotNull);
    expect(raw, contains('"autoSync":true'));
    expect(raw, contains('"autoSyncInterval":0'));

    final second = AppProvider();
    await second.loadWebDavConfig();
    expect(second.webDavConfig.autoSync, isTrue);
    expect(second.webDavConfig.autoSyncInterval, 0);
    expect(second.webDavConfig.enabled, isFalse);
  });

  test('只切自动备份开关也立即落盘，且不动服务器地址和上次备份时间', () async {
    final lastSync = DateTime(2026, 10, 20, 8, 30);
    final first = AppProvider();
    await first.updateWebDavConfig(
      WebDavConfig(
        serverUrl: 'https://dav.jianguoyun.com/dav/',
        username: 'u',
        password: 'secret',
        syncPath: '/inkpaper/',
        lastSyncTime: lastSync,
      ),
      skipInitialize: true,
    );

    await first.updateWebDavBackupPolicy(
      autoSync: true,
      autoSyncInterval: 0,
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('webdav_config');
    expect(raw, contains('"autoSync":true'));
    expect(raw, contains('"autoSyncInterval":0'));
    expect(raw, contains('https://dav.jianguoyun.com/dav/'));
    expect(raw, contains(lastSync.toIso8601String()));

    final second = AppProvider();
    await second.loadWebDavConfig();
    expect(second.webDavConfig.autoSync, isTrue);
    expect(second.webDavConfig.autoSyncInterval, 0);
    expect(second.webDavConfig.serverUrl, 'https://dav.jianguoyun.com/dav/');
    expect(second.webDavConfig.lastSyncTime, lastSync);
  });
}
