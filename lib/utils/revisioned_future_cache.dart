/// 按「语料版本号」缓存一次昂贵构建的结果。
///
/// 探索索引这类派生数据只在源语料变化时才需要重建。以前的写法是任何
/// `notifyListeners()` 都把缓存的 Future 置空，于是切换排序、首页翻页、
/// 切换媒体筛选都会让下一次进入随机漫步/相关笔记重新查全库并在后台
/// isolate 重建索引——排序只是列表视图状态，和语料无关。
///
/// 这里把「缓存还有没有效」收敛成一次版本号比较：
/// - 版本号没变 → 复用同一个 Future，并发调用共享同一次构建；
/// - 版本号变了 → 丢掉旧结果重建；
/// - 构建期间版本号又变了 → 这份结果已过期，再建一次，最多 [maxAttempts]
///   次，避免持续写入时无限重建（超过上限就返回手上这份最新的结果）。
class RevisionedFutureCache<T> {
  RevisionedFutureCache({
    required this.build,
    required this.revision,
    this.maxAttempts = 3,
  }) : assert(maxAttempts > 0, 'maxAttempts 至少为 1');

  final Future<T> Function() build;
  final int Function() revision;
  final int maxAttempts;

  Future<T>? _future;
  int _revision = -1;

  /// 是否持有与当前版本号匹配的缓存。
  bool get isPrimed => _future != null && _revision == revision();

  /// 取当前版本对应的结果：命中缓存就直接复用，否则构建并缓存。
  Future<T> get value async {
    for (var attempt = 0;; attempt++) {
      final currentRevision = revision();
      var building = _future;
      if (building == null || _revision != currentRevision) {
        building = _future = Future<T>.sync(build);
        _revision = currentRevision;
      }

      try {
        final result = await building;

        // 期间有别的调用方换成了新的构建，重新取那一份。
        if (!identical(building, _future)) {
          continue;
        }

        // 构建期间语料又变了：这份结果已经过期，重建。
        if (_revision == revision() || attempt + 1 >= maxAttempts) {
          return result;
        }
        _future = null;
        _revision = -1;
        continue;
      } on Object {
        // 失败不缓存，下次调用重新构建。
        if (identical(building, _future)) {
          _future = null;
          _revision = -1;
        }
        rethrow;
      }
    }
  }

  /// 手动丢弃缓存（例如测试之间重置状态）。
  void clear() {
    _future = null;
    _revision = -1;
  }
}
