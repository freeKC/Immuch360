package app.alextran.immich.djilink

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.util.AttributeSet
import android.util.TypedValue
import android.view.View
import kotlin.math.roundToInt

/**
 * The obstacle indicator as a circle around the centre of the video in the Quest's flight view, the default shape
 * ([RingCircle]): drawn in a transparent square panel over the middle of the video, the arcs fading toward the centre
 * as (1-x)^2 across the ring's thickness, the distance outside the circle by the nearest arc. Everything else in the
 * panel is transparent, and its layer is ordered over the video's ([FlightViewControls.CIRCLE_Z_INDEX]): whether the
 * compositor shows the video through it is not verified on a headset yet (the frame at the edges, drawn outside the
 * video, is the setting to use if it does not). Takes no touch: its panel is not hittable. Information only: nothing
 * here reaches the drone.
 */
class ObstacleCircleView @JvmOverloads constructor(
  context: Context,
  attrs: AttributeSet? = null,
) : View(context, attrs) {
  companion object {
    /** 20 sp, as the frame's number */
    private const val NUMBER_SP = 20f

    /** The profile (1-x)^2 from the outer edge inward, as gradient stops from the inner edge out */
    private val FALL_FROM_INNER = floatArrayOf(0f, 0.0625f, 0.25f, 0.5625f, 1f)
  }

  /** The video's height as a part of this view's height: the circle's radius and thickness follow it */
  var videoHeightPart = 1f

  private var arcs: List<RingArc> = emptyList()
  private var number: String? = null
  private val band = Paint(Paint.ANTI_ALIAS_FLAG)
  private val path = Path()
  private val outer = RectF()
  private val inner = RectF()
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
    if (arcs.isEmpty() || width <= 0 || height <= 0) {
      return
    }
    val cx = width / 2.0
    val cy = height / 2.0
    val pictureHeight = height * videoHeightPart.toDouble()
    val radius = RingCircle.radius(pictureHeight)
    val full = RingCircle.fullThickness(pictureHeight)
    for (piece in RingCircle.pieces(arcs)) {
      drawPiece(canvas, piece, cx.toFloat(), cy.toFloat(), radius, RingCircle.thickness(piece.strength, full))
    }
    drawNumber(canvas, cx, cy, pictureHeight)
  }

  /** One piece of the ring: an annular sector centred on the circle, its glow fading from the outer edge inward */
  private fun drawPiece(canvas: Canvas, piece: RingCircle.Piece, cx: Float, cy: Float, radius: Double, thick: Double) {
    val outerR = (radius + thick / 2).toFloat()
    val innerR = (radius - thick / 2).toFloat().coerceAtLeast(0f)
    if (outerR <= 0f) {
      return
    }
    outer.set(cx - outerR, cy - outerR, cx + outerR, cy + outerR)
    inner.set(cx - innerR, cy - innerR, cx + innerR, cy + innerR)
    // Bearings count from the top, Android's angles from the right
    val start = (piece.fromDeg - 90).toFloat()
    val sweep = (piece.toDeg - piece.fromDeg).toFloat()
    path.reset()
    path.arcTo(outer, start, sweep, true)
    path.arcTo(inner, start + sweep, -sweep, false)
    path.close()
    val first = innerR / outerR
    val stops = FloatArray(FALL_FROM_INNER.size) { index -> first + (1 - first) * index / (FALL_FROM_INNER.size - 1) }
    val colors = IntArray(FALL_FROM_INNER.size) { index ->
      val alpha = (piece.alpha * FALL_FROM_INNER[index] * 255).roundToInt().coerceIn(0, 255)
      (alpha shl 24) or (piece.argb and 0x00FFFFFF)
    }
    band.shader = RadialGradient(cx, cy, outerR, colors, stops, Shader.TileMode.CLAMP)
    canvas.drawPath(path, band)
  }

  /** The distance outside the circle by the nearest arc; with the even glow, low on the left */
  private fun drawNumber(canvas: Canvas, cx: Double, cy: Double, pictureHeight: Double) {
    val value = number ?: return
    val nearest = arcs.firstOrNull() ?: return
    val gap = text.textSize.toDouble()
    val (x, y) = RingCircle.numberPoint(nearest, cx, cy, pictureHeight, gap)
    val half = text.measureText(value) / 2
    val px = if (width > 2 * half) x.toFloat().coerceIn(half, width - half) else x.toFloat()
    val metrics = text.fontMetrics
    var baseline = y.toFloat() - (metrics.ascent + metrics.descent) / 2
    if (height > metrics.descent - metrics.ascent) {
      baseline = baseline.coerceIn(-metrics.ascent, height - metrics.descent)
    }
    canvas.drawText(value, px, baseline, text)
  }
}
