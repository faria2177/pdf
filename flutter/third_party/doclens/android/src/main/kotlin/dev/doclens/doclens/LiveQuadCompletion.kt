package dev.doclens.doclens

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

/**
 * Repairs a live outline when only some of its corners sit on real edges.
 *
 * A finger, glare, a shadow or the spine of an open book often hides one
 * corner (or a whole side); the detector then bends that corner onto some
 * other line and the box jumps. Corners are checked one by one
 * ([LiveQuadEvidence.cornerScores]):
 *
 * - three good corners: the fourth follows them — from the last stable box,
 *   moved with the three good corners, or else completing the parallelogram
 *   (D = A + C − B);
 * - two good corners on one side: the other two come from the last stable
 *   box, moved/scaled/turned exactly like that side.
 *
 * Anything else is left to the evidence gate.
 */
internal object LiveQuadCompletion {
    private const val GOOD = 0.6

    fun complete(q: Quad, previous: Quad?, luma: ByteArray, width: Int, height: Int): Quad {
        val scores = LiveQuadEvidence.cornerScores(q, luma, width, height)
        val good = BooleanArray(4) { scores[it] >= GOOD }
        val count = good.count { it }
        if (count == 4 || count <= 1) return q
        val pts = corners(q)
        if (count == 3) {
            val k = good.indexOfFirst { !it }
            val a = pts[(k + 3) % 4]; val b = pts[(k + 2) % 4]; val c = pts[(k + 1) % 4]
            val fromPrevious = previous?.let { prev ->
                val pp = corners(prev)
                val moves = (0..3).filter { good[it] }.map { pts[it].x - pp[it].x to pts[it].y - pp[it].y }
                val mx = moves.map { it.first }.average().toFloat()
                val my = moves.map { it.second }.average().toFloat()
                // Only a box that moved as one piece can be trusted.
                val coherent = moves.all { abs(it.first - mx) < 0.03f && abs(it.second - my) < 0.03f }
                if (coherent) PointF(pp[k].x + mx, pp[k].y + my) else null
            }
            pts[k] = fromPrevious ?: PointF(a.x + c.x - b.x, a.y + c.y - b.y)
            return clampQuad(pts)
        }
        // count == 2: only when the two good corners share a side.
        val i = (0..3).firstOrNull { good[it] && good[(it + 1) % 4] } ?: return q
        val prev = previous ?: return q
        val pp = corners(prev)
        val j = (i + 1) % 4
        // Similarity transform taking the previous side i→j onto the current one.
        val pvx = pp[j].x - pp[i].x; val pvy = pp[j].y - pp[i].y
        val cvx = pts[j].x - pts[i].x; val cvy = pts[j].y - pts[i].y
        val plen2 = pvx * pvx + pvy * pvy
        if (plen2 < 1e-6f) return q
        // complex ratio (cv / pv)
        val ra = (cvx * pvx + cvy * pvy) / plen2
        val rb = (cvy * pvx - cvx * pvy) / plen2
        val scale = hypot(ra, rb)
        if (scale < 0.8f || scale > 1.25f) return q   // too big a change to reuse the old shape
        for (m in 0..3) {
            if (good[m]) continue
            val dx = pp[m].x - pp[i].x; val dy = pp[m].y - pp[i].y
            pts[m] = PointF(pts[i].x + ra * dx - rb * dy, pts[i].y + rb * dx + ra * dy)
        }
        return clampQuad(pts)
    }

    private fun corners(q: Quad) = arrayOf(q.topLeft, q.topRight, q.bottomRight, q.bottomLeft)

    private fun clampQuad(p: Array<PointF>): Quad {
        fun c(v: PointF) = PointF(v.x.coerceIn(0f, 1f), v.y.coerceIn(0f, 1f))
        return Quad(c(p[0]), c(p[1]), c(p[2]), c(p[3]))
    }
}

/**
 * Keeps the green box still while the page is still: tiny detector noise is
 * ignored, normal movement is followed smoothly, and a sudden jump is only
 * taken once the next frame confirms it (one bad frame no longer makes the
 * corners leap).
 */
internal class LiveQuadStabilizer {
    private var shown: Quad? = null
    private var pending: Quad? = null

    val current: Quad? get() = shown

    fun reset() { shown = null; pending = null }

    fun update(q: Quad): Quad {
        val prev = shown ?: return q.also { shown = it }
        val d = distance(prev, q)
        if (d < DEAD_BAND) { pending = null; return prev }
        if (d > JUMP) {
            val p = pending
            if (p != null && distance(p, q) < CONFIRM) {
                shown = q; pending = null
                return q
            }
            pending = q
            return prev
        }
        pending = null
        val alpha = ((d - DEAD_BAND) / 0.08f).coerceIn(0.3f, 0.85f)
        val next = lerp(prev, q, alpha)
        shown = next
        return next
    }

    private fun distance(a: Quad, b: Quad): Float {
        val pa = arrayOf(a.topLeft, a.topRight, a.bottomRight, a.bottomLeft)
        val pb = arrayOf(b.topLeft, b.topRight, b.bottomRight, b.bottomLeft)
        var m = 0f
        for (i in 0..3) m = max(m, hypot(pa[i].x - pb[i].x, pa[i].y - pb[i].y))
        return m
    }

    private fun lerp(a: Quad, b: Quad, t: Float): Quad {
        fun l(p: PointF, q: PointF) = PointF(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t)
        return Quad(l(a.topLeft, b.topLeft), l(a.topRight, b.topRight),
            l(a.bottomRight, b.bottomRight), l(a.bottomLeft, b.bottomLeft))
    }

    private companion object {
        const val DEAD_BAND = 0.012f   // ~1 % of the frame: noise, keep the box
        const val JUMP = 0.12f         // a jump this big needs a second frame
        const val CONFIRM = 0.05f
    }
}
