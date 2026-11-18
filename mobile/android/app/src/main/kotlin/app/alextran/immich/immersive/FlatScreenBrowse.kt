package app.alextran.immich.immersive

/**
 * What the quad shows of a photo with two eyes: both eyes (3D), the relief of the headset on its 2.5D mesh (see
 * [ReliefMesh], experimental), or the left eye for both (2D)
 */
internal enum class StereoView {
  THREE_D,
  MESH_25D,
  TWO_D,
}

/**
 * The view kept while browsing the photos of a flat screen (issue 19, point 5): the view of the photo before applies
 * to the next one reached by previous, next or the slideshow, when that photo offers it. 2D and 3D go to every photo
 * of two eyes, 2.5D to a relief made in the headset only (any other photo of two eyes then shows in 3D); one picture
 * shows as it is. A photo opened from the app starts from its request, as before. Pure, unit tested.
 */
internal object BrowseView {
  /**
   * The view a photo starts in: [requested] (3D, or 2.5D for a relief whose request asks it) without a [kept] view, a
   * photo opened from the app; else the kept one where the photo offers it ([holdsTwoEyes], [relief]).
   */
  fun startView(kept: StereoView?, requested: StereoView, holdsTwoEyes: Boolean, relief: Boolean): StereoView =
    when {
      kept == null || !holdsTwoEyes -> requested
      kept == StereoView.MESH_25D -> if (relief) StereoView.MESH_25D else StereoView.THREE_D
      else -> kept
    }

  /**
   * Whether the relief of a photo that starts in [view] is made at once: not in 2D, where the user browses the
   * originals, so that no heat and no battery go to a relief nobody looks at; the 3D button makes it then.
   */
  fun computesRelief(view: StereoView): Boolean = view != StereoView.TWO_D
}

/**
 * The relief strengths of the AI relief made in the headset (release 46, lot feat-relief-strength-46): the whole
 * parallax of relief-v1, under the names the app keeps in its settings (ReliefStrength in Dart), checked against the
 * contract fixture stereo_pair_contract_v1.json so that the two sides cannot drift. The button "Relief: Normal" of the
 * viewer goes through them in this order (issue 19, point 4). Pure, unit tested.
 */
internal enum class ReliefStrengthChoice(val wire: String, val parallax: Double) {
  SUBTLE("subtle", 0.015),
  NORMAL("normal", 0.02),
  STRONG("strong", 0.03);

  /** The strength the button goes to next: Subtle, Normal, Strong, then Subtle again. */
  val next: ReliefStrengthChoice
    get() = entries[(ordinal + 1) % entries.size]

  /** The key of its name among the labels of the viewer. */
  val labelKey: String
    get() = "aiReliefStrength_$wire"

  companion object {
    /** The label of the button, "Relief: {strength}", and where its name goes. */
    const val LABEL_INFO = "aiReliefStrengthInfo"
    const val STRENGTH = "{strength}"

    /** The strength of [parallax], null for a parallax of none of them (a later version of the app). */
    fun ofParallax(parallax: Double): ReliefStrengthChoice? =
      entries.firstOrNull { kotlin.math.abs(it.parallax - parallax) < 1e-9 }
  }
}

/**
 * The slideshow of the photos of a flat screen (issue 19, point 2): each photo stays [photoMs] (the slideshow duration
 * of the app, 5 s by default) from the moment its final view is there (the original, its 3D relief, or the photo flat
 * after a refusal or "too warm"), never from the request, so that a slow photo or a relief being made is not cut
 * short. Its time stops while a hold is on (a grip held on the screen, the viewer behind the system or not focused) and
 * starts again from nothing when the user presses a button of the panel. The viewer asks for the next photo once
 * [isDue]; at "no next" the slideshow ends. A headset too warm for a relief turns the rest of the slideshow to 2D, said
 * once. Pure: the viewer gives the time. Unit tested.
 */
internal class SlideshowClock(val photoMs: Long = DEFAULT_PHOTO_MS) {
  /** Why the time of a photo stops for a while. */
  enum class Hold {
    GRIP,
    BACKGROUND,
  }

  /** The user started the slideshow and it did not end. */
  var playing = false
    private set

  /** The rest of the slideshow shows the photos in 2D: the headset was too warm for a relief. */
  var twoD = false
    private set

  private var finalView = false
  private val holds = mutableSetOf<Hold>()
  private var countedMs = 0L
  private var countingSince: Long? = null

  private val counting: Boolean
    get() = playing && finalView && holds.isEmpty()

  /** Runs [change] and moves the count to the state it leaves, at [nowMs]. */
  private inline fun update(nowMs: Long, change: () -> Unit) {
    countingSince?.let { countedMs += nowMs - it }
    countingSince = null
    change()
    if (counting) countingSince = nowMs
  }

  /** Play: the photo shown counts from now, from nothing. */
  fun play(nowMs: Long) = update(nowMs) {
    playing = true
    countedMs = 0L
  }

  /** Pause, or the end of the slideshow. */
  fun pause(nowMs: Long) = update(nowMs) { playing = false }

  /** Another photo was asked for: its time waits for its final view. */
  fun photoChanged(nowMs: Long) = update(nowMs) {
    finalView = false
    countedMs = 0L
  }

  /** The photo shown reached its final view: its time starts. */
  fun finalViewShown(nowMs: Long) = update(nowMs) { finalView = true }

  /** [hold] starts ([on]) or ends. */
  fun hold(hold: Hold, on: Boolean, nowMs: Long) = update(nowMs) { if (on) holds += hold else holds -= hold }

  /** A button of the panel was pressed: the photo shown counts again from nothing. */
  fun restartPhoto(nowMs: Long) = update(nowMs) { countedMs = 0L }

  /** Whether the next photo is due at [nowMs]. */
  fun isDue(nowMs: Long): Boolean = counting && countedMs + (nowMs - (countingSince ?: nowMs)) >= photoMs

  /** No photo after the last one: the slideshow ends (the viewer says "End of the slideshow"). */
  fun noNext(nowMs: Long) = pause(nowMs)

  /** The headset was too warm for a relief: true the first time (the viewer says so once), the rest goes on in 2D. */
  fun tooWarm(): Boolean {
    if (twoD) return false
    twoD = true
    return true
  }

  companion object {
    /** The slideshow duration of the app by default (SlideshowConfig.duration). */
    const val DEFAULT_PHOTO_MS = 5_000L

    /** The time of a photo for the [seconds] the app sent, 0 or less for the default. */
    fun photoMsOf(seconds: Long): Long = if (seconds > 0) seconds * 1000L else DEFAULT_PHOTO_MS
  }
}

/**
 * Whether the photo shown stays until the first picture of the next one is ready (issue 19, point 2: no black gap
 * between two photos of a flat screen): only for a photo of a flat screen reached by previous, next or the slideshow
 * from another one shown ([shownIsScreenPhoto], its picture there), never from a relief in 2.5D, whose mesh goes at
 * once; any other media hides the photo first, as before. The texture of the photo shown is replaced in one go, so at
 * most two photos are in memory during the swap. Pure, unit tested.
 */
internal object PhotoSwap {
  fun keepsShown(
    reachedByBrowsing: Boolean,
    shownIsScreenPhoto: Boolean,
    nextIsScreenPhoto: Boolean,
    shownIn25d: Boolean,
  ): Boolean = reachedByBrowsing && shownIsScreenPhoto && nextIsScreenPhoto && !shownIn25d
}

/**
 * The frosted background behind the photo of a flat screen (issue 19, point 2, experimental): a blurred, darker copy
 * of the photo on a small compositor layer behind it, which fills the box the user set (a portrait photo in a
 * landscape box has the blur on its sides) and goes a little past it. The passthrough of the headset cannot be blurred
 * by an app, so the picture is: the photo scaled to [SMALL_WIDTH] pixels, [PASSES] box blurs, its saturation brought
 * to [SATURATION] and a dark veil of [VEIL], drawn once per photo on a Surface of [SURFACE_WIDTH] x [SURFACE_HEIGHT]
 * that the compositor magnifies with its bilinear filter: nothing per frame. Pure, unit tested.
 */
internal object FrostedBackdrop {
  const val SMALL_WIDTH = 64
  const val SURFACE_WIDTH = 256
  const val SURFACE_HEIGHT = 144
  const val PASSES = 3
  const val RADIUS = 2
  const val SATURATION = 0.8f
  const val VEIL = 0.5f

  /** The backdrop goes this part of the box past each of its sides, and this far behind the photo, in meters. */
  const val MARGIN = 0.06f
  const val BEHIND_M = 0.02f

  /** The size of the small copy of a photo of [width] x [height]: [SMALL_WIDTH] wide, its aspect kept. */
  fun smallSize(width: Int, height: Int): Pair<Int, Int> {
    val h = (SMALL_WIDTH.toFloat() * height / width.coerceAtLeast(1)).let { kotlin.math.round(it).toInt() }
    return SMALL_WIDTH to h.coerceIn(1, 4 * SMALL_WIDTH)
  }

  /** The width and height in meters of the backdrop of a box [widthM] x [heightM]: [MARGIN] past each side. */
  fun size(widthM: Float, heightM: Float): Pair<Float, Float> = widthM * (1 + 2 * MARGIN) to heightM * (1 + 2 * MARGIN)

  /** [pixels] (ARGB, [width] x [height], row after row) frosted: blurred, desaturated and veiled, opaque. */
  fun frost(pixels: IntArray, width: Int, height: Int): IntArray {
    require(pixels.size == width * height && width > 0 && height > 0) { "${pixels.size} pixels for $width x $height" }
    val channels =
      Array(3) { channel -> FloatArray(pixels.size) { i -> ((pixels[i] shr (16 - 8 * channel)) and 0xFF).toFloat() } }
    for (channel in channels) blur(channel, width, height)
    return IntArray(pixels.size) { i ->
      val (r, g, b) = saturate(channels[0][i], channels[1][i], channels[2][i])
      opaque(r * (1 - VEIL), g * (1 - VEIL), b * (1 - VEIL))
    }
  }

  /** [PASSES] box blurs of [RADIUS] across and down [values], the edges repeated: what goes in comes out. */
  fun blur(values: FloatArray, width: Int, height: Int, passes: Int = PASSES, radius: Int = RADIUS) {
    val line = FloatArray(maxOf(width, height))
    repeat(passes) {
      for (y in 0 until height) boxLine(values, y * width, 1, width, radius, line)
      for (x in 0 until width) boxLine(values, x, width, height, radius, line)
    }
  }

  private fun boxLine(values: FloatArray, start: Int, step: Int, count: Int, radius: Int, line: FloatArray) {
    for (i in 0 until count) line[i] = values[start + i * step]
    val span = 2 * radius + 1
    for (i in 0 until count) {
      var sum = 0f
      for (k in -radius..radius) sum += line[(i + k).coerceIn(0, count - 1)]
      values[start + i * step] = sum / span
    }
  }

  /** [r], [g], [b] with their saturation brought to [SATURATION] around their grey. */
  fun saturate(r: Float, g: Float, b: Float): Triple<Float, Float, Float> {
    val grey = 0.299f * r + 0.587f * g + 0.114f * b
    return Triple(grey + (r - grey) * SATURATION, grey + (g - grey) * SATURATION, grey + (b - grey) * SATURATION)
  }

  private fun opaque(r: Float, g: Float, b: Float): Int {
    fun level(value: Float) = kotlin.math.round(value).toInt().coerceIn(0, 255)
    return (0xFF shl 24) or (level(r) shl 16) or (level(g) shl 8) or level(b)
  }
}
