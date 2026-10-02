package app.alextran.immich.immersive

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.Surface
import android.view.View
import android.widget.Button
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import app.alextran.immich.MainActivity
import app.alextran.immich.R
import app.alextran.immich.core.HttpClientManager
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.SpatialFeature
import com.meta.spatial.core.Vector3
import com.meta.spatial.runtime.ButtonBits
import com.meta.spatial.runtime.EquirectLayerConfig
import com.meta.spatial.runtime.PanelSceneObject
import com.meta.spatial.runtime.PanelShapeType
import com.meta.spatial.runtime.ReferenceSpace
import com.meta.spatial.runtime.SceneMaterial
import com.meta.spatial.runtime.SceneMesh
import com.meta.spatial.runtime.SceneTexture
import com.meta.spatial.runtime.SessionState
import com.meta.spatial.runtime.StereoMode
import com.meta.spatial.toolkit.AppSystemActivity
import com.meta.spatial.toolkit.DpDisplayOptions
import com.meta.spatial.toolkit.Equirect180ShapeOptions
import com.meta.spatial.toolkit.Equirect360ShapeOptions
import com.meta.spatial.toolkit.LayoutXMLPanelRegistration
import com.meta.spatial.toolkit.Material
import com.meta.spatial.toolkit.MediaPanelRenderOptions
import com.meta.spatial.toolkit.MediaPanelSettings
import com.meta.spatial.toolkit.Mesh
import com.meta.spatial.toolkit.MeshCollision
import com.meta.spatial.toolkit.Panel
import com.meta.spatial.toolkit.PanelRegistration
import com.meta.spatial.toolkit.PanelStyleOptions
import com.meta.spatial.toolkit.PixelDisplayOptions
import com.meta.spatial.toolkit.QuadShapeOptions
import com.meta.spatial.toolkit.SceneObjectSystem
import com.meta.spatial.toolkit.Transform
import com.meta.spatial.toolkit.UIPanelSettings
import com.meta.spatial.toolkit.VideoSurfacePanelRegistration
import com.meta.spatial.toolkit.Visible
import com.meta.spatial.toolkit.createPanelEntity
import com.meta.spatial.vr.LocomotionSystem
import com.meta.spatial.vr.VRFeature
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.coroutineContext
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sqrt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Immersive (Horizon OS) viewer for one equirectangular photo or video, started from the 2D Flutter
 * activity through ImmersiveApi. Follows Meta's HybridSample for the switch between the 2D panel and
 * the immersive activity, the skybox samples for photos and MediaPlayerSample for 360 video.
 *
 * Requests use the app's native HTTP session (HttpClientManager: session cookie, custom headers,
 * client certificate). The activity is exported like in HybridSample, so it only accepts intents that
 * carry the launch token of the last intent built by [intent]: anything else shows nothing.
 *
 * Controllers: trigger plays or pauses a video, B or Y goes back to the 2D app, A, X, grip or menu
 * show or hide the info panel, thumbstick left or right turns the image by 90 degrees (logged, to find
 * the right SKYBOX_YAW_DEGREES and VIDEO_YAW_DEGREES), thumbstick up or down changes the 3D layout
 * (mono, top and bottom, side by side), like the 3D layout button of the info panel. Hands: the Back,
 * 3D layout and field of view buttons of the info panel, the menu gesture toggles it.
 *
 * Stereoscopic (3D) 360 media hold one equirectangular image per eye, one above the other (left eye on
 * top) or side by side (left eye on the left). Each eye gets its own half: through the stereo mode of
 * the skybox material for photos, through the stereo mode of the equirect compositor layer for videos.
 *
 * VR180 media cover the front half of the sphere only: longitude -90 to +90 degrees, full latitude, and
 * the back half stays black. Photos then use a half sphere mesh (the equirect surface an Equirect180
 * panel draws) instead of the skybox, videos an Equirect180 layer instead of the Equirect360 one. Each
 * eye of a stereoscopic VR180 media gets its own half the same way. The field of view button of the
 * info panel (360° or 180°) switches between the full sphere and the half sphere.
 */
class ImmersiveViewerActivity : AppSystemActivity(), ImmersiveInputSystem.Listener {
  private data class MediaRequest(
    val url: String,
    val isVideo: Boolean,
    val title: String,
    /** The 3D layout Flutter guessed from the media size. */
    val stereoLayout: ImmersiveStereoLayout,
    /**
     * Translated labels of the 3D control, keyed "stereo", "mono", "topBottom", "leftRight", and of the field of
     * view control, keyed "coverage", "coverage_full", "coverage_half".
     */
    val stereoLabels: Map<String, String>,
    /** How much of the sphere the media covers: all of it, or the front half (VR180). */
    val coverage: ImmersiveSphereCoverage,
  )

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private var request: MediaRequest? = null
  private var sceneReady = false
  private var closing = false

  // Scene
  private var skyboxEntity: Entity? = null
  private var videoEntity: Entity? = null
  private var infoEntity: Entity? = null
  private var skyboxMaterial: SceneMaterial? = null
  /** Half sphere of 180° photos, shown instead of the skybox. Its material gets the same photo texture. */
  private var halfSphereEntity: Entity? = null
  private var halfSphereMaterial: SceneMaterial? = null
  /** Our own small copy of the idle gradient. The Material component texture is cached by the SDK. */
  private var idleTexture: SceneTexture? = null
  /** The photo texture we created and own. At most one at a time. */
  private var photoTexture: SceneTexture? = null
  private var pendingBitmap: Bitmap? = null
  private var infoVisible = false
  private var infoPlaced = false
  private var framesWithoutHead = 0
  private var lastHeadPosition: Vector3? = null
  private var lastHeadForward: Vector3? = null
  private var sphereCenter: Vector3? = null
  /** Rotation of each sphere around the vertical axis, in degrees, changed with the thumbstick. */
  private var photoYaw = SKYBOX_YAW_DEGREES
  private var videoYaw = VIDEO_YAW_DEGREES
  /**
   * 3D layout of the current media: the one Flutter guessed, then the one the user picked with the thumbstick or
   * the 3D layout button.
   */
  private var stereoLayout = ImmersiveStereoLayout.MONO
  /** Stereo mode set on the skybox material. Stays None (never set) as long as only mono photos are shown. */
  private var skyboxStereoMode = StereoMode.None
  /** Stereo mode set on the half sphere material, kept in step with the skybox one. */
  private var halfSphereStereoMode = StereoMode.None
  /**
   * How much of the sphere the current media covers: the value Flutter sent, then the one the user picked with the
   * field of view button.
   */
  private var coverage = ImmersiveSphereCoverage.FULL
  /** Scene object of the video panel, to change the stereo mode and the shape of its compositor layer. */
  private var videoPanel: PanelSceneObject? = null

  // Info panel views
  private var titleView: TextView? = null
  private var statusView: TextView? = null
  private var stereoView: Button? = null
  private var coverageView: Button? = null
  private var playPauseButton: Button? = null

  // Loading
  private var loadJob: Job? = null
  private var hideInfoJob: Job? = null
  /** Delay of the last hide scheduled: INFO_AUTO_HIDE_MS for the plain auto hide, longer for the decoder warning. */
  private var hideInfoDelayMs = 0L
  private val decodeMutex = Mutex()
  private val httpClient: OkHttpClient by lazy {
    // Same session as the rest of the app, without the API response cache (originals are large)
    HttpClientManager.getClient().newBuilder().cache(null).build()
  }

  // Video
  private var player: ExoPlayer? = null
  private var videoSurface: Surface? = null
  private var currentVideoUrl: String? = null
  private var videoFallbackTried = false
  private var wasPlayingBeforeMenu = false
  /** The video track of the current url was checked against the headset decoder limit. */
  private var decoderChecked = false
  /** Shown instead of the video format while a video above the decoder limit plays. */
  private var decoderWarning: String? = null

  override fun registerFeatures(): List<SpatialFeature> = listOf(VRFeature(this))

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    Log.i(TAG, "immersive viewer onCreate, max heap ${Runtime.getRuntime().maxMemory() / 1048576} MB")
    HttpClientManager.initialize(applicationContext)
    cacheDir.listFiles()?.filter { it.name.startsWith(ORIGINAL_PREFIX) }?.forEach { it.delete() }
    request = parse(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    // singleTask: other apps can reach this method too, an intent without the launch token changes nothing
    val parsed = parse(intent) ?: return
    setIntent(intent)
    request = parsed
    Log.i(TAG, "immersive viewer onNewIntent")
    if (sceneReady) showRequest()
  }

  override fun onSceneReady() {
    super.onSceneReady()
    Log.i(TAG, "immersive viewer onSceneReady")
    try {
      scene.setReferenceSpace(ReferenceSpace.LOCAL_FLOOR)
      // The thumbsticks turn the image instead of moving or snap turning the user
      try {
        systemManager.findSystem<LocomotionSystem>().enableLocomotion(false)
      } catch (e: Exception) {
        Log.w(TAG, "could not disable locomotion", e)
      }
      createSkybox()
      createHalfSphere()
      videoEntity = Entity.create(Panel(R.id.immersive_video_panel), Transform(), Visible(false))
      infoEntity =
        Entity.createPanelEntity(
          R.id.immersive_info_panel,
          Transform(Pose(Vector3(0f, 1.1f, INFO_DISTANCE), Quaternion(0f, 0f, 0f))),
          Visible(false),
        )
      systemManager.registerSystem(ImmersiveInputSystem(this))
      sceneReady = true
      showRequest()
    } catch (e: Exception) {
      Log.e(TAG, "immersive scene setup failed", e)
    }
  }

  override fun registerPanels(): List<PanelRegistration> =
    listOf(
      LayoutXMLPanelRegistration(
        R.id.immersive_info_panel,
        layoutIdCreator = { R.layout.immersive_info_panel },
        settingsCreator = {
          UIPanelSettings(
            shape = QuadShapeOptions(width = 1.0f, height = 0.36f),
            style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
            display = DpDisplayOptions(width = 720f, height = 260f, dpi = 260),
          )
        },
        panelSetupWithRootView = { rootView, _, _ -> bindInfoPanel(rootView) },
      ),
      // 360 video: equirectangular compositor layer, as in MediaPlayerSample. Created mono, with the coverage of
      // the first media, a stereoscopic video or another coverage reshapes the layer afterwards (applyVideoShape).
      VideoSurfacePanelRegistration(
        R.id.immersive_video_panel,
        surfaceConsumer = { _, surface ->
          Log.i(TAG, "video surface ready")
          videoSurface = surface
          player?.setVideoSurface(surface)
        },
        settingsCreator = {
          MediaPanelSettings(
            shape =
              if (coverage == ImmersiveSphereCoverage.HALF) Equirect180ShapeOptions(radius = VIDEO_SPHERE_RADIUS)
              else Equirect360ShapeOptions(radius = VIDEO_SPHERE_RADIUS),
            display = PixelDisplayOptions(width = 3840, height = 1920),
            rendering = MediaPanelRenderOptions(stereoMode = StereoMode.None, zIndex = -1),
          )
        },
        panelSetup = { panel, _ ->
          videoPanel = panel
          // After the panel creation returns: a stereoscopic or VR180 video may already be waiting for this panel
          scope.launch(Dispatchers.Main) { applyVideoShape() }
        },
      ),
    )

  /** The media to show, or null for an intent without the launch token (not started by this app) or without url. */
  private fun parse(intent: Intent?): MediaRequest? {
    if (intent == null) return null
    val token = intent.getStringExtra(EXTRA_TOKEN)
    // Not consumed on use: the system may deliver the same intent again
    if (token == null || token != launchToken) {
      Log.w(TAG, "immersive viewer intent without a valid launch token, ignored")
      return null
    }
    val url = intent.getStringExtra(EXTRA_URL)
    if (url.isNullOrBlank()) {
      Log.e(TAG, "immersive viewer started without a url")
      return null
    }
    val labels =
      intent.getBundleExtra(EXTRA_STEREO_LABELS)?.let { bundle ->
        bundle.keySet().mapNotNull { key -> bundle.getString(key)?.let { key to it } }.toMap()
      }
    return MediaRequest(
      url = url,
      isVideo = intent.getBooleanExtra(EXTRA_IS_VIDEO, false),
      title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
      stereoLayout =
        ImmersiveStereoLayout.ofRaw(intent.getIntExtra(EXTRA_STEREO_LAYOUT, ImmersiveStereoLayout.MONO.raw))
          ?: ImmersiveStereoLayout.MONO,
      stereoLabels = labels.orEmpty(),
      coverage =
        ImmersiveSphereCoverage.ofRaw(intent.getIntExtra(EXTRA_COVERAGE, ImmersiveSphereCoverage.FULL.raw))
          ?: ImmersiveSphereCoverage.FULL,
    )
  }

  private fun showRequest() {
    val media = request
    loadJob?.cancel()
    if (media == null) {
      showError(getString(R.string.immersive_error_nothing))
      return
    }
    Log.i(TAG, "show ${if (media.isVideo) "video" else "photo"}")
    stereoLayout = media.stereoLayout
    coverage = media.coverage
    if (media.stereoLayout != ImmersiveStereoLayout.MONO) {
      Log.i(TAG, "stereoscopic media, 3D layout ${media.stereoLayout}")
    }
    if (media.coverage != ImmersiveSphereCoverage.FULL) {
      Log.i(TAG, "half sphere media (VR180), coverage ${media.coverage}")
    }
    titleView?.text = media.title
    playPauseButton?.visibility = if (media.isVideo) View.VISIBLE else View.GONE
    updateStereoView()
    updateCoverageView()
    setInfoVisible(true, reposition = true)
    if (media.isVideo) showVideo(media) else showPhoto(media)
  }

  // ---------------------------------------------------------------------------------------------
  // Info panel

  private fun bindInfoPanel(root: View) {
    titleView = root.findViewById(R.id.immersive_title)
    statusView = root.findViewById(R.id.immersive_status)
    stereoView = root.findViewById(R.id.immersive_stereo)
    coverageView = root.findViewById(R.id.immersive_coverage)
    playPauseButton = root.findViewById(R.id.immersive_play_pause)
    root.findViewById<Button>(R.id.immersive_back)?.setOnClickListener { close() }
    playPauseButton?.setOnClickListener { togglePlayPause() }
    // A click from the controller ray or a hand pinch: the panel is on screen, it stays where it is
    stereoView?.setOnClickListener { cycleStereoLayout(1, fromPanel = true) }
    coverageView?.setOnClickListener { toggleCoverage() }
    request?.let { media ->
      titleView?.text = media.title
      playPauseButton?.visibility = if (media.isVideo) View.VISIBLE else View.GONE
    }
    updateStereoView()
    updateCoverageView()
  }

  private fun setStatus(text: String) {
    statusView?.text = text
  }

  /** The 3D layout button, "3D layout: 3D, top and bottom": shown whenever a media is loaded, mono ones included. */
  private fun updateStereoView() {
    val view = stereoView ?: return
    val media = request
    if (media == null) {
      view.visibility = View.GONE
      return
    }
    view.text = ImmersiveMedia.stereoLayoutText(stereoLayout, media.stereoLabels)
    view.visibility = View.VISIBLE
  }

  /**
   * The field of view button, "360°" or "180°", with "Field of view: 180°, half sphere (VR180)" as tooltip and
   * description: shown whenever a media is loaded.
   */
  private fun updateCoverageView() {
    val view = coverageView ?: return
    val media = request
    if (media == null) {
      view.visibility = View.GONE
      return
    }
    val description = ImmersiveMedia.coverageText(coverage, media.stereoLabels)
    view.text = ImmersiveMedia.coverageButtonText(coverage)
    view.tooltipText = description
    view.contentDescription = description
    view.visibility = View.VISIBLE
  }

  private fun showError(text: String) {
    Log.w(TAG, "shown to the user: $text")
    hideInfoJob?.cancel()
    setStatus(text)
    setInfoVisible(true, reposition = true)
  }

  /** Hides the info panel a few seconds after the media is on screen. */
  private fun scheduleInfoHide(delayMs: Long = INFO_AUTO_HIDE_MS) {
    hideInfoJob?.cancel()
    hideInfoDelayMs = delayMs
    hideInfoJob =
      scope.launch {
        delay(delayMs)
        setInfoVisible(false, reposition = false)
      }
  }

  private fun setInfoVisible(visible: Boolean, reposition: Boolean) {
    val panel = infoEntity ?: return
    if (visible && reposition) placeInfoInFront()
    panel.setComponent(Visible(visible && infoPlaced))
    infoVisible = visible
  }

  /** Puts the info panel in front of the user, like SplatSample.positionPanelInFrontOfUser. */
  private fun placeInfoInFront() {
    val panel = infoEntity ?: return
    val head = lastHeadPosition ?: return
    val forward = lastHeadForward ?: Vector3(0f, 0f, 1f)
    val flat = sqrt(forward.x * forward.x + forward.z * forward.z)
    val direction = if (flat < 1e-3f) Vector3(0f, 0f, 1f) else Vector3(forward.x / flat, 0f, forward.z / flat)
    val position = head + (direction * INFO_DISTANCE)
    position.y = head.y - 0.3f
    panel.setComponent(Transform(Pose(position, Quaternion.lookRotation(direction))))
  }

  // ---------------------------------------------------------------------------------------------
  // Frame and input

  override fun onFrame(head: Pose?) {
    if (head != null && (head.t.x != 0f || head.t.y != 0f || head.t.z != 0f)) {
      lastHeadPosition = Vector3(head.t.x, head.t.y, head.t.z)
      lastHeadForward = head.forward()
      centerSpheresOnHead(head.t)
    }
    if (infoPlaced) return
    if (lastHeadPosition != null || ++framesWithoutHead > 180) {
      if (lastHeadPosition == null) Log.w(TAG, "no head pose after 180 frames, default info panel position")
      infoPlaced = true
      setInfoVisible(infoVisible, reposition = true)
    }
  }

  /** 360 media are captured from one point: the spheres follow the head position (not its rotation). */
  private fun centerSpheresOnHead(head: Vector3) {
    val last = sphereCenter
    if (last != null && abs(last.x - head.x) < 0.01f && abs(last.y - head.y) < 0.01f && abs(last.z - head.z) < 0.01f) {
      return
    }
    sphereCenter = Vector3(head.x, head.y, head.z)
    applySphereTransforms()
  }

  private fun applySphereTransforms() {
    val center = sphereCenter ?: Vector3(0f, 0f, 0f)
    skyboxEntity?.setComponent(
      Transform(Pose(Vector3(center.x, center.y, center.z), Quaternion(0f, photoYaw, 0f))),
    )
    halfSphereEntity?.setComponent(
      Transform(Pose(Vector3(center.x, center.y, center.z), Quaternion(0f, photoYaw, 0f))),
    )
    videoEntity?.setComponent(Transform(Pose(Vector3(center.x, center.y, center.z), Quaternion(0f, videoYaw, 0f))))
  }

  /** Turns the sphere of the current media by [degrees] and logs the value to report. */
  private fun rotateSphere(degrees: Float) {
    val isVideo = request?.isVideo == true
    val yaw = normalizeDegrees((if (isVideo) videoYaw else photoYaw) + degrees)
    if (isVideo) videoYaw = yaw else photoYaw = yaw
    applySphereTransforms()
    val constant = if (isVideo) "VIDEO_YAW_DEGREES" else "SKYBOX_YAW_DEGREES"
    Log.i(TAG, "${if (isVideo) "video" else "photo"} yaw is now ${yaw.toInt()} degrees ($constant)")
    setStatus(getString(R.string.immersive_yaw, yaw.toInt()))
  }

  /**
   * Thumbstick up (next) or down (previous), or the 3D layout button of the info panel (next, [fromPanel]): mono,
   * top and bottom, side by side. Applies the layout to the media on screen and shows it on the info panel. A hidden
   * panel shows up for a few seconds. On a panel already on screen only the plain auto hide restarts: an error, the
   * loading or buffering status, the decoder warning and a panel opened by the user keep their own hide rules.
   */
  private fun cycleStereoLayout(step: Int, fromPanel: Boolean = false) {
    val media = request ?: return
    stereoLayout = ImmersiveMedia.cycleStereoLayout(stereoLayout, step)
    val mode = stereoModeFor(stereoLayout)
    Log.i(TAG, "3D layout is now $stereoLayout (${if (media.isVideo) "video" else "photo"} stereo mode $mode)")
    if (media.isVideo) {
      applyVideoShape()
    } else if (photoTexture != null) {
      // While the first image loads the idle sky stays mono, applySkyboxBitmap applies the layout
      setSkyboxStereoMode(mode)
    }
    updateStereoView()
    showControlChange(fromPanel)
  }

  /**
   * The field of view button of the info panel: 360° (full sphere) or 180° (VR180, the front half, black behind).
   * Photos switch between the skybox and the half sphere, videos reshape their equirect layer. The panel stays where
   * it is, as after a click on the 3D layout button.
   */
  private fun toggleCoverage() {
    val media = request ?: return
    coverage = ImmersiveMedia.toggleCoverage(coverage)
    Log.i(TAG, "field of view is now $coverage (${if (media.isVideo) "video" else "photo"})")
    if (media.isVideo) applyVideoShape() else showPhotoSphere()
    updateCoverageView()
    showControlChange(fromPanel = true)
  }

  /**
   * After a change of the 3D layout or of the field of view: a hidden panel shows up for a few seconds. On a panel
   * already on screen only the plain auto hide restarts, and a click on the panel ([fromPanel]) leaves it where it is.
   */
  private fun showControlChange(fromPanel: Boolean) {
    if (!infoVisible) {
      hideInfoJob?.cancel()
      setInfoVisible(true, reposition = true)
      // While a photo or the video probe loads, the end of the loading hides the panel
      if (loadJob?.isActive != true) scheduleInfoHide()
      return
    }
    // The thumbstick brings the panel in front of the user, a click on the panel leaves it where it is
    if (!fromPanel) setInfoVisible(true, reposition = true)
    // No decoder warning pending: its own hide uses the longer DECODER_WARNING_HIDE_MS
    val plainAutoHide = hideInfoJob?.isActive == true && hideInfoDelayMs == INFO_AUTO_HIDE_MS
    if (plainAutoHide) scheduleInfoHide()
    // Otherwise (error, panel opened by the user, loading, buffering) the timers stay as they are
  }

  private fun normalizeDegrees(value: Float): Float {
    val wrapped = ((value % 360f) + 360f) % 360f
    return if (wrapped > 180f) wrapped - 360f else wrapped
  }

  override fun onButtonsPressed(controllerBits: Int, handBits: Int) {
    if (handBits != 0) {
      if ((handBits and ButtonBits.ButtonMenu) != 0) {
        setInfoVisible(!infoVisible, reposition = true)
      } else if (!infoVisible && (handBits and (ButtonBits.ButtonA or ButtonBits.ButtonX)) != 0) {
        setInfoVisible(true, reposition = true)
      }
    }
    if (controllerBits == 0) return
    if ((controllerBits and (ButtonBits.ButtonB or ButtonBits.ButtonY)) != 0) {
      close()
      return
    }
    if ((controllerBits and (ButtonBits.ButtonThumbLL or ButtonBits.ButtonThumbRL)) != 0) {
      rotateSphere(-YAW_STEP_DEGREES)
    } else if ((controllerBits and (ButtonBits.ButtonThumbLR or ButtonBits.ButtonThumbRR)) != 0) {
      rotateSphere(YAW_STEP_DEGREES)
    } else if ((controllerBits and (ButtonBits.ButtonThumbLU or ButtonBits.ButtonThumbRU)) != 0) {
      cycleStereoLayout(1)
    } else if ((controllerBits and (ButtonBits.ButtonThumbLD or ButtonBits.ButtonThumbRD)) != 0) {
      cycleStereoLayout(-1)
    }
    val toggle =
      ButtonBits.ButtonA or ButtonBits.ButtonX or ButtonBits.ButtonMenu or ButtonBits.ButtonSqueezeL or
        ButtonBits.ButtonSqueezeR
    if ((controllerBits and toggle) != 0) {
      hideInfoJob?.cancel()
      setInfoVisible(!infoVisible, reposition = true)
    }
    // With the panel shown, the trigger clicks its buttons instead
    if (!infoVisible && (controllerBits and (ButtonBits.ButtonTriggerL or ButtonBits.ButtonTriggerR)) != 0) {
      togglePlayPause()
    }
  }

  @Deprecated("Deprecated in Java")
  override fun onBackPressed() {
    close()
  }

  /** Back to the 2D Flutter activity, the way HybridSample goes back to its panel. */
  private fun close() {
    if (closing) return
    closing = true
    Log.i(TAG, "immersive viewer closing")
    loadJob?.cancel()
    player?.stop()
    if (isHorizonOsDevice()) {
      try {
        val panelIntent =
          Intent(applicationContext, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
          }
        val pendingPanelIntent =
          PendingIntent.getActivity(
            applicationContext,
            0,
            panelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
          )
        val homeIntent =
          Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_HOME)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra("extra_launch_in_home_pending_intent", pendingPanelIntent)
        startActivity(homeIntent)
      } catch (e: Exception) {
        Log.e(TAG, "could not relaunch the 2D panel", e)
      }
    }
    finish()
  }

  // ---------------------------------------------------------------------------------------------
  // Photos: skybox texture

  private fun createSkybox() {
    val entity =
      Entity.create(
        listOf(
          Mesh(Uri.parse("mesh://skybox"), hittable = MeshCollision.NoCollision),
          Material().apply {
            baseTextureAndroidResourceId = R.drawable.immersive_idle_sky
            unlit = true
          },
          Transform(Pose(Vector3(0f, 0f, 0f), Quaternion(0f, photoYaw, 0f))),
          Visible(true),
        ),
      )
    skyboxEntity = entity
    systemManager.findSystem<SceneObjectSystem>().getSceneObject(entity)?.thenAccept { sceneObject ->
      runOnUiThread {
        val material = sceneObject.mesh?.materials?.firstOrNull()
        if (material == null) {
          Log.e(TAG, "skybox material not found, photos cannot be displayed")
          return@runOnUiThread
        }
        Log.i(TAG, "skybox material ready")
        skyboxMaterial = material
        idleTexture =
          try {
            BitmapFactory.decodeResource(resources, R.drawable.immersive_idle_sky)?.let { bitmap ->
              try {
                SceneTexture(bitmap)
              } finally {
                bitmap.recycle()
              }
            }
          } catch (e: Throwable) {
            Log.e(TAG, "idle texture creation failed", e)
            null
          }
        pendingBitmap?.let {
          pendingBitmap = null
          applySkyboxBitmap(it)
        }
      }
    } ?: Log.e(TAG, "skybox scene object not available")
  }

  /**
   * Half sphere of 180° photos: the equirect surface of an Equirect180 panel (SceneMesh.equirectSurface, 180 degrees
   * around the forward axis, 180 degrees from the bottom to the top) with an unlit material made like the skybox
   * one, so its stereo mode works the same way. The image covers it from edge to edge, and nothing is drawn behind
   * it: the back half stays black while the skybox is hidden, never the stretched or clamped edge of the photo.
   */
  private fun createHalfSphere() {
    registerMeshCreator(HALF_SPHERE_MESH) { entity ->
      SceneMesh.equirectSurface(
        HALF_SPHERE_RADIUS,
        PI.toFloat(),
        (PI / 2).toFloat(),
        (-PI / 2).toFloat(),
        entity.getComponent<Material>().generateSceneMaterial(entity, this),
      )
    }
    val entity =
      Entity.create(
        listOf(
          Mesh(Uri.parse(HALF_SPHERE_MESH), hittable = MeshCollision.NoCollision),
          Material().apply {
            baseTextureAndroidResourceId = R.drawable.immersive_idle_sky
            unlit = true
          },
          Transform(Pose(Vector3(0f, 0f, 0f), Quaternion(0f, photoYaw, 0f))),
          Visible(false),
        ),
      )
    halfSphereEntity = entity
    systemManager.findSystem<SceneObjectSystem>().getSceneObject(entity)?.thenAccept { sceneObject ->
      runOnUiThread {
        val material = sceneObject.mesh?.materials?.firstOrNull()
        if (material == null) {
          Log.e(TAG, "half sphere material not found, 180 degree photos stay on the full sphere")
          return@runOnUiThread
        }
        Log.i(TAG, "half sphere material ready")
        halfSphereMaterial = material
        // A photo may already be on the skybox
        photoTexture?.let { texture ->
          material.setAlbedoTexture(texture)
          setSkyboxStereoMode(stereoModeFor(stereoLayout))
        }
        showPhotoSphere()
      }
    } ?: Log.e(TAG, "half sphere scene object not available")
  }

  /**
   * Shows the sphere of the photo: the half sphere for a 180° photo once its texture and the half sphere are ready,
   * the skybox otherwise (360° photos, and the idle sky while the first image loads). Nothing changes for a video.
   */
  private fun showPhotoSphere() {
    if (request?.isVideo == true) return
    val half = coverage == ImmersiveSphereCoverage.HALF && photoTexture != null && halfSphereMaterial != null
    halfSphereEntity?.setComponent(Visible(half))
    skyboxEntity?.setComponent(Visible(!half))
  }

  /** Uploads the bitmap as the skybox texture, recycles it, destroys the previous photo texture. */
  private fun applySkyboxBitmap(bitmap: Bitmap) {
    val material = skyboxMaterial
    if (material == null) {
      Log.w(TAG, "skybox not ready yet, keeping the bitmap for later")
      pendingBitmap?.recycle()
      pendingBitmap = bitmap
      return
    }
    val texture =
      try {
        SceneTexture(bitmap)
      } catch (e: Throwable) {
        Log.e(TAG, "texture creation failed for ${bitmap.width}x${bitmap.height}", e)
        null
      } finally {
        bitmap.recycle()
      }
    if (texture == null) throw IOException("texture creation failed")
    material.setAlbedoTexture(texture)
    halfSphereMaterial?.setAlbedoTexture(texture)
    setSkyboxStereoMode(stereoModeFor(stereoLayout))
    photoTexture?.destroy()
    photoTexture = texture
    showPhotoSphere()
  }

  /**
   * Stereoscopic photos: the stereo mode of the skybox material. SceneMaterial.setStereoMode sets the
   * stereoParams of the material, and the SDK default vertex shader (metaSpatialSdkDefaultVertex.glsl)
   * samples the albedo texture at viewIndex * offset + uv * scale: UpDown gives the left eye the top half
   * and the right eye the bottom half, LeftRight the left and the right half. The same full resolution
   * texture and the same skybox serve mono and 3D photos, and the layout changes without a new upload.
   * A second equirect media panel drawn through lockCanvas was the other option: an extra swapchain,
   * a CPU copy of the image and a surface that arrives later, for the same result. The half sphere of
   * 180° photos uses the same default shader and gets the same stereo mode.
   */
  private fun setSkyboxStereoMode(mode: StereoMode) {
    skyboxMaterial?.let { material ->
      if (mode != skyboxStereoMode) {
        material.setStereoMode(mode)
        skyboxStereoMode = mode
        Log.i(TAG, "skybox stereo mode is now $mode")
      }
    }
    halfSphereMaterial?.let { material ->
      if (mode != halfSphereStereoMode) {
        material.setStereoMode(mode)
        halfSphereStereoMode = mode
      }
    }
  }

  private fun resetSkyboxToIdle() {
    pendingBitmap?.recycle()
    pendingBitmap = null
    val material = skyboxMaterial ?: return
    val idle = idleTexture
    if (idle == null) {
      // Never leave the material pointing to a destroyed texture
      Log.w(TAG, "no idle texture, keeping the current photo texture")
      return
    }
    material.setAlbedoTexture(idle)
    halfSphereMaterial?.setAlbedoTexture(idle)
    setSkyboxStereoMode(StereoMode.None)
    photoTexture?.destroy()
    photoTexture = null
  }

  private fun showPhoto(media: MediaRequest) {
    stopVideo()
    showPhotoSphere()
    setStatus(getString(R.string.immersive_loading))
    loadJob =
      scope.launch {
        var shown = false
        // A photo on the headset has no preview: the file itself is right there
        val isLocal = ImmersiveMedia.localFileFor(media.url) != null
        val previewUrl = if (isLocal) null else ImmersiveMedia.previewUrlFor(media.url)
        if (previewUrl != null) {
          try {
            val bytes = download(previewUrl)
            decodeAndApply { ImmersiveMedia.decodeBytes(bytes) }?.let { (w, h) ->
              shown = true
              setStatus(getString(R.string.immersive_preview_loading_full, w, h))
            }
          } catch (e: CancellationException) {
            throw e
          } catch (e: Throwable) {
            Log.w(TAG, "preview failed: ${e.message}", e)
          }
        }
        try {
          val (w, h) = loadFullResolution(media)
          setStatus(getString(R.string.immersive_full_resolution, w, h))
          scheduleInfoHide()
        } catch (e: CancellationException) {
          throw e
        } catch (e: Throwable) {
          Log.e(TAG, "full resolution failed", e)
          if (shown) {
            setStatus(getString(R.string.immersive_preview_only, e.message ?: e.javaClass.simpleName))
            scheduleInfoHide()
          } else {
            showError(getString(R.string.immersive_error_photo, e.message ?: e.javaClass.simpleName))
          }
        }
      }
  }

  private suspend fun loadFullResolution(media: MediaRequest): Pair<Int, Int> {
    // A photo on the headset (no server, or not uploaded) is decoded where it is: neither copied nor deleted
    ImmersiveMedia.localFileFor(media.url)?.let { local ->
      Log.i(TAG, "original on the headset")
      return decodeAndApply { ImmersiveMedia.decodeFile(local) }
        ?: throw IOException("this image cannot be read or decoded")
    }
    val file = File(cacheDir, "$ORIGINAL_PREFIX${System.nanoTime()}")
    try {
      val bytes = downloadTo(media.url, file)
      Log.i(TAG, "original downloaded: $bytes bytes")
      decodeAndApply { ImmersiveMedia.decodeFile(file) }?.let {
        return it
      }
      throw IOException("this image format cannot be decoded")
    } finally {
      file.delete()
    }
  }

  /**
   * Decodes off the main thread (one decode at a time), then uploads on the main thread. The bitmap
   * is recycled in every case. Returns the decoded size, or null if decoding failed.
   */
  private suspend fun decodeAndApply(decode: () -> Bitmap?): Pair<Int, Int>? {
    val holder = AtomicReference<Bitmap?>()
    try {
      decodeMutex.withLock { withContext(Dispatchers.Default) { holder.set(decode()) } }
      coroutineContext.ensureActive()
      val bitmap = holder.getAndSet(null) ?: return null
      val size = bitmap.width to bitmap.height
      applySkyboxBitmap(bitmap)
      return size
    } finally {
      holder.getAndSet(null)?.recycle()
    }
  }

  private fun httpRequest(url: String, range: String? = null): Request =
    Request.Builder().url(url).get().apply { if (range != null) header("Range", range) }.build()

  private suspend fun download(url: String): ByteArray =
    withContext(Dispatchers.IO) {
      httpClient.newCall(httpRequest(url)).execute().use { response ->
        if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
        response.body?.bytes() ?: throw IOException("empty response")
      }
    }

  private suspend fun downloadTo(url: String, file: File): Long =
    withContext(Dispatchers.IO) {
      httpClient.newCall(httpRequest(url)).execute().use { response ->
        if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
        val body = response.body ?: throw IOException("empty response")
        var total = 0L
        body.byteStream().use { input ->
          file.outputStream().use { output ->
            val buffer = ByteArray(256 * 1024)
            while (true) {
              ensureActive()
              val read = input.read(buffer)
              if (read < 0) break
              output.write(buffer, 0, read)
              total += read
            }
          }
        }
        total
      }
    }

  // ---------------------------------------------------------------------------------------------
  // Videos: equirectangular layer fed by ExoPlayer

  @OptIn(UnstableApi::class)
  private fun ensurePlayer(): ExoPlayer? {
    player?.let {
      return it
    }
    return try {
      // Server: the app session (cookie, custom headers, client certificate), same as the in-app player.
      // file:// and content:// (the copy on the headset) are read locally by DefaultDataSource.
      val dataSourceFactory = DefaultDataSource.Factory(this, HttpClientManager.createDataSourceFactory(emptyMap()))
      val audio = AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build()
      ExoPlayer.Builder(this)
        .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
        .setAudioAttributes(audio, true)
        .build()
        .apply {
          repeatMode = Player.REPEAT_MODE_ONE
          addListener(playerListener)
          videoSurface?.let { setVideoSurface(it) }
        }
        .also { player = it }
    } catch (e: Exception) {
      Log.e(TAG, "player creation failed", e)
      null
    }
  }

  private val playerListener =
    object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        Log.i(TAG, "video state $playbackState")
        when (playbackState) {
          Player.STATE_BUFFERING -> setStatus(getString(R.string.immersive_buffering))
          Player.STATE_READY -> {
            val format = player?.videoFormat
            val description =
              if (format != null) "${format.sampleMimeType} ${format.codecs ?: ""} ${format.width}x${format.height}"
              else "no video track"
            Log.i(TAG, "video format: $description")
            val warning = decoderWarning
            if (warning != null) {
              // Keeps the warning on screen for its own, longer delay, counted from the moment the video plays
              setStatus(warning)
              if (player?.playWhenReady == true) {
                hideInfoJob?.cancel()
                scheduleInfoHide(DECODER_WARNING_HIDE_MS)
              }
            } else {
              setStatus(description.trim())
              if (player?.playWhenReady == true) scheduleInfoHide()
            }
          }
          else -> Unit
        }
      }

      override fun onTracksChanged(tracks: Tracks) {
        selectedVideoFormat(tracks)?.let(::checkDecoderLimit)
      }

      override fun onIsPlayingChanged(isPlaying: Boolean) {
        playPauseButton?.setText(if (isPlaying) R.string.immersive_pause else R.string.immersive_play)
      }

      override fun onPlayerError(error: PlaybackException) {
        Log.e(TAG, "video error ${error.errorCodeName}: ${error.message}", error)
        val fallback = currentVideoUrl?.let { ImmersiveMedia.playbackUrlFor(it) }
        if (!videoFallbackTried && fallback != null) {
          videoFallbackTried = true
          setStatus(getString(R.string.immersive_video_fallback, error.errorCodeName))
          playUrl(fallback)
        } else {
          showError(getString(R.string.immersive_error_video, error.errorCodeName))
        }
      }
    }

  /** Format of the video track the player selected, or null without one. */
  private fun selectedVideoFormat(tracks: Tracks): Format? {
    for (group in tracks.groups) {
      if (group.type != C.TRACK_TYPE_VIDEO || !group.isSelected) continue
      for (i in 0 until group.length) {
        if (group.isTrackSelected(i)) return group.getTrackFormat(i)
      }
    }
    return null
  }

  /**
   * H.264 above 4K plays at a fraction of its frame rate on the Quest 3, with block artifacts. From the
   * original, tries the server playback stream (the Immich transcode when there is one), otherwise tells
   * the user what to change.
   */
  private fun checkDecoderLimit(format: Format) {
    val url = currentVideoUrl ?: return
    if (decoderChecked || format.width <= 0 || format.height <= 0) return
    decoderChecked = true
    if (!ImmersiveMedia.exceedsAvcDecoder(format.sampleMimeType, format.width, format.height)) return
    val size = "${format.width}x${format.height}"
    Log.w(TAG, "H.264 $size is above the headset decoder limit, expect dropped frames and block artifacts")
    val playback = ImmersiveMedia.playbackUrlFor(url)
    if (!videoFallbackTried && playback != null) {
      videoFallbackTried = true
      setStatus(getString(R.string.immersive_video_decoder_switch, "H.264 $size"))
      playUrl(playback)
      return
    }
    val message =
      if (url.startsWith("http")) R.string.immersive_avc_too_large else R.string.immersive_avc_too_large_local
    val warning = getString(message, format.width, format.height)
    Log.w(TAG, "shown to the user: $warning")
    decoderWarning = warning
    hideInfoJob?.cancel()
    setStatus(warning)
    setInfoVisible(true, reposition = true)
    scheduleInfoHide(DECODER_WARNING_HIDE_MS)
  }

  /**
   * Stereoscopic and VR180 videos: the stereo mode of the equirect compositor layer (UpDown for top and
   * bottom, LeftRight for side by side, None for mono) and its shape (EQUIRECT over 360 degrees, or
   * EQUIRECT180 over the front 180 degrees). The SDK reads them only when it creates the layer
   * (SceneEquirectLayer has no setter), and PanelSceneObject.reshape destroys the layer and the panel
   * mesh and creates new ones from the panel config, on the same swapchain: the Surface ExoPlayer draws
   * on stays valid, so the layout and the field of view change while the video plays. The config of
   * Equirect180ShapeOptions only differs from the Equirect360ShapeOptions one by its shape type and the
   * central horizontal angle of its layer (pi instead of 2 pi), the stereo mode works the same for both.
   * Nothing is drawn outside the 180 degree layer: the back half stays black. A mono 360 video never
   * reshapes the panel.
   */
  private fun applyVideoShape() {
    val panel = videoPanel ?: return
    if (request?.isVideo != true) return
    val mode = stereoModeFor(stereoLayout)
    val shape = panelShapeTypeFor(coverage)
    val config = panel.panelShapeConfig
    if (config == null) {
      Log.w(TAG, "video panel without a shape config, stereo mode $mode and shape $shape not applied")
      return
    }
    val previousMode = config.stereoMode
    val previousShape = config.panelShapeType
    if (previousMode == mode && previousShape == shape) return
    try {
      config.stereoMode = mode
      config.panelShapeType = shape
      val layer = config.layerConfig
      if (layer is EquirectLayerConfig) {
        layer.centralHorizontalAngle = horizontalAngleFor(coverage)
      } else {
        Log.w(TAG, "video panel without an equirect layer config, only its mesh follows the shape $shape")
      }
      panel.reshape(config)
      Log.i(TAG, "video stereo mode is now $mode (was $previousMode), shape $shape (was $previousShape)")
    } catch (e: Exception) {
      Log.e(TAG, "could not set the video stereo mode to $mode and the shape to $shape", e)
    }
  }

  private fun showVideo(media: MediaRequest) {
    resetSkyboxToIdle()
    skyboxEntity?.setComponent(Visible(false))
    halfSphereEntity?.setComponent(Visible(false))
    videoEntity?.setComponent(Visible(true))
    applyVideoShape()
    player?.stop()
    videoFallbackTried = false
    setStatus(getString(R.string.immersive_loading))
    if (ensurePlayer() == null) {
      showError(getString(R.string.immersive_error_video, "player"))
      return
    }
    loadJob =
      scope.launch {
        val playback = ImmersiveMedia.playbackUrlFor(media.url)
        var url = media.url
        if (playback != null && !isStreamable(media)) {
          // No Range support on /original and the MP4 index at the end: the whole file would have to
          // download before the first frame, the playback endpoint streams
          Log.i(TAG, "original not streamable, using /video/playback")
          videoFallbackTried = true
          url = playback
        }
        playUrl(url)
      }
  }

  /** Reads the first 64 KB of the original: streamable unless the server ignores Range and moov is last. */
  private suspend fun isStreamable(media: MediaRequest): Boolean =
    try {
      withContext(Dispatchers.IO) {
        httpClient.newCall(httpRequest(media.url, range = "bytes=0-65535")).execute().use { response ->
          if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
          val buffer = ByteArray(65536)
          var total = 0
          response.body?.byteStream()?.use { input ->
            while (total < buffer.size) {
              val read = input.read(buffer, total, buffer.size - total)
              if (read < 0) break
              total += read
            }
          }
          val ranged = response.code == 206
          val moovFirst = ImmersiveMedia.mp4MoovBeforeMdat(buffer, total)
          Log.i(TAG, "video probe: range=$ranged moovFirst=$moovFirst")
          ranged || moovFirst != false
        }
      }
    } catch (e: CancellationException) {
      throw e
    } catch (e: Throwable) {
      Log.w(TAG, "video probe failed, trying the original anyway", e)
      true
    }

  private fun playUrl(url: String) {
    val p = player ?: return
    currentVideoUrl = url
    decoderChecked = false
    decoderWarning = null
    val kind =
      when {
        !url.startsWith("http") -> "local copy"
        url.contains("/video/playback") -> "playback"
        else -> "original"
      }
    Log.i(TAG, "play $kind")
    p.setMediaItem(MediaItem.fromUri(url))
    p.prepare()
    p.playWhenReady = true
  }

  private fun stopVideo() {
    currentVideoUrl = null
    player?.let {
      it.stop()
      it.clearMediaItems()
    }
    videoEntity?.setComponent(Visible(false))
  }

  private fun togglePlayPause() {
    val p = player ?: return
    if (currentVideoUrl == null) return
    if (p.isPlaying) p.pause() else p.play()
  }

  // ---------------------------------------------------------------------------------------------
  // Lifecycle

  /** Pauses the video while the system menu is open, as recommended in MediaPlayerSample. */
  override fun onSessionStateChanged(state: SessionState) {
    super.onSessionStateChanged(state)
    Log.i(TAG, "session state $state")
    when (state) {
      SessionState.VISIBLE -> {
        wasPlayingBeforeMenu = player?.isPlaying == true
        player?.pause()
      }
      SessionState.FOCUSED -> {
        if (wasPlayingBeforeMenu) player?.play()
        wasPlayingBeforeMenu = false
      }
      else -> Unit
    }
  }

  override fun onPause() {
    super.onPause()
    player?.pause()
  }

  override fun onDestroy() {
    scope.cancel()
    super.onDestroy()
  }

  override fun onSpatialShutdown() {
    Log.i(TAG, "immersive viewer shutdown")
    scope.cancel()
    player?.release()
    player = null
    videoPanel = null
    pendingBitmap?.recycle()
    pendingBitmap = null
    // Textures still bound to the skybox material are released with the scene, as in the samples
    photoTexture = null
    idleTexture = null
    skyboxMaterial = null
    halfSphereMaterial = null
    super.onSpatialShutdown()
  }

  companion object {
    private const val EXTRA_URL = "app.alextran.immich.immersive.URL"
    private const val EXTRA_TOKEN = "app.alextran.immich.immersive.TOKEN"
    private const val EXTRA_IS_VIDEO = "app.alextran.immich.immersive.IS_VIDEO"
    private const val EXTRA_TITLE = "app.alextran.immich.immersive.TITLE"
    private const val EXTRA_STEREO_LAYOUT = "app.alextran.immich.immersive.STEREO_LAYOUT"
    private const val EXTRA_STEREO_LABELS = "app.alextran.immich.immersive.STEREO_LABELS"
    private const val EXTRA_COVERAGE = "app.alextran.immich.immersive.COVERAGE"
    private const val ORIGINAL_PREFIX = "immersive_original_"
    private const val INFO_DISTANCE = 1.3f
    private const val INFO_AUTO_HIDE_MS = 4000L
    private const val DECODER_WARNING_HIDE_MS = 10000L
    private const val VIDEO_SPHERE_RADIUS = 300f
    /** Mesh of the half sphere of 180° photos, and its radius: the distance of the video sphere. */
    private const val HALF_SPHERE_MESH = "mesh://immersive_half_sphere"
    private const val HALF_SPHERE_RADIUS = 300f

    /**
     * Starting rotation of the photo sphere and of the video sphere around the vertical axis. Not verified
     * on a headset: turn the image with the thumbstick until its center faces you, then use the value
     * logged as "photo yaw is now ..." or "video yaw is now ...".
     */
    private const val SKYBOX_YAW_DEGREES = 0f
    private const val VIDEO_YAW_DEGREES = 0f
    private const val YAW_STEP_DEGREES = 90f

    /** Token of the last intent built by [intent], checked by parse. Lives as long as the process. */
    @Volatile private var launchToken: String? = null

    fun intent(
      context: Context,
      url: String,
      isVideo: Boolean,
      title: String,
      stereoLayout: ImmersiveStereoLayout,
      stereoLabels: Map<String, String>,
      coverage: ImmersiveSphereCoverage,
    ): Intent {
      val token = UUID.randomUUID().toString()
      launchToken = token
      val labels = Bundle().apply { stereoLabels.forEach { (key, value) -> putString(key, value) } }
      return Intent(context, ImmersiveViewerActivity::class.java).apply {
        action = Intent.ACTION_MAIN
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        putExtra(EXTRA_TOKEN, token)
        putExtra(EXTRA_URL, url)
        putExtra(EXTRA_IS_VIDEO, isVideo)
        putExtra(EXTRA_TITLE, title)
        putExtra(EXTRA_STEREO_LAYOUT, stereoLayout.raw)
        putExtra(EXTRA_STEREO_LABELS, labels)
        putExtra(EXTRA_COVERAGE, coverage.raw)
      }
    }

    /** Compositor layer and material stereo mode of a 3D layout: each eye gets its own half of the frame. */
    private fun stereoModeFor(layout: ImmersiveStereoLayout): StereoMode =
      when (layout) {
        ImmersiveStereoLayout.MONO -> StereoMode.None
        ImmersiveStereoLayout.TOP_BOTTOM -> StereoMode.UpDown
        ImmersiveStereoLayout.LEFT_RIGHT -> StereoMode.LeftRight
      }

    /** Shape of the video panel for a coverage, the one Equirect360ShapeOptions or Equirect180ShapeOptions sets. */
    private fun panelShapeTypeFor(coverage: ImmersiveSphereCoverage): PanelShapeType =
      when (coverage) {
        ImmersiveSphereCoverage.FULL -> PanelShapeType.EQUIRECT
        ImmersiveSphereCoverage.HALF -> PanelShapeType.EQUIRECT180
      }

    /** Central horizontal angle of the equirect layer for a coverage, in radians, as the shape options set it. */
    private fun horizontalAngleFor(coverage: ImmersiveSphereCoverage): Float =
      when (coverage) {
        ImmersiveSphereCoverage.FULL -> (2 * PI).toFloat()
        ImmersiveSphereCoverage.HALF -> PI.toFloat()
      }
  }
}
