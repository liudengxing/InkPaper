package com.didichou.inkpaper

import android.appwidget.AppWidgetManager
import android.content.Context
import android.widget.RemoteViews
import org.json.JSONObject

/// 置顶笔记小组件：把 Note.isPinned 的那一条常驻桌面。
/// 对应 flomo 的「置顶」组件（大 4×4 / 小 4×2 两档）。
///
/// 没有「换一条」——置顶本来就是用户自己钉死的那一条，能换就不叫置顶了。
/// 点击直接进那条笔记；没有置顶时退回首页，别给个点不动的死块。
abstract class BasePinnedWidgetProvider : BaseInkPaperWidgetProvider() {
    protected abstract val wide: Boolean

    override fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val layoutRes = if (wide) {
            R.layout.inkpaper_pinned_widget_large
        } else {
            R.layout.inkpaper_pinned_widget_compact
        }
        val views = RemoteViews(context.packageName, layoutRes)
        val snapshot = snapshot(context)
        val hasSnapshot = !snapshot?.optString("generatedAt").isNullOrBlank()
        val pinned = snapshot?.optJSONObject("pinnedNote")

        if (pinned == null) {
            views.setTextViewText(
                R.id.inkpaper_widget_pinned_text,
                if (hasSnapshot) {
                    "还没有置顶笔记。长按一条笔记选「置顶」，它就会一直待在这里。"
                } else {
                    "打开 InkPaper 同步小组件"
                }
            )
            views.setTextViewText(R.id.inkpaper_widget_pinned_time, "")
            views.setOnClickPendingIntent(
                R.id.inkpaper_widget_glass_root,
                launchAppPendingIntent(context, 20 + layoutRes)
            )
        } else {
            val preview = if (wide) {
                pinned.optString("previewLong").takeIf { it.isNotBlank() }
                    ?: pinned.optString("preview")
            } else {
                pinned.optString("preview")
            }
            views.setTextViewText(
                R.id.inkpaper_widget_pinned_text,
                preview.takeIf { it.isNotBlank() } ?: "这条笔记没有正文"
            )
            views.setTextViewText(
                R.id.inkpaper_widget_pinned_time,
                if (wide) caption(pinned) else createdAtLabel(pinned)
            )
            val noteId = pinned.optString("id")
            views.setOnClickPendingIntent(
                R.id.inkpaper_widget_glass_root,
                if (noteId.isNotBlank()) {
                    deepLinkPendingIntent(context, "inkpaper://note/$noteId", 40 + layoutRes)
                } else {
                    launchAppPendingIntent(context, 20 + layoutRes)
                }
            )
        }

        applyGlassBackground(context, views)
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    /// 大卡底部一行：「时间 · #标签」；标签为空就只留时间。
    private fun caption(note: JSONObject): String {
        val time = createdAtLabel(note)
        if (time.isBlank()) return ""
        val tags = note.optJSONArray("tags") ?: return time
        val tagText = buildString {
            for (index in 0 until tags.length()) {
                val tag = tags.optString(index).trim()
                if (tag.isEmpty()) continue
                if (isNotEmpty()) append(' ')
                append(if (tag.startsWith("#")) tag else "#$tag")
            }
        }
        return if (tagText.isBlank()) time else "$time · $tagText"
    }

    /// Dart 侧格式化好的本地时间直接取用；老快照才退回裁 ISO 串。
    /// 这里坚决不解析成时间对象——Memos 的 ISO 串带 Z 但其实是本地挂钟时间。
    private fun createdAtLabel(note: JSONObject): String {
        val label = note.optString("createdAtLabel")
        if (label.isNotBlank()) return label
        val iso = note.optString("createdAt")
        if (iso.length < 16) return ""
        return iso.substring(0, 10) + " " + iso.substring(11, 16)
    }
}

/// 置顶 · 4×4：整条读完的量。
class InkPaperPinnedWidgetProvider : BasePinnedWidgetProvider() {
    override val wide = true
}

/// 置顶 · 4×2：露开头三行。
class InkPaperPinnedCompactWidgetProvider : BasePinnedWidgetProvider() {
    override val wide = false
}
