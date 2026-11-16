package com.didichou.inkpaper

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Dart 侧做不了的缩略图解码，统一走这里：HEIC/HEIF 与视频首帧。
 *
 * - **HEIC**：`package:image` 没有 HEVC 解码器，而 Android 从 API 28（P）起
 *   平台自带 HEIF 支持。这里用 [ImageDecoder] 而不是 BitmapFactory：前者会
 *   自动套用 EXIF 方向、处理色彩空间，而 BitmapFactory 解出来的是传感器
 *   方向，iPhone 竖拍的照片会横着躺进缩略图。
 * - **视频**：Dart 侧完全没有视频解码能力，用 [MediaMetadataRetriever] 取
 *   第 0 秒的关键帧，比先起一个播放器再抓帧快得多。
 *
 * 两者输出统一是 JPEG —— 都没有透明通道，不需要 PNG。
 */
object ThumbnailDecoder {

    private const val TAG = "ThumbnailDecoder"

    /** 与 Dart 侧 `ThumbCache._jpegQuality` 保持一致。 */
    private const val JPEG_QUALITY = 82

    /** 与 Dart 侧 `MediaPaths.videoExtensions` 保持一致。 */
    private val videoExtensions = setOf(
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "3gp",
    )

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
                ReleaseLog.e(TAG, "缩略图解码失败: ${t.message}", t)
                null
            }
            onDone(bytes)
        }
    }

    private fun decodeSync(path: String, targetWidth: Int): ByteArray? {
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            return null
        }
        val width = if (targetWidth > 0) targetWidth else 480
        return if (isVideo(path)) {
            decodeVideoFrame(file, width)
        } else {
            decodeImageFrame(file, width)
        }
    }

    private fun isVideo(path: String): Boolean {
        val dot = path.lastIndexOf('.')
        if (dot < 0 || dot == path.length - 1) {
            return false
        }
        val ext = path.substring(dot + 1).lowercase(Locale.ROOT)
        // 去掉可能附带在扩展名后面的查询串（服务端 URL 会带）
        val pure = ext.substringBefore('?').substringBefore('#')
        return pure in videoExtensions
    }

    private fun decodeImageFrame(file: File, width: Int): ByteArray? {
        // ImageDecoder 是 API 28 才有的；更老的系统没有 HEIF 解码器，
        // 返回 null 让 Dart 侧退回原图，表现与没有这条通道时完全一致。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return null
        }
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
        return compressScaled(decoded, width)
    }

    /**
     * 取视频第 0 秒的关键帧。
     *
     * 4K 帧解出来是 33MB 位图，所以能用 [MediaMetadataRetriever.getScaledFrameAtTime]
     * （API 27+）时直接解到目标尺寸；更老的版本退回全尺寸再缩。
     */
    private fun decodeVideoFrame(file: File, width: Int): ByteArray? {
        val retriever = MediaMetadataRetriever()
        var bitmap: Bitmap? = null
        try {
            retriever.setDataSource(file.absolutePath)
            val sourceWidth = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
            val sourceHeight = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0

            val raw = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 &&
                sourceWidth > 0 && sourceHeight > 0
            ) {
                val targetHeight = (width.toLong() * sourceHeight / sourceWidth)
                    .coerceAtLeast(1L)
                    .toInt()
                retriever.getScaledFrameAtTime(
                    0,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    width,
                    targetHeight,
                )
            } else {
                retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            } ?: return null
            bitmap = raw

            // 大多数机型返回的帧已经套用了旋转元数据，但个别机型会给出传感器
            // 方向（竖拍视频躺倒）。这里的判据是「元数据说转了、像素却是横的」。
            val rotation = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            if ((rotation == 90 || rotation == 270) && raw.width > raw.height) {
                val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
                val rotated = Bitmap.createBitmap(
                    raw, 0, 0, raw.width, raw.height, matrix, true,
                )
                if (rotated !== raw) {
                    raw.recycle()
                    bitmap = rotated
                }
            }

            return compressScaled(bitmap, width)
        } finally {
            retriever.release()
        }
    }

    /** 缩到目标宽度后压成 JPEG；入参位图由这里负责回收。 */
    private fun compressScaled(source: Bitmap, width: Int): ByteArray? {
        val scaled = if (source.width > width) {
            val height = (source.height.toLong() * width / source.width)
                .coerceAtLeast(1L)
                .toInt()
            Bitmap.createScaledBitmap(source, width, height, true)
        } else {
            source
        }
        val out = ByteArrayOutputStream()
        val ok = scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
        if (scaled !== source) {
            source.recycle()
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
