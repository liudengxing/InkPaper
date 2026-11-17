package com.didichou.inkpaper

import android.appwidget.AppWidgetManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import android.widget.RemoteViews
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/// 统计组件的四种组合：周/月 × 格子/柱状。
///
/// 图表不是用 RemoteViews 堆出来的：格子墙一个月要 30+ 个方块，一个个
/// View 塞进 RemoteViews 会让 launcher 每次刷新都重新 measure/layout 上百个
/// 子视图；改成 Kotlin 侧用 Canvas 画成一张位图塞进 ImageView，一次 setImageBitmap
/// 就完事，也省掉「View 不可用、只能 ImageView/TextView」的白名单限制。
///
/// 位图按固定像素画（不乘 density）：RemoteViews 对位图内存有硬上限，
/// 4×2 按屏幕密度画会到 4MB 级别。纯色直角块放大一点看不出来，不赌那个内存。
enum class WidgetChartStyle { GRID, BAR }

enum class WidgetStatsPeriod { WEEK, MONTH }

abstract class BaseStatsWidgetProvider : BaseInkPaperWidgetProvider() {
    protected abstract val period: WidgetStatsPeriod
    protected abstract val style: WidgetChartStyle
    protected abstract val wide: Boolean

    /// 位图画布尺寸。宽一点更细腻，但别超过 RemoteViews 的位图内存预算。
    /// 宽高比尽量贴近实际图表区（2×2 是偏高的小方块，4×2 是扁长条），
    /// 这样 fitXY 拉伸时格子不会被压成奇怪的形状。
    protected open val bitmapWidth: Int
        get() = if (wide) 800 else 320
    protected open val bitmapHeight: Int
        get() = if (wide) 220 else 240

    override fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        val layoutRes = if (wide) {
            R.layout.inkpaper_widget_stats_wide
        } else {
            R.layout.inkpaper_widget_stats_small
        }
        val views = RemoteViews(context.packageName, layoutRes)
        val stats = snapshot(context)
            ?.optJSONObject("stats")
            ?.optJSONObject(if (period == WidgetStatsPeriod.WEEK) "week" else "month")

        val days = stats?.optJSONArray("days")
        val counts = IntArray(days?.length() ?: 0) { days?.optInt(it, 0) ?: 0 }
        val total = stats?.optInt("total", counts.sum()) ?: counts.sum()
        val todayIndex = stats?.optInt("todayIndex", -1) ?: -1
        val firstWeekday = stats?.optInt("firstWeekday", 1) ?: 1

        views.setTextViewText(
            R.id.inkpaper_widget_stats_title,
            if (period == WidgetStatsPeriod.WEEK) "本周" else "本月"
        )
        val activeDays = counts.count { it > 0 }
        views.setTextViewText(
            R.id.inkpaper_widget_stats_total,
            if (wide) "$total 条 · $activeDays 天" else "$total 条"
        )

        val chart = when (style) {
            WidgetChartStyle.GRID -> drawGrid(counts, todayIndex, firstWeekday)
            WidgetChartStyle.BAR -> drawBars(counts, todayIndex)
        }
        views.setImageViewBitmap(R.id.inkpaper_widget_stats_chart, chart)
        views.setOnClickPendingIntent(
            R.id.inkpaper_widget_glass_root,
            launchAppPendingIntent(context, 60 + layoutRes)
        )
        applyGlassBackground(context, views)
        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    /// 格子墙：一周铺一行七格；一个月按周对齐，最多六行。
    /// 今天那一格描边，让「今天还没写」这件事一眼可见。
    private fun drawGrid(
        counts: IntArray,
        todayIndex: Int,
        firstWeekday: Int
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(bitmapWidth, bitmapHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        if (counts.isEmpty()) return bitmap

        val offset = if (period == WidgetStatsPeriod.MONTH) firstWeekday - 1 else 0
        val columns = 7
        val rows = ceil((offset + counts.size).toFloat() / columns).toInt().coerceAtLeast(1)
        val gap = bitmapWidth * 0.018f
        // 列宽跟画布铺满，行高按可用高度平分；只有单行（一周）时才取正方形，
        // 否则七格会被拉成又高又窄的条。
        val cellWidth = (bitmapWidth - gap * (columns - 1)) / columns
        val rowSpace = (bitmapHeight - gap * (rows - 1)) / rows
        val cellHeight = if (rows == 1) min(cellWidth, rowSpace) else rowSpace
        val radius = min(cellWidth, cellHeight) * 0.26f

        val gridHeight = cellHeight * rows + gap * (rows - 1)
        val startY = (bitmapHeight - gridHeight) / 2f

        val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        val todayStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = max(2f, min(cellWidth, cellHeight) * 0.09f)
            color = Color.parseColor("#1F6B52")
        }

        counts.forEachIndexed { index, count ->
            val slot = index + offset
            val column = slot % columns
            val row = slot / columns
            val left = column * (cellWidth + gap)
            val top = startY + row * (cellHeight + gap)
            val rect = RectF(left, top, left + cellWidth, top + cellHeight)
            fill.color = levelColor(count)
            canvas.drawRoundRect(rect, radius, radius, fill)
            if (index == todayIndex) {
                canvas.drawRoundRect(rect, radius, radius, todayStroke)
            }
        }
        return bitmap
    }

    /// 柱状：天数多的时候一根柱子只有十几像素，所以不画圆角也不画描边，
    /// 高度按当周/当月最大值归一。
    private fun drawBars(counts: IntArray, todayIndex: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(bitmapWidth, bitmapHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        if (counts.isEmpty()) return bitmap

        val maxCount = max(counts.maxOrNull() ?: 0, 1)
        val gap = bitmapWidth / (counts.size * 3.2f)
        val barWidth = (bitmapWidth - gap * (counts.size - 1)) / counts.size
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val radius = min(barWidth / 2f, bitmapHeight * 0.03f)

        counts.forEachIndexed { index, count ->
            val left = index * (barWidth + gap)
            val ratio = count.toFloat() / maxCount
            // 有条目的日子最少留一点高度，否则「1 条」和「0 条」看起来一样
            val height = if (count == 0) {
                bitmapHeight * 0.045f
            } else {
                max(bitmapHeight * ratio, bitmapHeight * 0.12f)
            }
            val top = bitmapHeight - height
            paint.color = if (index == todayIndex && count > 0) {
                Color.parseColor("#1F6B52")
            } else {
                levelColor(count)
            }
            val rect = RectF(left, top, left + barWidth, bitmapHeight.toFloat())
            canvas.drawRoundRect(rect, radius, radius, paint)
        }
        return bitmap
    }

    /// 五档色阶，和应用内热力图同一套绿：0 条是最浅的底格。
    private fun levelColor(count: Int): Int = when {
        count <= 0 -> Color.parseColor("#E7EAE8")
        count == 1 -> Color.parseColor("#C3DED4")
        count == 2 -> Color.parseColor("#8FC7B2")
        count <= 4 -> Color.parseColor("#5CAE90")
        else -> Color.parseColor("#2C9678")
    }
}

/// 周统计 · 2×2：七格看这一周哪天写了。
class InkPaperWeekStatsWidgetProvider : BaseStatsWidgetProvider() {
    override val period = WidgetStatsPeriod.WEEK
    override val style = WidgetChartStyle.GRID
    override val wide = false
    override val bitmapHeight: Int = 150
}

/// 周趋势 · 2×2：七根柱看这一周的高低。
class InkPaperWeekTrendWidgetProvider : BaseStatsWidgetProvider() {
    override val period = WidgetStatsPeriod.WEEK
    override val style = WidgetChartStyle.BAR
    override val wide = false
    override val bitmapHeight: Int = 150
}

/// 月统计 · 4×2：整月格子墙，按周对齐。
class InkPaperMonthStatsWidgetProvider : BaseStatsWidgetProvider() {
    override val period = WidgetStatsPeriod.MONTH
    override val style = WidgetChartStyle.GRID
    override val wide = true
}

/// 月趋势 · 4×2：整月逐日柱状。
class InkPaperMonthTrendWidgetProvider : BaseStatsWidgetProvider() {
    override val period = WidgetStatsPeriod.MONTH
    override val style = WidgetChartStyle.BAR
    override val wide = true
}
