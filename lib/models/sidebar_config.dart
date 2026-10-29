import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';

/// 侧边栏菜单项枚举
enum SidebarMenuItem {
  allNotes('all_notes', '全部笔记', '/', Icons.grid_view_rounded, false), // 不可隐藏
  randomReview(
    'random_review',
    '随机回顾',
    '/random-review',
    Icons.shuffle_rounded,
    true,
  ),
  allTags('all_tags', '全部标签', '/tags', Icons.local_offer_outlined, true),
  periodicReview(
    'periodic_review',
    '回顾',
    '/periodic-review',
    Icons.auto_stories_rounded,
    true,
  ),
  knowledgeGraph(
    'knowledge_graph',
    '知识图谱',
    '/knowledge-graph',
    Icons.account_tree_rounded,
    true,
  ),
  settings('settings', '设置', '/settings', Icons.settings_outlined, true);

  const SidebarMenuItem(
    this.id,
    this.label,
    this.path,
    this.icon,
    this.canHide,
  );

  final String id;
  final String label;
  final String path;
  final dynamic icon; // IconData
  final bool canHide; // 是否可以隐藏

  /// 获取国际化的标签文本
  String getLocalizedLabel(BuildContext context) {
    final l10n = AppLocalizationsSimple.of(context);
    switch (id) {
      case 'all_notes':
        return l10n?.allNotes ?? label;
      case 'random_review':
        return l10n?.randomReview ?? label;
      case 'all_tags':
        return l10n?.allTags ?? label;
      case 'periodic_review':
        return l10n?.periodicReview ?? label;
      case 'knowledge_graph':
        return l10n?.knowledgeGraph ?? label;
      case 'settings':
        return l10n?.settings ?? label;
      default:
        return label;
    }
  }

  static SidebarMenuItem? fromId(String id) {
    try {
      return SidebarMenuItem.values.firstWhere((item) => item.id == id);
    } on Object catch (_) {
      return null;
    }
  }
}

/// 侧边栏配置
class SidebarConfig {
  SidebarConfig({
    this.showHeatmap = true,
    this.showProfile = true,
    List<String>? visibleItems,
    List<String>? itemOrder,
  })  : visibleItems = visibleItems ?? _defaultVisibleItems(),
        itemOrder = itemOrder ?? _defaultItemOrder();

  /// 从JSON创建
  factory SidebarConfig.fromJson(Map<String, dynamic> json) {
    // 🎯 加载保存的配置
    final savedVisibleItems = (json['visibleItems'] as List<dynamic>?)
        ?.map((e) => e.toString())
        .toList();
    final savedItemOrder = (json['itemOrder'] as List<dynamic>?)
        ?.map((e) => e.toString())
        .toList();

    // 🎯 迁移逻辑：确保新增的菜单项（如 settings）被添加到旧配置中
    final allItemIds = SidebarMenuItem.values.map((item) => item.id).toList();

    if (savedVisibleItems != null) {
      // 已被移除的菜单项（如「帮助中心」）要从旧配置里清掉，否则会留下脏 id
      savedVisibleItems.removeWhere((id) => !allItemIds.contains(id));
      for (final itemId in allItemIds) {
        if (!savedVisibleItems.contains(itemId)) {
          // 新增的菜单项默认添加到可见列表
          savedVisibleItems.add(itemId);
        }
      }
    }

    if (savedItemOrder != null) {
      savedItemOrder.removeWhere((id) => !allItemIds.contains(id));
      for (final itemId in allItemIds) {
        if (!savedItemOrder.contains(itemId)) {
          // 新增的菜单项添加到顺序列表末尾
          savedItemOrder.add(itemId);
        }
      }

      // 「回顾」固定在「设置」上面：早期版本是按"追加到末尾"迁移的，
      // 老用户的配置里它排在设置之后，这里做一次性纠正。
      final reviewId = SidebarMenuItem.periodicReview.id;
      final settingsId = SidebarMenuItem.settings.id;
      final reviewIndex = savedItemOrder.indexOf(reviewId);
      final settingsIndex = savedItemOrder.indexOf(settingsId);
      if (reviewIndex != -1 &&
          settingsIndex != -1 &&
          reviewIndex > settingsIndex) {
        savedItemOrder.removeAt(reviewIndex);
        savedItemOrder.insert(settingsIndex, reviewId);
      }
    }

    return SidebarConfig(
      showHeatmap: json['showHeatmap'] ?? true,
      showProfile: json['showProfile'] ?? true,
      visibleItems: savedVisibleItems,
      itemOrder: savedItemOrder,
    );
  }

  final bool showHeatmap; // 是否显示活动记录
  final bool showProfile; // 是否显示个人中心
  final List<String> visibleItems; // 可见的菜单项ID列表
  final List<String> itemOrder; // 菜单项排序（ID列表）

  /// 默认可见菜单项
  static List<String> _defaultVisibleItems() =>
      SidebarMenuItem.values.map((item) => item.id).toList();

  /// 默认排序
  static List<String> _defaultItemOrder() =>
      SidebarMenuItem.values.map((item) => item.id).toList();

  /// 转换为JSON
  Map<String, dynamic> toJson() => {
        'showHeatmap': showHeatmap,
        'showProfile': showProfile,
        'visibleItems': visibleItems,
        'itemOrder': itemOrder,
      };

  /// 复制并修改
  SidebarConfig copyWith({
    bool? showHeatmap,
    bool? showProfile,
    List<String>? visibleItems,
    List<String>? itemOrder,
  }) =>
      SidebarConfig(
        showHeatmap: showHeatmap ?? this.showHeatmap,
        showProfile: showProfile ?? this.showProfile,
        visibleItems: visibleItems ?? this.visibleItems,
        itemOrder: itemOrder ?? this.itemOrder,
      );

  /// 检查菜单项是否可见
  bool isItemVisible(String itemId) => visibleItems.contains(itemId);

  /// 获取排序后的可见菜单项
  List<SidebarMenuItem> getOrderedVisibleItems() {
    final items = <SidebarMenuItem>[];

    // 按照 itemOrder 的顺序添加可见的菜单项
    for (final itemId in itemOrder) {
      if (visibleItems.contains(itemId)) {
        final menuItem = SidebarMenuItem.fromId(itemId);
        if (menuItem != null) {
          items.add(menuItem);
        }
      }
    }

    // 添加任何在 visibleItems 中但不在 itemOrder 中的项
    for (final itemId in visibleItems) {
      if (!itemOrder.contains(itemId)) {
        final menuItem = SidebarMenuItem.fromId(itemId);
        if (menuItem != null) {
          items.add(menuItem);
        }
      }
    }

    return items;
  }
}
