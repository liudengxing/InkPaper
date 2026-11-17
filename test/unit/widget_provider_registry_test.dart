import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 桌面组件有两处必须同时登记：
///
/// - `AndroidManifest.xml` 的 receiver —— 决定组件能不能被添加到桌面；
/// - `InkPaperWidgetProvider.kt` 的 `inkPaperWidgetProviders` —— 决定组件
///   会不会跟着快照更新重绘。
///
/// 只写 manifest 不写登记表，组件能拖到桌面上，但数据永远停在添加那一刻。
/// 1.1.115 的月统计「一片空白」就是这么来的：四个统计组件都不在通知名单里。
/// 这个测试把两份名单钉在一起，以后加组件忘了补登记会直接红。
void main() {
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  const registryPath = 'android/app/src/main/kotlin/com/didichou/inkpaper/'
      'InkPaperWidgetProvider.kt';

  Set<String> providersInManifest(String source) {
    final names = <String>{};
    for (final match in RegExp(
      r'<receiver[^>]*?\sandroid:name="\.(\w+)"',
      dotAll: true,
    ).allMatches(source)) {
      final name = match.group(1)!;
      if (name.endsWith('WidgetProvider')) {
        names.add(name);
      }
    }
    return names;
  }

  Set<String> providersInRegistry(String source) {
    final start = source.indexOf('internal val inkPaperWidgetProviders');
    if (start < 0) {
      return <String>{};
    }
    final end = source.indexOf(')', start);
    final block =
        end < 0 ? source.substring(start) : source.substring(start, end);
    return RegExp(r'(InkPaper\w+WidgetProvider)::class\.java')
        .allMatches(block)
        .map((match) => match.group(1)!)
        .toSet();
  }

  test('WS-R01 桌面组件登记表与 manifest 的 receiver 完全一致', () {
    final manifest = File(manifestPath).readAsStringSync();
    final registry = File(registryPath).readAsStringSync();

    final declared = providersInManifest(manifest);
    final registered = providersInRegistry(registry);

    expect(declared, isNotEmpty, reason: 'manifest 里没解析到任何组件，正则可能失效了');
    expect(registered, isNotEmpty, reason: '登记表里没解析到任何组件，正则可能失效了');
    expect(
      registered.difference(declared),
      isEmpty,
      reason: '登记表里有 manifest 没注册的组件',
    );
    expect(
      declared.difference(registered),
      isEmpty,
      reason: '这些组件注册了 manifest 却没进登记表，快照更新时不会重绘',
    );
  });
}
