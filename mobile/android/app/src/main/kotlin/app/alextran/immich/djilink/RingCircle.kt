package app.alextran.immich.djilink

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * The obstacle indicator as a circle around the picture's centre, the default shape since FreeKC's words of 25 October
 * ("comme dans Fortnite quand on se fait tirer dessus": a shooter's hit indicator is a translucent arc on a circle
 * around the crosshair, pointing toward where the shot came from). A thin ring of radius a quarter of the picture's
 * height; an arc about 70 degrees wide toward the obstacle (half its strength 22.5 degrees from its centre, nothing
 * from 45); front at the top of the circle, right on its right, back at its bottom, left on its left; the same colour,
 * opacity and fades as the frame at the edges ([RingGeometry]), which stays as a setting. Where arcs meet, the larger
 * wins; the even glow, when the side is not shown, is the whole circle, faint. The same numbers as
 * djiObstacleCirclePieces in dji_live_obstacle.widget.dart, for the Quest's flight view ([ObstacleCircleView]). Pure:
 * it draws, and never reaches the remote or the drone.
 */
object RingCircle {
  /** The circle's radius, a part of the picture's height */
  const val RADIUS_PART = 0.25

  /** The ring's full thickness (a strong arc), a part of the picture's height; a faint arc is 60 % of it */
  const val THICKNESS_PART = 0.045

  /** An arc weighs nothing this far from its centre, half at half of it: about 70 degrees wide */
  const val WINDOW_HALF_DEG = 45.0

  /** Pieces around the circle, 5 degrees each: the glow is soft, they are smooth */
  const val PIECES = 72

  /** Where the distance goes with the even glow, which says no side: low on the left, away from "ahead" */
  const val EVEN_NUMBER_DEG = -135.0

  /** One piece of the circle, from [fromDeg] to [toDeg] (bearings, clockwise from the top), and its glow */
  data class Piece(
    val fromDeg: Double,
    val toDeg: Double,
    val alpha: Double,
    val argb: Int,
    val strength: Double,
  )

  fun radius(pictureHeight: Double): Double = pictureHeight * RADIUS_PART

  fun fullThickness(pictureHeight: Double): Double = pictureHeight * THICKNESS_PART

  /** The thickness of an arc of [strength]: 60 % of the full one when faint, all of it when strong */
  fun thickness(strength: Double, full: Double): Double = RingGeometry.depth(strength, full)

  /** The weight of an arc [offsetDeg] from its centre: 1 there, 0.5 at 22.5 degrees, 0 from 45 */
  fun window(offsetDeg: Double): Double {
    val offset = abs(offsetDeg)
    return if (offset >= WINDOW_HALF_DEG) 0.0 else 0.5 * (1 + cos(PI * offset / WINDOW_HALF_DEG))
  }

  /** The point at [bearingDeg] on a circle of [radius] around ([cx], [cy]): 0 at the top, 90 on the right */
  fun point(bearingDeg: Double, cx: Double, cy: Double, radius: Double): Pair<Double, Double> {
    val radians = Math.toRadians(bearingDeg)
    return cx + radius * sin(radians) to cy - radius * cos(radians)
  }

  /**
   * The glow of [arcs] cut into [count] pieces around the circle: at the middle of each piece, the arc that weighs most
   * gives the alpha (its opacity times its window), the colour and the strength; where arcs meet the larger wins, they
   * never add up. The even glow (an arc with no bearing) is the same on every piece. Pieces with nothing to draw are
   * left out.
   */
  fun pieces(arcs: List<RingArc>, count: Int = PIECES): List<Piece> {
    if (arcs.isEmpty() || count <= 0) {
      return emptyList()
    }
    val step = 360.0 / count
    val pieces = mutableListOf<Piece>()
    for (index in 0 until count) {
      val from = -180.0 + index * step
      val middle = from + step / 2
      var best: RingArc? = null
      var bestAlpha = 0.0
      for (arc in arcs) {
        val centre = arc.centreDeg
        val alpha = arc.opacity * (if (centre == null) 1.0 else window(ObstacleRing.separation(middle, centre)))
        if (alpha > bestAlpha) {
          bestAlpha = alpha
          best = arc
        }
      }
      val chosen = best ?: continue
      pieces += Piece(from, from + step, bestAlpha, chosen.argb, chosen.strength)
    }
    return pieces
  }

  /**
   * Where the distance goes: outside the circle by the nearest arc, past its full thickness by [gap]; with the even
   * glow, low on the left ([EVEN_NUMBER_DEG])
   */
  fun numberPoint(
    nearest: RingArc,
    cx: Double,
    cy: Double,
    pictureHeight: Double,
    gap: Double,
  ): Pair<Double, Double> {
    val bearing = nearest.centreDeg ?: EVEN_NUMBER_DEG
    return point(bearing, cx, cy, radius(pictureHeight) + fullThickness(pictureHeight) / 2 + gap)
  }
}
