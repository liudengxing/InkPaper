import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/annotation_model.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/note_actions_service.dart';
import 'package:inkpaper/utils/snackbar_utils.dart';
import 'package:inkpaper/widgets/annotations_sidebar.dart';
import 'package:provider/provider.dart';

/// 批注（Annotation）相关的弹窗与写操作。
///
/// 原先这套逻辑在 `note_card.dart` 与 `note_actions_ui.dart` 各有一份副本，
/// 两边行为已经漂移（一处直接调 `AppProvider.updateNote`，一处走
/// `NoteActionsService`）。这里合并为唯一实现，调用方按场景传 `onUpdated`。
///
/// 之所以独立成文件：批注增删改是一个完整的小功能域（1 个侧边栏 + 3 个
/// 对话框 + 4 个写操作），跟「卡片长什么样」无关，塞在卡片里只能让卡片越来越胖。
class NoteAnnotationDialogs {
  /// 批注侧边栏。
  ///
  /// [onAnnotationOpened] 用于覆盖「点某条批注」的默认行为（默认只弹提示）；
  /// 首页卡片场景需要它跳到详情页。
  static Future<void> showSidebar({
    required BuildContext context,
    required Note note,
    required VoidCallback onUpdated,
    ValueChanged<Annotation>? onAnnotationOpened,
  }) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => AnnotationsSidebar(
          note: note,
          onAnnotationTap: (annotation) {
            Navigator.pop(context);
            if (onAnnotationOpened != null) {
              onAnnotationOpened(annotation);
              return;
            }
            final localizations = AppLocalizationsSimple.of(context);
            SnackBarUtils.showSuccess(
              context,
              localizations?.locatedToAnnotation ?? '已定位到批注',
            );
          },
          onAddAnnotation: () {
            Navigator.pop(context);
            showAdd(context, note, onUpdated);
          },
          onEditAnnotation: (annotation) {
            Navigator.pop(context);
            showEdit(context, note, annotation, onUpdated);
          },
          onDeleteAnnotation: (annotationId) {
            Navigator.pop(context);
            confirmDelete(context, note, annotationId, onUpdated);
          },
          onResolveAnnotation: (annotation) {
            resolve(context, note, annotation, onUpdated);
          },
        ),
      ),
    );
  }

  /// 添加批注对话框
  static Future<void> showAdd(
    BuildContext context,
    Note note,
    VoidCallback onUpdated,
  ) async {
    final textController = TextEditingController();
    var selectedType = AnnotationType.comment;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final localizations = AppLocalizationsSimple.of(context);
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.add_comment, size: 20),
                const SizedBox(width: 8),
                Text(localizations?.addAnnotation ?? '添加批注'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    localizations?.annotationType ?? '批注类型',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: AnnotationType.values.map((type) {
                      final annotation = Annotation(
                        id: '',
                        content: '',
                        createdAt: DateTime.now(),
                        type: type,
                      );
                      return ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(annotation.typeIcon, size: 16),
                            const SizedBox(width: 4),
                            Text(annotation.getTypeText(context)),
                          ],
                        ),
                        selected: selectedType == type,
                        selectedColor:
                            annotation.typeColor.withValues(alpha: 0.2),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() => selectedType = type);
                          }
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: textController,
                    maxLines: 5,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: localizations?.annotationPlaceholder ??
                          '在这里写下你的批注...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(localizations?.cancel ?? '取消'),
              ),
              FilledButton(
                onPressed: () {
                  final content = textController.text.trim();
                  if (content.isNotEmpty) {
                    final appProvider =
                        Provider.of<AppProvider>(context, listen: false);
                    final newAnnotation = Annotation(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      content: content,
                      createdAt: DateTime.now(),
                      type: selectedType,
                    );
                    final updatedAnnotations = [
                      ...note.annotations,
                      newAnnotation,
                    ];
                    final updatedNote = note.copyWith(
                      annotations: updatedAnnotations,
                      updatedAt: DateTime.now(),
                    );
                    NoteActionsService.updateContent(
                      appProvider,
                      updatedNote,
                      updatedNote.content,
                    );
                    Navigator.pop(context);
                    SnackBarUtils.showSuccess(
                      context,
                      localizations?.annotationAdded ?? '批注已添加',
                    );
                    onUpdated();
                  }
                },
                child: Text(localizations?.addAnnotation ?? '添加'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 编辑批注对话框
  static Future<void> showEdit(
    BuildContext context,
    Note note,
    Annotation annotation,
    VoidCallback onUpdated,
  ) async {
    final textController = TextEditingController(text: annotation.content);
    var selectedType = annotation.type;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.edit_outlined, size: 20),
              const SizedBox(width: 8),
              Text(
                AppLocalizationsSimple.of(context)?.editAnnotation ?? '编辑批注',
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizationsSimple.of(context)?.annotationType ?? '批注类型',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: AnnotationType.values.map((type) {
                    final tempAnnotation = Annotation(
                      id: '',
                      content: '',
                      createdAt: DateTime.now(),
                      type: type,
                    );
                    return ChoiceChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(tempAnnotation.typeIcon, size: 16),
                          const SizedBox(width: 4),
                          Text(tempAnnotation.typeText),
                        ],
                      ),
                      selected: selectedType == type,
                      selectedColor:
                          tempAnnotation.typeColor.withValues(alpha: 0.2),
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => selectedType = type);
                        }
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: textController,
                  maxLines: 5,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: AppLocalizationsSimple.of(context)
                            ?.annotationEditPlaceholder ??
                        '修改批注内容...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizationsSimple.of(context)?.cancel ?? '取消'),
            ),
            FilledButton(
              onPressed: () {
                final content = textController.text.trim();
                if (content.isNotEmpty) {
                  final appProvider =
                      Provider.of<AppProvider>(context, listen: false);
                  final updatedAnnotations = note.annotations.map((a) {
                    if (a.id == annotation.id) {
                      return a.copyWith(
                        content: content,
                        type: selectedType,
                        updatedAt: DateTime.now(),
                      );
                    }
                    return a;
                  }).toList();
                  final updatedNote = note.copyWith(
                    annotations: updatedAnnotations,
                    updatedAt: DateTime.now(),
                  );
                  NoteActionsService.updateContent(
                    appProvider,
                    updatedNote,
                    updatedNote.content,
                  );
                  Navigator.pop(context);
                  SnackBarUtils.showSuccess(
                    context,
                    AppLocalizationsSimple.of(context)?.annotationUpdated ??
                        '批注已更新',
                  );
                  onUpdated();
                }
              },
              child: Text(AppLocalizationsSimple.of(context)?.save ?? '保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 删除批注
  static Future<void> confirmDelete(
    BuildContext context,
    Note note,
    String annotationId,
    VoidCallback onUpdated,
  ) async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          AppLocalizationsSimple.of(context)?.deleteAnnotation ?? '删除批注',
        ),
        content: Text(
          AppLocalizationsSimple.of(context)?.confirmDeleteAnnotation ??
              '确定要删除这条批注吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizationsSimple.of(context)?.cancel ?? '取消'),
          ),
          FilledButton(
            onPressed: () {
              final appProvider =
                  Provider.of<AppProvider>(context, listen: false);
              final updatedAnnotations =
                  note.annotations.where((a) => a.id != annotationId).toList();
              final updatedNote = note.copyWith(
                annotations: updatedAnnotations,
                updatedAt: DateTime.now(),
              );
              NoteActionsService.updateContent(
                appProvider,
                updatedNote,
                updatedNote.content,
              );
              Navigator.pop(context);
              SnackBarUtils.showSuccess(
                context,
                AppLocalizationsSimple.of(context)?.annotationDeleted ??
                    '批注已删除',
              );
              onUpdated();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(AppLocalizationsSimple.of(context)?.delete ?? '删除'),
          ),
        ],
      ),
    );
  }

  /// 标记批注为已解决
  static void resolve(
    BuildContext context,
    Note note,
    Annotation annotation,
    VoidCallback onUpdated,
  ) {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    final updatedAnnotations = note.annotations.map((a) {
      if (a.id == annotation.id) {
        return a.copyWith(isResolved: true);
      }
      return a;
    }).toList();
    final updatedNote = note.copyWith(
      annotations: updatedAnnotations,
      updatedAt: DateTime.now(),
    );
    NoteActionsService.updateContent(
      appProvider,
      updatedNote,
      updatedNote.content,
    );
    SnackBarUtils.showSuccess(
      context,
      AppLocalizationsSimple.of(context)?.annotationMarkedResolved ?? '已标记为已解决',
    );
    onUpdated();
  }
}
