package com.didichou.inkpaper

import android.appwidget.AppWidgetManager
import android.content.Context
import android.widget.RemoteViews

/// 快捷入口 · 2×2：记一条 / 随机回顾 / 两个最常用标签。
///
/// 为什么不是 flomo 那套「新建 / 搜索 / 回顾 / 标签」：搜索与标签首页在
/// InkPaper 里没有可直达的深链，硬塞就是两个点了没反应的死按钮。
/// 换成「两个最常用标签」既保留 2×2 的四个热区，又每个都真能点到东西；
/// 没有标签数据时这两个退化成打开 App，不会空着。
class InkPaperQuickEntryWidgetProvider : BaseInkPaperWidgetProvider() {
    override fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val views = RemoteViews(context.packageName, R.layout.inkpaper_quick_entry_widget)
        views.setOnClickPendingIntent(
            R.id.inkpaper_widget_entry_compose,
            deepLinkPendingIntent(context, "inkpaper://quick-note", 70)
        )
        views.setOnClickPendingIntent(
            R.id.inkpaper_widget_entry_review,
            deepLinkPendingIntent(context, "inkpaper://random-review", 71)
        )

        val quickTags = snapshot(context)?.optJSONArray("quickTags")
        val slots = intArrayOf(
            R.id.inkpaper_widget_entry_tag_1,
            R.id.inkpaper_widget_entry_tag_2
        )
        for (index in slots.indices) {
            val tag = quickTags?.optString(index)?.trim().orEmpty()
            if (tag.isBlank()) {
                // 没有标签数据时不隐藏格子（会挖掉一块），改成打开 App
                views.setContentDescription(slots[index], "打开 InkPaper")
                views.setOnClickPendingIntent(
                    slots[index],
                    launchAppPendingIntent(context, 72 + index)
                )
            } else {
                views.setContentDescription(slots[index], "标签 #$tag")
                views.setOnClickPendingIntent(
                    slots[index],
                    deepLinkPendingIntent(
                        context,
                        "inkpaper://tag/${android.net.Uri.encode(tag)}",
                        72 + index
                    )
                )
            }
        }

        applyGlassBackground(context, views)
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}

/// 快速记录 · 4×1 细条：整条都是热区，点一下进编辑。
class InkPaperQuickRecordBarWidgetProvider : BaseInkPaperWidgetProvider() {
    override fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val views = RemoteViews(context.packageName, R.layout.inkpaper_quick_record_bar_widget)
        val todayCount = snapshot(context)
            ?.optJSONObject("today")
            ?.optInt("notes", 0)
            ?: 0
        views.setTextViewText(R.id.inkpaper_widget_bar_count, "今日 $todayCount 条")
        views.setOnClickPendingIntent(
            R.id.inkpaper_widget_glass_root,
            deepLinkPendingIntent(context, "inkpaper://quick-note", 75)
        )
        applyGlassBackground(context, views)
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
