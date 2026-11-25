package dev.doclens.doclens

import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.util.concurrent.TimeUnit
import kotlin.math.max

/**
 * Detects the dominant text direction of a (already dewarped) document crop so
 * the caller can rotate it upright.
 *
 * Uses ML Kit's on-device Latin text recognizer, delivered by Google Play
 * services (`play-services-mlkit-text-recognition`) — exactly like the
 * OS-native document scanner. No model is bundled in the app; it is downloaded
 * on demand the first time it's used. If the model isn't ready yet (or
 * recognition fails), this returns `0` so the crop is left untouched.
 *
 * The crop is recognised at each of the four 90° rotations; whichever the
 * recognizer reads the most confident text from is the upright one.
 */
object TextOrientationDetector {
    private val recognizer by lazy {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }

    /**
     * Number of clockwise 90° turns to apply to [bitmap] so its dominant text
     * reads upright (`0..3`). Returns `0` when no confident text orientation is
     * found (blank/graphical page, model unavailable, or recognition failed).
     *
     * MUST be called off the main thread — it blocks on the recognizer.
     */
    fun bestClockwiseTurns(bitmap: Bitmap): Int {
        val small = downscale(bitmap, 800)
        // ML Kit may still be reading `small` if we bail early; only recycle
        // it once every recognition has finished.
        var finished = false
        try {
            val scores = DoubleArray(4) { -1.0 }
            // Cards and pages read along their long side, so a landscape crop
            // is either upright or upside down, and a portrait crop of a
            // landscape card is a quarter turn off. Trying only the plausible
            // turns (and all of them at once) cut the wait after a card
            // capture from four sequential recognitions to one round.
            val degrees = when {
                small.width >= small.height * 1.2 -> intArrayOf(0, 180)
                small.height >= small.width * 1.2 -> intArrayOf(0, 90, 270)
                else -> intArrayOf(0, 90, 180, 270)
            }
            // `InputImage.fromBitmap(bm, rotationDegrees)` follows the CameraX
            // convention: `rotationDegrees` is the *clockwise* rotation that
            // brings the buffer upright, which ML Kit applies before
            // recognition. So if text reads best after rotating `deg`
            // clockwise, that same rotation (deg / 90 turns) is baked into the
            // output.
            val pending = degrees.map { deg ->
                deg to recognizer.process(InputImage.fromBitmap(small, deg))
            }
            for ((deg, task) in pending) {
                val text = try {
                    Tasks.await(task, 3, TimeUnit.SECONDS)
                } catch (_: Exception) {
                    // The recognizer is unavailable (model still downloading on
                    // demand) or timed out — leave the crop as-is.
                    return 0
                }
                scores[deg / 90] = scoreOf(text)
            }
            finished = true

            var bestTurns = 0
            var bestScore = scores[0]
            for (t in 1..3) {
                if (scores[t] < 0) continue
                if (scores[t] > bestScore) {
                    bestScore = scores[t]
                    bestTurns = t
                }
            }

            // Bias toward the current orientation. Upside-down (and sideways)
            // Latin text still "reads" as low-confidence garbage, so a flipped
            // crop can narrowly outscore the upright one. Only rotate when a
            // hypothesis beats the as-is (0°) score by a clear margin, and
            // clears an absolute floor — otherwise leave the crop untouched
            // (the common false-180° flip that left the image upside-down
            // while OCR, which detects orientation independently, read fine).
            if (bestTurns == 0) return 0
            return if (bestScore >= 1.0 && bestScore >= scores[0] * MIN_ROTATE_MARGIN) {
                bestTurns
            } else {
                0
            }
        } finally {
            if (finished && small !== bitmap) small.recycle()
        }
    }

    /** A non-zero rotation must beat the as-is score by this factor to win. */
    private const val MIN_ROTATE_MARGIN = 1.30

    private fun scoreOf(text: Text): Double {
        var score = 0.0
        for (block in text.textBlocks) {
            for (line in block.lines) {
                // `confidence` can be null or NaN on some models — treat as
                // fully confident so the recognised length still counts.
                val conf: Float? = line.confidence
                val weight = if (conf == null || conf.isNaN()) 1f else conf
                score += weight.toDouble() * line.text.length
            }
        }
        return score
    }

    private fun downscale(src: Bitmap, maxDimension: Int): Bitmap {
        val maxDim = max(src.width, src.height)
        if (maxDim <= maxDimension) return src
        val scale = maxDimension.toFloat() / maxDim
        val w = max(1, (src.width * scale).toInt())
        val h = max(1, (src.height * scale).toInt())
        return Bitmap.createScaledBitmap(src, w, h, true)
    }
}
