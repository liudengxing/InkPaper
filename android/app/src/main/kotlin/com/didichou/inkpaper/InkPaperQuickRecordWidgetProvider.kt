package com.didichou.inkpaper

import android.appwidget.AppWidgetManager
import android.content.Context
import android.widget.RemoteViews

/// 快速记录 · 2×2：上格写字、下格说话，对应 flomo 的「快速记录 · 2×2」。
///
/// 语音格没有另起录音链路：深链带上 voice=1，编辑态起来后由编辑器自己的
/// startWithSpeech 开录音。语音输入没配好时编辑器会照常打开，不会点了没反应。
class InkPaperQuickRecordWidgetProvider : BaseInkPaperWidgetProvider() {
    override fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val views = RemoteViews(context.packageName, R.layout.inkpaper_quick_record_widget)
        views.setOnClickPendingIntent(
            R.id.inkpaper_widget_record_text,
            deepLinkPendingIntent(context, "inkpaper://quick-note", 80)
        )
        views.setOnClickPendingIntent(
            R.id.inkpaper_widget_record_voice,
            deepLinkPendingIntent(context, "inkpaper://quick-note?voice=1", 81)
        )
        applyGlassBackground(context, views)
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}
