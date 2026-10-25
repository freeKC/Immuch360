package app.alextran.immich.djilink

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.graphics.Color
import android.util.TypedValue
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import app.alextran.immich.MainActivity
import app.alextran.immich.R
import app.alextran.immich.immersive.ImmersiveInputSystem
import app.alextran.immich.immersive.isHorizonOsDevice
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.SpatialFeature
import com.meta.spatial.core.Vector3
import com.meta.spatial.runtime.ButtonBits
import com.meta.spatial.runtime.PanelConfigOptions
import com.meta.spatial.runtime.PanelShapeLayerBlendType
import com.meta.spatial.runtime.ReferenceSpace
import com.meta.spatial.runtime.StereoMode
import com.meta.spatial.toolkit.AppSystemActivity
import com.meta.spatial.toolkit.CylinderShapeOptions
import com.meta.spatial.toolkit.DpDisplayOptions
import com.meta.spatial.toolkit.Hittable
import com.meta.spatial.toolkit.LayoutXMLPanelRegistration
import com.meta.spatial.toolkit.MediaPanelRenderOptions
import com.meta.spatial.toolkit.MediaPanelSettings
import com.meta.spatial.toolkit.MeshCollision
import com.meta.spatial.toolkit.Panel
import com.meta.spatial.toolkit.PanelRegistration
import com.meta.spatial.toolkit.PanelRenderMode
import com.meta.spatial.toolkit.PanelSettings
import com.meta.spatial.toolkit.PanelStyleOptions
import com.meta.spatial.toolkit.PixelDisplayOptions
import com.meta.spatial.toolkit.QuadShapeOptions
import com.meta.spatial.toolkit.Scale
import com.meta.spatial.toolkit.Transform
import com.meta.spatial.toolkit.UIPanelRenderOptions
import com.meta.spatial.toolkit.UIPanelSettings
import com.meta.spatial.toolkit.UIPanelShapeOptions
import com.meta.spatial.toolkit.VideoSurfacePanelRegistration
import com.meta.spatial.toolkit.Visible
import com.meta.spatial.toolkit.createPanelEntity
import com.meta.spatial.vr.LocomotionSystem
import com.meta.spatial.vr.VRFeature
import java.util.Locale
import java.util.UUID
import kotlin.math.sqrt

/** What the flight view's panel shows, read from the controller four times a second */
data class DjiFlightNumbers(
  val receiving: Boolean,
  /** A capture is played on this headset itself */
  val localReplay: Boolean,
  val state: RelayReceiveState,
  val replay: Boolean,
  val phoneHasSource: Boolean,
  val replayName: String?,
  /** Since the last picture shown here (for a relayed stream), or out of the decoder */
  val lastPictureAgoMs: Long?,
  val picturesPerSecond: Double,
  /** Phone receive to picture shown, the most of the last 2 s; null while it cannot be measured or nothing shows */
  val receiveToPictureMs: Double?,
  val values: TelemetryValues?,
  /** What the obstacle ring decided on this device, from the readings and the choices the phone relays */
  val alert: ObstacleDecision = ObstacleDecision.OFF,
  /** Before the clocks are aligned: relay, in process and decode, without the jitter buffer */
  val delayEstimateMs: Double? = null,
  /** "Show the distance by the glow", this headset's own choice */
  val ringNumbers: Boolean = false,
  /** The indicator as a frame around the video, this headset's own choice; false is the circle around its centre */
  val ringFrame: Boolean = false,
)

/**
 * What the controllers do in the flight view, decided apart from the activity so that it is unit tested. Nothing here
 * reaches the receiver, the phone or the drone: every action changes the view only.
 *
 * - B or Y goes back to the window, and nothing else happens on that update;
 * - A, or the menu gesture of a hand, shows or hides the values panel;
 * - X makes the video flat or curved;
 * - either thumbstick left or right puts the video in front of the gaze again (yaw only);
 * - either thumbstick up or down makes the video wider or narrower;
 * - any button, the trigger and the grips too, brings the warnings back for five seconds ([TransientText]): the state
 *   of the picture, the red line, the observer note, watching only, the DJI Fly line and the hint.
 */
internal object FlightViewControls {
  enum class Action { CLOSE, TOGGLE_VALUES, TOGGLE_CURVE, RECENTER, WIDER, NARROWER }

  private val STICK_SIDE = ButtonBits.ButtonThumbLL or ButtonBits.ButtonThumbLR or ButtonBits.ButtonThumbRL or
    ButtonBits.ButtonThumbRR
  private val STICK_UP = ButtonBits.ButtonThumbLU or ButtonBits.ButtonThumbRU
  private val STICK_DOWN = ButtonBits.ButtonThumbLD or ButtonBits.ButtonThumbRD

  fun actionsFor(controllerBits: Int, handBits: Int): List<Action> {
    // Bits only a controller has count as controller bits even when the SDK files them under a hand for a while
    val controllerOnly = ButtonBits.ButtonB or ButtonBits.ButtonY or STICK_SIDE or STICK_UP or STICK_DOWN
    val controller = controllerBits or (handBits and controllerOnly)
    val hand = handBits and controllerOnly.inv()
    if ((controller and (ButtonBits.ButtonB or ButtonBits.ButtonY)) != 0) {
      return listOf(Action.CLOSE)
    }
    val actions = mutableListOf<Action>()
    if ((controller and ButtonBits.ButtonA) != 0 || (hand and ButtonBits.ButtonMenu) != 0) {
      actions += Action.TOGGLE_VALUES
    }
    if ((controller and ButtonBits.ButtonX) != 0) {
      actions += Action.TOGGLE_CURVE
    }
    when {
      (controller and STICK_SIDE) != 0 -> actions += Action.RECENTER
      (controller and STICK_UP) != 0 -> actions += Action.WIDER
      (controller and STICK_DOWN) != 0 -> actions += Action.NARROWER
    }
    return actions
  }

  /** Any button or gesture brings the warnings back (B or Y also closes the view) */
  fun recalls(controllerBits: Int, handBits: Int): Boolean = (controllerBits or handBits) != 0

  /**
   * The state lines that stay (an error that needs an action until it is resolved): the phone lost the remote, a
   * refused or new code, another version, a phone that did not prove the code, a reception that ended. "Live", "a
   * capture" and "lost, trying again" come and go.
   */
  private val KEPT_STATES = setOf("noSource", "wrongCode", "otherVersion", "unproven", "ended")

  fun stateKeeps(stateKeys: List<String>): Boolean = stateKeys.any { it in KEPT_STATES }

  /** The red line stays while it says why no picture shows: the video is hidden ([hideVideo]) */
  fun redLineKeeps(line: StripLine, lastPictureAgoMs: Long?): Boolean =
    (line == StripLine.NO_PICTURE || line == StripLine.STALE) && hideVideo(lastPictureAgoMs)

  /** The widths of the video at 2.5 m, about 35 to 77 degrees */
  val WIDTHS_M = floatArrayOf(1.6f, 2.4f, 3.2f, 4.0f)
  const val DEFAULT_WIDTH_INDEX = 1

  fun nextWidth(index: Int, action: Action): Int = when (action) {
    Action.WIDER -> (index + 1).coerceAtMost(WIDTHS_M.size - 1)
    Action.NARROWER -> (index - 1).coerceAtLeast(0)
    else -> index
  }

  /** A picture is shown live only while it is fresh: a red line after 500 ms, the video hidden after 2 s */
  fun staleLine(lastPictureAgoMs: Long?): Boolean = lastPictureAgoMs == null || lastPictureAgoMs > 500

  fun hideVideo(lastPictureAgoMs: Long?): Boolean = lastPictureAgoMs == null || lastPictureAgoMs > 2_000

  /** From this delay behind the phone on, the red line warns the pilot (the 500 ms of stage 2b) */
  const val DELAY_WARNING_MS = 500.0

  enum class StripLine { NONE, NO_PICTURE, STALE, DELAY_HIGH }

  /**
   * The red line of the strip (p2/review-relay-2026-10-25.md M1 and M4): no picture yet, a picture that stopped, or a
   * picture shown late, from the delay of the last 2 s
   */
  fun stripLine(lastPictureAgoMs: Long?, delayNowMs: Double?): StripLine = when {
    lastPictureAgoMs == null -> StripLine.NO_PICTURE
    staleLine(lastPictureAgoMs) -> StripLine.STALE
    delayNowMs != null && delayNowMs >= DELAY_WARNING_MS -> StripLine.DELAY_HIGH
    else -> StripLine.NONE
  }

  /**
   * The two columns beside the video (p2/design-final-2026-10-24.md, 7.2), in this order: the flight values on its
   * left, the state of the drone on its right, as the phone's two bands. Flutter passes a label and a value template
   * ("cell.droneBattery.label", "cell.droneBattery.value" = "{value} %") only for the fields its gate lets over the
   * picture; a field without a template has no cell, whatever arrives.
   */
  val LEFT_FIELDS = listOf("height", "verticalSpeed", "distanceHome", "speed", "distanceBelow")
  val RIGHT_FIELDS = listOf(
    "droneBattery",
    "timeLeft",
    "motorTime",
    "signalBars",
    "remoteBattery",
    "satellites",
    "heading",
    "landing",
  )

  /** Every field a template may name, the two columns first */
  val VALUE_FIELDS = LEFT_FIELDS + RIGHT_FIELDS +
    listOf("motors", "batteryVoltage", "batteryTemperature", "signal", "linkRate", "obstacle")

  /** Under this the drone's battery is drawn in amber, with "low" in its label, as on the phone */
  const val BATTERY_LOW_PERCENT = 20

  /** One value of a column: a small label over a large number */
  data class Cell(val field: String, val label: String, val value: String, val low: Boolean = false)

  fun cellLabelKey(field: String) = "cell.$field.label"

  fun cellValueKey(field: String) = "cell.$field.value"

  /** The cells of [fields] that have a template and a fresh value, in that order */
  fun cells(values: TelemetryValues?, labels: Map<String, String>, fields: List<String>): List<Cell> {
    if (values == null) {
      return emptyList()
    }
    return fields.mapNotNull { field ->
      val template = labels[cellValueKey(field)]
      val number = if (template.isNullOrEmpty()) null else freshValue(values, field, labels)
      if (template == null || number == null) {
        null
      } else {
        val battery = values.battery?.takeIf { !it.stale }?.value
        val low = field == "droneBattery" && battery != null && battery.percent < BATTERY_LOW_PERCENT
        val label = labels[cellLabelKey(field)] ?: ""
        Cell(
          field = field,
          label = if (low) "$label ${labels["batteryLow"] ?: ""}".trim() else label,
          value = template.replace("{value}", number),
          low = low,
        )
      }
    }
  }

  /** The number of [field] when its group is fresh, in the format of the phone (dji_live_fields.dart) */
  private fun freshValue(values: TelemetryValues, field: String, labels: Map<String, String>): String? {
    val flight = values.flight?.takeIf { !it.stale }?.value
    // The height and the speeds in the air only: before lift off the height drifts, on the ground the speeds are stale;
    // the height also waits out the phone's HeightHold (after lift off, after a jump no aircraft makes)
    val air = flight?.airborne
    val battery = values.battery?.takeIf { !it.stale }?.value
    return when (field) {
      "droneBattery" -> battery?.percent?.toString()
      "batteryVoltage" -> battery?.let { decimals(it.voltageV, 2) }
      "batteryTemperature" -> battery?.let { decimals(it.temperatureC, 1) }
      "motorTime" -> flight?.let { minutesSeconds(it.motorTimeS) }
      "motors" -> flight?.let { labels[if (it.motorsOn) "on" else "off"] ?: "" }
      "heading" -> flight?.let { decimals(it.headingDeg, 0) }
      "height" -> flight?.pilotHeightM?.let { height(it) }
      "verticalSpeed" -> air?.let { verticalSpeed(it.verticalSpeedMps) }
      "speed" -> air?.let { decimals(it.horizontalSpeedMps, 1) }
      "satellites" -> flight?.satellites?.toString()
      // A chip: its template is the word itself
      "landing" -> flight?.takeIf { it.mode == TelemetryFields.MODE_AUTOMATIC_LANDING }?.let { "" }
      "signal" -> values.link.signalRemoteSide?.takeIf { !it.stale }?.value?.toString()
      "linkRate" -> values.link.liveRateMbps?.takeIf { !it.stale }?.value?.let { decimals(it, 1) }
      "signalBars" -> values.signalBars?.takeIf { !it.stale }?.value?.let { "$it/5" }
      "remoteBattery" -> values.remoteBatteryPercent?.takeIf { !it.stale }?.value?.toString()
      "distanceBelow" -> values.rangeBelow?.takeIf { !it.stale }?.value?.distanceM?.let { decimals(it, 2) }
      "obstacle" -> values.obstacles?.takeIf { !it.stale }?.value?.nearestM?.let { decimals(it, 1) }
      // No field of our captures gives these yet: nothing reads any byte for them
      "distanceHome", "timeLeft" -> null
      else -> null
    }
  }

  /**
   * How far from the video's centre a column's centre sits, along the video: past its edge at every width. At 4.0 m
   * that is about 42 degrees from the centre of a flat video. The design's move under the corners at the two widest
   * sizes is not made: under a video 1.8 to 2.25 m tall, a column 1 m tall would reach below the floor of a pilot who
   * stands.
   */
  fun columnOffsetM(videoWidthM: Float, columnWidthM: Float, gapM: Float): Float =
    videoWidthM / 2f + gapM + columnWidthM / 2f

  /** One decimal under 100 m, whole metres from there, as the phone */
  fun height(metres: Double): String = if (kotlin.math.abs(metres) >= 100) decimals(metres, 0) else decimals(metres, 1)

  /** An arrow up while climbing, down while descending, none at 0.0, then the speed without its sign */
  fun verticalSpeed(metresPerSecond: Double): String {
    val number = decimals(kotlin.math.abs(metresPerSecond), 1)
    return when {
      number == "0.0" -> number
      metresPerSecond > 0 -> "\u2191 $number"
      else -> "\u2193 $number"
    }
  }

  /**
   * The obstacle ring's halo around the video (p2/design-obstacle-ring-2026-10-25.md, 5.3): a margin of 0.10 m on each
   * side at the reference width, scaled with the video as its panel is
   */
  const val HALO_MARGIN_M = 0.10f
  const val VIDEO_REFERENCE_WIDTH_M = 2.4f

  fun haloMarginM(videoWidthM: Float): Float = HALO_MARGIN_M * videoWidthM / VIDEO_REFERENCE_WIDTH_M

  /** The halo panel's width and height at [videoWidthM], the video being 16:9 */
  fun haloSizeM(videoWidthM: Float): Pair<Float, Float> {
    val margin = haloMarginM(videoWidthM)
    return videoWidthM + 2 * margin to videoWidthM * 9f / 16f + 2 * margin
  }

  /**
   * The circle's panel (the default shape, [RingCircle]): a square over the middle of the video, the circle's radius a
   * quarter of the video's height, its thickness, and room for the distance outside it; scaled with the video as its
   * panel is. At every width it stays inside the video's rectangle.
   */
  const val CIRCLE_ROOM_M = 0.12f

  fun circleSideM(videoWidthM: Float): Float {
    val height = videoWidthM * 9f / 16f
    val room = CIRCLE_ROOM_M * videoWidthM / VIDEO_REFERENCE_WIDTH_M
    return 2f * (height * RingCircle.RADIUS_PART.toFloat() + height * RingCircle.THICKNESS_PART.toFloat() + room)
  }

  /** The video's height as a part of the circle panel's side, for [ObstacleCircleView.videoHeightPart] */
  fun circleVideoHeightPart(videoWidthM: Float): Float = videoWidthM * 9f / 16f / circleSideM(videoWidthM)

  /**
   * The compositor's order of the three layers (review of build 30, minor 1): the halo (frame) under the video, the
   * circle over it. All three are compositor layers, and at the same z index the order is left to their distances;
   * a higher z index is drawn over a lower one (the immersive viewer's video sphere at -1 is under its panels on the
   * Quest). None is below 0, which would put it under the scene.
   */
  const val HALO_Z_INDEX = 0
  const val VIDEO_Z_INDEX = 1
  const val CIRCLE_Z_INDEX = 2

  /** The ring shows in the halo: arcs to draw, the ring on or its data stopped */
  fun ringShows(decision: ObstacleDecision): Boolean = decision.arcs.isNotEmpty() && (decision.on || decision.stopped)

  /**
   * The distance by the nearest arc ("1.4 m"), null when it does not show: asked on this headset, the values shown (A
   * hides it with them), the ring on and its data fresh
   */
  fun ringNumber(
    decision: ObstacleDecision,
    labels: Map<String, String>,
    numbersOn: Boolean,
    valuesShown: Boolean,
  ): String? {
    val nearest = decision.nearestM ?: decision.arcs.firstOrNull()?.distanceM
    if (!numbersOn || !valuesShown || !decision.on || decision.stopped || nearest == null) {
      return null
    }
    val template = labels["obstacleDistance"]?.takeIf { it.isNotEmpty() } ?: return null
    return template.replace("{distance}", decimals(nearest, 1))
  }

  /** The motor time as minutes and seconds, as the phone writes it: 41.6 s is 0:41 */
  fun minutesSeconds(seconds: Double): String {
    val whole = kotlin.math.floor(seconds).toLong().coerceAtLeast(0L)
    return "${whole / 60}:${(whole % 60).toString().padStart(2, '0')}"
  }

  fun decimals(value: Double, digits: Int): String = String.format(Locale.ROOT, "%.${digits}f", value)

  /**
   * The labels of the state line, said one after the other. A reception that ended on its own (a refused or new code,
   * another version, a phone that did not prove the code) gives its reason, then that no picture comes any more;
   * "local" is only ever said of a capture being played on this headset.
   */
  fun stateLabels(numbers: DjiFlightNumbers): List<String> = when {
    numbers.receiving && numbers.state == RelayReceiveState.RECEIVING && !numbers.phoneHasSource -> listOf("noSource")
    numbers.receiving && numbers.state == RelayReceiveState.RECEIVING && numbers.replay -> listOf("replay")
    numbers.receiving && numbers.state == RelayReceiveState.RECEIVING -> listOf("live")
    numbers.receiving -> listOf("lost")
    numbers.localReplay -> listOf("local")
    numbers.state == RelayReceiveState.WRONG_CODE -> listOf("wrongCode", "ended")
    numbers.state == RelayReceiveState.OTHER_VERSION -> listOf("otherVersion", "ended")
    numbers.state == RelayReceiveState.PHONE_UNPROVEN -> listOf("unproven", "ended")
    else -> listOf("ended")
  }
}

/**
 * The flight view of the Quest (p2/design-stage2b.md, 8.3): the drone's picture relayed by the phone on a flat (or
 * curved) video panel 2.5 m in front, world locked so that the pilot looks around freely, passthrough around it, a
 * strip under it whose warnings come and go (the state of the picture, the stale line, the observer note, watching
 * only; the line that says why no picture shows stays while it does not) and the values panel under the strip, which
 * A shows or hides. The decoder of the window page renders into the video
 * panel's surface through setOutputSurface ([DjiLinkVideoSurfaces]), so going in and out never restarts it.
 *
 * Watching only: nothing in this activity reaches the receiver, the phone or the drone. The controllers change the
 * view (size, place, curve, panel) and leave it; the remote in the pilot's hands flies the drone.
 *
 * Exported like the immersive viewer, so that Horizon OS can start it as a VR activity; it ignores intents without the
 * app's launch token.
 */
class DjiFlightViewActivity : AppSystemActivity() {
  companion object {
    private const val TAG = "DjiFlightView"
    private const val EXTRA_TOKEN = "app.alextran.immich.djilink.flight.TOKEN"
    private const val EXTRA_LABELS = "app.alextran.immich.djilink.flight.LABELS"

    private const val VIDEO_DISTANCE_M = 2.5f
    private const val VIDEO_DROP_M = 0.1f
    private const val VIDEO_REFERENCE_WIDTH_M = FlightViewControls.VIDEO_REFERENCE_WIDTH_M
    private const val CURVE_RADIUS_M = 2.5f
    private const val PANEL_WIDTH_M = 1.6f
    private const val PANEL_HEIGHT_M = 0.3f
    private const val PANEL_WIDTH_DP = 800f
    private const val PANEL_HEIGHT_DP = 150f
    private const val STRIP_HEIGHT_M = 0.22f
    private const val STRIP_HEIGHT_DP = 110f
    private const val PANEL_GAP_M = 0.06f

    /** The two value columns beside the video (p2/design-final-2026-10-24.md, 7.2), 500 dp per metre as the panels */
    private const val COLUMN_WIDTH_M = 0.36f
    private const val COLUMN_HEIGHT_M = 1.0f
    private const val COLUMN_WIDTH_DP = 180f
    private const val COLUMN_HEIGHT_DP = 500f
    private const val COLUMN_GAP_M = 0.05f

    /** The obstacle ring's halo around the video: 250 dp per metre, the glow is soft */
    private const val HALO_DP_PER_M = 250f

    /**
     * The halo sits this far behind the video, and its layer under the video's ([FlightViewControls.HALO_Z_INDEX]): the
     * picture stays on top of it even if the halo's clear centre were not blended
     * (p2/review-obstacle-ring-2026-10-25.md, minor 1). Seen from 2.5 m, its inner edge moves 7 mm under the video's
     * at most.
     */
    private const val HALO_BEHIND_M = 0.015f
    private const val HALO_FADE_IN_MS = 150L
    private const val HALO_FADE_OUT_MS = 400L

    /**
     * The circle's panel sits this far in front of the video, inside its rectangle, and its layer is ordered over the
     * video's ([FlightViewControls.CIRCLE_Z_INDEX]). Whether the compositor shows the video through its transparent
     * parts is not verified on a headset: the owner's sample decides (a missing circle is a no go too), and the frame
     * at the edges (behind the video) is the setting to use if the picture does not show through.
     */
    private const val CIRCLE_FRONT_M = 0.015f

    /** Labels 18 sp, values 40 sp: about 0.08 m tall at 2.5 m, read at a glance */
    private const val CELL_LABEL_SP = 18f
    private const val CELL_VALUE_SP = 40f
    private const val CELL_GAP_DP = 10
    private val CELL_LABEL_COLOR = Color.parseColor("#FFB0B8CC")
    private val CELL_VALUE_COLOR = Color.parseColor("#FFFFFFFF")
    private val CELL_LOW_COLOR = Color.parseColor("#FFFFB300")

    /** The values follow the drone ten times a second; a text is set only when it changed */
    private const val REFRESH_MS = 100L

    /** Token of the last intent built by [intent], checked in onCreate. Lives as long as the process. */
    @Volatile
    private var launchToken: String? = null

    /** The last flight view could not set its scene up: the window says so */
    @Volatile
    var lastFailed = false
      private set

    fun intent(context: Context, labels: Map<String, String>): Intent {
      val token = UUID.randomUUID().toString()
      launchToken = token
      val bundle = Bundle().apply { labels.forEach { (key, value) -> putString(key, value) } }
      return Intent(context, DjiFlightViewActivity::class.java).apply {
        action = Intent.ACTION_MAIN
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        putExtra(EXTRA_LABELS, bundle)
        putExtra(EXTRA_TOKEN, token)
      }
    }
  }

  private var labels: Map<String, String> = emptyMap()
  private var valid = false
  private var sceneReady = false
  private var closing = false
  private var released = false
  private var videoEntity: Entity? = null
  private var stripEntity: Entity? = null
  private var panelEntity: Entity? = null
  private var leftEntity: Entity? = null
  private var rightEntity: Entity? = null
  private var haloEntity: Entity? = null
  private var curved = false
  private var widthIndex = FlightViewControls.DEFAULT_WIDTH_INDEX
  private var panelShown = true
  private var videoVisible = false
  private var placed = false
  private var framesWithoutHead = 0
  private var headPosition: Vector3? = null
  private var headForward: Vector3? = null

  /** The head the video was placed from: the columns of a curved video sit on its circle */
  private var placedHead: Vector3? = null
  private var videoPosition: Vector3? = null
  private var videoDirection: Vector3? = null
  private var stateText: TextView? = null
  private var staleText: TextView? = null
  private var latencyText: TextView? = null
  private var leftCells: LinearLayout? = null
  private var rightCells: LinearLayout? = null
  private var leftShown: List<FlightViewControls.Cell> = emptyList()
  private var rightShown: List<FlightViewControls.Cell> = emptyList()
  private var haloView: ObstacleHaloView? = null
  private var haloShown = false
  private var circleEntity: Entity? = null
  private var circleView: ObstacleCircleView? = null
  private var circleShown = false

  /** The warnings of the strip and of the panel, which come and go ([TransientText]) */
  private var stripRoot: View? = null
  private var observerText: TextView? = null
  private var watchingText: TextView? = null
  private var flyNoteText: TextView? = null
  private var hintText: TextView? = null
  private val stateClock = TransientClock()
  private val redClock = TransientClock()
  private val watchingClock = TransientClock()
  private val flyNoteClock = TransientClock()
  private val hintClock = TransientClock()
  private val faded = mutableMapOf<View, Boolean>()
  private var stripGone = false
  private val handler = Handler(Looper.getMainLooper())
  private val refresh = object : Runnable {
    override fun run() {
      refreshNow()
      handler.postDelayed(this, REFRESH_MS)
    }
  }

  override fun registerFeatures(): List<SpatialFeature> = listOf(VRFeature(this))

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val token = intent?.getStringExtra(EXTRA_TOKEN)
    valid = token != null && token == launchToken
    if (!valid) {
      Log.w(TAG, "flight view intent without a valid launch token, ignored")
    }
    labels = intent?.getBundleExtra(EXTRA_LABELS)?.let { bundle ->
      bundle.keySet().associateWith { bundle.getString(it) ?: "" }
    } ?: emptyMap()
    lastFailed = false
    DjiLinkController.of(this).flightViewOpened()
  }

  override fun onSceneReady() {
    super.onSceneReady()
    if (!valid) {
      close()
      return
    }
    try {
      scene.setReferenceSpace(ReferenceSpace.LOCAL_FLOOR)
      // The pilot sees the field, the remote in his hands and the observer around the picture
      runCatching { scene.enablePassthrough(true) }.onFailure { Log.w(TAG, "no passthrough: ${it.message}") }
      runCatching { systemManager.findSystem<LocomotionSystem>().enableLocomotion(false) }
      videoEntity = Entity.create(Panel(videoPanelId()), Transform(), Visible(false))
      stripEntity = Entity.createPanelEntity(R.id.dji_flight_strip_panel, Transform(), Visible(false))
      panelEntity = Entity.createPanelEntity(R.id.dji_flight_panel, Transform(), Visible(false))
      leftEntity = Entity.createPanelEntity(R.id.dji_flight_left_panel, Transform(), Visible(false))
      rightEntity = Entity.createPanelEntity(R.id.dji_flight_right_panel, Transform(), Visible(false))
      haloEntity = createHalo()
      circleEntity = createCircle()
      systemManager.registerSystem(ImmersiveInputSystem(input))
      sceneReady = true
      handler.post(refresh)
    } catch (e: Exception) {
      Log.e(TAG, "flight view scene setup failed", e)
      lastFailed = true
      close()
    }
  }

  private fun videoPanelId(): Int = if (curved) R.id.dji_flight_video_curved else R.id.dji_flight_video_flat

  private fun haloPanelId(): Int = if (curved) R.id.dji_flight_ring_curved else R.id.dji_flight_ring_flat

  /** The halo, flat or curved as the video is; the controllers' rays go through it */
  private fun createHalo(): Entity =
    Entity.createPanelEntity(haloPanelId(), Transform(), Visible(false), Hittable(MeshCollision.NoCollision))

  private fun circlePanelId(): Int = if (curved) R.id.dji_flight_circle_curved else R.id.dji_flight_circle_flat

  /** The circle's panel, flat or curved as the video is; the controllers' rays go through it */
  private fun createCircle(): Entity =
    Entity.createPanelEntity(circlePanelId(), Transform(), Visible(false), Hittable(MeshCollision.NoCollision))

  override fun registerPanels(): List<PanelRegistration> =
    listOf(
      videoRegistration(R.id.dji_flight_video_flat) {
        QuadShapeOptions(width = VIDEO_REFERENCE_WIDTH_M, height = VIDEO_REFERENCE_WIDTH_M * 9f / 16f)
      },
      videoRegistration(R.id.dji_flight_video_curved) {
        CylinderShapeOptions(
          radius = CURVE_RADIUS_M,
          width = VIDEO_REFERENCE_WIDTH_M,
          height = VIDEO_REFERENCE_WIDTH_M * 9f / 16f,
        )
      },
      LayoutXMLPanelRegistration(
        R.id.dji_flight_strip_panel,
        layoutIdCreator = { R.layout.dji_flight_strip },
        settingsCreator = {
          UIPanelSettings(
            shape = QuadShapeOptions(width = PANEL_WIDTH_M, height = STRIP_HEIGHT_M),
            style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
            display = DpDisplayOptions(width = PANEL_WIDTH_DP, height = STRIP_HEIGHT_DP, dpi = 260),
          )
        },
        panelSetupWithRootView = { root, _, _ -> bindStrip(root) },
      ),
      LayoutXMLPanelRegistration(
        R.id.dji_flight_panel,
        layoutIdCreator = { R.layout.dji_flight_panel },
        settingsCreator = {
          UIPanelSettings(
            shape = QuadShapeOptions(width = PANEL_WIDTH_M, height = PANEL_HEIGHT_M),
            style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
            display = DpDisplayOptions(width = PANEL_WIDTH_DP, height = PANEL_HEIGHT_DP, dpi = 260),
          )
        },
        panelSetupWithRootView = { root, _, _ -> bindPanel(root) },
      ),
      columnRegistration(R.id.dji_flight_left_panel) { root -> leftCells = root.findViewById(R.id.dji_flight_cells) },
      columnRegistration(R.id.dji_flight_right_panel) { root -> rightCells = root.findViewById(R.id.dji_flight_cells) },
      haloRegistration(R.id.dji_flight_ring_flat) { width, height -> QuadShapeOptions(width = width, height = height) },
      haloRegistration(R.id.dji_flight_ring_curved) { width, height ->
        CylinderShapeOptions(radius = CURVE_RADIUS_M, width = width, height = height)
      },
      circleRegistration(R.id.dji_flight_circle_flat) { side -> QuadShapeOptions(width = side, height = side) },
      circleRegistration(R.id.dji_flight_circle_curved) { side ->
        CylinderShapeOptions(radius = CURVE_RADIUS_M, width = side, height = side)
      },
    )

  /**
   * The obstacle ring's halo: a transparent layer a margin larger than the video at the reference width, blended over
   * what is behind it, with the same pose and scale as the video ([applyPlacement])
   */
  private fun haloRegistration(id: Int, shape: (Float, Float) -> UIPanelShapeOptions): PanelRegistration {
    val (width, height) = FlightViewControls.haloSizeM(VIDEO_REFERENCE_WIDTH_M)
    val margin = FlightViewControls.haloMarginM(VIDEO_REFERENCE_WIDTH_M)
    return LayoutXMLPanelRegistration(
      id,
      layoutIdCreator = { R.layout.dji_flight_ring },
      settingsCreator = {
        layeredAt(
          FlightViewControls.HALO_Z_INDEX,
          UIPanelSettings(
            shape = shape(width, height),
            style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
            display = DpDisplayOptions(width = width * HALO_DP_PER_M, height = height * HALO_DP_PER_M, dpi = 260),
            rendering = UIPanelRenderOptions(PanelRenderMode.Layer(PanelShapeLayerBlendType.ALPHA_BLEND)),
          ),
        )
      },
      panelSetupWithRootView = { root, _, _ ->
        haloView = root.findViewById<ObstacleHaloView>(R.id.dji_flight_ring_halo)?.apply {
          marginWidthPart = margin / width
          marginHeightPart = margin / height
          alpha = 0f
        }
        haloShown = false
        refreshNow()
      },
    )
  }

  /**
   * The circle around the video's centre (the default shape): a transparent layer over the middle of the video at the
   * reference width, blended over it, with the same pose and scale as the video ([applyPlacement]), a little in front
   */
  private fun circleRegistration(id: Int, shape: (Float) -> UIPanelShapeOptions): PanelRegistration {
    val side = FlightViewControls.circleSideM(VIDEO_REFERENCE_WIDTH_M)
    return LayoutXMLPanelRegistration(
      id,
      layoutIdCreator = { R.layout.dji_flight_circle },
      settingsCreator = {
        layeredAt(
          FlightViewControls.CIRCLE_Z_INDEX,
          UIPanelSettings(
            shape = shape(side),
            style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
            display = DpDisplayOptions(width = side * HALO_DP_PER_M, height = side * HALO_DP_PER_M, dpi = 260),
            rendering = UIPanelRenderOptions(PanelRenderMode.Layer(PanelShapeLayerBlendType.ALPHA_BLEND)),
          ),
        )
      },
      panelSetupWithRootView = { root, _, _ ->
        circleView = root.findViewById<ObstacleCircleView>(R.id.dji_flight_circle_view)?.apply {
          videoHeightPart = FlightViewControls.circleVideoHeightPart(VIDEO_REFERENCE_WIDTH_M)
          alpha = 0f
        }
        circleShown = false
        refreshNow()
      },
    )
  }

  /**
   * [settings] with its compositor layer at [zIndex]: the render options of a UI panel give no z index in this SDK
   * (0.14.0), the layer config they make has one
   */
  private fun layeredAt(zIndex: Int, settings: UIPanelSettings): PanelSettings = object : PanelSettings {
    override fun toPanelConfigOptions(): PanelConfigOptions =
      settings.toPanelConfigOptions().apply { layerConfig?.let { it.zIndex = zIndex } }
  }

  /** A column of values beside the video; its cells are made in [fillColumn] */
  private fun columnRegistration(id: Int, bind: (View) -> Unit): PanelRegistration =
    LayoutXMLPanelRegistration(
      id,
      layoutIdCreator = { R.layout.dji_flight_column },
      settingsCreator = {
        UIPanelSettings(
          shape = QuadShapeOptions(width = COLUMN_WIDTH_M, height = COLUMN_HEIGHT_M),
          style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
          display = DpDisplayOptions(width = COLUMN_WIDTH_DP, height = COLUMN_HEIGHT_DP, dpi = 260),
        )
      },
      panelSetupWithRootView = { root, _, _ ->
        bind(root)
        leftShown = emptyList()
        rightShown = emptyList()
        refreshNow()
      },
    )

  /** A compositor layer the decoder renders into with no copy; its surface goes to the window page's decoder */
  private fun videoRegistration(
    id: Int,
    shape: () -> com.meta.spatial.toolkit.MediaPanelShapeOptions,
  ): VideoSurfacePanelRegistration =
    VideoSurfacePanelRegistration(
      id,
      surfaceConsumer = { _, surface ->
        Log.i(TAG, "video surface ready")
        DjiLinkVideoSurfaces.created(DjiLinkVideoSurfaces.FLIGHT_VIEW_ID, surface)
      },
      settingsCreator = {
        MediaPanelSettings(
          shape = shape(),
          display = PixelDisplayOptions(width = 1920, height = 1080),
          rendering = MediaPanelRenderOptions(stereoMode = StereoMode.None, zIndex = FlightViewControls.VIDEO_Z_INDEX),
        )
      },
    )

  /** The strip under the video, whose warnings come and go */
  private fun bindStrip(root: View) {
    stripRoot = root
    stateText = root.findViewById(R.id.dji_flight_state)
    staleText = root.findViewById(R.id.dji_flight_stale)
    observerText = root.findViewById<TextView>(R.id.dji_flight_observer)?.apply { text = label("observer") }
    watchingText = root.findViewById<TextView>(R.id.dji_flight_watching)?.apply { text = label("watching") }
    faded.clear()
    stripGone = false
    refreshNow()
  }

  /** The values panel under the strip, which A shows or hides; its DJI Fly line and hint come and go */
  private fun bindPanel(root: View) {
    latencyText = root.findViewById(R.id.dji_flight_latency)
    flyNoteText = root.findViewById<TextView>(R.id.dji_flight_fly_note)?.apply { text = label("flyNote") }
    hintText = root.findViewById<TextView>(R.id.dji_flight_hint)?.apply { text = label("hint") }
    root.findViewById<TextView>(R.id.dji_flight_back)?.apply {
      text = label("back")
      setOnClickListener { close() }
    }
    refreshNow()
  }

  private fun label(key: String): String = labels[key] ?: ""

  private fun fill(key: String, vararg values: Pair<String, String>): String {
    var text = label(key)
    for ((name, value) in values) {
      text = text.replace("{$name}", value)
    }
    return text
  }

  private fun number(value: Double?, digits: Int = 1): String =
    if (value == null) "-" else String.format(Locale.ROOT, "%.${digits}f", value)

  /** A text set only when it changed: a value that stays the same never relays out its panel */
  private fun TextView.show(value: String) {
    if (text?.toString() != value) {
      text = value
    }
  }

  /**
   * Ten times a second, on the main thread: the state line, the two columns, the ring around the video, and the video
   * hidden while no picture comes
   */
  private fun refreshNow() {
    if (!sceneReady || closing) {
      return
    }
    val numbers = runCatching { DjiLinkController.of(this).flightViewNumbers() }.getOrNull() ?: return
    val stateKeys = FlightViewControls.stateLabels(numbers)
    stateText?.show(
      stateKeys.joinToString(" ") { key ->
        if (key == "replay") fill("replay", "name" to (numbers.replayName ?: "-")) else label(key)
      },
    )
    val ago = numbers.lastPictureAgoMs
    val line = FlightViewControls.stripLine(ago, numbers.receiveToPictureMs)
    staleText?.apply {
      visibility = if (line == FlightViewControls.StripLine.NONE) View.GONE else View.VISIBLE
      show(
        when (line) {
          FlightViewControls.StripLine.NO_PICTURE -> label("noPicture")
          FlightViewControls.StripLine.STALE -> fill("stale", "seconds" to number((ago ?: 0) / 1000.0))
          FlightViewControls.StripLine.DELAY_HIGH -> fill("delayHigh", "ms" to number(numbers.receiveToPictureMs, 0))
          FlightViewControls.StripLine.NONE -> ""
        },
      )
    }
    showWarnings(stateKeys, line, ago)
    val values = numbers.values
    leftShown =
      fillColumn(leftCells, leftShown, FlightViewControls.cells(values, labels, FlightViewControls.LEFT_FIELDS))
    rightShown =
      fillColumn(rightCells, rightShown, FlightViewControls.cells(values, labels, FlightViewControls.RIGHT_FIELDS))
    // The delay from the phone in one short line, the most of the last 2 s; the parts of it stay on the Diagnostics
    // page. Before the clocks are aligned, the estimate says what it leaves out.
    latencyText?.show(
      numbers.receiveToPictureMs?.let { fill("delay", "ms" to number(it, 0)) }
        ?: numbers.delayEstimateMs?.let { fill("delayEstimate", "ms" to number(it, 0)) }
        ?: "",
    )
    showRing(numbers)
    val show = !FlightViewControls.hideVideo(ago)
    if (show != videoVisible || !placed) {
      videoVisible = show
      videoEntity?.setComponent(Visible(show && placed))
    }
    stripEntity?.setComponent(Visible(placed && !stripGone))
    panelEntity?.setComponent(Visible(panelShown && placed))
    // A hides the columns with the lower panel; the ring always shows, the strip while it holds a warning
    leftEntity?.setComponent(Visible(panelShown && placed && leftShown.isNotEmpty()))
    rightEntity?.setComponent(Visible(panelShown && placed && rightShown.isNotEmpty()))
  }

  /**
   * The warnings of the strip and of the panel (FreeKC's rule of 25 October, [TransientText]): each shows five seconds
   * when it comes or changes kind and after any button, then fades; the state line that needs an action and the red
   * line while the video is hidden stay. The strip goes once nothing is left in it, and comes back with the next one.
   */
  private fun showWarnings(stateKeys: List<String>, line: FlightViewControls.StripLine, ago: Long?) {
    val now = android.os.SystemClock.uptimeMillis()
    stateClock.follow(stateKeys.joinToString(","), now)
    redClock.follow(line.takeIf { it != FlightViewControls.StripLine.NONE }, now)
    watchingClock.follow("watching", now)
    flyNoteClock.follow("flyNote", now)
    hintClock.follow("hint", now)
    val stateShown = stateClock.shown(now, keep = FlightViewControls.stateKeeps(stateKeys))
    val redShown = redClock.shown(now, keep = FlightViewControls.redLineKeeps(line, ago))
    val watchingShown = watchingClock.shown(now)
    fade(stateText, stateShown)
    fade(staleText, redShown)
    fade(observerText, watchingShown)
    fade(watchingText, watchingShown)
    fade(flyNoteText, flyNoteClock.shown(now))
    fade(hintText, hintClock.shown(now))
    // The strip itself, its dark plate included, once nothing is left in it
    val anything = stateShown || redShown || watchingShown
    val root = stripRoot ?: return
    if (anything && stripGone) {
      stripGone = false
      stripEntity?.setComponent(Visible(placed))
    }
    fade(root, anything) {
      stripGone = true
      stripEntity?.setComponent(Visible(false))
    }
  }

  /** In over 250 ms, out over 0.8 s, only when it changes; [gone] runs once it faded out */
  private fun fade(view: View?, shown: Boolean, gone: (() -> Unit)? = null) {
    if (view == null || faded[view] == shown) {
      return
    }
    faded[view] = shown
    view.animate().cancel()
    if (shown) {
      view.animate().alpha(1f).setDuration(TransientText.FADE_IN_MS).start()
    } else {
      view.animate().alpha(0f).setDuration(TransientText.FADE_OUT_MS).withEndAction {
        if (faded[view] == false) {
          gone?.invoke()
        }
      }.start()
    }
  }

  /**
   * The obstacle indicator: the circle around the video's centre (the default) or the frame around the video, as
   * chosen on this headset. Nothing at all while nothing is close; it comes in over 150 ms and leaves over 400 ms, and
   * its panel is hidden once it has faded.
   */
  private fun showRing(numbers: DjiFlightNumbers) {
    val decision = numbers.alert
    val shows = FlightViewControls.ringShows(decision)
    val number = FlightViewControls.ringNumber(decision, labels, numbers.ringNumbers, panelShown)
    showHalo(shows && numbers.ringFrame, decision, number)
    showCircle(shows && !numbers.ringFrame, decision, number)
  }

  private fun showHalo(shows: Boolean, decision: ObstacleDecision, number: String?) {
    val view = haloView ?: return
    if (shows) {
      view.show(decision.arcs, number)
      if (!haloShown) {
        haloShown = true
        haloEntity?.setComponent(Visible(placed))
        view.animate().cancel()
        view.animate().alpha(1f).setDuration(HALO_FADE_IN_MS).start()
      }
    } else if (haloShown) {
      haloShown = false
      view.animate().cancel()
      view.animate().alpha(0f).setDuration(HALO_FADE_OUT_MS).withEndAction {
        if (!haloShown) {
          haloEntity?.setComponent(Visible(false))
          view.show(emptyList(), null)
        }
      }.start()
    }
    if (haloShown) {
      haloEntity?.setComponent(Visible(placed))
    }
  }

  private fun showCircle(shows: Boolean, decision: ObstacleDecision, number: String?) {
    val view = circleView ?: return
    if (shows) {
      view.show(decision.arcs, number)
      if (!circleShown) {
        circleShown = true
        circleEntity?.setComponent(Visible(placed))
        view.animate().cancel()
        view.animate().alpha(1f).setDuration(HALO_FADE_IN_MS).start()
      }
    } else if (circleShown) {
      circleShown = false
      view.animate().cancel()
      view.animate().alpha(0f).setDuration(HALO_FADE_OUT_MS).withEndAction {
        if (!circleShown) {
          circleEntity?.setComponent(Visible(false))
          view.show(emptyList(), null)
        }
      }.start()
    }
    if (circleShown) {
      circleEntity?.setComponent(Visible(placed))
    }
  }

  /**
   * The cells of a column: made again when the fields change (a value that comes or goes), otherwise each value's text
   * is set only when it changed. Returns what the column shows now.
   */
  private fun fillColumn(
    column: LinearLayout?,
    shown: List<FlightViewControls.Cell>,
    cells: List<FlightViewControls.Cell>,
  ): List<FlightViewControls.Cell> {
    if (column == null) {
      return shown
    }
    if (cells.map { it.field } != shown.map { it.field } || column.childCount != cells.size * 2) {
      column.removeAllViews()
      cells.forEachIndexed { index, _ ->
        column.addView(
          TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, CELL_LABEL_SP)
            setTextColor(CELL_LABEL_COLOR)
            maxLines = 1
            if (index > 0) {
              setPadding(0, (CELL_GAP_DP * resources.displayMetrics.density).toInt(), 0, 0)
            }
          },
        )
        column.addView(
          TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, CELL_VALUE_SP)
            setTextColor(CELL_VALUE_COLOR)
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            fontFeatureSettings = "tnum"
            maxLines = 1
          },
        )
      }
    }
    cells.forEachIndexed { index, cell ->
      (column.getChildAt(index * 2) as? TextView)?.apply {
        show(cell.label)
        visibility = if (cell.label.isEmpty()) View.GONE else View.VISIBLE
      }
      (column.getChildAt(index * 2 + 1) as? TextView)?.apply {
        show(cell.value)
        setTextColor(if (cell.low) CELL_LOW_COLOR else CELL_VALUE_COLOR)
      }
    }
    return cells
  }

  // Frame and input

  /** The input system of the immersive viewer, reused: it polls the controllers and the head every frame */
  private val input = object : ImmersiveInputSystem.Listener {
    override fun onButtonsPressed(controllerBits: Int, handBits: Int) = onButtons(controllerBits, handBits)

    override fun onFrame(head: Pose?) = onHead(head)
  }

  private fun onHead(head: Pose?) {
    if (head != null && (head.t.x != 0f || head.t.y != 0f || head.t.z != 0f)) {
      headPosition = Vector3(head.t.x, head.t.y, head.t.z)
      headForward = head.forward()
    }
    if (placed || !sceneReady) {
      return
    }
    if (headPosition != null || ++framesWithoutHead > 180) {
      placeInFront()
    }
  }

  /** The video 2.5 m in front of the head along its yaw, its centre below the eyes; the strip, then the panel */
  private fun placeInFront() {
    val head = headPosition ?: Vector3(0f, 1.6f, 0f)
    val forward = headForward ?: Vector3(0f, 0f, 1f)
    val flat = sqrt(forward.x * forward.x + forward.z * forward.z)
    val direction = if (flat < 1e-3f) Vector3(0f, 0f, 1f) else Vector3(forward.x / flat, 0f, forward.z / flat)
    val position = head + (direction * VIDEO_DISTANCE_M)
    position.y = head.y - VIDEO_DROP_M
    videoPosition = position
    videoDirection = direction
    placedHead = head
    placed = true
    applyPlacement()
  }

  private fun applyPlacement() {
    val position = videoPosition ?: return
    val direction = videoDirection ?: return
    val width = FlightViewControls.WIDTHS_M[widthIndex]
    val scale = width / VIDEO_REFERENCE_WIDTH_M
    val rotation = Quaternion.lookRotation(direction)
    videoEntity?.setComponent(Transform(Pose(position, rotation)))
    videoEntity?.setComponent(Scale(Vector3(scale, scale, 1f)))
    videoEntity?.setComponent(Visible(videoVisible))
    val videoBottom = position.y - width * 9f / 32f
    val stripPosition = Vector3(position.x, position.y, position.z)
    stripPosition.y = videoBottom - PANEL_GAP_M - STRIP_HEIGHT_M / 2f
    stripEntity?.setComponent(Transform(Pose(stripPosition, rotation)))
    stripEntity?.setComponent(Visible(!stripGone))
    val panelPosition = Vector3(position.x, position.y, position.z)
    panelPosition.y = videoBottom - PANEL_GAP_M - STRIP_HEIGHT_M - PANEL_GAP_M - PANEL_HEIGHT_M / 2f
    panelEntity?.setComponent(Transform(Pose(panelPosition, rotation)))
    panelEntity?.setComponent(Visible(panelShown))
    // The ring's halo around the video, as the video: same turn, same scale, a little behind it; A never hides it
    haloEntity?.setComponent(Transform(Pose(position + (direction * HALO_BEHIND_M), rotation)))
    haloEntity?.setComponent(Scale(Vector3(scale, scale, 1f)))
    // The circle over the middle of the video, the same turn and scale, a little in front of it
    circleEntity?.setComponent(Transform(Pose(position - (direction * CIRCLE_FRONT_M), rotation)))
    circleEntity?.setComponent(Scale(Vector3(scale, scale, 1f)))
    placeColumns(position, direction, rotation, width)
  }

  /**
   * The two columns at the video's edges, centred on its height, turned to face the head: beside a flat video along its
   * width, on the circle of a curved one past its ends. Which way is right comes from the video's own pose.
   */
  private fun placeColumns(position: Vector3, direction: Vector3, rotation: Quaternion, width: Float) {
    val head = placedHead ?: Vector3(position.x, position.y, position.z) - (direction * VIDEO_DISTANCE_M)
    val right = Pose(position, rotation).right()
    val beside = FlightViewControls.columnOffsetM(width, COLUMN_WIDTH_M, COLUMN_GAP_M)
    for ((entity, sign) in listOf(leftEntity to -1f, rightEntity to 1f)) {
      val target = entity ?: continue
      val place = if (curved) {
        val angle = sign * beside / CURVE_RADIUS_M
        val around = (direction * kotlin.math.cos(angle)) + (right * kotlin.math.sin(angle))
        head + (around * VIDEO_DISTANCE_M)
      } else {
        position + (right * (sign * beside))
      }
      place.y = position.y
      val facing = place - head
      val flat = sqrt(facing.x * facing.x + facing.z * facing.z)
      val look = if (flat < 1e-3f) direction else Vector3(facing.x / flat, 0f, facing.z / flat)
      target.setComponent(Transform(Pose(place, Quaternion.lookRotation(look))))
    }
  }

  private fun onButtons(controllerBits: Int, handBits: Int) {
    if (FlightViewControls.recalls(controllerBits, handBits)) {
      val now = android.os.SystemClock.uptimeMillis()
      for (clock in listOf(stateClock, redClock, watchingClock, flyNoteClock, hintClock)) {
        clock.recall(now)
      }
    }
    for (action in FlightViewControls.actionsFor(controllerBits, handBits)) {
      when (action) {
        FlightViewControls.Action.CLOSE -> {
          close()
          return
        }
        FlightViewControls.Action.TOGGLE_VALUES -> {
          // The values only: the strip with its warnings and the ring are not A's
          panelShown = !panelShown
          panelEntity?.setComponent(Visible(panelShown && placed))
          leftEntity?.setComponent(Visible(panelShown && placed && leftShown.isNotEmpty()))
          rightEntity?.setComponent(Visible(panelShown && placed && rightShown.isNotEmpty()))
        }
        FlightViewControls.Action.TOGGLE_CURVE -> toggleCurve()
        FlightViewControls.Action.RECENTER -> placeInFront()
        FlightViewControls.Action.WIDER, FlightViewControls.Action.NARROWER -> {
          widthIndex = FlightViewControls.nextWidth(widthIndex, action)
          applyPlacement()
        }
      }
    }
  }

  /** Flat or curved: the panel entity is made again, and the decoder moves to the new surface with setOutputSurface */
  private fun toggleCurve() {
    val old = videoEntity ?: return
    // The decoder leaves the old surface before it goes: the window's panel or the parking surface takes it meanwhile
    DjiLinkVideoSurfaces.destroyed(DjiLinkVideoSurfaces.FLIGHT_VIEW_ID)
    old.destroy()
    curved = !curved
    videoEntity = Entity.create(Panel(videoPanelId()), Transform(), Visible(false))
    // The halo and the circle follow the video's shape: their new panels bind new views
    haloEntity?.destroy()
    haloView = null
    haloShown = false
    haloEntity = createHalo()
    circleEntity?.destroy()
    circleView = null
    circleShown = false
    circleEntity = createCircle()
    applyPlacement()
  }

  @Deprecated("Deprecated in Java")
  override fun onBackPressed() {
    close()
  }

  /** Back to the window, the way the immersive viewer goes back: the receiver keeps running, held by the page */
  private fun close() {
    if (closing) {
      return
    }
    closing = true
    handler.removeCallbacks(refresh)
    releaseSurface()
    if (isHorizonOsDevice()) {
      try {
        val panelIntent = Intent(applicationContext, MainActivity::class.java).apply {
          action = Intent.ACTION_MAIN
          addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val pendingPanelIntent = PendingIntent.getActivity(
          applicationContext,
          0,
          panelIntent,
          PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val homeIntent = Intent(Intent.ACTION_MAIN)
          .addCategory(Intent.CATEGORY_HOME)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
          .putExtra("extra_launch_in_home_pending_intent", pendingPanelIntent)
        startActivity(homeIntent)
      } catch (e: Exception) {
        Log.e(TAG, "could not relaunch the window", e)
      }
    }
    finish()
  }

  private fun releaseSurface() {
    if (released) {
      return
    }
    released = true
    DjiLinkVideoSurfaces.destroyed(DjiLinkVideoSurfaces.FLIGHT_VIEW_ID)
  }

  override fun onSpatialShutdown() {
    handler.removeCallbacks(refresh)
    releaseSurface()
    super.onSpatialShutdown()
  }

  override fun onDestroy() {
    handler.removeCallbacks(refresh)
    releaseSurface()
    DjiLinkController.existing()?.flightViewClosed()
    super.onDestroy()
  }
}
