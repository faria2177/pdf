package dev.doclens.doclens

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Last check before a live outline is shown: is there really an object edge
 * under each side of the box?
 *
 * With no document in view (carpet, an arm, a sofa) the detectors can still
 * assemble four lines out of texture and the green box appeared over nothing.
 * A real page or card has, along each side, a *consistent* step in brightness
 * (paper brighter than the table, or the other way round). Texture gives
 * steps too, but with random direction from point to point. A side running
 * off the camera frame (a page photographed from close up) counts as
 * supported.
 */
internal object LiveQuadEvidence {
    private const val STEP = 12            // luma step that counts as an edge
    private const val SAMPLES = 24         // points per side
    private const val STRONG = 0.60        // share of points with the same step
    private const val WEAK = 0.50

    fun supported(q: Quad, luma: ByteArray, width: Int, height: Int): Boolean {
        if (width < 16 || height < 16 || luma.size < width * height) return true
        val xs = floatArrayOf(q.topLeft.x, q.topRight.x, q.bottomRight.x, q.bottomLeft.x)
        val ys = floatArrayOf(q.topLeft.y, q.topRight.y, q.bottomRight.y, q.bottomLeft.y)
        for (i in 0..3) { xs[i] *= width; ys[i] *= height }
        val cx = xs.average(); val cy = ys.average()
        var strong = 0
        var weak = 0
        for (i in 0..3) {
            val j = (i + 1) % 4
            val dx = xs[j] - xs[i]; val dy = ys[j] - ys[i]
            val len = hypot(dx, dy)
            if (len < 10f) return false
            var nx = -dy / len; var ny = dx / len
            val mx = (xs[i] + xs[j]) / 2; val my = (ys[i] + ys[j]) / 2
            if ((cx - mx) * nx + (cy - my) * ny < 0) { nx = -nx; ny = -ny }
            // The smoothed outline may sit a few pixels off the true edge.
            var best = 0.0
            for (shift in intArrayOf(-3, 0, 3)) {
                best = max(best, sideScore(luma, width, height, xs[i], ys[i], dx, dy, nx, ny, shift))
                if (best >= STRONG) break
            }
            if (best >= STRONG) strong++ else if (best >= WEAK) weak++
        }
        // Three clear sides and a fourth that is at least partly visible
        // (a hand or glare can hide part of one side).
        return strong >= 3 && strong + weak == 4
    }

    private fun sideScore(
        luma: ByteArray, w: Int, h: Int, ax: Float, ay: Float, dx: Float, dy: Float,
        nx: Float, ny: Float, shift: Int,
    ): Double {
        var pos = 0; var neg = 0; var total = 0; var offFrame = 0
        for (k in 0 until SAMPLES) {
            val t = 0.1f + 0.8f * k / (SAMPLES - 1)
            val px = ax + dx * t + nx * shift
            val py = ay + dy * t + ny * shift
            val inside = mean(luma, w, h, px, py, nx, ny, 2, 6)
            val outside = mean(luma, w, h, px, py, -nx, -ny, 2, 6)
            if (outside < 0) { offFrame++; continue }
            if (inside < 0) continue
            total++
            val diff = inside - outside
            if (diff >= STEP) pos++ else if (diff <= -STEP) neg++
        }
        if (offFrame > SAMPLES / 2) return 1.0
        if (total < SAMPLES / 3) return 0.0
        return max(pos, neg).toDouble() / total
    }

    /** Mean luma along the normal from [from] to [to] px; -1 if off frame. */
    private fun mean(
        luma: ByteArray, w: Int, h: Int, px: Float, py: Float,
        nx: Float, ny: Float, from: Int, to: Int,
    ): Double {
        var sum = 0; var n = 0
        for (d in from..to) {
            val x = (px + nx * d).roundToInt()
            val y = (py + ny * d).roundToInt()
            if (x < 0 || y < 0 || x >= w || y >= h) return -1.0
            sum += luma[y * w + x].toInt() and 0xFF
            n++
        }
        return sum.toDouble() / n
    }
}
