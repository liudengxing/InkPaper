import 'dart:async';

import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/models/sort_order.dart';
import 'package:inkpaper/services/notes_pagination_helper.dart';

/// 笔记域状态（`STATE-CORE-005` 第二步）。
///
/// 只做字段归属迁移：把笔记集合、加载/分页、排序、缓存与删除队列从
/// `AppProvider` 搬到这里，`AppProvider` 仅保留 `_notesStore.` 转发。
/// 业务逻辑、方法签名与调用方行为均不变。
class NotesStore {
  /// 内存中的笔记列表。
  List<Note> notes = [];

  /// 首次加载是否进行中。
  bool isLoading = false;

  /// 是否已完成初始化（登录恢复 / 本地模式首屏）。
  bool isInitialized = false;

  /// 分页加载状态。
  NotesPaginationState pagingState = initialNotesPaginationState();

  /// 防止重复触发「加载更多」的并发闸门。
  Completer<void>? loadMoreCompleter;

  /// 数据库总笔记数，用于「已加载 x / 共 y」。
  int totalNotesCount = 0;

  /// 上次加载时间。
  DateTime? lastLoadTime;

  /// 加载耗时计时器。
  final Stopwatch loadStopwatch = Stopwatch();

  /// 当前排序方式。
  SortOrder sortOrder = SortOrder.newest;

  /// `notes` getter 的缓存，`notifyListeners` 时清空。
  List<Note>? visibleNotesCache;

  /// 待删除 id 队列（批量删除）。
  final List<String> deleteQueue = [];

  /// 已排队删除、尚未落库的笔记 id。
  final Set<String> pendingDeleteIds = {};

  /// 是否正在处理删除队列。
  bool isProcessingDelete = false;

  /// 删除防抖计时器。
  Timer? deleteDebounceTimer;

  /// 最近一次被删除的笔记（撤销用）。
  Note? lastDeletedNote;

  /// 最近一次被删除笔记的原索引（撤销用）。
  int? lastDeletedIndex;

  /// 待提交删除的计时器（撤销窗口）。
  Timer? pendingDeleteCommitTimer;
}
