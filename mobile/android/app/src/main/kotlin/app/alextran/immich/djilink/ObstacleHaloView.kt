package app.alextran.immich.djilink

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.graphics.Typeface
import android.util.AttributeSet
import android.util.TypedValue
import android.view.View
import kotlin.math.roundToInt

/**
 * The obstacle ring around the video of the Quest's flight view (p2/design-obstacle-ring-2026-10-25.md, 5.3): drawn in
 * the margin of a transparent panel a little larger than the video, outward from the video's edge, so the picture
 * itself stays fully visible whatever order the compositor draws the two layers in. The same rules as the Flutter
 * overlay of the phone and the TV ([RingGeometry]): front on the top edge, an arc about 90 degrees wide, fading away
 * from the video as (1-x)^2, the strong arc filling the margin and the faint one 60 % of it. The video's rectangle is
 * left transparent. Takes no touch: its panel is not hittable. Information only: nothing here reaches the drone.
 */
class ObstacleHaloView @JvmOverloads constructor(
  context: Context,
  attrs: AttributeSet? = null,
) : View(context, attrs) {
  companion object {
    /** Pieces per edge: the glow is soft, 24 are smooth at this size */
    const val PER_EDGE = 24

    /** 20 sp in the margin, outside the video */
    private const val NUMBER_SP = 20f

    /** The profile (1-x)^2 across the band, as gradient stops */
    private val STOPS = floatArrayOf(0f, 0.25f, 0.5f, 0.75f, 1f)
    private val FALL = floatArrayOf(1f, 0.5625f, 0.25f, 0.0625f, 0f)
  }

  /** The video's margin inside this view, as a part of its width and of its height */
  var marginWidthPart = 0f
  var marginHeightPart = 0f

  private var arcs: List<RingArc> = emptyList()
  private var number: String? = null
  private val band = Paint(Paint.ANTI_ALIAS_FLAG)
  private val path = Path()
  private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    color = Color.WHITE
    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    textAlign = Paint.Align.CENTER
    fontFeatureSettings = "tnum"
    textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, NUMBER_SP, resources.displayMetrics)
    setShadowLayer(6f, 0f, 1f, Color.argb(160, 0, 0, 0))
  }

  /** The arcs to draw, and the distance by the nearest one (null for none); redrawn only when they changed */
  fun show(arcs: List<RingArc>, number: String?) {
    if (arcs == this.arcs && number == this.number) {
      return
    }
    this.arcs = arcs
    this.number = number
    invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val w = width.toFloat()
    val h = height.toFloat()
    val mx = w * marginWidthPart
    val my = h * marginHeightPart
    if (arcs.isEmpty() || mx <= 0f || my <= 0f) {
      return
    }
    val innerW = w - 2 * mx
    val innerH = h - 2 * my
    for (segment in RingGeometry.segments(arcs, innerW.toDouble(), innerH.toDouble(), PER_EDGE)) {
      drawSegment(canvas, segment, mx, my, innerW, innerH, w, h)
    }
    drawNumber(canvas, mx, my, innerW, innerH)
  }

  /**
   * One piece of the band, a trapezoid from the video's edge to the view's edge, mitred at the corners like a picture
   * frame, with a gradient from the video's edge outward over the depth of its strength
   */
  private fun drawSegment(
    canvas: Canvas,
    segment: RingGeometry.Segment,
    mx: Float,
    my: Float,
    innerW: Float,
    innerH: Float,
    w: Float,
    h: Float,
  ) {
    val from = segment.from.toFloat()
    val to = segment.to.toFloat()
    path.reset()
    val depth: Float
    val gradient: LinearGradient
    val colors = IntArray(STOPS.size) { index ->
      val alpha = (segment.alpha * FALL[index] * 255).roundToInt().coerceIn(0, 255)
      (alpha shl 24) or (segment.argb and 0x00FFFFFF)
    }
    when (segment.edge) {
      RingGeometry.Edge.TOP -> {
        depth = RingGeometry.depth(segment.strength, my.toDouble()).toFloat()
        path.moveTo(mx + innerW * from, my)
        path.lineTo(mx + innerW * to, my)
        path.lineTo(w * to, 0f)
        path.lineTo(w * from, 0f)
        gradient = LinearGradient(0f, my, 0f, my - depth, colors, STOPS, Shader.TileMode.CLAMP)
      }
      RingGeometry.Edge.RIGHT -> {
        depth = RingGeometry.depth(segment.strength, mx.toDouble()).toFloat()
        path.moveTo(mx + innerW, my + innerH * from)
        path.lineTo(mx + innerW, my + innerH * to)
        path.lineTo(w, h * to)
        path.lineTo(w, h * from)
        gradient = LinearGradient(mx + innerW, 0f, mx + innerW + depth, 0f, colors, STOPS, Shader.TileMode.CLAMP)
      }
      RingGeometry.Edge.BOTTOM -> {
        depth = RingGeometry.depth(segment.strength, my.toDouble()).toFloat()
        path.moveTo(mx + innerW * (1 - from), my + innerH)
        path.lineTo(mx + innerW * (1 - to), my + innerH)
        path.lineTo(w * (1 - to), h)
        path.lineTo(w * (1 - from), h)
        gradient = LinearGradient(0f, my + innerH, 0f, my + innerH + depth, colors, STOPS, Shader.TileMode.CLAMP)
      }
      RingGeometry.Edge.LEFT -> {
        depth = RingGeometry.depth(segment.strength, mx.toDouble()).toFloat()
        path.moveTo(mx, my + innerH * (1 - from))
        path.lineTo(mx, my + innerH * (1 - to))
        path.lineTo(0f, h * (1 - to))
        path.lineTo(0f, h * (1 - from))
        gradient = LinearGradient(mx, 0f, mx - depth, 0f, colors, STOPS, Shader.TileMode.CLAMP)
      }
    }
    path.close()
    band.shader = gradient
    canvas.drawPath(path, band)
  }

  /** The distance by the nearest arc, in the margin outside the video; with the even glow, at the top centre */
  private fun drawNumber(canvas: Canvas, mx: Float, my: Float, innerW: Float, innerH: Float) {
    val value = number ?: return
    val centre = arcs.firstOrNull()?.centreDeg
    val (bx, by) = if (centre == null) {
      innerW / 2.0 to 0.0
    } else {
      RingGeometry.borderPoint(centre, innerW.toDouble(), innerH.toDouble())
    }
    // Out from the video's edge by half the margin, on the side of the edge the point is on
    var x = mx + bx.toFloat()
    var y = my + by.toFloat()
    val toEdge = floatArrayOf(by.toFloat(), innerW - bx.toFloat(), innerH - by.toFloat(), bx.toFloat())
    when (toEdge.indices.minByOrNull { toEdge[it] }) {
      0 -> y -= my / 2
      1 -> x += mx / 2
      2 -> y += my / 2
      else -> x -= mx / 2
    }
    // Kept inside the view
    val half = text.measureText(value) / 2
    if (width > 2 * half) {
      x = x.coerceIn(half, width - half)
    }
    val metrics = text.fontMetrics
    var baseline = y - (metrics.ascent + metrics.descent) / 2
    if (height > metrics.descent - metrics.ascent) {
      baseline = baseline.coerceIn(-metrics.ascent, height - metrics.descent)
    }
    canvas.drawText(value, x, baseline, text)
  }
}
