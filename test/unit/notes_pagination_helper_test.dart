import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/load_more_state.dart';
import 'package:inkpaper/utils/notes_pagination_helper.dart';

void main() {
  test('PAGE-01 initial state is page 0, hasMore, idle', () {
    final s = initialNotesPaginationState();
    expect(s.currentPage, 0);
    expect(s.hasMoreData, isTrue);
    expect(s.loadMoreState, LoadMoreState.idle);
  });

  test('PAGE-02 canStartLoadMore requires hasMoreData and canLoadMore state',
      () {
    expect(
      canStartLoadMore(
        const NotesPaginationState(
          currentPage: 0,
          hasMoreData: true,
          loadMoreState: LoadMoreState.idle,
        ),
      ),
      isTrue,
    );
    expect(
      canStartLoadMore(
        const NotesPaginationState(
          currentPage: 0,
          hasMoreData: false,
          loadMoreState: LoadMoreState.idle,
        ),
      ),
      isFalse,
    );
    expect(
      canStartLoadMore(
        const NotesPaginationState(
          currentPage: 0,
          hasMoreData: true,
          loadMoreState: LoadMoreState.loadingMore,
        ),
      ),
      isFalse,
    );
  });

  test('PAGE-03 beginLoadMore increments page and sets loadingMore', () {
    final s = beginLoadMore(
      const NotesPaginationState(
        currentPage: 3,
        hasMoreData: true,
        loadMoreState: LoadMoreState.idle,
      ),
    );
    expect(s.currentPage, 4);
    expect(s.loadMoreState, LoadMoreState.loadingMore);
  });

  test('PAGE-04 applyLoadMoreResult noMore on empty, success otherwise', () {
    const base = NotesPaginationState(
      currentPage: 1,
      hasMoreData: true,
      loadMoreState: LoadMoreState.loadingMore,
    );

    final empty = applyLoadMoreResult(
      state: base,
      itemCount: 0,
      loadedCount: 50,
      totalCount: 50,
    );
    expect(empty.hasMoreData, isFalse);
    expect(empty.loadMoreState, LoadMoreState.noMore);

    final nonEmpty = applyLoadMoreResult(
      state: base,
      itemCount: 10,
      loadedCount: 60,
      totalCount: 100,
    );
    expect(nonEmpty.hasMoreData, isTrue);
    expect(nonEmpty.loadMoreState, LoadMoreState.success);
  });

  test('PAGE-04B initial page result uses total count instead of page size',
      () {
    final shortList = applyInitialPageResult(
      state: initialNotesPaginationState(),
      loadedCount: 1,
      totalCount: 1,
    );
    expect(shortList.hasMoreData, isFalse);
    expect(shortList.loadMoreState, LoadMoreState.noMore);

    final fullFirstPageButMoreExists = applyInitialPageResult(
      state: initialNotesPaginationState(),
      loadedCount: 50,
      totalCount: 51,
    );
    expect(fullFirstPageButMoreExists.hasMoreData, isTrue);
    expect(fullFirstPageButMoreExists.loadMoreState, LoadMoreState.idle);
  });

  test('PAGE-04C load more stops when loaded count reaches total', () {
    final result = applyLoadMoreResult(
      state: const NotesPaginationState(
        currentPage: 1,
        hasMoreData: true,
        loadMoreState: LoadMoreState.loadingMore,
      ),
      itemCount: 1,
      loadedCount: 51,
      totalCount: 51,
    );

    expect(result.hasMoreData, isFalse);
    expect(result.loadMoreState, LoadMoreState.noMore);
  });

  test('PAGE-05 applyLoadMoreFailure decrements page and marks failed', () {
    final s = applyLoadMoreFailure(
      const NotesPaginationState(
        currentPage: 5,
        hasMoreData: true,
        loadMoreState: LoadMoreState.loadingMore,
      ),
    );
    expect(s.currentPage, 4);
    expect(s.loadMoreState, LoadMoreState.failed);
  });

  test('PAGE-06 endLoadAttempt resets to idle unless noMore', () {
    final idle = endLoadAttempt(
      const NotesPaginationState(
        currentPage: 1,
        hasMoreData: true,
        loadMoreState: LoadMoreState.success,
      ),
    );
    expect(idle.loadMoreState, LoadMoreState.idle);

    final noMore = endLoadAttempt(
      const NotesPaginationState(
        currentPage: 1,
        hasMoreData: false,
        loadMoreState: LoadMoreState.noMore,
      ),
    );
    expect(noMore.loadMoreState, LoadMoreState.noMore);
  });

  test('PAGE-07 续页结果只保留窗口里没有的 id', () {
    final loaded = <String>['n-3', 'n-2', 'n-1'];
    // 第 2 页里有两条与窗口重叠（引用回调插进来过的那种情况）
    final page = <String>['n-1', 'n-0', 'n--1'];

    expect(
      filterUnloadedNotes(loaded, page, (id) => id),
      <String>['n-0', 'n--1'],
      reason: '重叠的 id 不能再追加一次，否则列表里出现两张同 id 卡片',
    );

    // 整页都不重叠时原样返回，顺序不变
    expect(
      filterUnloadedNotes(loaded, <String>['n-0', 'n--1'], (id) => id),
      <String>['n-0', 'n--1'],
    );

    // 整页都重叠时返回空，调用方据此知道这一页没有新增
    expect(
      filterUnloadedNotes(loaded, <String>['n-2'], (id) => id),
      isEmpty,
    );
  });
}
