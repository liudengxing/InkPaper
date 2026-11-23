import 'package:flutter_test/flutter_test.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sort_order.dart';
import 'package:inkpaper/utils/note_sorting_helper.dart';

Note _n(
  String id, {
  required DateTime created,
  required DateTime updated,
  bool pinned = false,
}) =>
    Note(
      id: id,
      content: id,
      createdAt: created,
      updatedAt: updated,
      isPinned: pinned,
    );

void main() {
  test('SORT-01 pinned notes always come first', () {
    final notes = [
      _n('a', created: DateTime(2024, 1, 2), updated: DateTime(2024, 1, 2)),
      _n(
        'p',
        created: DateTime(2024),
        updated: DateTime(2024),
        pinned: true,
      ),
    ];
    final sorted = sortedNotesCopy(notes, SortOrder.newest);
    expect(sorted.first.id, 'p');
  });

  test('SORT-02 newest sorts by createdAt desc within same pinned group', () {
    final notes = [
      _n('1', created: DateTime(2024), updated: DateTime(2024)),
      _n('2', created: DateTime(2024, 1, 2), updated: DateTime(2024, 1, 2)),
    ];
    final sorted = sortedNotesCopy(notes, SortOrder.newest);
    expect(sorted.map((n) => n.id).toList(), ['2', '1']);
  });

  test('SORT-03 oldest sorts by createdAt asc within same pinned group', () {
    final notes = [
      _n('1', created: DateTime(2024), updated: DateTime(2024)),
      _n('2', created: DateTime(2024, 1, 2), updated: DateTime(2024, 1, 2)),
    ];
    final sorted = sortedNotesCopy(notes, SortOrder.oldest);
    expect(sorted.map((n) => n.id).toList(), ['1', '2']);
  });

  test('SORT-04 updated sorts by updatedAt desc within same pinned group', () {
    final notes = [
      _n('1', created: DateTime(2024), updated: DateTime(2024)),
      _n('2', created: DateTime(2024, 1, 2), updated: DateTime(2024, 1, 3)),
    ];
    final sorted = sortedNotesCopy(notes, SortOrder.updated);
    expect(sorted.map((n) => n.id).toList(), ['2', '1']);
  });

  test('SORT-05 updatedOldest sorts by updatedAt asc', () {
    final notes = [
      _n('1', created: DateTime(2024), updated: DateTime(2024, 3)),
      _n('2', created: DateTime(2024, 1, 2), updated: DateTime(2024, 2)),
    ];
    final sorted = sortedNotesCopy(notes, SortOrder.updatedOldest);
    expect(sorted.map((n) => n.id).toList(), ['2', '1']);
  });

  test('SORT-06 同一时间戳按 id 倒序兜底（与 SQL 的 id DESC 一致）', () {
    final same = DateTime(2025, 5, 1, 9);
    final notes = [
      _n('a', created: same, updated: same),
      _n('c', created: same, updated: same),
      _n('b', created: same, updated: same),
    ];
    for (final order in [SortOrder.newest, SortOrder.updated]) {
      final sorted = sortedNotesCopy(notes, order);
      expect(
        sorted.map((n) => n.id).toList(),
        ['c', 'b', 'a'],
        reason: '$order 时间并列时应按 id 倒序',
      );
    }
  });

  test('SORT-07 正序排序的 id 兜底方向翻转（镜像 SQL 的 id ASC）', () {
    final same = DateTime(2025, 5, 1, 9);
    final notes = [
      _n('c', created: same, updated: same),
      _n('a', created: same, updated: same),
      _n('b', created: same, updated: same),
    ];
    for (final order in [SortOrder.oldest, SortOrder.updatedOldest]) {
      final sorted = sortedNotesCopy(notes, order);
      expect(
        sorted.map((n) => n.id).toList(),
        ['a', 'b', 'c'],
        reason: '$order 时间并列时应按 id 正序',
      );
    }
  });

  test('SORT-08 加 id 兜底后置顶仍是第一级', () {
    final same = DateTime(2025, 5, 1, 9);
    final notes = [
      _n('z', created: same, updated: same),
      _n('m', created: same, updated: same, pinned: true),
      _n('a', created: same, updated: same),
    ];
    for (final order in SortOrder.values) {
      expect(sortedNotesCopy(notes, order).first.id, 'm', reason: '$order');
    }
  });

  test('SORT-09 SQL 排序子句固定三级：置顶、时间字段、id 兜底', () {
    // 与 noteComparator 逐级对应；改动其中一处必须同时改另一边
    expect(
      noteOrderBySql(SortOrder.newest),
      'IFNULL(isPinned, 0) DESC, createdAt DESC, id DESC',
    );
    expect(
      noteOrderBySql(SortOrder.oldest),
      'IFNULL(isPinned, 0) DESC, createdAt ASC, id ASC',
    );
    expect(
      noteOrderBySql(SortOrder.updated),
      'IFNULL(isPinned, 0) DESC, updatedAt DESC, id DESC',
    );
    expect(
      noteOrderBySql(SortOrder.updatedOldest),
      'IFNULL(isPinned, 0) DESC, updatedAt ASC, id ASC',
    );
  });
}
