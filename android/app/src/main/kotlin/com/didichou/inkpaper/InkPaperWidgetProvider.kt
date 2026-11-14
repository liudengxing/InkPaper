package com.didichou.inkpaper

import android.app.PendingIntent
import android.app.AlarmManager
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONObject

abstract class BaseInkPaperWidgetProvider : AppWidgetProvider() {
    final override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId)
        }
    }

    protected abstract fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    )

    protected fun snapshot(context: Context): JSONObject? {
        val raw = context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(SNAPSHOT_KEY, null)
        return try {
            if (raw.isNullOrBlank()) null else JSONObject(raw)
        } catch (e: Exception) {
            null
        }
    }

    protected fun deepLinkPendingIntent(
        context: Context,
        url: String,
        requestCode: Int
    ): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
            setPackage(context.packageName)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val immutableFlag =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag
        return PendingIntent.getActivity(context, requestCode, intent, flags)
    }

    /// 真玻璃背景：壁纸模糊位图可用则铺上（WallpaperGlass 烘焙，
    /// 已含圆角/底色/高光/暗边），拿不到壁纸就保持手绘玻璃兜底。
    protected fun applyGlassBackground(context: Context, views: RemoteViews) {
        val glass = WallpaperGlass.glassBitmap(context)
        android.util.Log.i(
            "WidgetGlass",
            "applyGlassBackground: glass=${if (glass != null) "${glass.width}x${glass.height}" else "null"}"
        )
        if (glass != null) {
            views.setViewVisibility(R.id.inkpaper_widget_glass, View.VISIBLE)
            views.setImageViewBitmap(R.id.inkpaper_widget_glass, glass)
        } else {
            views.setViewVisibility(R.id.inkpaper_widget_glass, View.GONE)
        }
    }

    companion object {
        const val PREFS_NAME = "inkpaper_widget"
        const val SNAPSHOT_KEY = "inkpaper_widget_snapshot"

        /// 按当前时间桶从快照里选出要展示的回顾笔记。Provider（时间行/调度）
        /// 与 ListView 工厂（预览文本）共用同一套选择逻辑，保证两边同一条。
        fun selectReviewNote(snapshot: JSONObject?): JSONObject? {
            val reviewNotes = snapshot?.optJSONArray("reviewNotes") ?: return null
            val reviewCount = reviewNotes.length()
            if (reviewCount == 0) return null
            val refreshMinutes =
                snapshot?.optJSONObject("reviewConfig")?.optInt("refreshIntervalMinutes", 60)
                    ?: 60
            val intervalMillis = refreshMinutes.coerceIn(15, 1440) * 60_000L
            val bucket = System.currentTimeMillis() / intervalMillis
            return reviewNotes.optJSONObject((bucket % reviewCount.toLong()).toInt())
        }
    }
}

class InkPaperQuickNoteWidgetProvider : BaseInkPaperWidgetProvider() {
    override fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val snapshot = snapshot(context)
        val views = RemoteViews(context.packageName, R.layout.inkpaper_quick_note_widget)
        val noteCount = snapshot?.optJSONObject("today")?.optInt("notes", 0) ?: 0
        val pendingTodos = snapshot?.optJSONObject("today")?.optInt("pendingTodos", 0) ?: 0
        val unsynced = snapshot?.optJSONObject("sync")?.optInt("unsyncedCount", 0) ?: 0
        val quickTags = snapshot?.optJSONArray("quickTags")

        views.setTextViewText(R.id.inkpaper_widget_subtitle, "今日 $noteCount 条")
        views.setTextViewText(
            R.id.inkpaper_widget_status,
            when {
                unsynced > 0 -> "$unsynced 条待同步"
                pendingTodos > 0 -> "$pendingTodos 个待办"
                else -> "静待沉淀，蓄势而鸣"
            }
        )
        views.setOnClickPendingIntent(
            R.id.inkpaper_widget_quick_note,
            deepLinkPendingIntent(context, "inkpaper://quick-note", 10)
        )

        val tagIds = intArrayOf(
            R.id.inkpaper_widget_tag_1,
            R.id.inkpaper_widget_tag_2,
            R.id.inkpaper_widget_tag_3
        )
        for (index in tagIds.indices) {
            val tag = quickTags?.optString(index).orEmpty()
            if (tag.isBlank()) {
                views.setViewVisibility(tagIds[index], View.GONE)
            } else {
                views.setViewVisibility(tagIds[index], View.VISIBLE)
                views.setTextViewText(tagIds[index], "#$tag")
                views.setOnClickPendingIntent(
                    tagIds[index],
                    deepLinkPendingIntent(
                        context,
                        "inkpaper://quick-note?tag=${Uri.encode(tag)}",
                        30 + index
                    )
                )
            }
        }

        applyGlassBackground(context, views)

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }
}

class InkPaperRandomReviewWidgetProvider : BaseInkPaperWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == ACTION_RANDOM_REVIEW_TICK) {
            updateAllReviewWidgets(context)
            scheduleReviewUpdate(context)
            return
        }
        super.onReceive(context, intent)
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        scheduleReviewUpdate(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        cancelReviewUpdate(context)
    }

    override fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val snapshot = snapshot(context)
        val views = RemoteViews(context.packageName, R.layout.inkpaper_random_review_widget)
        val reviewConfig = snapshot?.optJSONObject("reviewConfig")
        val refreshMinutes = reviewConfig?.optInt("refreshIntervalMinutes", 60) ?: 60
        val rangeDays = reviewConfig?.optInt("rangeDays", 0) ?: 0
        val review = selectReviewNote(snapshot)

        // 预览文本改由 RemoteViewsFactory 提供：单行长条目 ListView，
        // 文本超出小部件可视区时可以上下滚动（RemoteViews 里 ScrollView/
        // TextView 都不支持滚动，集合视图是唯一解）。
        // 选中的笔记 id 随 Intent 一起交给工厂：两边各自按时间桶算的话，
        // 跨桶瞬间会出现「时间行是 A、正文是 B」。
        val adapterIntent =
            Intent(context, InkPaperReviewListService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                putExtra(InkPaperReviewListService.EXTRA_REVIEW_ID, review?.optString("id").orEmpty())
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
        views.setRemoteAdapter(R.id.inkpaper_widget_review_list, adapterIntent)
        // 行点击 → 打开对应笔记（fillInIntent 提供 URI）；没有笔记可看时
        // 工厂会给兜底行填随机回顾页的 URI
        views.setPendingIntentTemplate(
            R.id.inkpaper_widget_review_list,
            templatePendingIntent(context)
        )
        val reviewTime = formatWidgetTime(review)
        if (reviewTime == null) {
            views.setViewVisibility(R.id.inkpaper_widget_review_time, View.GONE)
        } else {
            views.setViewVisibility(R.id.inkpaper_widget_review_time, View.VISIBLE)
            views.setTextViewText(R.id.inkpaper_widget_review_time, reviewTime)
        }
        views.setTextViewText(
            R.id.inkpaper_widget_status,
            "${formatRefresh(refreshMinutes)} · ${formatRange(rangeDays)}"
        )
        // 整块点击 → 直接打开「小部件上正在显示的这条笔记」。
        // 不再跳随机回顾列表页：那个页面进来会重新抽一批，跟这里显示的对不上，
        // 用户看到的和点开的必须是同一条。没有笔记时才退回列表页兜底。
        val reviewId = review?.optString("id").orEmpty()
        views.setOnClickPendingIntent(
            R.id.inkpaper_widget_review_container,
            deepLinkPendingIntent(
                context,
                if (reviewId.isNotBlank()) {
                    "inkpaper://note/$reviewId"
                } else {
                    "inkpaper://random-review"
                },
                50
            )
        )

        applyGlassBackground(context, views)
        appWidgetManager.updateAppWidget(appWidgetId, views)
        scheduleReviewUpdate(context, refreshMinutes)
    }

    /// PendingIntent 模板：本体不带 URI，行点击时由 fillInIntent 补上
    /// （fillIn 只补空缺字段，模板带 URI 会把行内笔记链接压掉）。
    /// ⚠️ 这里必须是 FLAG_MUTABLE：系统要往模板里填 fillInIntent，immutable
    /// 的 PendingIntent 会拒绝填充 —— 表现就是点正文毫无反应（点标题却正常，
    /// 因为容器用的是自带完整 URI 的 immutable PendingIntent）。
    private fun templatePendingIntent(context: Context): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setPackage(context.packageName)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val mutableFlag =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        return PendingIntent.getActivity(
            context,
            60,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag
        )
    }

    /// 展示笔记创建时间。Dart 侧已按本地时区格式化好（createdAtLabel），
    /// 直接用；老快照没有该字段时才退回裁剪 ISO 字符串。
    private fun formatWidgetTime(note: JSONObject?): String? {
        if (note == null) return null
        val label = note.optString("createdAtLabel")
        if (label.isNotBlank()) return label
        val iso = note.optString("createdAt")
        if (iso.length < 16) return null
        return iso.substring(0, 10) + " " + iso.substring(11, 16)
    }

    private fun formatRefresh(minutes: Int): String =
        if (minutes < 60) "${minutes}分钟刷新" else "${minutes / 60}小时刷新"

    private fun formatRange(days: Int): String =
        when (days) {
            0 -> "全部"
            30 -> "近30天"
            90 -> "近90天"
            180 -> "近半年"
            365 -> "近一年"
            else -> "${days}天"
        }

    private fun updateAllReviewWidgets(context: Context) {
        val appWidgetManager = AppWidgetManager.getInstance(context)
        val widgetIds = appWidgetManager.getAppWidgetIds(
            ComponentName(context, InkPaperRandomReviewWidgetProvider::class.java)
        )
        for (appWidgetId in widgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId)
        }
    }

    private fun scheduleReviewUpdate(context: Context, refreshMinutes: Int = currentRefreshMinutes(context)) {
        val appWidgetManager = AppWidgetManager.getInstance(context)
        val widgetIds = appWidgetManager.getAppWidgetIds(
            ComponentName(context, InkPaperRandomReviewWidgetProvider::class.java)
        )
        if (widgetIds.isEmpty()) {
            cancelReviewUpdate(context)
            return
        }

        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val intervalMillis = refreshMinutes.coerceIn(15, 1440) * 60_000L
        val pendingIntent = reviewUpdatePendingIntent(context)
        alarmManager.cancel(pendingIntent)
        alarmManager.setInexactRepeating(
            AlarmManager.RTC,
            System.currentTimeMillis() + intervalMillis,
            intervalMillis,
            pendingIntent
        )
    }

    private fun cancelReviewUpdate(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        alarmManager.cancel(reviewUpdatePendingIntent(context))
    }

    private fun currentRefreshMinutes(context: Context): Int {
        val snapshot = snapshot(context)
        return snapshot
            ?.optJSONObject("reviewConfig")
            ?.optInt("refreshIntervalMinutes", 60)
            ?: 60
    }

    private fun reviewUpdatePendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, InkPaperRandomReviewWidgetProvider::class.java).apply {
            action = ACTION_RANDOM_REVIEW_TICK
        }
        val immutableFlag =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        return PendingIntent.getBroadcast(
            context,
            92,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag
        )
    }

    companion object {
        private const val ACTION_RANDOM_REVIEW_TICK =
            "com.didichou.inkpaper.action.RANDOM_REVIEW_WIDGET_TICK"
    }
}

/// 随机回顾预览文本的滚动数据源：RemoteViews 里只有集合视图
/// （ListView/GridView/Stack）能滚动，「单行长条目」是各家小部件
/// 实现长文本滚动的通用做法。
class InkPaperReviewListService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsService.RemoteViewsFactory =
        InkPaperReviewListFactory(this, intent)

    companion object {
        /// Provider 已选定的笔记 id：正文、时间行、点击跳转必须同一条
        const val EXTRA_REVIEW_ID = "inkpaper.reviewId"
    }
}

class InkPaperReviewListFactory(
    private val context: Context,
    private val intent: Intent
) : RemoteViewsService.RemoteViewsFactory {

    private var review: JSONObject? = null
    private var hasSnapshot = false

    override fun onCreate() {}

    override fun onDataSetChanged() {
        val raw = context
            .getSharedPreferences(BaseInkPaperWidgetProvider.PREFS_NAME, Context.MODE_PRIVATE)
            .getString(BaseInkPaperWidgetProvider.SNAPSHOT_KEY, null)
        val snapshot = raw?.takeIf { it.isNotBlank() }?.let {
            try {
                JSONObject(it)
            } catch (e: Exception) {
                null
            }
        }
        hasSnapshot = snapshot != null && snapshot.optString("generatedAt").isNotBlank()
        // 优先用 Provider 传进来的 id（保证与时间行、点击目标同一条），
        // 老版本传不进来时才按时间桶自己算一次
        val wantedId = intent.getStringExtra(InkPaperReviewListService.EXTRA_REVIEW_ID).orEmpty()
        review = findReviewById(snapshot, wantedId)
            ?: BaseInkPaperWidgetProvider.selectReviewNote(snapshot)
    }

    private fun findReviewById(snapshot: JSONObject?, id: String): JSONObject? {
        if (id.isBlank()) return null
        val notes = snapshot?.optJSONArray("reviewNotes") ?: return null
        for (index in 0 until notes.length()) {
            val note = notes.optJSONObject(index) ?: continue
            if (note.optString("id") == id) return note
        }
        return null
    }

    override fun onDestroy() {}

    override fun getCount(): Int = 1

    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.inkpaper_widget_review_row)
        val text = review?.optString("preview")?.takeIf { it.isNotBlank() }
            ?: if (hasSnapshot) "暂无可回顾笔记" else "打开 InkPaper 同步小组件"
        views.setTextViewText(R.id.inkpaper_widget_review_row_text, text)
        // 有笔记 → 点行进笔记；空状态 → 进随机回顾页兜底
        val reviewId = review?.optString("id").orEmpty()
        views.setOnClickFillInIntent(
            R.id.inkpaper_widget_review_row,
            if (reviewId.isNotBlank()) {
                Intent(Intent.ACTION_VIEW, Uri.parse("inkpaper://note/$reviewId"))
            } else {
                Intent(Intent.ACTION_VIEW, Uri.parse("inkpaper://random-review"))
            }
        )
        return views
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = false
}
