package app.alextran.immich.djilink

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
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
import com.meta.spatial.runtime.ReferenceSpace
import com.meta.spatial.runtime.StereoMode
import com.meta.spatial.toolkit.AppSystemActivity
import com.meta.spatial.toolkit.CylinderShapeOptions
import com.meta.spatial.toolkit.DpDisplayOptions
import com.meta.spatial.toolkit.LayoutXMLPanelRegistration
import com.meta.spatial.toolkit.MediaPanelRenderOptions
import com.meta.spatial.toolkit.MediaPanelSettings
import com.meta.spatial.toolkit.Panel
import com.meta.spatial.toolkit.PanelRegistration
import com.meta.spatial.toolkit.PanelStyleOptions
import com.meta.spatial.toolkit.PixelDisplayOptions
import com.meta.spatial.toolkit.QuadShapeOptions
import com.meta.spatial.toolkit.Scale
import com.meta.spatial.toolkit.Transform
import com.meta.spatial.toolkit.UIPanelSettings
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
  val state: RelayReceiveState,
  val replay: Boolean,
  val phoneHasSource: Boolean,
  val replayName: String?,
  val lastPictureAgoMs: Long?,
  val picturesPerSecond: Double,
  val receiveToPictureMs: Double?,
  val values: TelemetryValues?,
)

/**
 * What the controllers do in the flight view, decided apart from the activity so that it is unit tested. Nothing here
 * reaches the receiver, the phone or the drone: every action changes the view only.
 *
 * - B or Y goes back to the window, and nothing else happens on that update;
 * - A, or the menu gesture of a hand, shows or hides the flight panel;
 * - X makes the video flat or curved;
 * - either thumbstick left or right puts the video in front of the gaze again (yaw only);
 * - either thumbstick up or down makes the video wider or narrower;
 * - the trigger and the grips do nothing.
 */
internal object FlightViewControls {
  enum class Action { CLOSE, TOGGLE_PANEL, TOGGLE_CURVE, RECENTER, WIDER, NARROWER }

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
      actions += Action.TOGGLE_PANEL
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
}

/**
 * The flight view of the Quest (p2/design-stage2b.md, 8.3): the drone's picture relayed by the phone on a flat (or
 * curved) video panel 2.5 m in front, world locked so that the pilot looks around freely, passthrough around it, and a
 * small flight panel under it. The decoder of the window page renders into the panel's surface through
 * setOutputSurface ([DjiLinkVideoSurfaces]), so going in and out never restarts it.
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
    private const val VIDEO_REFERENCE_WIDTH_M = 2.4f
    private const val CURVE_RADIUS_M = 2.5f
    private const val PANEL_WIDTH_M = 1.6f
    private const val PANEL_HEIGHT_M = 0.45f
    private const val PANEL_WIDTH_DP = 800f
    private const val PANEL_HEIGHT_DP = 225f
    private const val PANEL_GAP_M = 0.06f
    private const val REFRESH_MS = 250L

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
  private var panelEntity: Entity? = null
  private var curved = false
  private var widthIndex = FlightViewControls.DEFAULT_WIDTH_INDEX
  private var panelShown = true
  private var videoVisible = false
  private var placed = false
  private var framesWithoutHead = 0
  private var headPosition: Vector3? = null
  private var headForward: Vector3? = null
  private var videoPosition: Vector3? = null
  private var videoDirection: Vector3? = null
  private var stateText: TextView? = null
  private var staleText: TextView? = null
  private var valuesText: TextView? = null
  private var latencyText: TextView? = null
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
      panelEntity = Entity.createPanelEntity(R.id.dji_flight_panel, Transform(), Visible(false))
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
          rendering = MediaPanelRenderOptions(stereoMode = StereoMode.None),
        )
      },
    )

  private fun bindPanel(root: View) {
    stateText = root.findViewById(R.id.dji_flight_state)
    staleText = root.findViewById(R.id.dji_flight_stale)
    valuesText = root.findViewById(R.id.dji_flight_values)
    latencyText = root.findViewById(R.id.dji_flight_latency)
    root.findViewById<TextView>(R.id.dji_flight_fly_note)?.text = label("flyNote")
    root.findViewById<TextView>(R.id.dji_flight_observer)?.text = label("observer")
    root.findViewById<TextView>(R.id.dji_flight_watching)?.text = label("watching")
    root.findViewById<TextView>(R.id.dji_flight_hint)?.text = label("hint")
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

  /** Four times a second, on the main thread: the panel's lines, and the video hidden while no picture comes */
  private fun refreshNow() {
    if (!sceneReady || closing) {
      return
    }
    val numbers = runCatching { DjiLinkController.of(this).flightViewNumbers() }.getOrNull() ?: return
    stateText?.text = when {
      numbers.receiving && numbers.state == RelayReceiveState.RECEIVING && !numbers.phoneHasSource -> label("noSource")
      numbers.receiving && numbers.state == RelayReceiveState.RECEIVING && numbers.replay ->
        fill("replay", "name" to (numbers.replayName ?: "-"))
      numbers.receiving && numbers.state == RelayReceiveState.RECEIVING -> label("live")
      numbers.receiving -> label("lost")
      else -> label("local")
    }
    val ago = numbers.lastPictureAgoMs
    staleText?.apply {
      visibility = if (FlightViewControls.staleLine(ago)) View.VISIBLE else View.GONE
      text = if (ago == null) label("noPicture") else fill("stale", "seconds" to number(ago / 1000.0))
    }
    valuesText?.text = valuesLine(numbers.values)
    latencyText?.text = fill(
      "latency",
      "ms" to number(numbers.receiveToPictureMs, 0),
      "pictures" to number(numbers.picturesPerSecond, 0),
    )
    val show = !FlightViewControls.hideVideo(ago)
    if (show != videoVisible || !placed) {
      videoVisible = show
      videoEntity?.setComponent(Visible(show && placed))
    }
    panelEntity?.setComponent(Visible(panelShown && placed))
  }

  private fun valuesLine(values: TelemetryValues?): String {
    val flight = values?.flight?.value ?: return label("noValues")
    val battery = values.battery?.value
    val lines = mutableListOf(
      fill(
        "flight",
        "heading" to number(flight.headingDeg),
        "heightMetres" to number(flight.heightM),
        "speeds" to flight.speedsMps.joinToString(" / ") { number(it) },
        "mode" to flight.mode.toString(),
        "motors" to label(if (flight.motorsOn) "on" else "off"),
      ),
      fill(
        "power",
        "battery" to (battery?.percent?.toString() ?: "-"),
        "volts" to number(battery?.voltageV, 2),
        "remote" to (values.remoteBatteryPercent?.value?.toString() ?: "-"),
        "aircraftSignal" to (values.link.signalAircraftSide?.value?.toString() ?: "-"),
        "remoteSignal" to (values.link.signalRemoteSide?.value?.toString() ?: "-"),
      ),
    )
    if (values.flight?.stale == true) {
      lines += label("valuesStale")
    }
    return lines.joinToString("\n")
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

  /** The video 2.5 m in front of the head along its yaw, its centre a little below the eyes; the panel under it */
  private fun placeInFront() {
    val head = headPosition ?: Vector3(0f, 1.6f, 0f)
    val forward = headForward ?: Vector3(0f, 0f, 1f)
    val flat = sqrt(forward.x * forward.x + forward.z * forward.z)
    val direction = if (flat < 1e-3f) Vector3(0f, 0f, 1f) else Vector3(forward.x / flat, 0f, forward.z / flat)
    val position = head + (direction * VIDEO_DISTANCE_M)
    position.y = head.y - VIDEO_DROP_M
    videoPosition = position
    videoDirection = direction
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
    val panelPosition = Vector3(position.x, position.y, position.z)
    panelPosition.y = position.y - width * 9f / 32f - PANEL_GAP_M - PANEL_HEIGHT_M / 2f
    panelEntity?.setComponent(Transform(Pose(panelPosition, rotation)))
    panelEntity?.setComponent(Visible(panelShown))
  }

  private fun onButtons(controllerBits: Int, handBits: Int) {
    for (action in FlightViewControls.actionsFor(controllerBits, handBits)) {
      when (action) {
        FlightViewControls.Action.CLOSE -> {
          close()
          return
        }
        FlightViewControls.Action.TOGGLE_PANEL -> {
          panelShown = !panelShown
          panelEntity?.setComponent(Visible(panelShown && placed))
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
