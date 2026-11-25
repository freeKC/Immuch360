package app.alextran.immich.immersive

/**
 * What surrounds the photo of a flat screen (issue 19, the choice promised on 19 November 2026): nothing (black, the
 * viewer as before), a blurred copy of the photo filling the box around it (see FrostedBackdrop, the frosted
 * background of build 49), or the room seen through the cameras of the headset (the passthrough of the Spatial SDK,
 * Scene.enablePassthrough, the call the flight view of DJI link makes; not an experimental API of the SDK). The
 * settings of the app keep it under [wire] (SlideshowBackground in Dart); the button "Background: Blurred photo" of
 * the panel goes through them in this order. Pure, unit tested.
 */
internal enum class SlideshowBackground(val wire: String) {
  BLACK("black"),
  BLURRED("blurred"),
  PASSTHROUGH("passthrough");

  /** The background the button goes to next: Black, Blurred photo, Your room, then Black again. */
  val next: SlideshowBackground
    get() = entries[(ordinal + 1) % entries.size]

  /** The key of its name among the labels of the viewer. */
  val labelKey: String
    get() = "slideshowBackground_$wire"

  companion object {
    /** The label of the button, "Background: {choice}". */
    const val LABEL_INFO = "slideshowBackgroundInfo"

    /** The background the app sent under [wire]; a name this build does not know, or none, gives [BLURRED]. */
    fun ofWire(wire: String?): SlideshowBackground = entries.firstOrNull { it.wire == wire } ?: BLURRED
  }
}

/**
 * How the photo of a flat screen gives way to the next one reached by previous, next or the slideshow (issue 19): at
 * once (as in build 49), a cross fade, or a slide (the photo shown leaves to one side as the next one comes from the
 * other, both fading). [durationMs] is how long it takes. Only between two photos drawn on the photo layer of the
 * compositor (Sharper flat screens, on by default); any other photo goes at once. Pure, unit tested.
 */
internal enum class SlideshowTransition(val wire: String, val durationMs: Long) {
  NONE("none", 0L),
  CROSS_FADE("crossFade", 700L),
  SLIDE("slide", 600L);

  /** The transition the button goes to next: None, Cross fade, Slide, then None again. */
  val next: SlideshowTransition
    get() = entries[(ordinal + 1) % entries.size]

  /** The key of its name among the labels of the viewer. */
  val labelKey: String
    get() = "slideshowTransition_$wire"

  companion object {
    /** The label of the button, "Transition: {choice}". */
    const val LABEL_INFO = "slideshowTransitionInfo"

    /** Where the name of the choice goes in both labels. */
    const val CHOICE = "{choice}"

    /** The transition the app sent under [wire]; a name this build does not know, or none, gives [CROSS_FADE]. */
    fun ofWire(wire: String?): SlideshowTransition = entries.firstOrNull { it.wire == wire } ?: CROSS_FADE
  }
}

/** The background and the transition of the photos of a flat screen, for one opening of the viewer. */
internal data class SlideshowLook(
  val background: SlideshowBackground = SlideshowBackground.BLURRED,
  val transition: SlideshowTransition = SlideshowTransition.CROSS_FADE,
) {
  /** Whether the passthrough is on while [screenPhoto] (a photo of a flat screen) shows: only for Your room. */
  fun passthrough(screenPhoto: Boolean): Boolean = screenPhoto && background == SlideshowBackground.PASSTHROUGH

  /** Whether the blurred copy of the photo shows behind it. */
  val blurred: Boolean
    get() = background == SlideshowBackground.BLURRED
}

/**
 * One frame of a [PhotoTransition]: the opacity of the photo that comes ([incomingAlpha]) and of the one that goes
 * ([outgoingAlpha]), how far each stands from its place, in widths of its box, to the right for a positive value
 * ([incomingShift], [outgoingShift]), and the opacity of the blurred background ([backdropAlpha]), which goes out and
 * comes back with the copy of the next photo at [atMiddle].
 */
internal data class TransitionFrame(
  val incomingAlpha: Float,
  val outgoingAlpha: Float,
  val incomingShift: Float,
  val outgoingShift: Float,
  val backdropAlpha: Float,
  val atMiddle: Boolean,
  val done: Boolean,
)

/**
 * A transition between two photos of a flat screen, each on its own compositor layer (the photo layer of the viewer
 * and its twin): the viewer asks [frame] once per frame of the headset (ImmersiveInputSystem.onFrame, at the display
 * rate) and sets what it says on the two layers: their colour scale (the opacity, with a premultiplied alpha blend)
 * and, for a slide, their poses. Nothing else runs per frame: both photos were drawn on their Surfaces before the
 * first frame, so the transition costs the compositor one more quad layer for its length and the viewer a few calls a
 * frame. Its progress comes from the time of each frame, never from a count of frames, so a late frame never slows it
 * down. [step] is +1 for the next photo (a slide comes from the right), -1 for the previous one. Pure: the viewer gives
 * the time. Unit tested.
 */
internal class PhotoTransition(val kind: SlideshowTransition, val step: Int) {
  private var startNanos: Long? = null
  private var lastNanos = 0L
  private var middlePassed = false

  /** Frames drawn since the start, and the longest gap between two of them, for the line of the log at the end. */
  var frames = 0
    private set

  var longestGapNanos = 0L
    private set

  /** The transition has its first frame. */
  val started: Boolean
    get() = startNanos != null

  /** The state at the frame of [nowNanos] (System.nanoTime), the first call starting the transition. */
  fun frame(nowNanos: Long): TransitionFrame {
    val start = startNanos ?: nowNanos.also { startNanos = it }
    if (frames > 0) longestGapNanos = maxOf(longestGapNanos, nowNanos - lastNanos)
    lastNanos = nowNanos
    frames++
    val durationNanos = kind.durationMs * 1_000_000L
    val elapsedNanos = nowNanos - start
    // Done from the time itself: a float of the ratio rounds to 1 a few nanoseconds early
    val done = elapsedNanos >= durationNanos
    val t = if (done) 1f else (elapsedNanos.toDouble() / durationNanos).toFloat().coerceIn(0f, 1f)
    val atMiddle = !middlePassed && elapsedNanos * 2 >= durationNanos
    if (atMiddle) middlePassed = true
    return frameAt(kind, step, t, atMiddle).copy(done = done)
  }

  /** How long the transition ran, in milliseconds, from its first frame to the last one asked. */
  val elapsedMs: Long
    get() = startNanos?.let { (lastNanos - it) / 1_000_000L } ?: 0L

  /** The line of the log at the end: frames, time, frames a second (the gaps between them) and the longest gap. */
  fun summary(): String {
    val rate = if (elapsedMs > 0) (frames - 1) * 1000.0 / elapsedMs else 0.0
    return "photo transition ${kind.wire}: $frames frames in $elapsedMs ms (" +
      "${"%.1f".format(java.util.Locale.ROOT, rate)} a second), longest gap " +
      "${"%.1f".format(java.util.Locale.ROOT, longestGapNanos / 1e6)} ms"
  }

  companion object {
    /** How far a slide takes each photo: its width and a little more, so that the two never overlap at the middle. */
    const val SLIDE_DISTANCE = 1.08f

    /** Smoothstep: starts and ends slowly. */
    fun ease(t: Float): Float {
      val x = t.coerceIn(0f, 1f)
      return x * x * (3f - 2f * x)
    }

    /**
     * The state of a transition of [kind] at [t] (0 to 1). A cross fade lays the next photo over the one shown and
     * brings it from transparent to opaque, while the one shown fades out in the second half only, where the next one
     * covers it nearly whole: the background never shows through the middle of the photo, and a photo of another
     * shape leaves no part of the one before behind. A slide moves both by [SLIDE_DISTANCE] widths, the one shown
     * fading out and the next one fading in, so that neither appears or vanishes at an edge.
     */
    fun frameAt(kind: SlideshowTransition, step: Int, t: Float, atMiddle: Boolean = false): TransitionFrame {
      val e = ease(t)
      val done = t >= 1f
      val backdrop = kotlin.math.abs(1f - 2f * e)
      return when (kind) {
        SlideshowTransition.NONE -> TransitionFrame(1f, 0f, 0f, 0f, 1f, atMiddle = true, done = true)
        SlideshowTransition.CROSS_FADE ->
          TransitionFrame(
            incomingAlpha = e,
            outgoingAlpha = 1f - ease(2f * t - 1f),
            incomingShift = 0f,
            outgoingShift = 0f,
            backdropAlpha = backdrop,
            atMiddle = atMiddle,
            done = done,
          )
        SlideshowTransition.SLIDE -> {
          val side = if (step < 0) -1f else 1f
          TransitionFrame(
            incomingAlpha = e,
            outgoingAlpha = 1f - e,
            incomingShift = side * SLIDE_DISTANCE * (1f - e),
            outgoingShift = -side * SLIDE_DISTANCE * e,
            backdropAlpha = backdrop,
            atMiddle = atMiddle,
            done = done,
          )
        }
      }
    }
  }
}
