package com.didichou.inkpaper

import android.app.WallpaperManager
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.drawable.BitmapDrawable
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import kotlin.math.max

/// 小部件的真玻璃背景。
///
/// Android 的 RemoteViews 渲染在 launcher 进程里，拿不到窗口级实时模糊
/// （Android 12+ 的 window blur 只对 Activity/Dialog 生效），所以各家 APP
/// 实现 iOS 式玻璃小部件的通用做法是：把系统壁纸读出来 → 压小再放大做
/// 高斯感模糊 → 叠上底色、斜向高光、暗边 → 裁出圆角交给 ImageView 显示。
///
/// 壁纸没变就命中磁盘缓存，不重复烘焙；动态壁纸/读取失败返回 null，
/// 布局会回退到手绘玻璃背景（inkpaper_widget_background）。
object WallpaperGlass {
    private const val PREFS_NAME = "inkpaper_widget"
    private const val KEY_WALLPAPER_ID = "inkpaper_widget_glass_wallpaper_id"
    private const val CACHE_FILE = "inkpaper_widget_glass.png"

    /// 输出位图尺寸：远小于真实壁纸，模糊后视觉效果一致且省内存/IPC 体积。
    private const val OUTPUT_WIDTH = 512
    private const val OUTPUT_HEIGHT = 320

    /// 与布局圆角一致（inkpaper_widget_background 的 22dp）。
    private const val CORNER_RADIUS_DP = 22f

    private const val BASE_WIDTH_DP = 320f

    fun glassBitmap(context: Context): Bitmap? {
        val wallpaperManager = WallpaperManager.getInstance(context)
        // 壁纸 id 从 API 24 开始提供；拿不到就当作「未知」，跳过缓存直接重算
        val wallpaperId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                wallpaperManager.getWallpaperId(WallpaperManager.FLAG_SYSTEM)
            } catch (e: Exception) {
                Int.MIN_VALUE
            }
        } else {
            Int.MIN_VALUE
        }

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val cacheFile = File(context.cacheDir, CACHE_FILE)
        val cachedId = prefs.getInt(KEY_WALLPAPER_ID, Int.MIN_VALUE)
        if (cachedId == wallpaperId && cacheFile.exists()) {
            try {
                BitmapFactory.decodeFile(cacheFile.absolutePath)?.let { return it }
            } catch (e: Exception) {
                // 缓存损坏就重算
            }
        }

        val wallpaper = try {
            wallpaperManager.drawable
        } catch (e: Exception) {
            null
        } ?: return null
        var ownsSource = false
        val source = decodeWallpaper(wallpaper) { ownsSource = true } ?: return null

        val result = try {
            bakeGlass(context, source)
        } finally {
            // 只有我们自己创建的位图才回收；BitmapDrawable 里的可能是
            // WallpaperManager 的缓存，recycle 后再次取壁纸会崩
            if (ownsSource && !source.isRecycled) {
                source.recycle()
            }
        }
        try {
            FileOutputStream(cacheFile).use { out ->
                result.compress(Bitmap.CompressFormat.PNG, 100, out)
            }
            prefs.edit().putInt(KEY_WALLPAPER_ID, wallpaperId).apply()
        } catch (e: Exception) {
            // 缓存写失败不影响本次显示
        }
        return result
    }

    /// 壁纸 Drawable 统一转成 Bitmap（动态壁纸等非位图 Drawable 画到画布上）。
    /// [onCreated] 标记返回的位图是本次新建的（可安全回收）。
    private fun decodeWallpaper(
        wallpaper: android.graphics.drawable.Drawable,
        onCreated: () -> Unit,
    ): Bitmap? =
        try {
            if (wallpaper is BitmapDrawable) {
                wallpaper.bitmap
            } else {
                val w = wallpaper.intrinsicWidth.takeIf { it > 0 } ?: OUTPUT_WIDTH
                val h = wallpaper.intrinsicHeight.takeIf { it > 0 } ?: OUTPUT_HEIGHT
                val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                wallpaper.setBounds(0, 0, w, h)
                wallpaper.draw(canvas)
                onCreated()
                bitmap
            }
        } catch (e: Exception) {
            null
        }

    /// 壁纸 → 中央裁剪 → 缩小再放大（双线性插值的廉价模糊，效果接近
    /// 高斯模糊且远快于像素级卷积）→ 叠底色/高光/暗边 → 圆角蒙版。
    private fun bakeGlass(context: Context, source: Bitmap): Bitmap {
        val cropped = centerCrop(source, OUTPUT_WIDTH, OUTPUT_HEIGHT)

        // 缩到约 1/12 再放大：双线性插值天然抹平高频细节，就是「磨砂玻璃」
        val smallWidth = (OUTPUT_WIDTH / 12f).toInt().coerceAtLeast(16)
        val smallHeight = (OUTPUT_HEIGHT / 12f).toInt().coerceAtLeast(16)
        val small = Bitmap.createScaledBitmap(cropped, smallWidth, smallHeight, true)
        val blurred = Bitmap.createScaledBitmap(small, OUTPUT_WIDTH, OUTPUT_HEIGHT, true)

        // 输出位图代表约 320dp 宽的小部件，圆角/描边按比例换算成像素
        val dpScale = OUTPUT_WIDTH / BASE_WIDTH_DP
        val radiusPx = CORNER_RADIUS_DP * dpScale
        val borderPx = 1f * dpScale
        val systemNight = isSystemNightMode()
        val tint = colorOf(context, if (systemNight) R.color.inkpaper_widget_glass_tint_night else R.color.inkpaper_widget_glass_tint)
        val highlightStart = colorOf(
            context,
            if (systemNight) {
                R.color.inkpaper_widget_glass_highlight_start_night
            } else {
                R.color.inkpaper_widget_glass_highlight_start
            },
        )
        val highlightEnd = colorOf(
            context,
            if (systemNight) {
                R.color.inkpaper_widget_glass_highlight_end_night
            } else {
                R.color.inkpaper_widget_glass_highlight_end
            },
        )
        val borderColor = colorOf(
            context,
            if (systemNight) R.color.inkpaper_widget_glass_border_night else R.color.inkpaper_widget_glass_border,
        )

        val layer = Bitmap.createBitmap(OUTPUT_WIDTH, OUTPUT_HEIGHT, Bitmap.Config.ARGB_8888)
        val layerCanvas = Canvas(layer)
        val rect = RectF(0f, 0f, OUTPUT_WIDTH.toFloat(), OUTPUT_HEIGHT.toFloat())
        layerCanvas.drawBitmap(blurred, 0f, 0f, null)
        // 底色：磨砂的主要观感来源
        layerCanvas.drawColor(tint)
        // 斜向高光：玻璃 glint
        layerCanvas.drawRect(
            rect,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(
                    0f,
                    0f,
                    OUTPUT_WIDTH.toFloat(),
                    OUTPUT_HEIGHT.toFloat(),
                    highlightStart,
                    highlightEnd,
                    Shader.TileMode.CLAMP,
                )
            },
        )
        // 暗边：玻璃 rim（inset 会原地修改，复制一份）
        val borderRect = RectF(rect)
        borderRect.inset(borderPx / 2f, borderPx / 2f)
        layerCanvas.drawRect(
            borderRect,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = borderPx
                color = borderColor
            },
        )

        // 圆角裁切：DST_IN 抗锯齿蒙版，避免 clipPath 的直角锯齿
        val result = Bitmap.createBitmap(OUTPUT_WIDTH, OUTPUT_HEIGHT, Bitmap.Config.ARGB_8888)
        val resultCanvas = Canvas(result)
        resultCanvas.drawBitmap(layer, 0f, 0f, null)
        val mask = Bitmap.createBitmap(OUTPUT_WIDTH, OUTPUT_HEIGHT, Bitmap.Config.ARGB_8888)
        Canvas(mask).drawRoundRect(
            rect,
            radiusPx,
            radiusPx,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK },
        )
        resultCanvas.drawBitmap(
            mask,
            0f,
            0f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN)
            },
        )
        mask.recycle()
        layer.recycle()
        return result
    }

    /// 中央裁剪到目标宽高比。
    private fun centerCrop(source: Bitmap, outWidth: Int, outHeight: Int): Bitmap {
        val scale = max(
            outWidth / source.width.toFloat(),
            outHeight / source.height.toFloat(),
        )
        val scaledWidth = (source.width * scale).toInt().coerceAtLeast(outWidth)
        val scaledHeight = (source.height * scale).toInt().coerceAtLeast(outHeight)
        val scaled = Bitmap.createScaledBitmap(source, scaledWidth, scaledHeight, true)
        val offsetX = ((scaledWidth - outWidth) / 2).coerceIn(0, (scaledWidth - outWidth).coerceAtLeast(0))
        val offsetY = ((scaledHeight - outHeight) / 2).coerceIn(0, (scaledHeight - outHeight).coerceAtLeast(0))
        return Bitmap.createBitmap(scaled, offsetX, offsetY, outWidth, outHeight)
    }

    /// App 进程的主题可能与系统不一致，位图叠色必须以系统明暗为准。
    private fun isSystemNightMode(): Boolean =
        (Resources.getSystem().configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    private fun colorOf(context: Context, id: Int): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.resources.getColor(id, null)
        } else {
            @Suppress("DEPRECATION")
            context.resources.getColor(id)
        }
}
