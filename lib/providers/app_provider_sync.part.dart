part of 'app_provider.dart';

extension AppProviderSyncPart on AppProvider {
  // 从服务器获取笔记
  Future<void> fetchNotesFromServer() async {
    // 设置同步状态
    _setSyncUi(syncing: true, message: '正在从服务器获取数据...');

    try {
      // 检查并快速重新初始化API服务
      if (_memosApiService == null) {
        await _ensureApiServiceInitialized();
      }

      // 首先获取本地所有笔记（包括已同步和未同步的）
      _setSyncMessage('备份本地笔记...');

      debugPrint('AppProvider: 获取所有本地笔记');
      final localNotes =
          _excludePendingDeletedNotes(await _databaseService.getNotes());
      final unsyncedNotes = _excludePendingDeletedNotes(
        await _databaseService.getUnsyncedNotes(),
      );
      debugPrint(
        'AppProvider: 本地共有 ${localNotes.length} 条笔记，其中 ${unsyncedNotes.length} 条未同步',
      );

      _setSyncMessage('获取远程笔记...');

      debugPrint('AppProvider: 从服务器获取笔记');
      final response = await _memosApiService!.getMemos();
      final isRemoteComplete = response['isComplete'] as bool? ?? true;

      _setSyncMessage('处理笔记数据...');

      final memosList = response['memos'] as List<dynamic>;
      final serverNotes = memosList
          .map((memo) => Note.fromJson(memo as Map<String, dynamic>))
          .where(_isVisibleNote) // 🔥 过滤掉归档和待删除笔记
          .toList();

      // 🚀 性能优化：批量处理标签提取，不阻塞UI
      // Note.fromJson已经包含relationList，无需单独请求引用关系
      for (var i = 0; i < serverNotes.length; i++) {
        final note = serverNotes[i];
        final tags = Note.extractTagsFromContent(note.content);

        // 确保服务器笔记都标记为已同步，relations已在fromJson中处理
        serverNotes[i] = note.copyWith(
          tags: tags,
          isSynced: true,
        );
      }

      _setSyncMessage('智能合并数据...');

      // 智能合并策略：优先保留服务器数据，但不丢失本地未同步的数据
      final mergedNotes = <Note>[];
      final serverNoteIds = serverNotes.map((note) => note.id).toSet();
      // 内容哈希 -> 服务端笔记，用于识别「同内容、不同 id」的残留副本
      final serverNotesByHash = <String, Note>{
        for (final note in serverNotes) _calculateNoteHash(note): note,
      };
      final localNotesById = {for (final note in localNotes) note.id: note};

      // 1. 添加所有服务器笔记，但保留本地的引用关系和置顶状态
      for (final serverNote in serverNotes) {
        final localNote = localNotesById[serverNote.id];

        if (localNote != null) {
          mergedNotes
              .add(
          _mergeServerNoteWithLocalState(
            serverNote,
            localNote,
            keepLocalPendingChanges: true,
          ),
        );
        } else {
          mergedNotes.add(serverNote);
        }
      }
      debugPrint('AppProvider: 添加 ${serverNotes.length} 条服务器笔记');

      // 2. 添加本地未同步的笔记（避免重复）
      var addedUnsyncedCount = 0;
      // 内容与服务端某条完全一致、但 id 不同的本地未同步残留，稍后物理删除
      final staleLocalIds = <String>[];

      for (var note in unsyncedNotes) {
        final noteHash = _calculateNoteHash(note);
        final duplicateTarget = serverNotesByHash[noteHash];
        final hasIdConflict =
            serverNoteIds.contains(note.id) && !note.id.startsWith('local_');

        if (duplicateTarget == null) {
          // 如果ID冲突但内容不重复，生成新的本地ID
          if (hasIdConflict) {
            note = note.copyWith(
              id: 'local_${DateTime.now().millisecondsSinceEpoch}_$addedUnsyncedCount',
              isSynced: false,
            );
          }
          mergedNotes.add(note);
          addedUnsyncedCount++;
        } else if (!hasIdConflict) {
          // 同内容、不同 id：多半是「远端被删后重建」在本机留下的旧副本。
          // 剪枝会跳过未同步行，如果只是跳过，库里会同时存在两条一样的笔记。
          // 把本地增强数据（置顶、批注、引用）并到服务端那条上，再删掉旧副本。
          final index =
              mergedNotes.indexWhere((merged) => merged.id == duplicateTarget.id);
          if (index != -1) {
            mergedNotes[index] = _mergeServerNoteWithLocalState(
              duplicateTarget,
              note,
              keepLocalPendingChanges: true,
            );
          }
          staleLocalIds.add(note.id);
          debugPrint(
            'AppProvider: 清理同内容残留副本 ${note.id} → ${duplicateTarget.id}',
          );
        } else {
          debugPrint('AppProvider: 跳过重复笔记: ${note.id}');
        }
      }

      debugPrint('AppProvider: 添加 $addedUnsyncedCount 条本地未同步笔记');

      // 3. 更新本地数据库（upsert 策略：不清空，避免写入中断时丢失数据）
      debugPrint('AppProvider: 更新本地数据库');
      await _databaseService.saveNotes(mergedNotes);
      for (final staleId in staleLocalIds) {
        await _databaseService.deleteNote(staleId);
      }
      // 删除服务器已不存在的本地已同步笔记，未同步笔记保留
      if (isRemoteComplete) {
        await _databaseService.deleteSyncedNotesNotIn(serverNoteIds.toList());
      } else {
        debugPrint('AppProvider: 远程分页未完整，跳过本地删除清理');
      }

      // 4. 🚀 同步完成后重新完整加载笔记
      // 大厂标准：同步完成后应该从数据库重新加载全部数据，确保数据一致性
      _totalNotesCount = mergedNotes.length;

      // 🔥 关键修复：从数据库重新加载全部笔记（确保数据新鲜且正确排序）
      final dbNotes = _excludePendingDeletedNotes(
        await _databaseService.getNotes(),
      ); // 加载全部数据

      // ✅ 保护内存中的批注数据（批注是本地增强功能，不同步到服务器）
      final memoryNotesMap = {for (final note in _notes) note.id: note};

      _notes = dbNotes.map((dbNote) {
        // 如果内存中有这个笔记且有批注，保留其批注
        final memoryNote = memoryNotesMap[dbNote.id];
        if (memoryNote != null && memoryNote.annotations.isNotEmpty) {
          return dbNote.copyWith(annotations: memoryNote.annotations);
        }
        return dbNote;
      }).toList();

      // 重置分页状态
      _pagingState = paging.NotesPaginationState(
        currentPage:
            (_notes.length / AppProvider._pageSize).floor(), // 根据实际加载的数量计算页码
        hasMoreData: false, // 已经全部加载
        loadMoreState: LoadMoreState.idle,
      );

      _setSyncMessage('同步完成');

      debugPrint(
        'AppProvider: ✅ 笔记同步完成！数据库总计 $_totalNotesCount 条，已全部加载 ${_notes.length} 条到内存',
      );
    } on Object catch (e, stackTrace) {
      debugPrint('AppProvider: 从服务器获取数据失败: $e');
      debugPrint('AppProvider: 错误堆栈: $stackTrace');

      // 🔥 过滤 Firebase 错误（项目未使用 Firebase，忽略相关错误）
      final errorString = e.toString();
      if (errorString.contains('Firebase') ||
          errorString.contains('[core/no-app]') ||
          errorString.contains('FirebaseApp')) {
        debugPrint('⚠️ 检测到 Firebase 相关错误，已忽略（项目未使用 Firebase）');
        _setSyncUi(syncing: false);
        // 继续加载本地数据
        await loadNotesFromLocal();
        return;
      }

      // 检查是否为Token过期异常
      if (e is TokenExpiredException || sync_status.isTokenExpiredError(e)) {
        debugPrint('AppProvider: 检测到Token过期，强制用户重新登录');
        _setSyncMessage('登录已过期，请重新登录');
        await _handleTokenExpired();
        return;
      }

      _setSyncMessage(sync_status.syncFailedMessage(e));

      // 如果是API服务初始化失败，尝试清除登录状态
      if (e.toString().contains('API服务初始化失败')) {
        await logout(force: true);
      }

      debugPrint('AppProvider: 保留本地数据');
      // 加载本地数据作为后备
      await loadNotesFromLocal();

      rethrow;
    } finally {
      // 延迟一点时间再清除同步状态，让用户有时间看到"同步完成"
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _setSyncUi(syncing: false);
        }
      });
    }
  }

  // 从云端同步数据
  Future<void> syncWithServer() async {
    if (!isLoggedIn || _memosApiService == null) {
      throw Exception('请先登录您的账号');
    }

    // 设置同步状态
    _setSyncUi(syncing: true, message: '准备同步...');

    try {
      // 0. 先补交之前失败的远端删除，避免已删笔记在下次拉取时被服务端"还回来"
      _setSyncMessage('同步删除记录...');
      await flushPendingNoteDeletes();

      // 1. 先将本地未同步的笔记上传到服务器
      _setSyncMessage('上传本地笔记...');

      final unsyncedNotes = _excludePendingDeletedNotes(
        await _databaseService.getUnsyncedNotes(),
      );
      debugPrint('AppProvider: 发现 ${unsyncedNotes.length} 条未同步笔记');

      // 已连续失败太多次的笔记不再重试：内容被服务端拒绝时重试没有意义，
      // 只会每轮同步都白跑一次。用户再编辑该笔记时会清掉计数。
      final pendingAttempts = await _databaseService.getPendingUpsertAttempts();

      var failedUploads = 0;
      var blockedUploads = 0;
      for (final note in unsyncedNotes) {
        final attempts = pendingAttempts[note.id] ?? 0;
        if (attempts >= AppProvider.maxUploadAttempts) {
          blockedUploads++;
          debugPrint(
            'AppProvider: 跳过上传失败 $attempts 次的笔记 ${note.id}，等待用户编辑后重试',
          );
          continue;
        }

        try {
          await _syncUnsyncedNotesSnapshot([note]);
          if (attempts > 0) {
            await _databaseService.clearPendingUpsert(note.id);
          }
        } on Object catch (e) {
          failedUploads++;
          await _databaseService.markPendingUpsertAttempt(
            note.id,
            error: e.toString(),
          );
          debugPrint('同步笔记到服务器失败: ${note.id} - $e');
        }
      }

      if (blockedUploads > 0) {
        debugPrint(
          'AppProvider: $blockedUploads 条笔记多次上传失败，已暂停自动重试',
        );
        _setSyncMessage('$blockedUploads 条笔记多次上传失败，编辑后会自动重试');
      } else if (failedUploads > 0) {
        // 未上传的笔记仍是 is_synced=0，下次同步会自动重试；
        // 这里只让用户知道"还有内容没传上去"，而不是静默。
        debugPrint('AppProvider: $failedUploads 条笔记上传失败，将在下次同步重试');
        _setSyncMessage('$failedUploads 条笔记未上传，稍后自动重试');
      }

      // 2. 从服务器获取最新数据
      _setSyncMessage('获取服务器数据...');

      final response = await _memosApiService!.getMemos();
      final isRemoteComplete = response['isComplete'] as bool? ?? true;

      final memosList = response['memos'] as List<dynamic>;
      final serverNotes = memosList
          .map((memo) => Note.fromJson(memo as Map<String, dynamic>))
          .where(_isVisibleNote) // 🔥 过滤掉归档和待删除笔记
          .toList();
      final localNotes =
          _excludePendingDeletedNotes(await _databaseService.getNotes());
      final localNotesById = {for (final note in localNotes) note.id: note};

      // 3. 为所有服务器笔记重新提取标签
      _setSyncMessage('处理笔记数据...');

      for (var i = 0; i < serverNotes.length; i++) {
        final note = serverNotes[i];
        final tags = Note.extractTagsFromContent(note.content);
        if (tags.isNotEmpty) {
          serverNotes[i] = note.copyWith(tags: tags);
        }
      }

      // 4. 更新本地数据库（upsert 策略）
      _setSyncMessage('更新本地数据...');

      // 内容与服务端某条一致、但 id 不同的本地未同步副本（远端被删后重建的残留）
      final duplicateLocalCopies = findDuplicateLocalCopies(
        localNotes: localNotes,
        serverNotes: serverNotes,
      );
      // 服务端 id -> 可继承本地状态的副本
      final copyByServerId = <String, Note>{
        for (final entry in duplicateLocalCopies.entries)
          entry.value.id: localNotesById[entry.key]!,
      };

      final mergedServerNotes = serverNotes.map((serverNote) {
        final localNote =
            localNotesById[serverNote.id] ?? copyByServerId[serverNote.id];
        return localNote == null
            ? serverNote
            : _mergeServerNoteWithLocalState(
                serverNote,
                localNote,
                keepLocalPendingChanges: true,
              );
      }).toList();
      await _databaseService.saveNotes(mergedServerNotes);
      for (final copyId in duplicateLocalCopies.keys) {
        await _databaseService.deleteNote(copyId);
        debugPrint('AppProvider: 清理同内容残留副本 $copyId');
      }
      final syncedServerIds = mergedServerNotes.map((n) => n.id).toList();
      if (isRemoteComplete) {
        await _databaseService.deleteSyncedNotesNotIn(syncedServerIds);
      } else {
        debugPrint('AppProvider: 远程分页未完整，跳过本地删除清理');
      }

      // 5. 更新内存中的列表
      _notes = _excludePendingDeletedNotes(await _databaseService.getNotes());

      _setSyncMessage('同步完成');

      // 延迟一点时间再清除同步状态
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _setSyncUi(syncing: false);
        }
      });
    } on Object catch (e) {
      debugPrint('同步失败: $e');
      _setSyncMessage(sync_status.syncFailedMessage(e));

      // 延迟一点时间再清除同步状态
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          _setSyncUi(syncing: false);
        }
      });

      rethrow;
    }
  }
}
