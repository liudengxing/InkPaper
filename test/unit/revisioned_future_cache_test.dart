// ============================================================
// OPT-03 · 按版本号缓存的 Future（RevisionedFutureCache）
//
// 探索索引的缓存状态机：版本号不变就复用，变了就重建，构建期间又变
// 就再建一次（有上限），失败不缓存，并发调用共享同一次构建。
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/utils/revisioned_future_cache.dart';

void main() {
  test('RFC-01 版本号不变时复用结果，不重复构建', () async {
    const revision = 0;
    var builds = 0;
    final cache = RevisionedFutureCache<String>(
      revision: () => revision,
      build: () async {
        builds++;
        return 'build-$builds';
      },
    );

    expect(await cache.value, 'build-1');
    expect(cache.isPrimed, isTrue);
    expect(await cache.value, 'build-1');
    expect(builds, 1, reason: '切排序/翻页只改视图状态，不该重建索引');
  });

  test('RFC-02 版本号变化后重建', () async {
    var revision = 0;
    var builds = 0;
    final cache = RevisionedFutureCache<String>(
      revision: () => revision,
      build: () async {
        builds++;
        return 'build-$builds';
      },
    );

    expect(await cache.value, 'build-1');
    revision = 1;
    expect(cache.isPrimed, isFalse);
    expect(await cache.value, 'build-2');
    expect(builds, 2);
  });

  test('RFC-03 构建期间版本号变化，丢弃过期结果再建一次', () async {
    var revision = 0;
    var builds = 0;
    final cache = RevisionedFutureCache<String>(
      revision: () => revision,
      build: () async {
        builds++;
        if (builds == 1) {
          // 模拟构建期间用户又保存了一条笔记
          revision = 1;
        }
        return 'build-$builds';
      },
    );

    expect(await cache.value, 'build-2');
    expect(builds, 2);
  });

  test('RFC-04 持续变化时最多重建 maxAttempts 次，不无限重试', () async {
    var revision = 0;
    var builds = 0;
    final cache = RevisionedFutureCache<String>(
      revision: () => revision,
      maxAttempts: 2,
      build: () async {
        builds++;
        revision++;
        return 'build-$builds';
      },
    );

    expect(await cache.value, 'build-2');
    expect(builds, 2);
  });

  test('RFC-05 构建失败不缓存，下一次重新构建', () async {
    var builds = 0;
    final cache = RevisionedFutureCache<int>(
      revision: () => 0,
      build: () async {
        builds++;
        if (builds == 1) {
          throw StateError('boom');
        }
        return 7;
      },
    );

    await expectLater(cache.value, throwsStateError);
    expect(cache.isPrimed, isFalse);
    expect(await cache.value, 7);
    expect(builds, 2);
  });

  test('RFC-06 并发调用共享同一次构建', () async {
    var builds = 0;
    final cache = RevisionedFutureCache<int>(
      revision: () => 0,
      build: () async {
        builds++;
        await Future<void>.delayed(Duration.zero);
        return 42;
      },
    );

    final results = await Future.wait([
      cache.value,
      cache.value,
      cache.value,
    ]);
    expect(results, [42, 42, 42]);
    expect(builds, 1);
  });

  test('RFC-07 clear 后下一次调用必然重建', () async {
    var builds = 0;
    final cache = RevisionedFutureCache<String>(
      revision: () => 0,
      build: () async {
        builds++;
        return 'build-$builds';
      },
    );

    await cache.value;
    cache.clear();
    expect(cache.isPrimed, isFalse);
    expect(await cache.value, 'build-2');
    expect(builds, 2);
  });
}
