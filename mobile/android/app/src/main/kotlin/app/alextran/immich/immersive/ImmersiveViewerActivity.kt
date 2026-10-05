package app.alextran.immich.immersive

import android.annotation.SuppressLint
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
import android.widget.ImageButton
import android.widget.SeekBar
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
import app.alextran.immich.core.DualFisheyeEffect
import app.alextran.immich.core.HttpClientManager
import app.alextran.immich.core.PlaybackStatsLogger
import app.alextran.immich.core.StreamingLoadControl
import app.alextran.immich.core.VideoDecoders
import app.alextran.immich.core.raw.RawMessage
import app.alextran.immich.core.raw.RawMode
import app.alextran.immich.core.raw.RawPlan
import app.alextran.immich.core.raw.RawPlaybackPlanner
import app.alextran.immich.core.raw.RawProjection
import app.alextran.immich.core.raw.RawStitchException
import app.alextran.immich.core.raw.RawTrack
import app.alextran.immich.core.raw.TwoLensPlayback
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.SpatialFeature
import com.meta.spatial.core.Vector3
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
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/** Log tag of the rawProjection parse result and of its refusals, shared with the phone player. */
private const val RAW_PROJECTION_TAG = "RawProjection"

/**
 * Immersive (Horizon OS) viewer for one equirectangular photo or video, started from the 2D Flutter
 * activity through ImmersiveApi. Follows Meta's HybridSample for the switch between the 2D panel and
 * the immersive activity, the skybox samples for photos and MediaPlayerSample for 360 video.
 *
 * Requests use the app's native HTTP session (HttpClientManager: session cookie, custom headers,
 * client certificate). The activity is exported like in HybridSample, so it only accepts intents that
 * carry the launch token of the last intent built by [intent]: anything else shows nothing.
 *
 * Controllers: trigger plays or pauses a video while the info panel is hidden (on the panel it clicks),
 * B or Y goes back to the 2D app, A, X, grip or menu show or hide the info panel. Thumbstick left or
 * right opens the previous or the next media of the app without leaving the immersive view: Flutter
 * picks it and the viewer shows it in place (see [navigate]). Thumbstick up or down seeks 10 seconds forward or
 * back in a video, and turns a photo by 90 degrees (logged, to find the right SKYBOX_YAW_DEGREES).
 * The thumbstick never brings the info panel up: with the panel hidden, a one line feedback panel shows the new
 * time, the title of the new media or the angle for a moment (see [showFeedback]). The decisions are in
 * [ImmersiveControls]. The 3D layout is on the info panel only. Hands and controller rays: the buttons of the info
 * panel (time bar and its 10 second buttons for a video, previous, play or pause, next, turn by 90 degrees,
 * 3D layout, field of view, back), the menu gesture toggles it.
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
 *
 * A raw 360° video comes with its rawProjection JSON (see [RawProjection]); the video panel stays a mono 360° layer
 * and the 3D and field of view buttons hide for it. Both lenses side by side in one track: [DualFisheyeEffect]
 * stitches each frame before it reaches the panel. Lenses in two tracks or two files (Insta360 X4 and later, split
 * pairs, GoPro .360, DJI .osv): [TwoLensPlayback] decodes both streams and its compositor draws the stitched frame
 * into the panel Surface. [RawPlaybackPlanner] decides how it plays and falls back (one lens, the transcoded streams,
 * unstitched), see [ensurePlayer]. Raw photos arrive stitched by Flutter.
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
    /** Where a video starts, so that the immersive view carries on from the flat player. 0 for a photo. */
    val startPositionMs: Long,
    /**
     * The opening of the viewer by Flutter this media belongs to, sent back with every event so that Flutter ignores
     * the events of an opening it no longer follows. A previous or next media keeps the id of the opening it was
     * reached from; a fresh open from the app (onNewIntent) brings its own.
     */
    val openingId: Long,
    /**
     * The server's transcoded stream of a video, played instead of [url] once when the headset cannot decode the
     * original (checked at its first tracks) or when the original fails. Null for a photo, for a media without one
     * (a file of a network share) and when the user chose to always play the original.
     */
    val fallbackUrl: String?,
    /**
     * The rawProjection JSON of a raw 360° video (see [RawProjection]), which the player stitches with
     * [DualFisheyeEffect] or [TwoLensPlayback]. Null for an equirectangular media, and ignored for a photo (Flutter
     * sends raw photos already stitched).
     */
    val rawProjection: String? = null,
  ) {
    /** A raw 360° video, drawn as a mono 360° video whatever the 3D layout and the field of view say. */
    val isRawVideo: Boolean
      get() = isVideo && rawProjection != null
  }

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  private var request: MediaRequest? = null
  private var sceneReady = false
  private var closing = false
  /** Flutter got the closed event of this viewer: sent once, from close() or when the system closes the viewer. */
  private var closedSent = false
  /**
   * Playback position of the current video when the viewer last paused, for a closed event sent once the player is
   * gone (the system closing the viewer). Null for a photo and for a video that has not played yet.
   */
  private var lastKnownPositionMs: Long? = null

  // Scene
  private var skyboxEntity: Entity? = null
  private var videoEntity: Entity? = null
  private var infoEntity: Entity? = null
  /** One line panel below the line of sight for the thumbstick actions, see [showFeedback]. */
  private var feedbackEntity: Entity? = null
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
  /**
   * Rotation of each sphere around the vertical axis, in degrees, changed with the Turn button or the thumbstick.
   * Back to the starting value for every new media (showRequest).
   */
  private var photoYaw = SKYBOX_YAW_DEGREES
  private var videoYaw = VIDEO_YAW_DEGREES
  /**
   * 3D layout of the current media: the one Flutter guessed, then the one the user picked with the 3D layout button.
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
  /** Time bar row of a video: 10 seconds back, the bar, the time, 10 seconds forward. Hidden for a photo. */
  private var seekRow: View? = null
  private var seekBar: SeekBar? = null
  private var timeView: TextView? = null
  private var seekBackButton: ImageButton? = null
  private var seekForwardButton: ImageButton? = null
  private var previousButton: Button? = null
  private var nextButton: Button? = null

  // Feedback panel
  private var feedbackView: TextView? = null
  /** The text of the feedback panel, kept for a panel bound after it was asked for. */
  private var feedbackText = ""
  /** Hides the feedback panel FEEDBACK_SHOW_MS after its last text. */
  private var feedbackJob: Job? = null

  // Time bar
  /** Refreshes the time bar while the panel is on screen with a video, see [updateProgressTicker]. */
  private var progressJob: Job? = null
  /**
   * The user is dragging the time bar: the bar follows the pointer rather than the player, and the auto hide waits
   * for the end of the drag (see [scheduleInfoHide]). Dropped when the panel hides or the bar is disabled, since the
   * bar may then never report the end of the drag.
   */
  private var userSeeking = false
  /** "This video cannot be seeked" was shown for the current video: once is enough. */
  private var notSeekableShown = false

  // Previous and next media
  /**
   * Number of the previous or next request waiting for Flutter, null when none is. Only the media Flutter shows for
   * this number (ImmersiveApiImpl.showAdjacent) is accepted. The number is dropped when that media arrives, when the
   * request fails or times out, and when the viewer closes, so that a late answer shows nothing.
   */
  private var pendingRequestId: Long? = null
  /** Number of the last request whose media was shown, to tell Flutter's true answer for it from a late one. */
  private var appliedRequestId: Long? = null
  /** Gives the buttons back if Flutter never answers, see ADJACENT_TIMEOUT_MS. */
  private var navigationTimeoutJob: Job? = null
  /** "Looking for the next media", as shown for the pending request. */
  private var navigationStatus = ""
  /**
   * The pending request came from the thumbstick with the info panel hidden: the panel stays hidden, the feedback panel
   * says what happens instead (the request, then the title of the new media or why there is none).
   */
  private var navigationQuiet = false
  /** Direction of the last request: -1 previous, 1 next. */
  private var navigationStep = 0
  /**
   * The status line held back under "Looking for the next media": the one shown before the request, then whatever
   * the current media reported meanwhile (see [setStatus]). Shown again if the request times out.
   */
  private var statusBeforeNavigation = ""

  // Loading
  private var loadJob: Job? = null
  private var hideInfoJob: Job? = null
  /** Delay of the last hide scheduled: INFO_AUTO_HIDE_MS for the plain auto hide, longer for the decoder warning. */
  private var hideInfoDelayMs = 0L
  /**
   * Delay of an auto hide held back while the user drags the time bar or a previous or next request is pending: the
   * panel must not vanish under the pointer, nor before the answer can be read. [runDeferredHide] starts it once
   * both are over.
   */
  private var deferredHideMs: Long? = null
  private val decodeMutex = Mutex()
  private val httpClient: OkHttpClient by lazy {
    // Same session as the rest of the app, without the API response cache (originals are large)
    HttpClientManager.getClient().newBuilder().cache(null).build()
  }

  // Video
  private var player: ExoPlayer? = null
  /**
   * The current player was built with the streaming buffers (a video read over HTTP). The buffers are fixed when the
   * player is built, so a local video after a streamed one, or the other way round, gets a new player.
   */
  private var playerStreamed = false
  /**
   * [RawPlan.key] of the current player: its mode (plain, side by side effect, lens player, unstitched), its decoded
   * streams and its URLs. The effects and the lens renderers are set up before prepare, so a video of another plan
   * gets a new player.
   */
  private var playerPlanKey: String? = null
  /** How the current player plays the current video, see [RawPlaybackPlanner]; PLAIN for an equirectangular one. */
  private var playerPlan: RawPlan? = null
  /** The lens player of a LENSES plan, whose [TwoLensPlayback.player] is [player]; null otherwise. */
  private var twoLens: TwoLensPlayback? = null
  /** The plan a fallback step chose for the current media, which [ensurePlayer] keeps until the next media. */
  private var rawPlanOverride: RawPlan? = null
  /** A plan whose message shows once its url plays (playUrl clears the status of the previous url first). */
  private var pendingRawMessage: RawPlan? = null
  /** The stitching of the current raw video failed while playing: its frames now play as they are. */
  private var rawEffectFailed = false
  /** A new plan is posted for the current media: errors that follow from the same failure do not post another. */
  private var rawReplanPending = false
  /** The JSON parsed last and its projection (null when refused), so that each media is parsed once. */
  private var parsedRawJson: String? = null
  private var parsedRawProjection: RawProjection? = null
  /** The lens tracks of the current url were checked against the headset decoders, the instance count included. */
  private var lensDecodersChecked = false
  /**
   * The headset took the decoders back while the viewer was not in front (system menu, headset off): the player
   * prepares again at the same position once the viewer is back, in the same plan, see [resumeHeldPlayback].
   */
  private var reprepareOnReturn = false
  /**
   * Decoder, input format, dropped frames and per loop counts of the current player, for the device checks. One per
   * player: it tells the renderers of a lens player apart by the order they are enabled in, see PlaybackStatsLogger.
   */
  private var playbackStats: PlaybackStatsLogger? = null
  /** The next STATE_READY is the first one of the current url: the end of the loading hides the panel. */
  private var hideWhenReady = false
  /**
   * The video panel shows the current video. It stays hidden from the start of a video to its first frame, so that
   * the last frame of the previous video does not show up with the 3D layout or the field of view of the new one.
   */
  private var videoRevealed = false
  private var videoSurface: Surface? = null
  private var currentVideoUrl: String? = null
  private var videoFallbackTried = false
  /** Between onResume and onPause: the viewer is the activity in front. */
  private var resumed = false
  /**
   * The session has the input focus (FOCUSED): headset on, no system menu over the viewer. True until the session
   * reports a state, so that a session that never reports one does not keep every video paused.
   */
  private var focused = true
  /**
   * The video was playing, or about to start, when the viewer lost the front (onPause, system menu, headset off), or
   * was shown meanwhile: it plays once the viewer is resumed and focused again, never before, so that no sound comes
   * out of a headset nobody wears or from behind the system menu.
   */
  private var playOnReturn = false
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
    // A recreation goes on with the media shown last: the system hands back the intent that first started the viewer,
    // which knows neither a previous or next media nor a fresh open received in onNewIntent
    request = savedInstanceState?.getBundle(STATE_REQUEST)?.let(::requestOf) ?: parse(intent)
    liveViewer = this
  }

  /**
   * Keeps the media shown now for a recreation (see onCreate), with the 3D layout and the field of view on screen (the
   * user's corrections) and, for a video, the position it reached, so that the new viewer carries on with the same
   * opening as if nothing happened.
   */
  override fun onSaveInstanceState(outState: Bundle) {
    super.onSaveInstanceState(outState)
    val media = request ?: return
    val shown =
      media.copy(
        stereoLayout = shownStereoLayout(media),
        coverage = shownCoverage(media),
        startPositionMs = currentPositionMs(media),
      )
    outState.putBundle(STATE_REQUEST, extrasOf(shown))
  }

  /**
   * A fresh open from the app while the viewer is in front (ImmersiveApiImpl.open): a new opening, whose id the events
   * carry from now on. Previous and next never come this way: they arrive through ImmersiveApiImpl.showAdjacent.
   */
  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    // singleTask: other apps can reach this method too, an intent without the launch token changes nothing
    val parsed = parse(intent) ?: return
    setIntent(intent)
    request = parsed
    Log.i(TAG, "immersive viewer onNewIntent, opening ${parsed.openingId}")
    if (sceneReady) showRequest()
  }

  override fun onSceneReady() {
    super.onSceneReady()
    Log.i(TAG, "immersive viewer onSceneReady")
    try {
      scene.setReferenceSpace(ReferenceSpace.LOCAL_FLOOR)
      // The thumbsticks change the media, seek and turn the image instead of moving or snap turning the user
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
      feedbackEntity =
        Entity.createPanelEntity(
          R.id.immersive_feedback_panel,
          Transform(Pose(Vector3(0f, 1.1f - FEEDBACK_DROP, FEEDBACK_DISTANCE), Quaternion(0f, 0f, 0f))),
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
            shape = QuadShapeOptions(width = INFO_PANEL_WIDTH_M, height = INFO_PANEL_HEIGHT_M),
            style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
            display = DpDisplayOptions(width = INFO_PANEL_WIDTH_DP, height = INFO_PANEL_HEIGHT_DP, dpi = 260),
          )
        },
        panelSetupWithRootView = { rootView, _, _ -> bindInfoPanel(rootView) },
      ),
      // One line under the line of sight, closer than the info panel, same theme and the same dp per meter
      LayoutXMLPanelRegistration(
        R.id.immersive_feedback_panel,
        layoutIdCreator = { R.layout.immersive_feedback_panel },
        settingsCreator = {
          UIPanelSettings(
            shape = QuadShapeOptions(width = FEEDBACK_PANEL_WIDTH_M, height = FEEDBACK_PANEL_HEIGHT_M),
            style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
            display = DpDisplayOptions(width = FEEDBACK_PANEL_WIDTH_DP, height = FEEDBACK_PANEL_HEIGHT_DP, dpi = 260),
          )
        },
        panelSetupWithRootView = { rootView, _, _ -> bindFeedbackPanel(rootView) },
      ),
      // 360 video: equirectangular compositor layer, as in MediaPlayerSample. Created mono, with the coverage of
      // the first media, a stereoscopic video or another coverage reshapes the layer afterwards (applyVideoShape).
      VideoSurfacePanelRegistration(
        R.id.immersive_video_panel,
        surfaceConsumer = { _, surface ->
          Log.i(TAG, "video surface ready")
          videoSurface = surface
          player?.let { attachVideoSurface(it, surface) }
        },
        settingsCreator = {
          MediaPanelSettings(
            shape =
              if (shownVideoCoverage() == ImmersiveSphereCoverage.HALF) {
                Equirect180ShapeOptions(radius = VIDEO_SPHERE_RADIUS)
              } else {
                Equirect360ShapeOptions(radius = VIDEO_SPHERE_RADIUS)
              },
            display = PixelDisplayOptions(width = VIDEO_PANEL_WIDTH_PX, height = VIDEO_PANEL_HEIGHT_PX),
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
    val extras = intent.extras
    if (extras == null) {
      Log.e(TAG, "immersive viewer started without a url")
      return null
    }
    return requestOf(extras)
  }

  /**
   * Shows [request]: the first media, a new one the app opened while the viewer is in front (onNewIntent), or the
   * previous or next one Flutter picked (applyAdjacent). Whatever the previous media left running stops first: its
   * loading (downloads included), its auto hide, held back or not, a pending previous or next request (this media is
   * its answer, or replaces it) and the drag of the time bar. The info panel comes in front of the user for the
   * loading, unless [revealInfo] is false: a media reached with the thumbstick while the panel was hidden, which the
   * feedback panel announces instead.
   */
  private fun showRequest(revealInfo: Boolean = true) {
    val media = request
    loadJob?.cancel()
    hideInfoJob?.cancel()
    hideInfoJob = null
    endNavigation()
    userSeeking = false
    deferredHideMs = null
    lastKnownPositionMs = null
    rawEffectFailed = false
    rawPlanOverride = null
    pendingRawMessage = null
    reprepareOnReturn = false
    if (media == null) {
      showError(getString(R.string.immersive_error_nothing))
      return
    }
    Log.i(TAG, "show ${if (media.isVideo) "video" else "photo"}, start at ${media.startPositionMs} ms")
    stereoLayout = media.stereoLayout
    coverage = media.coverage
    // Each file has its own orientation: a turn that brought the center of the previous media in front of the user
    // means nothing for this one, which starts from the default rotation
    photoYaw = SKYBOX_YAW_DEGREES
    videoYaw = VIDEO_YAW_DEGREES
    applySphereTransforms()
    if (media.stereoLayout != ImmersiveStereoLayout.MONO) {
      Log.i(TAG, "stereoscopic media, 3D layout ${media.stereoLayout}")
    }
    if (media.coverage != ImmersiveSphereCoverage.FULL) {
      Log.i(TAG, "half sphere media (VR180), coverage ${media.coverage}")
    }
    if (media.isRawVideo) Log.i(TAG, "raw 360 video, stitched on the headset")
    titleView?.text = media.title
    updateVideoControls()
    updateStereoView()
    updateCoverageView()
    if (revealInfo) setInfoVisible(true, reposition = true)
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
    seekRow = root.findViewById(R.id.immersive_seek_row)
    seekBar = root.findViewById(R.id.immersive_seek_bar)
    timeView = root.findViewById(R.id.immersive_time)
    seekBackButton = root.findViewById(R.id.immersive_seek_back)
    seekForwardButton = root.findViewById(R.id.immersive_seek_forward)
    previousButton = root.findViewById(R.id.immersive_previous)
    nextButton = root.findViewById(R.id.immersive_next)
    root.findViewById<Button>(R.id.immersive_back)?.setOnClickListener { close() }
    // A click from the controller ray or a hand pinch: the panel is on screen, it stays where it is, and a pending
    // auto hide starts again so that the panel does not vanish while the user is using it
    onPanelClick(playPauseButton) { togglePlayPause() }
    onPanelClick(stereoView) { cycleStereoLayout(1, fromPanel = true) }
    onPanelClick(coverageView) { toggleCoverage() }
    onPanelClick(root.findViewById(R.id.immersive_turn)) { rotateSphere(YAW_STEP_DEGREES) }
    onPanelClick(seekBackButton) { seekBy(-1) }
    onPanelClick(seekForwardButton) { seekBy(1) }
    // Previous and next handle the auto hide themselves: the panel stays until Flutter answers
    previousButton?.setOnClickListener { navigate(-1) }
    nextButton?.setOnClickListener { navigate(1) }
    seekBar?.setOnSeekBarChangeListener(seekBarListener)
    request?.let { media -> titleView?.text = media.title }
    updateVideoControls()
    updateNavigationButtons()
    updateStereoView()
    updateCoverageView()
  }

  /** Runs [action] on a click on [view], then restarts a pending auto hide (see [restartPendingHide]). */
  private fun onPanelClick(view: View?, action: () -> Unit) {
    view?.setOnClickListener {
      action()
      restartPendingHide()
    }
  }

  /**
   * Play or pause and the time bar row are there for a video only. The row starts empty and disabled, the ticker
   * fills it once the player knows the duration.
   */
  private fun updateVideoControls() {
    val visibility = if (request?.isVideo == true) View.VISIBLE else View.GONE
    playPauseButton?.visibility = visibility
    seekRow?.visibility = visibility
    updateProgress()
  }

  /** Previous and next are disabled while a request waits for its answer. */
  private fun updateNavigationButtons() {
    val enabled = pendingRequestId == null
    previousButton?.isEnabled = enabled
    nextButton?.isEnabled = enabled
  }

  /**
   * The status line of the media and of the controls. While a previous or next request is pending the line keeps
   * saying "Looking for the next media", which the user waits for: [text] is held back instead, and shown if the
   * request times out (see [timeoutNavigation]). Errors and the decoder warning do not wait, see [showError].
   */
  private fun setStatus(text: String) {
    if (pendingRequestId != null) {
      statusBeforeNavigation = text
      return
    }
    showStatus(text)
  }

  /** Writes the status line whatever is pending: the request itself and its answer. */
  private fun showStatus(text: String) {
    statusView?.text = text
  }

  /** The 3D layout button, "3D layout: 3D, top and bottom": shown whenever a media is loaded, mono ones included. */
  private fun updateStereoView() {
    val view = stereoView ?: return
    val media = request
    // A stitched frame is mono: the layout would change nothing
    if (media == null || media.isRawVideo) {
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
    // A stitched frame covers the full sphere
    if (media == null || media.isRawVideo) {
      view.visibility = View.GONE
      return
    }
    val description = ImmersiveMedia.coverageText(coverage, media.stereoLabels)
    view.text = ImmersiveMedia.coverageButtonText(coverage)
    view.tooltipText = description
    view.contentDescription = description
    view.visibility = View.VISIBLE
  }

  /**
   * An error stays on screen: no auto hide, not even one held back for a drag or a pending request. It shows at once,
   * even over "Looking for the next media": held back, the answer to the request (often "no next media") would
   * overwrite it unread. The request goes on, and its answer leaves the error in place (see [finishNavigation]).
   */
  private fun showError(text: String) {
    Log.w(TAG, "shown to the user: $text")
    cancelInfoHide()
    showStatus(text)
    setInfoVisible(true, reposition = true)
  }

  /**
   * Hides the info panel [delayMs] after the media is on screen. While the user drags the time bar or a previous or
   * next request is pending, the hide is held back instead (see [deferredHideMs]): the end of a load must not take
   * the panel away from under the pointer, nor before the answer to the request can be read.
   */
  private fun scheduleInfoHide(delayMs: Long = INFO_AUTO_HIDE_MS) {
    hideInfoJob?.cancel()
    hideInfoJob = null
    hideInfoDelayMs = delayMs
    if (userSeeking || pendingRequestId != null) {
      deferredHideMs = delayMs
      return
    }
    deferredHideMs = null
    hideInfoJob =
      scope.launch {
        delay(delayMs)
        hideInfoJob = null
        setInfoVisible(false, reposition = false)
      }
  }

  /** Starts the auto hide held back by a drag or a pending request, once neither holds it any more. */
  private fun runDeferredHide() {
    if (userSeeking || pendingRequestId != null) return
    val delayMs = deferredHideMs ?: return
    scheduleInfoHide(delayMs)
  }

  /** No auto hide any more, running or held back: an error, or the user showing or hiding the panel with a button. */
  private fun cancelInfoHide() {
    hideInfoJob?.cancel()
    hideInfoJob = null
    deferredHideMs = null
  }

  /**
   * A click or a drag on the info panel: a pending auto hide starts again from now, with its own delay, so that the
   * panel does not vanish while the user is using it. A panel without a pending hide (opened by the user, showing an
   * error, or loading) keeps its own rules.
   */
  private fun restartPendingHide() {
    if (hideInfoJob?.isActive == true) scheduleInfoHide(hideInfoDelayMs)
  }

  private fun setInfoVisible(visible: Boolean, reposition: Boolean) {
    if (!visible) {
      // A hidden panel has nothing left to hide, and the drag of its time bar is over even if the bar never reports
      // the end of the touch: a drag left on would hold every later auto hide back
      cancelInfoHide()
      userSeeking = false
    }
    // The panel says it all: the feedback line below it would only cover its buttons
    if (visible) hideFeedback()
    val panel = infoEntity ?: return
    if (visible && reposition) placeInfoInFront()
    panel.setComponent(Visible(visible && infoPlaced))
    infoVisible = visible
    updateProgressTicker()
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
  // Feedback panel

  private fun bindFeedbackPanel(root: View) {
    feedbackView = root.findViewById(R.id.immersive_feedback_text)
    feedbackView?.text = feedbackText
  }

  /**
   * Shows [text] on the one line feedback panel for FEEDBACK_SHOW_MS, lower and closer than the info panel, in front
   * of where the user looks now: the answer to a thumbstick action while the info panel is hidden, which it neither
   * shows nor moves. A new text restarts the delay.
   */
  private fun showFeedback(text: String) {
    if (text.isBlank()) return
    feedbackText = text
    feedbackView?.text = text
    val panel = feedbackEntity ?: return
    placeFeedbackInFront(panel)
    panel.setComponent(Visible(infoPlaced))
    feedbackJob?.cancel()
    feedbackJob =
      scope.launch {
        delay(FEEDBACK_SHOW_MS)
        feedbackJob = null
        hideFeedback()
      }
  }

  private fun hideFeedback() {
    feedbackJob?.cancel()
    feedbackJob = null
    feedbackEntity?.setComponent(Visible(false))
  }

  /** Like [placeInfoInFront], at FEEDBACK_DISTANCE and FEEDBACK_DROP below the eyes. */
  private fun placeFeedbackInFront(panel: Entity) {
    val head = lastHeadPosition ?: return
    val forward = lastHeadForward ?: Vector3(0f, 0f, 1f)
    val flat = sqrt(forward.x * forward.x + forward.z * forward.z)
    val direction = if (flat < 1e-3f) Vector3(0f, 0f, 1f) else Vector3(forward.x / flat, 0f, forward.z / flat)
    val position = head + (direction * FEEDBACK_DISTANCE)
    position.y = head.y - FEEDBACK_DROP
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

  /** Turns the sphere of the current media by [degrees] and logs the value to report. Returns the status shown. */
  private fun rotateSphere(degrees: Float): String {
    val isVideo = request?.isVideo == true
    val yaw = normalizeDegrees((if (isVideo) videoYaw else photoYaw) + degrees)
    if (isVideo) videoYaw = yaw else photoYaw = yaw
    applySphereTransforms()
    val constant = if (isVideo) "VIDEO_YAW_DEGREES" else "SKYBOX_YAW_DEGREES"
    Log.i(TAG, "${if (isVideo) "video" else "photo"} yaw is now ${yaw.toInt()} degrees ($constant)")
    val status = getString(R.string.immersive_yaw, yaw.toInt())
    setStatus(status)
    return status
  }

  /**
   * A turn from the thumbstick (the right one left or right on any media, either one up or down on a photo), told by
   * the feedback panel while the info panel is hidden.
   */
  private fun turnFromThumbstick(degrees: Float) {
    val status = rotateSphere(degrees)
    if (!infoVisible) showFeedback(status)
  }

  /**
   * The 3D layout button of the info panel ([step] 1, [fromPanel]): mono, top and bottom, side by side, [step] -1
   * goes the other way. Applies the layout to the media on screen and shows it on the info panel. A hidden panel
   * shows up for a few seconds. On a panel already on screen only the plain auto hide restarts: an error, the
   * loading or buffering status, the decoder warning and a panel opened by the user keep their own hide rules.
   */
  private fun cycleStereoLayout(step: Int, fromPanel: Boolean = false) {
    val media = request ?: return
    if (media.isRawVideo) return
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
    if (media.isRawVideo) return
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

  /**
   * The buttons just pressed, see [ImmersiveControls] for what each one does. The info panel only comes up for A, X,
   * grip, menu and the menu gesture; the thumbstick answers on the feedback panel. A press also proves that the
   * session has the input focus (OpenXR only hands input to the focused session): a FOCUSED state that never came back
   * after a sleep of the headset would otherwise leave the trigger unable to play.
   */
  override fun onButtonsPressed(controllerBits: Int, handBits: Int) {
    val panel = if (infoVisible) "shown" else "hidden"
    val controller = Integer.toHexString(controllerBits)
    Log.d(TAG, "buttons pressed: controller 0x$controller, hand 0x${Integer.toHexString(handBits)}, panel $panel")
    val actions = ImmersiveControls.actionsFor(controllerBits, handBits, infoVisible)
    if (!focused) {
      Log.w(TAG, "button press while the session was not reported focused: taken as focused (resumed=$resumed)")
      focused = true
      // The trigger of this very press decides about the held video itself: resuming it here would make the same
      // press pause it again
      if (ImmersiveControls.Action.PLAY_PAUSE in actions) playOnReturn = false else resumeHeldPlayback()
    }
    val isVideo = request?.isVideo == true
    for (action in actions) {
      when (action) {
        ImmersiveControls.Action.CLOSE -> {
          close()
          return
        }
        ImmersiveControls.Action.PREVIOUS -> navigate(-1, fromThumbstick = true)
        ImmersiveControls.Action.NEXT -> navigate(1, fromThumbstick = true)
        ImmersiveControls.Action.TURN_LEFT -> turnFromThumbstick(-SNAP_TURN_DEGREES)
        ImmersiveControls.Action.TURN_RIGHT -> turnFromThumbstick(SNAP_TURN_DEGREES)
        ImmersiveControls.Action.STICK_UP ->
          if (isVideo) seekFromThumbstick(1) else turnFromThumbstick(YAW_STEP_DEGREES)
        ImmersiveControls.Action.STICK_DOWN ->
          if (isVideo) seekFromThumbstick(-1) else turnFromThumbstick(-YAW_STEP_DEGREES)
        ImmersiveControls.Action.TOGGLE_PANEL -> {
          // A panel opened by the user stays until the user hides it
          cancelInfoHide()
          setInfoVisible(!infoVisible, reposition = true)
        }
        ImmersiveControls.Action.SHOW_PANEL -> setInfoVisible(true, reposition = true)
        ImmersiveControls.Action.PLAY_PAUSE -> togglePlayPause()
      }
    }
  }

  @Deprecated("Deprecated in Java")
  override fun onBackPressed() {
    close()
  }

  // ---------------------------------------------------------------------------------------------
  // Previous and next media

  /**
   * Previous ([step] -1) or next ([step] 1) media, from the panel buttons or the thumbstick. The viewer does not know
   * the app's list of media: it asks Flutter (ImmersiveEvents.requestAdjacent) under a new request number, with the 3D
   * layout and the field of view shown now so that the app keeps the user's corrections. Flutter looks for the nearest
   * media that can be shown immersively in that direction and hands it to [applyAdjacent] under the same number, then
   * answers true. Until then the buttons are disabled, a second request is ignored, and neither the end of a load nor
   * the auto hide takes "Looking for the next media" away. The status line tells when there is no such media, or when
   * no app window can answer; a timeout gives the buttons back if Flutter never answers. From the thumbstick
   * ([fromThumbstick]) with the panel hidden, the panel stays hidden and the feedback panel tells all that instead.
   */
  private fun navigate(step: Int, fromThumbstick: Boolean = false) {
    if (closing || isFinishing) return
    if (pendingRequestId != null) {
      // Still looking: the feedback says so again rather than nothing happening
      if (fromThumbstick && !infoVisible) showFeedback(navigationStatus)
      return
    }
    // Without a media there is no opening for Flutter to move in
    val openingId = request?.openingId ?: return
    val id = nextRequestId()
    pendingRequestId = id
    navigationStep = step
    navigationQuiet = fromThumbstick && !infoVisible
    statusBeforeNavigation = statusView?.text?.toString().orEmpty()
    if (!navigationQuiet) {
      // The answer must stay readable: a hidden panel shows up for it and hides again afterwards, a running auto hide
      // waits for it. A hide already held back by a drag stays as it is
      when {
        hideInfoJob?.isActive == true -> deferredHideMs = hideInfoDelayMs
        !infoVisible -> deferredHideMs = INFO_AUTO_HIDE_MS
      }
      hideInfoJob?.cancel()
      hideInfoJob = null
      if (!infoVisible) setInfoVisible(true, reposition = true)
    }
    val label = getString(if (step < 0) R.string.immersive_previous else R.string.immersive_next)
    navigationStatus = getString(R.string.immersive_adjacent_loading, label)
    showStatus(navigationStatus)
    if (navigationQuiet) showFeedback(navigationStatus)
    updateNavigationButtons()
    navigationTimeoutJob?.cancel()
    navigationTimeoutJob =
      scope.launch {
        delay(ADJACENT_TIMEOUT_MS)
        navigationTimeoutJob = null
        timeoutNavigation(id, step)
      }
    Log.i(TAG, "asking the app for the media at step $step, opening $openingId, request $id")
    ImmersiveApiImpl.requestAdjacent(openingId, id, step, stereoLayout, coverage) { found ->
      val noneStatus = getString(if (step < 0) R.string.immersive_no_previous else R.string.immersive_no_next)
      when (found) {
        // Flutter answers true after applyAdjacent accepted the media, which ended the request: nothing left to do.
        // A true without that media (refused, or never sent) leaves the request pending and counts as none found
        true ->
          when {
            pendingRequestId == id -> {
              Log.w(TAG, "the app found the media at step $step but did not show it, request $id")
              finishNavigation(id, noneStatus)
            }
            appliedRequestId == id -> Log.i(TAG, "the app showed the media at step $step, request $id")
            else -> Log.i(TAG, "the app answered request $id after it ended")
          }
        false -> finishNavigation(id, noneStatus)
        null -> finishNavigation(id, getString(R.string.immersive_no_app))
      }
    }
  }

  /**
   * Flutter's answer to request [requestId] (ImmersiveApiImpl.showAdjacent): shows the media in place of the current
   * one, from its start, with the labels of the controls the app sent when it opened the viewer. Returns false and
   * shows nothing when the viewer is closing or no longer waits for this request (Back, a timeout, a newer media from
   * the app), so that Flutter does not count the media as shown.
   */
  private fun applyAdjacent(
    requestId: Long,
    url: String,
    isVideo: Boolean,
    title: String,
    mediaLayout: ImmersiveStereoLayout,
    mediaCoverage: ImmersiveSphereCoverage,
    fallbackUrl: String?,
    rawProjection: String?,
  ): Boolean {
    if (closing || isFinishing || isDestroyed) {
      Log.i(TAG, "adjacent media for request $requestId refused, the viewer is closing")
      return false
    }
    if (pendingRequestId != requestId) {
      Log.i(TAG, "adjacent media for request $requestId refused, the viewer waits for ${pendingRequestId ?: "none"}")
      return false
    }
    if (url.isBlank()) {
      Log.w(TAG, "adjacent media for request $requestId refused, no url")
      return false
    }
    // navigate only asks with a media on screen, which a pending request keeps
    val current = request ?: return false
    Log.i(TAG, "show adjacent ${if (isVideo) "video" else "photo"} for request $requestId")
    appliedRequestId = requestId
    // Still the same opening: Flutter follows it, and the events of the new media keep its id
    request =
      MediaRequest(
        url = url,
        isVideo = isVideo,
        title = title,
        stereoLayout = mediaLayout,
        stereoLabels = current.stereoLabels,
        coverage = mediaCoverage,
        startPositionMs = 0L,
        openingId = current.openingId,
        fallbackUrl = fallbackUrl,
        rawProjection = rawProjection,
      )
    // A thumbstick request with the panel still hidden: the feedback panel shows the title, the info panel stays away
    val quiet = navigationQuiet && !infoVisible
    val label = getString(if (navigationStep < 0) R.string.immersive_previous else R.string.immersive_next)
    // showRequest ends the request, so that Flutter's true answer finds nothing left to do. The scene is ready
    // whenever a request could start, onSceneReady would show the media otherwise
    if (sceneReady) showRequest(revealInfo = !quiet) else endNavigation()
    // showRequest may have opened the info panel itself (an error): the feedback line never shows over it
    if (quiet && !infoVisible) showFeedback(title.ifBlank { label })
    return true
  }

  /**
   * Ends request [id] without a new media: previous and next work again, [status] replaces "Looking for the next
   * media" (an error or the decoder warning shown meanwhile stays), and an auto hide held back for the request starts.
   * A late answer to an older request, or one that arrives after the new media, changes nothing.
   */
  private fun finishNavigation(id: Long, status: String) {
    if (closing || isDestroyed || pendingRequestId != id) return
    val quiet = navigationQuiet && !infoVisible
    endNavigation()
    replaceNavigationStatus(status)
    runDeferredHide()
    if (quiet) showFeedback(status)
  }

  /**
   * Flutter did not answer request [id] in time (it gives up after 12 seconds itself, so this covers an answer that
   * never comes). The request is dropped, so that a late media for it is refused, and "Looking for the next media"
   * gives way to the status held back meanwhile, unless something else replaced it already.
   */
  private fun timeoutNavigation(id: Long, step: Int) {
    if (closing || isDestroyed || pendingRequestId != id) return
    Log.w(TAG, "no answer from the app $ADJACENT_TIMEOUT_MS ms after request $id for step $step")
    endNavigation()
    replaceNavigationStatus(statusBeforeNavigation)
    runDeferredHide()
  }

  /** Shows [text] in place of "Looking for the next media", unless an error or a warning replaced it meanwhile. */
  private fun replaceNavigationStatus(text: String) {
    val shown = statusView?.text?.toString() ?: return
    showStatus(ImmersiveMedia.statusAfterNavigation(shown, navigationStatus, text))
  }

  /** Forgets the request in progress, if any: no timeout left, previous and next enabled again. */
  private fun endNavigation() {
    pendingRequestId = null
    navigationQuiet = false
    navigationTimeoutJob?.cancel()
    navigationTimeoutJob = null
    updateNavigationButtons()
  }

  // ---------------------------------------------------------------------------------------------
  // Time bar of a video

  /**
   * The 10 second buttons ([direction] 1 forward, -1 back): Media3 adds or removes SEEK_INCREMENT_MS from the
   * position, within the video. Nothing happens before the player knows the duration; a video that cannot be seeked
   * says so in the status line. Returns the line for the feedback panel: the new position, why there was no seek, or
   * null before the video is known.
   */
  private fun seekBy(direction: Int): String? {
    val p = player ?: return null
    if (currentVideoUrl == null || p.duration == C.TIME_UNSET) return null
    if (!p.isCurrentMediaItemSeekable) {
      val status = getString(R.string.immersive_not_seekable)
      setStatus(status)
      return status
    }
    if (direction > 0) p.seekForward() else p.seekBack()
    updateProgress()
    // The player reports the new position at once, before the seek is done
    val duration = p.duration
    val position = p.currentPosition.coerceIn(0L, duration.coerceAtLeast(0L))
    return getString(R.string.immersive_time, ImmersiveMedia.formatTime(position), ImmersiveMedia.formatTime(duration))
  }

  /**
   * Thumbstick up or down on a video: the same seek as the 10 second buttons. The info panel is left as it is: on
   * screen its time bar shows the new position and its auto hide starts again, hidden it stays hidden and the
   * feedback panel shows the new position instead.
   */
  private fun seekFromThumbstick(direction: Int) {
    val feedback = seekBy(direction)
    if (infoVisible) {
      restartPendingHide()
    } else if (feedback != null) {
      showFeedback(feedback)
    }
  }

  /**
   * Starts the time bar ticker while the panel is on screen with a video loaded, stops it otherwise: nobody reads the
   * bar on a hidden panel. While the user drags the bar the ticker skips its updates, the bar then follows the pointer.
   */
  private fun updateProgressTicker() {
    val wanted = infoVisible && !closing && request?.isVideo == true && currentVideoUrl != null
    if (!wanted) {
      stopProgressTicker()
      return
    }
    if (progressJob?.isActive == true) return
    progressJob =
      scope.launch {
        while (true) {
          if (!userSeeking) updateProgress()
          delay(PROGRESS_INTERVAL_MS)
        }
      }
  }

  private fun stopProgressTicker() {
    progressJob?.cancel()
    progressJob = null
  }

  /**
   * The time bar and its label from the player: the position, the duration and the buffered part (the secondary
   * progress, which shows how far a stream over a network share is loaded). Until the player is ready the duration
   * is unknown (C.TIME_UNSET): the label reads 0:00 and the bar and its buttons are disabled. They stay disabled for a
   * video that cannot be seeked, which the status line says once.
   */
  private fun updateProgress() {
    val bar = seekBar ?: return
    val p = player
    val duration = if (p != null && currentVideoUrl != null) p.duration else C.TIME_UNSET
    if (p == null || duration == C.TIME_UNSET || duration <= 0) {
      setSeekControlsEnabled(false)
      bar.max = 0
      bar.progress = 0
      bar.secondaryProgress = 0
      timeView?.text = getString(R.string.immersive_time, ImmersiveMedia.formatTime(0), ImmersiveMedia.formatTime(0))
      return
    }
    val seekable = p.isCurrentMediaItemSeekable
    if (!seekable && !notSeekableShown) {
      notSeekableShown = true
      Log.i(TAG, "the video cannot be seeked")
      // The decoder warning matters more, the status says it instead; a seek attempt still explains it
      if (decoderWarning == null) setStatus(getString(R.string.immersive_not_seekable))
    }
    setSeekControlsEnabled(seekable)
    // The bar under the user's pointer follows the drag, not the player: the end of the drag updates it
    if (userSeeking) return
    val max = duration.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    val position = p.currentPosition.coerceIn(0L, duration)
    if (bar.max != max) bar.max = max
    bar.progress = position.toInt()
    bar.secondaryProgress = p.bufferedPosition.coerceIn(0L, duration).toInt()
    timeView?.text =
      getString(R.string.immersive_time, ImmersiveMedia.formatTime(position), ImmersiveMedia.formatTime(duration))
  }

  private fun setSeekControlsEnabled(enabled: Boolean) {
    seekBar?.isEnabled = enabled
    seekBackButton?.isEnabled = enabled
    seekForwardButton?.isEnabled = enabled
    if (!enabled && userSeeking) {
      // A disabled bar may never report the end of the drag: the drag is over, and the hide it held back can start
      userSeeking = false
      runDeferredHide()
    }
  }

  /**
   * Dragging the time bar: the label follows the pointer, the video seeks once at the end of the drag (a seek on each
   * move would restart the loading over the network at every step), and the auto hide waits for the end of the drag.
   */
  private val seekBarListener =
    object : SeekBar.OnSeekBarChangeListener {
      override fun onStartTrackingTouch(bar: SeekBar) {
        userSeeking = true
        if (hideInfoJob?.isActive == true) {
          deferredHideMs = hideInfoDelayMs
          hideInfoJob?.cancel()
          hideInfoJob = null
        }
      }

      override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
        if (!fromUser) return
        val duration = player?.duration ?: return
        if (duration == C.TIME_UNSET) return
        timeView?.text =
          getString(
            R.string.immersive_time,
            ImmersiveMedia.formatTime(progress.toLong()),
            ImmersiveMedia.formatTime(duration),
          )
      }

      override fun onStopTrackingTouch(bar: SeekBar) {
        // A drag dropped meanwhile (panel hidden, bar disabled, another media) does not seek: the bar may no longer
        // match the video that plays now
        val dragging = userSeeking
        userSeeking = false
        val p = player
        if (dragging && p != null && currentVideoUrl != null && p.isCurrentMediaItemSeekable) {
          Log.i(TAG, "seek to ${bar.progress} ms")
          p.seekTo(bar.progress.toLong())
        }
        runDeferredHide()
        updateProgress()
      }
    }

  /** Back to the 2D Flutter activity, the way HybridSample goes back to its panel. */
  private fun close() {
    if (closing) return
    closing = true
    Log.i(TAG, "immersive viewer closing")
    loadJob?.cancel()
    hideInfoJob?.cancel()
    stopProgressTicker()
    // A media Flutter sends for a request from now on is refused, and the closed event stops its search
    endNavigation()
    reportClosed()
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

  /**
   * Tells Flutter, once per viewer, that it closed on the media shown last: its url, the 3D layout and the field of
   * view shown (the user's corrections, which the app keeps for that media), and where a video stopped, so that the
   * flat player resumes there. Sent by close(), and by onStop or onDestroy when the system closes the viewer. Nothing
   * to report for an intent that showed nothing.
   */
  private fun reportClosed() {
    if (closedSent) return
    val media = request ?: return
    closedSent = true
    val shownLayout = shownStereoLayout(media)
    val shownCoverage = shownCoverage(media)
    val positionMs = currentPositionMs(media)
    Log.i(
      TAG,
      "immersive viewer closed, opening ${media.openingId}, 3D layout=$shownLayout, coverage=$shownCoverage, " +
        "position=$positionMs ms",
    )
    ImmersiveApiImpl.notifyClosed(media.openingId, media.url, shownLayout, shownCoverage, positionMs)
  }

  /** The 3D layout on screen. Before the scene is ready nothing was applied yet: still the one of [media]. */
  private fun shownStereoLayout(media: MediaRequest): ImmersiveStereoLayout =
    if (sceneReady) stereoLayout else media.stereoLayout

  /** The field of view on screen. Before the scene is ready nothing was applied yet: still the one of [media]. */
  private fun shownCoverage(media: MediaRequest): ImmersiveSphereCoverage =
    if (sceneReady) coverage else media.coverage

  /** Where the video of [media] is now, 0 for a photo, see ImmersiveMedia.closingPositionMs. */
  private fun currentPositionMs(media: MediaRequest): Long {
    val playerPositionMs = player?.takeIf { currentVideoUrl != null }?.currentPosition
    return ImmersiveMedia.closingPositionMs(media.isVideo, playerPositionMs, lastKnownPositionMs, media.startPositionMs)
  }

  /** Keeps the position of the video that plays, for a closed event sent after the player is gone. */
  private fun rememberPosition() {
    val p = player ?: return
    if (request?.isVideo == true && currentVideoUrl != null) lastKnownPositionMs = p.currentPosition.coerceAtLeast(0L)
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
    // Back to the idle sky until the new photo is decoded: the previous photo must not show up with the field of view
    // or the 3D layout of this one (a 360° photo cut in half, or the two eyes of a 3D photo shown on a mono one)
    resetSkyboxToIdle()
    if (photoTexture != null) {
      // No idle texture to fall back on: nothing at all is better than the previous photo, applySkyboxBitmap shows
      // the sphere again with the new texture
      skyboxEntity?.setComponent(Visible(false))
      halfSphereEntity?.setComponent(Visible(false))
    } else {
      showPhotoSphere()
    }
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
            // A failure notice shows at once, even while a previous/next request holds the other statuses back
            showStatus(getString(R.string.immersive_preview_only, e.message ?: e.javaClass.simpleName))
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

  /**
   * Runs [request] on the IO dispatcher and hands the response to [read], which runs there too; the response is
   * closed afterwards. OkHttp's execute() and the reads of a body block their thread and do not see the cancellation
   * of the coroutine: a load cancelled for the next media would go on downloading a large original to the end, and a
   * few quick "next" would pile up downloads. The watcher cancels the call as soon as the coroutine is cancelled,
   * which makes the blocked execute() or read throw right away.
   */
  private suspend fun <T> fetch(request: Request, read: CoroutineScope.(Response) -> T): T =
    coroutineScope {
      val call = httpClient.newCall(request)
      // Started undispatched, so that it waits before the call starts even if the coroutine is cancelled at once
      val watcher =
        launch(start = CoroutineStart.UNDISPATCHED) {
          try {
            awaitCancellation()
          } finally {
            call.cancel()
          }
        }
      try {
        withContext(Dispatchers.IO) { call.execute().use { response -> read(response) } }
      } catch (e: IOException) {
        // A call cancelled with the coroutine fails with an IOException: report the cancellation instead, so that the
        // loading of the previous media does not show an error over the new one
        ensureActive()
        throw e
      } finally {
        watcher.cancel()
      }
    }

  private suspend fun download(url: String): ByteArray =
    fetch(httpRequest(url)) { response ->
      if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
      response.body?.bytes() ?: throw IOException("empty response")
    }

  private suspend fun downloadTo(url: String, file: File): Long =
    fetch(httpRequest(url)) { response ->
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

  // ---------------------------------------------------------------------------------------------
  // Videos: equirectangular layer fed by ExoPlayer

  /**
   * The player for a video at [url]. A video read over HTTP (the server, or the media bridge of a network share) gets
   * the larger buffers of StreamingLoadControl, as in the 360° player of the phone app, so that a seek over a share
   * that answers in bursts does not stall again a few seconds later; a file on the headset keeps the Media3 defaults.
   * The buffers are fixed when the player is built: a video read the other way than the previous one gets a new
   * player, on the same video surface. So is a raw video of another plan ([RawPlaybackPlanner]): the side by side
   * effect ([DualFisheyeEffect]) and the lens renderers ([TwoLensPlayback]) are set up before prepare, so a raw video
   * after another kind of video, two raw files with different plans, or the other way round, get a new player, and
   * only a raw video pays for the stitching.
   *
   * The previous player and its compositor go first, in that order: the old decoders and the old EGL surface must
   * leave the panel Surface before anything else connects to it.
   */
  @OptIn(UnstableApi::class)
  private fun ensurePlayer(url: String, media: MediaRequest): ExoPlayer? {
    val streamed = StreamingLoadControl.isStreamed(url)
    var plan = rawPlanOverride ?: planFor(media)
    player?.let { current ->
      if (playerStreamed == streamed && playerPlanKey == playerKeyOf(plan, media)) {
        playerPlan = plan
        return current
      }
      Log.i(TAG, "new player for a ${if (streamed) "streamed" else "local"} video, plan ${plan.mode} ${plan.streams}")
      releasePlayer()
    }
    return try {
      // Server: the app session (cookie, custom headers, client certificate), same as the in-app player.
      // file:// and content:// (the copy on the headset) are read locally by DefaultDataSource.
      val dataSourceFactory = DefaultDataSource.Factory(this, HttpClientManager.createDataSourceFactory(emptyMap()))
      val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
      val audio = AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build()
      val builder =
        StreamingLoadControl.applyTo(ExoPlayer.Builder(this), url)
          .setMediaSourceFactory(mediaSourceFactory)
          .setAudioAttributes(audio, true)
          // The 10 second buttons and the thumbstick up and down
          .setSeekBackIncrementMs(SEEK_INCREMENT_MS)
          .setSeekForwardIncrementMs(SEEK_INCREMENT_MS)
      val projection = projectionFor(media)
      var lens: TwoLensPlayback? = null
      if (plan.mode == RawMode.LENSES && projection != null) {
        lens = createLensPlayback(projection, plan, builder, mediaSourceFactory)
        if (lens == null) {
          rawEffectFailed = true
          plan = RawPlaybackPlanner.afterStitchFailure(plan) ?: plan
          rawPlanOverride = plan
        }
      }
      // Told once the url plays: the decoder message of a pre-check, a fallback step, the stitching that failed
      pendingRawMessage = plan.takeIf { it.message != null }
      (lens?.player ?: builder.build()).also {
        player = it
        twoLens = lens
        playerStreamed = streamed
        playerPlanKey = playerKeyOf(plan, media)
        playerPlan = plan
        if (plan.mode != RawMode.PLAIN) Log.i(TAG, "raw plan ${plan.mode} ${plan.streams}: ${plan.reason}")
        // Before the surface and before prepare, which sets up the effect pipeline
        if (plan.mode == RawMode.EFFECT_SIDE_BY_SIDE && projection != null) {
          it.setVideoEffects(listOf(DualFisheyeEffect(projection, VIDEO_PANEL_WIDTH_PX, VIDEO_PANEL_HEIGHT_PX)))
        }
        it.repeatMode = Player.REPEAT_MODE_ONE
        it.addListener(playerListener)
        playbackStats = PlaybackStatsLogger(TAG, lens?.streams.orEmpty()).also(it::addAnalyticsListener)
        // Each lens renderer gets its own Surface of the compositor, never the player's surface API
        lens?.bindRendererOutputs()
        videoSurface?.let { surface -> attachVideoSurface(it, surface) }
      }
    } catch (e: Exception) {
      Log.e(TAG, "player creation failed", e)
      null
    }
  }

  /**
   * The lens player of [plan], or null when its compositor cannot start (no OpenGL ES 3, a shader the driver
   * refuses): the video then plays unstitched.
   */
  @OptIn(UnstableApi::class)
  private fun createLensPlayback(
    projection: RawProjection,
    plan: RawPlan,
    builder: ExoPlayer.Builder,
    mediaSourceFactory: DefaultMediaSourceFactory,
  ): TwoLensPlayback? {
    val listener = LensListener()
    return try {
      TwoLensPlayback.create(
        this,
        projection,
        plan.streams,
        RawPlaybackPlanner.assignmentOf(plan, projection),
        builder,
        mediaSourceFactory,
        listener,
      ).also { listener.playback = it }
    } catch (e: RawStitchException) {
      Log.e(TAG, "the lens compositor cannot start, the raw video plays unstitched", e)
      null
    }
  }

  /** What the lens player tells, on the main thread; ignored once that player is replaced. */
  private inner class LensListener : TwoLensPlayback.Listener {
    var playback: TwoLensPlayback? = null

    override fun onFirstFrameDrawn() {
      // A lens renderer's first frame is not on the panel yet: the compositor's is
      if (playback != null && playback === twoLens) revealVideo()
    }

    override fun onStitchError(error: Exception) {
      if (playback == null || playback !== twoLens) return
      Log.e(TAG, "the lens compositor failed while playing", error)
      playWithoutStitching()
    }

    override fun onStreamsMissing(streams: List<Int>) {
      if (playback == null || playback !== twoLens) return
      Log.w(TAG, "no decodable track for streams $streams")
      // Without a next step there is no error to show either (no track, no decoder error): the frame plays unstitched,
      // where the default renderers may still find a decoder, or fail with an error the viewer shows
      replanRaw(rawDecoderFailurePlan() ?: playerPlan?.let(RawPlaybackPlanner::afterStitchFailure))
    }
  }

  /** Releases the current player, and then its compositor when it is a lens player. */
  private fun releasePlayer() {
    val current = player ?: return
    current.removeListener(playerListener)
    playbackStats?.let(current::removeAnalyticsListener)
    playbackStats = null
    val lens = twoLens
    twoLens = null
    if (lens != null) lens.release() else current.release()
    player = null
    playerPlanKey = null
    playerPlan = null
  }

  /**
   * Hands the surface of the video panel to [p]. A player that stitches draws the frames itself with OpenGL and must
   * be told the size of the surface, the one of its swapchain: the stitched frame is scaled to it. A lens player draws
   * through its compositor.
   */
  @OptIn(UnstableApi::class)
  private fun attachVideoSurface(p: ExoPlayer, surface: Surface) {
    val lens = twoLens
    if (p === player && lens != null) {
      lens.setOutput(surface, VIDEO_PANEL_WIDTH_PX, VIDEO_PANEL_HEIGHT_PX)
      return
    }
    p.setVideoSurface(surface)
    if (p === player && playerPlan?.mode == RawMode.EFFECT_SIDE_BY_SIDE) {
      DualFisheyeEffect.setOutputResolution(p, VIDEO_PANEL_WIDTH_PX, VIDEO_PANEL_HEIGHT_PX)
    }
  }

  /**
   * What a player is built for: the plan's key, and for the side by side effect its projection too (the effect holds
   * the calibration of one camera).
   */
  private fun playerKeyOf(plan: RawPlan, media: MediaRequest): String =
    if (plan.mode == RawMode.EFFECT_SIDE_BY_SIDE) "${plan.key} ${media.rawProjection}" else plan.key

  /** The rawProjection of [media] parsed, or null for an equirectangular media and a JSON the parser refuses. */
  private fun projectionFor(media: MediaRequest): RawProjection? {
    val json = media.rawProjection
    if (!media.isVideo || json == null) return null
    if (json == parsedRawJson) return parsedRawProjection
    val projection =
      try {
        RawProjection.parse(json).also { Log.i(RAW_PROJECTION_TAG, it.summary()) }
      } catch (e: IllegalArgumentException) {
        Log.e(RAW_PROJECTION_TAG, "rawProjection rejected: ${e.message}")
        null
      }
    parsedRawJson = json
    parsedRawProjection = projection
    return projection
  }

  /**
   * How [media] starts, see [RawPlaybackPlanner.initial]: plain for an equirectangular video, unstitched once its
   * stitching failed, otherwise as its rawProjection and the headset decoders allow.
   */
  private fun planFor(media: MediaRequest): RawPlan {
    val json = if (media.isVideo) media.rawProjection else null
    return RawPlaybackPlanner.initial(
      json != null,
      projectionFor(media),
      media.url,
      media.fallbackUrl,
      rawEffectFailed,
      ::canDecodeRaw,
    )
  }

  /** Whether the headset decodes [instances] streams like [track] at once, null when the JSON cannot tell. */
  private fun canDecodeRaw(track: RawTrack, instances: Int): Boolean? {
    val codec = track.codecs ?: track.codec ?: return null
    val verdict =
      VideoDecoders.canDecode(
        codec,
        track.codecs,
        track.width,
        track.height,
        track.frameRate,
        track.bitDepth,
        transferCharacteristics = 0,
        instances = instances,
      )
    return verdict.supported
  }

  /** The next step of the ladder after a decoder failure of the current lens player, or null. */
  private fun rawDecoderFailurePlan(): RawPlan? {
    val plan = playerPlan ?: return null
    val media = request ?: return null
    val projection = projectionFor(media) ?: return null
    return RawPlaybackPlanner.afterDecoderFailure(plan, projection, media.url, media.fallbackUrl)
  }

  /**
   * The next step of the ladder after any other failure of the current lens player, or null: a read error of a split
   * pair keeps the lens of the opened file first; any other failure (a container the extractor refuses, a timeout)
   * plays the transcoded streams, once, like the fallback of other videos.
   */
  private fun rawSourceFailurePlan(plan: RawPlan, error: PlaybackException): RawPlan? {
    val media = request ?: return null
    val projection = projectionFor(media) ?: return null
    val oneFile =
      if (error.errorCode in 2000..2999) RawPlaybackPlanner.afterSourceError(plan, projection, media.url) else null
    return oneFile ?: RawPlaybackPlanner.afterSourceFailure(plan, projection, media.url, media.fallbackUrl)
  }

  /**
   * Plays the current raw video again from where it stopped with [newPlan] (one lens, the transcoded streams,
   * unstitched), on a new player, and tells the user why. False without a new plan: the error then shows.
   */
  private fun replanRaw(newPlan: RawPlan?): Boolean {
    if (newPlan == null) return false
    val media = request ?: return false
    if (currentVideoUrl == null) return false
    if (rawReplanPending) return true
    rawReplanPending = true
    val from = playerPlan
    Log.i(TAG, "raw plan ${from?.mode} ${from?.streams} -> ${newPlan.mode} ${newPlan.streams}: ${newPlan.reason}")
    rawPlanOverride = newPlan
    val position = resumePositionMs()
    // Posted, not run from within the listener of the player being replaced
    scope.launch(Dispatchers.Main) {
      rawReplanPending = false
      if (request !== media) return@launch
      // The new player shows the message of its plan once it plays, see pendingRawMessage
      if (ensurePlayer(media.url, media) != null) playUrl(plannedUrl(media), position)
    }
    return true
  }

  /** The url to play for [media]: the original, or the first url of a raw plan (the transcoded stream for one). */
  private fun plannedUrl(media: MediaRequest): String {
    val plan = playerPlan ?: return media.url
    return if (plan.mode == RawMode.PLAIN) media.url else plan.urls.firstOrNull() ?: media.url
  }

  /** The message of [plan], if it has one, on the status line for a while, like the decoder warning. */
  private fun showRawWarning(plan: RawPlan) {
    val text =
      when (plan.message ?: return) {
        RawMessage.ONE_LENS_DECODER -> {
          val track = projectionFor(request ?: return)?.tracks?.maxByOrNull { it.pixels }
          val codec = VideoDecoders.codecName(VideoDecoders.mimeFor(track?.codecs ?: track?.codec ?: ""))
          getString(R.string.immersive_raw_one_lens_decoder, codec, track?.width ?: 0, track?.height ?: 0)
        }
        RawMessage.ONE_LENS_FILE -> getString(R.string.immersive_raw_one_lens_file)
        RawMessage.UNSTITCHED -> getString(R.string.immersive_raw_unstitched)
      }
    Log.w(TAG, "shown to the user: $text")
    decoderWarning = text
    hideInfoJob?.cancel()
    showStatus(text)
    setInfoVisible(true, reposition = true)
    scheduleInfoHide(DECODER_WARNING_HIDE_MS)
  }

  /**
   * The stitching failed while playing (a GL error in the effect or in the lens compositor): the same video plays
   * again from where it stopped, the frame as it is, rather than ending on an error. False when the current player
   * does not stitch.
   */
  private fun playWithoutStitching(): Boolean {
    val plan = playerPlan ?: return false
    if (rawEffectFailed) return false
    val next = RawPlaybackPlanner.afterStitchFailure(plan) ?: return false
    rawEffectFailed = true
    Log.w(TAG, "the raw stitching failed, the raw frame plays as it is")
    return replanRaw(next)
  }

  /**
   * Once per url of a lens player with two streams: the selected lens tracks against the headset decoders, the
   * instance count included. Two streams the headset refuses become one lens, with a message.
   */
  @OptIn(UnstableApi::class)
  private fun checkLensDecoders(tracks: Tracks) {
    val plan = playerPlan ?: return
    if (lensDecodersChecked || plan.streams.size < 2) return
    val formats =
      tracks.groups.filter { it.type == C.TRACK_TYPE_VIDEO && it.isSelected }.flatMap { group ->
        (0 until group.length).filter { group.isTrackSelected(it) }.map { group.getTrackFormat(it) }
      }
    val largest = formats.filter { it.width > 0 && it.height > 0 }.maxByOrNull { it.width * it.height } ?: return
    lensDecodersChecked = true
    val verdict = VideoDecoders.canDecode(largest, instances = plan.streams.size)
    Log.i(TAG, "lens decoders: ${formats.size} tracks selected, ${verdict.reason}")
    if (!verdict.supported) replanRaw(rawDecoderFailurePlan())
  }

  private val playerListener =
    object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        Log.i(TAG, "video state $playbackState")
        when (playbackState) {
          Player.STATE_BUFFERING -> setStatus(getString(R.string.immersive_buffering))
          Player.STATE_READY -> {
            // Normally the first frame did it already; a video that renders no frame still shows its panel. A lens
            // player's panel waits for the compositor's first frame, see LensListener
            if (twoLens == null) revealVideo()
            // Only the end of the loading hides the panel: a seek also goes through BUFFERING and READY, and the panel
            // the user is seeking on must not vanish
            val firstReady = hideWhenReady
            hideWhenReady = false
            val format = player?.videoFormat
            val description =
              if (format != null) "${format.sampleMimeType} ${format.codecs ?: ""} ${format.width}x${format.height}"
              else "no video track"
            Log.i(TAG, "video format: $description")
            val warning = decoderWarning
            // A video held until the viewer is back in front (playOnReturn) starts then: its loading is over all the
            // same. A video the user paused keeps the panel
            val starting = player?.playWhenReady == true || playOnReturn
            // During a drag or a pending previous or next request scheduleInfoHide holds the hide back, and setStatus
            // keeps "Looking for the next media" on screen
            if (warning != null) {
              // Keeps the warning on screen for its own, longer delay, counted from the moment the video plays
              setStatus(warning)
              if (firstReady && starting) scheduleInfoHide(DECODER_WARNING_HIDE_MS)
            } else {
              setStatus(description.trim())
              if (firstReady && starting) scheduleInfoHide()
            }
            // A seek during a drag also ends with READY: the bar stays under the pointer until the drag ends
            if (!userSeeking) updateProgress()
          }
          else -> Unit
        }
      }

      override fun onRenderedFirstFrame() {
        // A lens renderer's first frame is still to be stitched: the compositor reveals the panel, see LensListener
        if (twoLens == null) revealVideo()
      }

      override fun onTracksChanged(tracks: Tracks) {
        if (twoLens != null) checkLensDecoders(tracks) else selectedVideoFormat(tracks)?.let(::checkDecoderLimit)
      }

      override fun onIsPlayingChanged(isPlaying: Boolean) {
        playPauseButton?.setText(if (isPlaying) R.string.immersive_pause else R.string.immersive_play)
      }

      override fun onPlayerError(error: PlaybackException) {
        Log.e(TAG, "video error ${error.errorCodeName}: ${error.message}", error)
        // The headset took the decoders back for another app while the viewer was away: the same player prepares
        // again once the viewer is back, rather than falling back to one lens or to the transcoded stream
        if (error.errorCode == PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED && !playbackAllowed()) {
          Log.i(TAG, "decoders reclaimed while the viewer is away, preparing again on return")
          reprepareOnReturn = true
          return
        }
        val plan = playerPlan
        if (plan?.mode == RawMode.EFFECT_SIDE_BY_SIDE && DualFisheyeEffect.isStitchingError(error) &&
          playWithoutStitching()
        ) {
          return
        }
        if (plan?.mode == RawMode.LENSES) {
          // The ladder replaces the fallback of other videos: a lens player shows the error once it has nothing left
          val next = if (isDecoderError(error)) rawDecoderFailurePlan() else rawSourceFailurePlan(plan, error)
          if (!replanRaw(next)) showError(getString(R.string.immersive_error_video, error.errorCodeName))
          return
        }
        val fallback = currentVideoUrl?.let(::fallbackFor)
        if (!videoFallbackTried && fallback != null) {
          videoFallbackTried = true
          setStatus(getString(R.string.immersive_video_fallback, error.errorCodeName))
          playUrl(fallback, resumePositionMs())
        } else {
          showError(getString(R.string.immersive_error_video, error.errorCodeName))
        }
      }
    }

  /** Media3 errors of a decoder that cannot run (or no longer runs) the lens streams: the ladder's decoder step. */
  private fun isDecoderError(error: PlaybackException): Boolean =
    error.errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ||
      error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ||
      error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ||
      error.errorCode == PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED

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
   * A video above what the headset decodes plays at a fraction of its frame rate, with block artifacts: H.264 above 4K
   * on the Quest 3, whatever its decoder list says, or anything the list refuses (see VideoDecoders). From the
   * original, tries the transcoded stream Flutter sent once; otherwise tells the user what to change: the transcoding
   * settings for a server media, a re-encode for a file of the headset or of a network share.
   */
  private fun checkDecoderLimit(format: Format) {
    val url = currentVideoUrl ?: return
    if (decoderChecked || format.width <= 0 || format.height <= 0) return
    decoderChecked = true
    val verdict = VideoDecoders.canDecode(format)
    if (verdict.supported) return
    val codec = VideoDecoders.codecName(format.sampleMimeType)
    val size = "${format.width}x${format.height}"
    Log.w(TAG, "$codec $size is above what the headset decodes (${verdict.reason}), expect dropped frames")
    val fallback = request?.fallbackUrl?.takeIf { it != url }
    if (!videoFallbackTried && fallback != null) {
      videoFallbackTried = true
      setStatus(getString(R.string.immersive_video_decoder_switch, "$codec $size"))
      playUrl(fallback, resumePositionMs())
      return
    }
    val message =
      if (ImmersiveMedia.isFileMedia(url)) {
        R.string.immersive_codec_too_large_file
      } else {
        R.string.immersive_codec_too_large
      }
    val warning = getString(message, codec, format.width, format.height)
    Log.w(TAG, "shown to the user: $warning")
    decoderWarning = warning
    hideInfoJob?.cancel()
    // At once, like an error: held back under a pending request, the answer would overwrite it unread
    showStatus(warning)
    setInfoVisible(true, reposition = true)
    scheduleInfoHide(DECODER_WARNING_HIDE_MS)
  }

  /**
   * The stream to play when [url] fails or cannot stream: the transcoded stream Flutter sent. Null when [url] is that
   * stream already, or when Flutter sent none: the user chose to always play the original, or the media has no
   * transcoded stream (a file of a network share). The viewer then shows the error rather than play, unasked, the
   * stream the user turned down.
   */
  private fun fallbackFor(url: String): String? = request?.fallbackUrl?.takeIf { it != url }

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
    val mode = stereoModeFor(shownVideoLayout())
    val shape = panelShapeTypeFor(shownVideoCoverage())
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
        layer.centralHorizontalAngle = horizontalAngleFor(shownVideoCoverage())
      } else {
        Log.w(TAG, "video panel without an equirect layer config, only its mesh follows the shape $shape")
      }
      panel.reshape(config)
      Log.i(TAG, "video stereo mode is now $mode (was $previousMode), shape $shape (was $previousShape)")
    } catch (e: Exception) {
      Log.e(TAG, "could not set the video stereo mode to $mode and the shape to $shape", e)
    }
  }

  /** The 3D layout the video layer shows: mono for a stitched raw video, the current layout otherwise. */
  private fun shownVideoLayout(): ImmersiveStereoLayout =
    if (request?.isRawVideo == true) ImmersiveStereoLayout.MONO else stereoLayout

  /** The coverage the video layer shows: the full sphere for a stitched raw video, the current coverage otherwise. */
  private fun shownVideoCoverage(): ImmersiveSphereCoverage =
    if (request?.isRawVideo == true) ImmersiveSphereCoverage.FULL else coverage

  private fun showVideo(media: MediaRequest) {
    resetSkyboxToIdle()
    skyboxEntity?.setComponent(Visible(false))
    halfSphereEntity?.setComponent(Visible(false))
    // Hidden until the first frame of this video: the surface still holds the last frame of the previous one
    videoRevealed = false
    videoEntity?.setComponent(Visible(false))
    player?.stop()
    // playUrl decides again for this video whether it starts now or once the viewer is back in front
    playOnReturn = false
    // No video until playUrl: the time bar must not show the duration of the previous one meanwhile
    currentVideoUrl = null
    updateProgress()
    applyVideoShape()
    videoFallbackTried = false
    setStatus(getString(R.string.immersive_loading))
    if (ensurePlayer(media.url, media) == null) {
      showError(getString(R.string.immersive_error_video, "player"))
      return
    }
    loadJob =
      scope.launch {
        val playback = fallbackFor(media.url)
        // A raw plan may start on the transcoded stream, a lens plan opens its own urls
        var url = plannedUrl(media)
        val plain = playerPlan?.mode != RawMode.LENSES
        if (plain && playback != null && url == media.url && StreamingLoadControl.isStreamed(media.url) &&
          !isStreamable(media)
        ) {
          // No Range support on /original and the MP4 index at the end: the whole file would have to
          // download before the first frame, the transcoded stream streams
          Log.i(TAG, "original not streamable, using the transcoded stream")
          videoFallbackTried = true
          url = playback
        }
        playUrl(url, media.startPositionMs)
      }
  }

  /** Shows the video panel once the current video has a frame on it, see [videoRevealed]. */
  private fun revealVideo() {
    if (videoRevealed || request?.isVideo != true || currentVideoUrl == null) return
    videoRevealed = true
    videoEntity?.setComponent(Visible(true))
  }

  /** Where a fallback url starts: where the failed one stopped, or the start position it was given. */
  private fun resumePositionMs(): Long = player?.currentPosition?.coerceAtLeast(0L) ?: 0L

  /** Reads the first 64 KB of the original: streamable unless the server ignores Range and moov is last. */
  private suspend fun isStreamable(media: MediaRequest): Boolean =
    try {
      fetch(httpRequest(media.url, range = "bytes=0-65535")) { response ->
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
    } catch (e: CancellationException) {
      throw e
    } catch (e: Throwable) {
      Log.w(TAG, "video probe failed, trying the original anyway", e)
      true
    }

  /** Plays [url] from [startPositionMs] (0 from the beginning). */
  private fun playUrl(url: String, startPositionMs: Long) {
    val p = player ?: return
    currentVideoUrl = url
    decoderChecked = false
    lensDecodersChecked = false
    reprepareOnReturn = false
    decoderWarning = null
    notSeekableShown = false
    hideWhenReady = true
    val kind =
      when {
        url == request?.fallbackUrl || url.contains("/video/playback") -> "playback"
        !url.startsWith("http") -> "local copy"
        else -> "original"
      }
    Log.i(TAG, "play $kind from $startPositionMs ms")
    val lens = twoLens
    val plan = playerPlan
    if (lens != null && plan != null) {
      lens.setMedia(plan.urls, startPositionMs.coerceAtLeast(0L))
    } else {
      p.setMediaItem(MediaItem.fromUri(url), startPositionMs.coerceAtLeast(0L))
    }
    p.prepare()
    // A video that arrives while the viewer is paused or behind the system menu (a previous or next media Flutter
    // answered meanwhile, a fallback url, a recreation) loads but waits, see [playOnReturn]
    val allowed = playbackAllowed()
    p.playWhenReady = allowed
    playOnReturn = !allowed
    if (!allowed) Log.i(TAG, "the viewer is not in front, the video starts once it is")
    updateProgress()
    updateProgressTicker()
    // After the reset of decoderWarning above, so that the READY state keeps the message on screen
    pendingRawMessage?.let {
      pendingRawMessage = null
      showRawWarning(it)
    }
  }

  private fun stopVideo() {
    currentVideoUrl = null
    playOnReturn = false
    stopProgressTicker()
    player?.let {
      it.stop()
      it.clearMediaItems()
    }
    videoRevealed = false
    videoEntity?.setComponent(Visible(false))
    updateProgress()
  }

  private fun togglePlayPause() {
    val p = player ?: return
    if (currentVideoUrl == null) return
    when {
      p.isPlaying -> p.pause()
      playbackAllowed() -> p.play()
      // Not in front: the press decides whether the video starts once the viewer is back, it never plays behind the
      // menu or in a headset nobody wears
      else -> playOnReturn = !playOnReturn
    }
  }

  /** A video plays only while the viewer is resumed and the session focused, see [playOnReturn]. */
  private fun playbackAllowed(): Boolean = resumed && focused

  /**
   * The viewer lost the front: the video pauses, and plays again once the viewer is back if it was playing or about to
   * start. playWhenReady rather than isPlaying, which is false while the video buffers: a menu opened during the
   * loading must not leave the video paused afterwards. A second loss (session state and onPause both report it)
   * keeps what the first one noted, since the player is paused by then.
   */
  private fun holdPlayback() {
    val p = player ?: return
    if (currentVideoUrl != null && p.playWhenReady) playOnReturn = true
    p.pause()
  }

  /**
   * Plays the video held by [holdPlayback] or [playUrl] once the viewer is both resumed and focused. A player whose
   * decoders the headset took back meanwhile prepares again first, at the position it had.
   */
  private fun resumeHeldPlayback() {
    if (!playbackAllowed()) return
    if (reprepareOnReturn) {
      reprepareOnReturn = false
      val p = player
      if (p != null && currentVideoUrl != null) {
        // The player keeps its position in the error state. The one remembered at the last onPause is stale when the
        // viewer only lost the focus (system menu, headset off) and played on since
        val position = p.currentPosition.coerceAtLeast(0L)
        Log.i(TAG, "preparing again after the decoders were reclaimed, at $position ms")
        p.prepare()
        p.seekTo(position)
      }
    }
    if (!playOnReturn) return
    playOnReturn = false
    if (currentVideoUrl != null) player?.play()
  }

  // ---------------------------------------------------------------------------------------------
  // Lifecycle

  /**
   * Pauses the video while the session has no input focus (system menu open, headset off), as recommended in
   * MediaPlayerSample, and plays it again once the focus is back, if the viewer is resumed too.
   */
  override fun onSessionStateChanged(state: SessionState) {
    super.onSessionStateChanged(state)
    Log.i(TAG, "session state $state")
    when (state) {
      SessionState.FOCUSED -> {
        focused = true
        resumeHeldPlayback()
      }
      // A state this SDK does not know says nothing about the focus
      SessionState.UNKNOWN -> Unit
      // Every other OpenXR state is without input focus: VISIBLE behind the system menu, the rest not even visible
      else -> {
        focused = false
        holdPlayback()
      }
    }
  }

  override fun onResume() {
    super.onResume()
    resumed = true
    resumeHeldPlayback()
  }

  override fun onPause() {
    super.onPause()
    resumed = false
    // The system may close the viewer from here on without close(): the closed event then reports this position
    rememberPosition()
    holdPlayback()
  }

  override fun onStop() {
    // Closed by the system (not through Back): Flutter still learns which media was shown last and where it stopped
    if (isFinishing) {
      endNavigation()
      reportClosed()
    }
    super.onStop()
  }

  override fun onDestroy() {
    // Last chance for the closed event when the viewer is finishing (onStop already sent it when it was stopped first).
    // A destroy that is not a finish (a recreation for a configuration change the manifest does not list, or the system
    // tearing down the stopped viewer while keeping its record) is no close: the viewer comes back from its saved
    // state under the same opening, and sends the event when it closes
    if (isFinishing) reportClosed()
    pendingRequestId = null
    navigationTimeoutJob?.cancel()
    navigationTimeoutJob = null
    if (liveViewer === this) liveViewer = null
    scope.cancel()
    super.onDestroy()
  }

  override fun onSpatialShutdown() {
    Log.i(TAG, "immersive viewer shutdown")
    rememberPosition()
    stopProgressTicker()
    pendingRequestId = null
    navigationTimeoutJob?.cancel()
    navigationTimeoutJob = null
    scope.cancel()
    // The player first, then the lens compositor, before the panel goes
    releasePlayer()
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
    private const val EXTRA_START_POSITION_MS = "app.alextran.immich.immersive.START_POSITION_MS"
    private const val EXTRA_OPENING_ID = "app.alextran.immich.immersive.OPENING_ID"
    private const val EXTRA_FALLBACK_URL = "app.alextran.immich.immersive.FALLBACK_URL"
    private const val EXTRA_RAW_PROJECTION = "app.alextran.immich.immersive.RAW_PROJECTION"
    /** The media shown, in the saved state of a recreation, with the same keys as the extras of [intent]. */
    private const val STATE_REQUEST = "app.alextran.immich.immersive.REQUEST"
    private const val ORIGINAL_PREFIX = "immersive_original_"
    private const val INFO_DISTANCE = 1.3f
    private const val INFO_AUTO_HIDE_MS = 4000L
    private const val DECODER_WARNING_HIDE_MS = 10000L

    /**
     * Size of the info panel: its layout in dp, and its quad in meters. Both keep the 1 m for 720 dp of the first
     * panel (720 x 260 dp on 1.0 x 0.36 m) so that the text keeps its size in the headset; the height grew for the
     * time bar and the previous and next buttons (see immersive_info_panel.xml).
     */
    private const val INFO_PANEL_WIDTH_DP = 720f
    private const val INFO_PANEL_HEIGHT_DP = 400f
    private const val INFO_PANEL_WIDTH_M = 1.0f
    private const val INFO_PANEL_HEIGHT_M = INFO_PANEL_WIDTH_M * INFO_PANEL_HEIGHT_DP / INFO_PANEL_WIDTH_DP

    /**
     * The feedback panel: one line, at the same 1 m for 720 dp as the info panel so that the text keeps its size,
     * shown FEEDBACK_SHOW_MS, closer than the info panel and lower, under the line of sight rather than over the image.
     */
    private const val FEEDBACK_PANEL_WIDTH_DP = 420f
    private const val FEEDBACK_PANEL_HEIGHT_DP = 60f
    private const val FEEDBACK_PANEL_WIDTH_M = INFO_PANEL_WIDTH_M * FEEDBACK_PANEL_WIDTH_DP / INFO_PANEL_WIDTH_DP
    private const val FEEDBACK_PANEL_HEIGHT_M = INFO_PANEL_WIDTH_M * FEEDBACK_PANEL_HEIGHT_DP / INFO_PANEL_WIDTH_DP
    private const val FEEDBACK_DISTANCE = 1.0f
    private const val FEEDBACK_DROP = 0.45f
    private const val FEEDBACK_SHOW_MS = 1500L

    /**
     * Size of the swapchain of the video panel. A player that stitches draws into it with OpenGL and is told this size
     * (see attachVideoSurface); the decoder of any other video writes its own size there.
     */
    private const val VIDEO_PANEL_WIDTH_PX = 3840
    private const val VIDEO_PANEL_HEIGHT_PX = 1920

    /** Refresh interval of the time bar while the panel is on screen. */
    private const val PROGRESS_INTERVAL_MS = 500L

    /** Step of the 10 second buttons and of the thumbstick up and down on a video. */
    private const val SEEK_INCREMENT_MS = 10_000L

    /**
     * How long previous and next wait for Flutter's answer before working again. Longer than the 12 seconds Flutter
     * searches at most, so that its own answer (none found) normally comes first: this only covers an answer that
     * never comes, from an app window that is busy, paused or gone.
     */
    private const val ADJACENT_TIMEOUT_MS = 20_000L
    private const val VIDEO_SPHERE_RADIUS = 300f
    /** Mesh of the half sphere of 180° photos, and its radius: the distance of the video sphere. */
    private const val HALF_SPHERE_MESH = "mesh://immersive_half_sphere"
    private const val HALF_SPHERE_RADIUS = 300f

    /**
     * Starting rotation of the photo sphere and of the video sphere around the vertical axis, for every
     * new media. Not verified on a headset: turn the image with the Turn button (or the thumbstick up or
     * down on a photo) until its center faces you, then use the value logged as "photo yaw is now ..." or
     * "video yaw is now ...".
     */
    private const val SKYBOX_YAW_DEGREES = 0f
    private const val VIDEO_YAW_DEGREES = 0f
    private const val YAW_STEP_DEGREES = 90f

    /**
     * The turn of one push of the right thumbstick: a snap turn of the size most headset apps use, small enough to
     * keep the bearings and repeated while the stick is held, so that looking behind takes one long push.
     */
    private const val SNAP_TURN_DEGREES = 30f

    /** Token of the last intent built by [intent], checked by parse. Lives as long as the process. */
    @Volatile private var launchToken: String? = null

    /**
     * The viewer on screen, set in onCreate and cleared in onDestroy, so that [showAdjacent] reaches the viewer that
     * asked. A static reference to an activity is acceptable here: there is one viewer at a time (singleTask), in the
     * process of the app engine that answers, it is only read and written on the main thread, and onDestroy clears
     * it, so a destroyed viewer is never kept alive. A new viewer may start before the old one is destroyed: the old
     * one only clears the reference while it still points to itself.
     */
    @SuppressLint("StaticFieldLeak") private var liveViewer: ImmersiveViewerActivity? = null

    /**
     * Number of the last previous or next request. Counted for the whole process rather than per viewer, so that a
     * late answer meant for a viewer that closed never matches a request of the next one. Main thread only.
     */
    private var lastRequestId = 0L

    private fun nextRequestId(): Long = ++lastRequestId

    /**
     * Flutter's answer to a previous or next request ([ImmersiveApiImpl.showAdjacent]), on the main thread: shows the
     * media in the viewer on screen if it still waits for [requestId]. False, and nothing shown, without such a viewer.
     */
    fun showAdjacent(
      requestId: Long,
      url: String,
      isVideo: Boolean,
      title: String,
      stereoLayout: ImmersiveStereoLayout,
      coverage: ImmersiveSphereCoverage,
      fallbackUrl: String?,
      rawProjection: String?,
    ): Boolean {
      val viewer = liveViewer
      if (viewer == null) {
        Log.i(TAG, "adjacent media for request $requestId refused, no immersive viewer")
        return false
      }
      return viewer.applyAdjacent(requestId, url, isVideo, title, stereoLayout, coverage, fallbackUrl, rawProjection)
    }

    fun intent(
      context: Context,
      url: String,
      isVideo: Boolean,
      title: String,
      stereoLayout: ImmersiveStereoLayout,
      stereoLabels: Map<String, String>,
      coverage: ImmersiveSphereCoverage,
      startPositionMs: Long,
      openingId: Long,
      fallbackUrl: String?,
      rawProjection: String?,
    ): Intent {
      val token = UUID.randomUUID().toString()
      launchToken = token
      val media =
        MediaRequest(
          url = url,
          isVideo = isVideo,
          title = title,
          stereoLayout = stereoLayout,
          stereoLabels = stereoLabels,
          coverage = coverage,
          startPositionMs = startPositionMs,
          openingId = openingId,
          fallbackUrl = fallbackUrl,
          rawProjection = rawProjection,
        )
      return Intent(context, ImmersiveViewerActivity::class.java).apply {
        action = Intent.ACTION_MAIN
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        putExtras(extrasOf(media))
        putExtra(EXTRA_TOKEN, token)
      }
    }

    /** [media] as extras: those of the intent that opens the viewer, and the saved state of a recreation. */
    private fun extrasOf(media: MediaRequest): Bundle {
      val labels = Bundle().apply { media.stereoLabels.forEach { (key, value) -> putString(key, value) } }
      return Bundle().apply {
        putString(EXTRA_URL, media.url)
        putBoolean(EXTRA_IS_VIDEO, media.isVideo)
        putString(EXTRA_TITLE, media.title)
        putInt(EXTRA_STEREO_LAYOUT, media.stereoLayout.raw)
        putBundle(EXTRA_STEREO_LABELS, labels)
        putInt(EXTRA_COVERAGE, media.coverage.raw)
        putLong(EXTRA_START_POSITION_MS, media.startPositionMs)
        putLong(EXTRA_OPENING_ID, media.openingId)
        putString(EXTRA_FALLBACK_URL, media.fallbackUrl)
        putString(EXTRA_RAW_PROJECTION, media.rawProjection)
      }
    }

    /** The media [extrasOf] wrote in [extras], or null without a url. */
    private fun requestOf(extras: Bundle): MediaRequest? {
      val url = extras.getString(EXTRA_URL)
      if (url.isNullOrBlank()) {
        Log.e(TAG, "immersive viewer started without a url")
        return null
      }
      val labels =
        extras.getBundle(EXTRA_STEREO_LABELS)?.let { bundle ->
          bundle.keySet().mapNotNull { key -> bundle.getString(key)?.let { key to it } }.toMap()
        }
      return MediaRequest(
        url = url,
        isVideo = extras.getBoolean(EXTRA_IS_VIDEO, false),
        title = extras.getString(EXTRA_TITLE).orEmpty(),
        stereoLayout =
          ImmersiveStereoLayout.ofRaw(extras.getInt(EXTRA_STEREO_LAYOUT, ImmersiveStereoLayout.MONO.raw))
            ?: ImmersiveStereoLayout.MONO,
        stereoLabels = labels.orEmpty(),
        coverage =
          ImmersiveSphereCoverage.ofRaw(extras.getInt(EXTRA_COVERAGE, ImmersiveSphereCoverage.FULL.raw))
            ?: ImmersiveSphereCoverage.FULL,
        startPositionMs = extras.getLong(EXTRA_START_POSITION_MS, 0L).coerceAtLeast(0L),
        openingId = extras.getLong(EXTRA_OPENING_ID, 0L),
        fallbackUrl = extras.getString(EXTRA_FALLBACK_URL)?.takeIf { it.isNotBlank() },
        rawProjection = extras.getString(EXTRA_RAW_PROJECTION)?.takeIf { it.isNotBlank() },
      )
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
