import 'package:inkpaper/models/load_more_state.dart';

class NotesPaginationState {
  const NotesPaginationState({
    required this.currentPage,
    required this.hasMoreData,
    required this.loadMoreState,
  });

  final int currentPage;
  final bool hasMoreData;
  final LoadMoreState loadMoreState;

  NotesPaginationState copyWith({
    int? currentPage,
    bool? hasMoreData,
    LoadMoreState? loadMoreState,
  }) =>
      NotesPaginationState(
        currentPage: currentPage ?? this.currentPage,
        hasMoreData: hasMoreData ?? this.hasMoreData,
        loadMoreState: loadMoreState ?? this.loadMoreState,
      );
}

NotesPaginationState initialNotesPaginationState() =>
    const NotesPaginationState(
      currentPage: 0,
      hasMoreData: true,
      loadMoreState: LoadMoreState.idle,
    );

bool canStartLoadMore(NotesPaginationState state) =>
    state.loadMoreState.canLoadMore && state.hasMoreData;

NotesPaginationState beginLoadMore(NotesPaginationState state) =>
    state.copyWith(
      currentPage: state.currentPage + 1,
      loadMoreState: LoadMoreState.loadingMore,
    );

NotesPaginationState applyInitialPageResult({
  required NotesPaginationState state,
  required int loadedCount,
  required int totalCount,
}) {
  final hasMore = loadedCount < totalCount;
  return state.copyWith(
    currentPage: 0,
    hasMoreData: hasMore,
    loadMoreState: hasMore ? LoadMoreState.idle : LoadMoreState.noMore,
  );
}

NotesPaginationState applyLoadMoreResult({
  required NotesPaginationState state,
  required int itemCount,
  required int loadedCount,
  required int totalCount,
}) {
  if (itemCount == 0 || loadedCount >= totalCount) {
    return state.copyWith(
      hasMoreData: false,
      loadMoreState: LoadMoreState.noMore,
    );
  }

  return state.copyWith(loadMoreState: LoadMoreState.success);
}

/// 从一页结果里去掉窗口已经有的 id。
///
/// 续页用 `OFFSET` 取，理论上不会与已加载窗口重叠；但引用回调、同步合并、
/// 重建引用这些路径都会改 `notes`，一旦某条被提前插进来，同一个 id 就会在
/// 列表里出现两张卡片。这里按 id 过滤一遍，返回值即「真正需要追加的部分」。
List<T> filterUnloadedNotes<T>(
  Iterable<T> loaded,
  Iterable<T> page,
  String Function(T item) idOf,
) {
  final seen = <String>{for (final item in loaded) idOf(item)};
  return <T>[
    for (final item in page)
      if (seen.add(idOf(item))) item,
  ];
}

NotesPaginationState applyLoadMoreFailure(NotesPaginationState state) =>
    state.copyWith(
      currentPage: state.currentPage - 1,
      loadMoreState: LoadMoreState.failed,
    );

NotesPaginationState endLoadAttempt(NotesPaginationState state) {
  if (state.loadMoreState == LoadMoreState.noMore) {
    return state;
  }
  return state.copyWith(loadMoreState: LoadMoreState.idle);
}
