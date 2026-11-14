package com.didichou.inkpaper

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * HEIC/HEIF 缩略图的原生解码。
 *
 * Dart 侧的 `package:image` 没有 HEVC 解码器，而 Android 从 API 28（P）起
 * 平台自带 HEIF 支持。这里用 [ImageDecoder] 而不是 BitmapFactory：前者会
 * 自动套用 EXIF 方向、处理色彩空间，而 BitmapFactory 解出来的是传感器
 * 方向，iPhone 竖拍的照片会横着躺进缩略图，还得自己读 ExifInterface 再转。
 *
 * 输出统一是 JPEG —— HEIC 没有透明通道，不需要 PNG。
 */
object ThumbnailDecoder {

    private const val TAG = "ThumbnailDecoder"

    /** 与 Dart 侧 `ThumbCache._jpegQuality` 保持一致。 */
    private const val JPEG_QUALITY = 82

    /**
     * 两路并发，和 Dart 侧 `_maxConcurrentEncodes` 对齐。
     *
     * 信息流里快速划过多图笔记时 `ensure` 会连着提交好几张 HEIC，单线程串行
     * 会让后面的笔记干等前一张解完。
     */
    private val executor = Executors.newFixedThreadPool(2)

    /**
     * 在后台线程解码，结果通过 [onDone] 回调（仍在后台线程）。
     *
     * MethodChannel 的 result 必须在 platform 线程回调，所以这里只负责把
     * 解码挪出主线程，切回主线程由调用方处理（见 MainActivity）。
     */
    fun decode(path: String, targetWidth: Int, onDone: (ByteArray?) -> Unit) {
        executor.execute {
            val bytes = try {
                decodeSync(path, targetWidth)
            } catch (t: Throwable) {
                ReleaseLog.e(TAG, "HEIC 缩略图解码失败: ${t.message}", t)
                null
            }
            onDone(bytes)
        }
    }

    private fun decodeSync(path: String, targetWidth: Int): ByteArray? {
        // ImageDecoder 是 API 28 才有的；更老的系统没有 HEIF 解码器，
        // 返回 null 让 Dart 侧退回原图，表现与没有这条通道时完全一致。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return null
        }
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            return null
        }
        val width = if (targetWidth > 0) targetWidth else 480
        val decoded = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            // 硬件位图读不了像素，缩放会直接抛异常，必须软件分配
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            // HEIC 常见 Display P3 / 10bit HDR，统一落到 sRGB 8bit，
            // 否则压出来的 JPEG 会偏色。
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
            // 一张 12MP 的 HEIC 全量解出来是 48MB，先用 2 的幂采样削到
            // 目标宽度的两倍以内，再精缩一次，省掉大头。
            decoder.setTargetSampleSize(sampleSizeFor(info.size.width, width))
        }
        val scaled = if (decoded.width > width) {
            val height = (decoded.height.toLong() * width / decoded.width)
                .coerceAtLeast(1L)
                .toInt()
            Bitmap.createScaledBitmap(decoded, width, height, true)
        } else {
            decoded
        }
        val out = ByteArrayOutputStream()
        val ok = scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
        if (scaled !== decoded) {
            decoded.recycle()
        }
        scaled.recycle()
        return if (ok && out.size() > 0) out.toByteArray() else null
    }

    /**
     * 采样步长只能是 2 的幂，取「解出来仍然不小于目标宽度」的最大值。
     *
     * 源宽 4032、目标 480 时：1→2→4→8（4032/8 = 504 ≥ 480），再到 16 就
     * 只剩 252 宽了，会糊。所以停在 8，解出 504 宽再精缩到 480。
     */
    private fun sampleSizeFor(sourceWidth: Int, targetWidth: Int): Int {
        if (sourceWidth <= 0 || targetWidth <= 0) {
            return 1
        }
        var sample = 1
        while (sourceWidth / (sample * 2) >= targetWidth) {
            sample *= 2
        }
        return sample
    }
}
