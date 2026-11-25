package dev.doclens.doclens

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileOutputStream
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Fast, EXIF-aware "small upright copy of part of a photo" for the Dart
 * detectors, so they never decode a 12–50 MP JPEG themselves.
 */
internal object UprightRegion {
    /**
     * [left]..[bottom] are normalized in the *upright* image. The crop is
     * scaled so its long side is at most [maxSide]. Returns the JPEG path and
     * the full upright size of the original.
     */
    fun extract(
        context: Context, path: String, left: Double, top: Double, right: Double,
        bottom: Double, maxSide: Int,
    ): Map<String, Any>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val orientation = ExifRotator.orientationOf(path)
        val swapped = orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
            orientation == ExifInterface.ORIENTATION_ROTATE_270 ||
            orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
            orientation == ExifInterface.ORIENTATION_TRANSVERSE
        val fullW = if (swapped) bounds.outHeight else bounds.outWidth
        val fullH = if (swapped) bounds.outWidth else bounds.outHeight
        // Region size in full pixels decides how much we may subsample.
        val regionLong = max((right - left) * fullW, (bottom - top) * fullH)
        var sample = 1
        while (regionLong / (sample * 2) >= maxSide) sample *= 2
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inSampleSize = sample
        }
        val decoded = BitmapFactory.decodeFile(path, options) ?: return null
        val upright = ExifRotator.rotated(decoded, orientation)
        if (upright !== decoded) decoded.recycle()
        val x0 = (left * upright.width).roundToInt().coerceIn(0, upright.width - 1)
        val y0 = (top * upright.height).roundToInt().coerceIn(0, upright.height - 1)
        val x1 = (right * upright.width).roundToInt().coerceIn(x0 + 1, upright.width)
        val y1 = (bottom * upright.height).roundToInt().coerceIn(y0 + 1, upright.height)
        var crop = Bitmap.createBitmap(upright, x0, y0, x1 - x0, y1 - y0)
        if (crop !== upright) upright.recycle()
        val long = max(crop.width, crop.height)
        if (long > maxSide) {
            val s = maxSide.toDouble() / long
            val scaled = Bitmap.createScaledBitmap(
                crop, max(1, (crop.width * s).roundToInt()), max(1, (crop.height * s).roundToInt()), true,
            )
            if (scaled !== crop) crop.recycle()
            crop = scaled
        }
        val out = File(context.cacheDir, "doclens_region_${System.nanoTime()}.jpg")
        FileOutputStream(out).use { crop.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        crop.recycle()
        return mapOf(
            "path" to out.absolutePath,
            "fullWidth" to fullW,
            "fullHeight" to fullH,
        )
    }
}
