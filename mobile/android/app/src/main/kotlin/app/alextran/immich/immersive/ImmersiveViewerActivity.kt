package app.alextran.immich.immersive

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import android.view.View
import android.widget.Button
import android.widget.ImageButton
import android.widget.ProgressBar
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
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.MediaExtractorCompat
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import app.alextran.immich.MainActivity
import app.alextran.immich.R
import app.alextran.immich.core.AppHealth
import app.alextran.immich.core.DualFisheyeEffect
import app.alextran.immich.core.HttpClientManager
import app.alextran.immich.core.PlaybackStatsLogger
import app.alextran.immich.core.StreamingLoadControl
import app.alextran.immich.core.PlaybackErrors
import app.alextran.immich.core.VideoDecoders
import app.alextran.immich.core.raw.RawDecoderVerdict
import app.alextran.immich.core.raw.RawMessage
import app.alextran.immich.core.raw.RawMode
import app.alextran.immich.core.raw.RawPlan
import app.alextran.immich.core.raw.RawPlaybackPlanner
import app.alextran.immich.core.raw.RawProjection
import app.alextran.immich.core.raw.RawStitchException
import app.alextran.immich.core.raw.RawTrack
import app.alextran.immich.core.raw.TwoLensPlayback
import app.alextran.immich.djilink.TransientText
import app.alextran.immich.immersive.scene.SceneGate
import app.alextran.immich.immersive.scene.SceneOpener
import app.alextran.immich.immersive.scene.SceneOpening
import app.alextran.immich.immersive.scene.ScenePrepared
import app.alextran.immich.immersive.scene.SceneRefusal
import app.alextran.immich.immersive.scene.SceneSource
import app.alextran.immich.immersive.scene.SceneStop
import app.alextran.immich.immersive.scene.SceneTexts
import app.alextran.immich.immersive.scene.SceneVerdict
import app.alextran.immich.immersive.scene.SceneView
import app.alextran.immich.immersive.scene.SceneViewerOptions
import app.alextran.immich.immersive.splat.GaussianSplatSpec
import app.alextran.immich.immersive.splat.SplatBuild
import app.alextran.immich.immersive.splat.SplatCacheFiles
import app.alextran.immich.immersive.splat.SplatEngines
import app.alextran.immich.immersive.splat.SplatGate
import app.alextran.immich.immersive.splat.SplatPreparation
import app.alextran.immich.immersive.splat.SplatPreparer
import app.alextran.immich.immersive.splat.SplatRefusal
import app.alextran.immich.immersive.splat.SplatStage
import app.alextran.immich.immersive.splat.SplatTexts
import app.alextran.immich.immersive.splat.SplatUprightMemory
import app.alextran.immich.immersive.splat.SplatUprightStore
import app.alextran.immich.immersive.splat.SplatVerdict
import app.alextran.immich.immersive.splat.SplatViewerOptions
import app.alextran.immich.relief.ReliefJob
import app.alextran.immich.relief.ReliefListener
import app.alextran.immich.relief.ReliefRequest
import app.alextran.immich.relief.ReliefResult
import app.alextran.immich.relief.ReliefRun
import app.alextran.immich.relief.ReliefStage
import app.alextran.immich.relief.ReliefStop
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.SpatialFeature
import com.meta.spatial.core.Vector3
import com.meta.spatial.isdk.IsdkSystem
import com.meta.spatial.runtime.AddressMode
import com.meta.spatial.runtime.ButtonBits
import com.meta.spatial.runtime.EquirectLayerConfig
import com.meta.spatial.runtime.Filter
import com.meta.spatial.runtime.MaterialSidedness
import com.meta.spatial.runtime.PanelSceneObject
import com.meta.spatial.runtime.PanelShapeType
import com.meta.spatial.runtime.ReferenceSpace
import com.meta.spatial.runtime.SamplerConfig
import com.meta.spatial.runtime.SceneMaterial
import com.meta.spatial.runtime.SceneMesh
import com.meta.spatial.runtime.SceneTexture
import com.meta.spatial.runtime.SessionState
import com.meta.spatial.runtime.StereoMode
import com.meta.spatial.runtime.TriangleMesh
import com.meta.spatial.toolkit.AppSystemActivity
import com.meta.spatial.toolkit.AvatarSystem
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
import com.meta.spatial.toolkit.Scale
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
import java.io.InputStream
import java.io.RandomAccessFile
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.coroutineContext
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
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
 *
 * An Apple spatial photo comes with its stereoPair JSON (see [StereoPairSpec]): no sphere for it, both eyes are
 * decoded ([StereoHeicDecoder]) and shown side by side on a flat quad 2 m in front of the user, whose material gives
 * each eye its half (StereoMode.LeftRight, the mechanism of the 3D photos on the skybox). The 3D button switches to the
 * left eye for both eyes (MonoLeft), the thumbstick up or down resizes the quad and left or right brings it in front
 * of the gaze again; previous and next are not available for it yet. See [showStereoPhoto].
 *
 * A flat photo holding two eyes side by side comes with the sbsPhoto JSON (see [StereoPhotoKind] and [SbsPhotoSpec]):
 * the same quad, its frame cut in two eyes ([SbsPhoto]). When the file says its relief was estimated by AI (the 3D
 * photos the computers make), the quad says so for a few seconds when it shows in 3D, its 2D button reads "2D
 * (original)" and it stays within 60 degrees; the file of another tool keeps the labels of any stereo photo.
 *
 * A flat photo whose relief the headset estimates comes with the depthRelief JSON: shown flat on the quad at once,
 * then [ReliefJob] makes its right eye on a thread of its own, the stages on the status line under an indeterminate
 * bar, and the 3D button reads "Stop relief" meanwhile; both eyes replace the flat photo once ready. A relief stopped,
 * refused or failed leaves the photo flat with its reason for a few seconds. See [showReliefPhoto].
 *
 * Such a relief can also show in 2.5D (experimental): the photo on a mesh moved by its depth map ([ReliefMesh]), which
 * answers the head as well as the eyes, the quad just behind it as a backdrop for the gaps of the mesh. The 3D button
 * goes from 3D to 2.5D, then 2D; the request says which of 3D or 2.5D comes first (stereo by default, the
 * aiReliefQuestMode setting). The relief fades as the head moves away from where the quad was placed. See
 * [applyStereoPlacement].
 *
 * A photo that carries a 3D scene a computer made from it comes with the volumetricScene JSON (design-final
 * 2026-10-27, section 3, lot S3): its file is read whole into the cache, its JPEG preview shows flat on the quad at
 * once under "Preparing the 3D scene" and the bar, then the scene replaces it once its meshes are made (see
 * [showScene] and [SceneView]): fixed in the world, the left thumbstick glides within the zone the file allows, a click
 * of a thumbstick or Reset in the panel lays it at the head again, the 3D button switches to the photo (2D) and back,
 * the right thumbstick does nothing and previous and next are not offered. A scene the gate or the file refuses leaves
 * the preview flat with the reason for a few seconds. Nothing of the AI is needed to read a scene.
 *
 * A flat 3D media told by its file name (_SBS, _HSBS, _LR, _TB, _OU, Half-SBS and the others, an idea and a first
 * version of Gaurav Mukherjee, gmfun/Immuch360 branch quest/flat-3d) comes with the flat3d JSON (see [FlatStereoSpec]):
 * a photo goes on the stereo quad, its two eyes cut from the frame as it packs them ([FlatStereoPhoto]); a video plays
 * on the flat video screen, a quad compositor layer 2 m in front of the user whose stereo mode gives each eye its half
 * of the frame (LeftRight or UpDown, see [applyFlatVideoShape]), as wide as fits its shape and as high as one
 * eye once the player told the frame size. The 3D button switches it to the first eye for both, the right thumbstick
 * left or right brings it in front of the gaze again, up or down seeks as for any video; previous and next are not
 * offered from it. "3D told by the file name (experimental)" passes once when such a media first shows.
 *
 * An ordinary photo or video opened with "View on a big screen" (an idea of Gaurav Mukherjee, gmfun/Immuch360 branch
 * quest/flat-3d) comes with the bigScreen JSON (see [BigScreenSpec]): the photo goes on the stereo quad as one
 * picture, upright as its EXIF says, the video on the flat video screen, its whole frame for both eyes; each opens as
 * wide as fits its shape in 60 by 40 degrees and plays on its own, without previous or next.
 *
 * A flat screen (a photo of the stereo quad but a relief made in the headset and a 3D scene, a video of the flat video
 * screen) moves and resizes with the grips, as FreeKC chose on 29 October on an idea and a first version of Gaurav
 * Mukherjee (gmfun/Immuch360 branch quest/flat-3d), see [ScreenGrip]: a short grip press still shows or hides the info
 * panel, a grip held 300 ms on the screen grabs it and the screen follows its ray around the eyes, the thumbstick up or
 * down meanwhile takes it farther or nearer, and both grips held resize it with the spread of the hands. Its Size and
 * Distance, each with minus and plus buttons, take the place of previous and next in the info panel; the distance
 * chosen last is kept for the next flat screens. With Sharper flat screens on (experimental, on by default), its
 * photos are drawn on a compositor quad layer with the quality filters of the compositor, see [FlatScreenLayer].
 *
 * A 360° panorama a computer generated beyond the edges of a photo, or its 3D version, is told by our packet at the
 * head of its file, which the viewer reads for every photo on a sphere, the one the app opened as those previous and
 * next reach (design-final 2026-10-27, section 5, lot P4; see [GeneratedPanorama]): the sphere opens with the photo
 * itself where the user looks, "Generated by AI beyond the photo's edges" passes on every path of the sphere and stays
 * in the panel with the flags of the file, and an outline of the photo ([PanoramaOutline]) shows meanwhile. Nothing of
 * the AI is needed to read a panorama.
 *
 * A kiosk opening (Settings, Advanced, "Kiosk mode", lot quest-kiosk) comes with the kiosk JSON (see [KioskOptions]):
 * the media plays for the visitors of an exhibition, the need shown by the exhibition builds of
 * ppawelstachh-sys/Immuch360. [KioskSession] decides what happens: the film starts again from 0:00 on a new player
 * each time the headset is put on, pauses and lets its player go when it comes off, plays once and ends on a card
 * where the visitor looks over a dark sphere, and a failure in its last 15 seconds counts as its end. No info panel,
 * no hands, no controllers and no pointer are drawn, every press is ignored, and only B or Y held one second leaves;
 * a notice says so at the start. See [runKiosk].
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
    /**
     * The stereoPair JSON of a photo shown on the stereo quad rather than on a sphere (see [StereoPhotoKind]): an
     * Apple spatial photo, a side by side photo, a flat photo for an AI relief, a flat 3D photo told by its name. For a
     * video, the flat3d JSON of a flat 3D video (see [flatVideo]). Null for any other media.
     */
    val stereoPairJson: String? = null,
    /**
     * The "Reverse thumbstick turn" setting when the app opened the viewer: the right thumbstick then turns the sphere
     * the other way (see [ImmersiveControls.snapTurnDegrees]). A previous or next media keeps the value of its opening.
     */
    val reverseThumbstickTurn: Boolean = false,
    /**
     * The "Sharper flat screens" setting when the app opened the viewer (experimental, on by default): the photos of a
     * flat screen go on the compositor quad layer and the flat screens get the compositor filters (see
     * [FlatScreenLayer]); off, the photos go on the quad mesh and no filter applies. A previous or next media keeps the
     * value of its opening.
     */
    val sharpFlatScreens: Boolean = true,
    /**
     * The kiosk JSON of the opening (see [KioskOptions]): the media plays for the visitors of an exhibition, see
     * [KioskSession]. Null for any other opening; a kiosk has no previous or next media.
     */
    val kioskJson: String? = null,
    /**
     * What to tell the user about the file Flutter chose for a video, decodability first (chooseVideoSource in Dart): the
     * server's copy plays as the original is beyond the decoder of the headset, or the original as the copy is. Shown
     * once the video plays, as the decoder warning; null for nothing.
     */
    val sourceNotice: String? = null,
    /**
     * Nothing the server has decodes on the headset: what Flutter says of it (the file, the limit, what to change in
     * Immich), said at once instead of a player that stalls; null for a video that may play.
     */
    val sourceRefusal: String? = null,
    /**
     * The "Gaussian splats" setting when the app opened the viewer (experimental, on by default; lot S5): the viewer
     * registers the splat module as it opens only when it is on (see [SplatGate.registers]), so that the module never
     * runs for the users who turned the splats off. A previous or next media keeps the value of its opening.
     */
    val gaussianSplats: Boolean = true,
  ) {
    /** Where this media shows and how its flat screen behaves, see [FlatScreenMedia]: pure, unit tested there. */
    private val screenMedia: FlatScreenMedia by lazy {
      FlatScreenMedia(isVideo, rawProjection, stereoPairJson, sharpFlatScreens)
    }

    /** A raw 360° video, drawn as a mono 360° video whatever the 3D layout and the field of view say. */
    val isRawVideo: Boolean
      get() = screenMedia.isRawVideo

    /** A photo of the stereo quad: in 3D when its JSON reads and both eyes decode, flat otherwise. */
    val isStereoPhoto: Boolean
      get() = screenMedia.isStereoPhoto

    /** What the quad shows, null when the JSON does not read (the photo then shows flat on the quad). */
    val stereoKind: StereoPhotoKind?
      get() = screenMedia.stereoKind

    /** The two eyes of an Apple spatial photo, null for any other kind. */
    val stereoPair: StereoPairSpec?
      get() = (stereoKind as? StereoPhotoKind.HeicPair)?.spec

    /**
     * The angular widths the screen of this media takes (see FlatScreenGeometry.angleBounds): those of the stereo quad
     * for a photo of two eyes, 60 degrees at most for an estimated relief, 15 to 110 for one picture and the flat
     * video screen.
     */
    val screenAngleBounds: ClosedFloatingPointRange<Float>
      get() = screenMedia.angleBounds

    /** A photo that carries a 3D scene, shown by [SceneView] once read, its preview flat on the quad meanwhile. */
    val isScene: Boolean
      get() = stereoKind is StereoPhotoKind.VolumetricScene

    /** A Gaussian splat file of another tool, shown by [SplatStage] with the splat module (lot S5). */
    val isSplat: Boolean
      get() = screenMedia.isSplat

    /** A 3D scene or a splat: the panel and the thumbsticks of a scene (Reset, the glide), no previous or next. */
    val isExplorable: Boolean
      get() = isScene || isSplat

    /** A flat 3D video told by its file name, on the flat video screen, see [FlatScreenMedia.flatVideo]. */
    val flatVideo: FlatStereoSpec?
      get() = screenMedia.flatVideo

    /** An ordinary video opened with "View on a big screen", see [FlatScreenMedia.isBigScreenVideo]. */
    val isBigScreenVideo: Boolean
      get() = screenMedia.isBigScreenVideo

    /** A video of the flat video screen: a flat 3D video, or an ordinary one on the big screen. */
    val isFlatVideo: Boolean
      get() = screenMedia.isFlatVideo

    /** A media opened with "View on a big screen": a photo of the stereo quad, or a video of the flat video screen. */
    val isBigScreen: Boolean
      get() = screenMedia.isBigScreen

    /** A media told 3D by its file name: a video of the flat video screen, or a photo of the stereo quad. */
    val isFlat3d: Boolean
      get() = screenMedia.isFlat3d

    /** A media on a flat screen the user may move and resize, see [FlatScreenMedia.isMovableScreen]. */
    val isMovableScreen: Boolean
      get() = screenMedia.isMovableScreen

    /** A photo drawn on the photo layer rather than on the quad mesh, see [FlatScreenMedia.photoOnLayer]. */
    val photoOnLayer: Boolean
      get() = screenMedia.photoOnLayer

    /** The texts of a kiosk opening, null for any other opening (or a kiosk JSON that does not read). */
    val kiosk: KioskOptions? by lazy { KioskOptions.parse(kioskJson) }
  }

  /**
   * The texture of a spatial photo: both eyes of [eyeWidth] x [eyeHeight] side by side, see StereoComposer, or with
   * [single] one picture alone in its cell (an ordinary photo on the big screen).
   */
  private class StereoTexture(
    val bitmap: Bitmap,
    val eyeWidth: Int,
    val eyeHeight: Int,
    /** Both eyes were decoded: false shows the left eye in 2D. */
    val hasSecondEye: Boolean,
    /** One picture in one cell, no second half: the quad mesh shows it with the stereo mode None. */
    val single: Boolean = false,
    /**
     * The pixels of each eye on [bitmap], its gutter aside: the eye size, or less for the photo layer, whose Surface
     * holds no more (see [fitForLayer]); [eyeWidth] x [eyeHeight] still give the shape of the picture.
     */
    val cellWidth: Int = eyeWidth,
    val cellHeight: Int = eyeHeight,
  )

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
  /**
   * The objects of the scene below (entities, panels, materials, textures, meshes, the Surfaces of the layers) are
   * held through it: they read null from the start of onSpatialShutdown on, so that onPause, onStop and onDestroy,
   * which the SDK runs after its shutdown for a finishing viewer, and whatever comes later touch nothing of a scene
   * gone (see [SpatialHold]). Declared before them.
   */
  private val sceneHold = SpatialHold()
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
  private var skyboxEntity: Entity? by sceneHold.ref()
  private var videoEntity: Entity? by sceneHold.ref()
  private var infoEntity: Entity? by sceneHold.ref()
  /** One line panel below the line of sight for the thumbstick actions, see [showFeedback]. */
  private var feedbackEntity: Entity? by sceneHold.ref()
  private var skyboxMaterial: SceneMaterial? by sceneHold.ref()
  /** Half sphere of 180° photos, shown instead of the skybox. Its material gets the same photo texture. */
  private var halfSphereEntity: Entity? by sceneHold.ref()
  private var halfSphereMaterial: SceneMaterial? by sceneHold.ref()
  /** Our own small copy of the idle gradient. The Material component texture is cached by the SDK. */
  private var idleTexture: SceneTexture? by sceneHold.ref()
  /** The photo texture we created and own. At most one at a time. */
  private var photoTexture: SceneTexture? by sceneHold.ref()
  private var pendingBitmap: Bitmap? = null
  private var infoVisible = false
  private var infoPlaced = false
  /**
   * The eyes and the gaze the info panel was last put in front of, so that it can come nearer than a flat screen
   * brought near meanwhile, where it stands (see [keepPanelsBeforeScreen]).
   */
  private var infoAnchor: Pair<Vector3, Vector3>? = null
  /** Where the info panel stands and its size, scale included, for the grips (see [pointsAtScreen]). */
  private var infoQuad: UprightQuad? = null
  /** The scale of the info panel and of the feedback line: below 1 only before a flat screen nearer than them. */
  private var infoScale = 1f
  private var feedbackScale = 1f
  /** Like [infoAnchor], for the feedback line. */
  private var feedbackAnchor: Pair<Vector3, Vector3>? = null
  private var feedbackDistance = FEEDBACK_DISTANCE
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
  private var videoPanel: PanelSceneObject? by sceneHold.ref()

  // Flat video screen of the flat 3D videos, see showVideo and applyFlatVideoShape
  /** Its entity, made at the first flat 3D video: the second video swapchain only exists once one is shown. */
  private var flatVideoEntity: Entity? by sceneHold.ref()
  /** Its scene object, to change the stereo mode and the size of its quad layer. */
  private var flatVideoPanel: PanelSceneObject? by sceneHold.ref()
  /** The Surface of its swapchain, which the player draws a flat 3D video on. */
  private var flatVideoSurface: Surface? by sceneHold.ref()
  /** Display size of the frames of the flat 3D video playing, as the player told it; null until it does. */
  private var flatVideoSize: Pair<Int, Int>? = null
  /** The screen was placed in front of a known head pose: until then the first pose places it again. */
  private var flatPlacedWithHead = false
  /** The player draws on the flat video screen rather than on the sphere. */
  private var playerOnFlatScreen = false
  /** The angular width the user gave the flat video screen of the video shown, null for as wide as fits its shape. */
  private var flatVideoAngleDeg: Float? = null
  /** "3D told by the file name (experimental)" passed for the media shown, see [announceFlat3d]. */
  private var flat3dAnnounced = false

  // Stereo quad of the spatial photos, see showStereoPhoto
  private var stereoQuadEntity: Entity? by sceneHold.ref()
  private var stereoQuadMaterial: SceneMaterial? by sceneHold.ref()
  /** The texture of the spatial photo on the quad, ours: the previous one is destroyed once a new one is set. */
  private var stereoTexture: SceneTexture? by sceneHold.ref()
  /** A texture decoded before the material of the quad was ready, set once it is. */
  private var pendingStereo: StereoTexture? = null
  /** Size of an eye on the texture shown, without its gutter; null before the first spatial photo. */
  private var stereoEyeSize: Pair<Int, Int>? = null
  /** Angular width of the quad, from the field of view of the photo, then the thumbstick. */
  private var stereoAngleDeg = StereoComposer.DEFAULT_ANGLE_DEG
  /** 3D (each eye its own) or 2D (the left eye for both), the 3D button of the info panel. */
  private var stereo3d = true
  /** Both eyes of the photo shown were decoded. */
  private var stereoHasSecondEye = false
  /** The quad was placed in front of a known head pose: until then the first pose places it again. */
  private var stereoPlacedWithHead = false
  /** Url and opening of the spatial photo that stereo3d and stereoAngleDeg belong to, null before the first one. */
  private var stereoChoicesFor: Pair<String, Long>? = null
  /** The choices on the spatial photo shown before a recreation (see onCreate), taken back once by showStereoPhoto. */
  private var restoredStereoChoices: StereoPhotoChoices? = null
  /** Where the eyes were and where they looked when the quad was last placed: the start pose of the 2.5D view. */
  private var stereoEyes: Vector3? = null
  private var stereoGaze: Vector3? = null
  /** Takes "Relief estimated by AI" off the status line once it was read, see [showReliefEstimated]. */
  private var reliefLabelJob: Job? = null
  /** The status line of the stereo photo shown, under a passing label. */
  private var stereoStatus = ""
  /** The texture shown holds one picture alone (see StereoTexture.single). */
  private var stereoSingle = false
  /**
   * The angular width of the photo shown comes from its first picture, preview or original: an ordinary photo on the
   * big screen opens as wide as fits its shape (see FlatScreenGeometry.fittingAngle), unless a recreation restored it.
   */
  private var stereoSizeFromPicture = false

  // Photo layer: the photos of a flat screen on a compositor quad layer while Sharper flat screens is on, see
  // FlatScreenLayer and drawPhotoLayer
  /** Its entity, made at the first photo that goes on it, and its panel and Surface once the SDK made them. */
  private var photoLayerEntity: Entity? by sceneHold.ref()
  private var photoLayerPanel: PanelSceneObject? by sceneHold.ref()
  private var photoLayerSurface: Surface? by sceneHold.ref()
  /** The photo on the layer, kept to draw it again on a new Surface; null while the layer shows nothing. */
  private var photoLayerTexture: StereoTexture? = null
  /** [photoLayerTexture] is on the Surface. */
  private var photoLayerDrawn = false

  /** Where the flat screen shown stands (a movable photo of the stereo quad, the flat video screen), null before. */
  private var screenPlace: ScreenPlace? = null

  // The grips on a flat screen: a short press shows or hides the info panel, a hold on the screen moves it, both grips
  // resize it (see ScreenGrip; FreeKC's mapping of 29 October on an idea of Gaurav Mukherjee, gmfun/Immuch360 branch
  // quest/flat-3d)
  private val screenGrip = ScreenGrip()
  /** The viewer follows the grips: a movable flat screen shows, see [followScreenGrips]. */
  private var gripsFollowed = false
  /** The grab in progress and the side of its grip, null while no grip holds the screen. */
  private var screenDrag: ScreenDrag? = null
  private var screenDragSide: GripSide? = null
  /** The stretch of both grips, started once both rays are known. */
  private val screenStretch = ScreenStretch()
  private var stretchStarted = false
  /** When the stretch last resized the screen (uptime ms), and the size it still has to take. */
  private var stretchAppliedAt = 0L
  private var stretchPendingAngle: Float? = null
  /** The pose of each controller on this frame, see ImmersiveInputSystem.Listener.onControllerRays. */
  private var controllerRays: Map<GripSide, Pose> = emptyMap()
  /** The hint of the grips, and the word on Sharper flat screens, passed once in this viewer. */
  private var screenHintShown = false
  private var sharpNoticeShown = false

  // AI relief of a flat photo, see showReliefPhoto
  /** The reliefs of this viewer, made at its first depthRelief photo and closed with it. */
  private var reliefJob: ReliefJob? = null
  /** The relief of the photo shown while it runs: the 3D button reads "Stop relief" meanwhile. */
  private var reliefRun: ReliefRun? = null
  /** Puts both eyes of a finished relief on the quad. */
  private var reliefApplyJob: Job? = null
  /** The heat of the headset, watched while the viewer has a relief job. */
  private var thermalWatch: ThermalWatch? = null

  // 2.5D view of a relief, see createReliefMesh and ReliefMesh
  /** The mesh of the 2.5D view, hidden but while a relief shows in 2.5D. */
  private var reliefMeshEntity: Entity? by sceneHold.ref()
  /** Its material, once its scene object is there. */
  private var reliefMeshMaterial: SceneMaterial? by sceneHold.ref()
  /** Its triangles and the scene mesh made of them, written by the mesh creator (volatile in [SpatialHold]). */
  private var reliefTriangles: TriangleMesh? by sceneHold.ref()
  private var reliefSceneMesh: SceneMesh? by sceneHold.ref()
  /** The mesh of the relief shown, null for any other photo and before its relief is made. */
  private var reliefMesh: ReliefMesh? = null
  /** The texture coordinates and the triangles of [reliefMesh] are in the triangles of the scene. */
  private var reliefMeshWritten = false
  /** 2.5D chosen for the relief shown (its request, a recreation, the 3D button): shown once its mesh is there. */
  private var stereo25d = false
  /** The part of the relief the vertices were last placed for, see ReliefMesh.attenuation. */
  private var reliefAttenuation = 1.0
  /** The arrays handed to the triangles, made at the first 2.5D view. */
  private var meshPositions: FloatArray? = null
  private var meshTextureCoordinates: FloatArray? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  // 3D scene of a photo, see showScene and SceneView
  /** The scene of the photo shown, null for any other media and until its textures are decoded. */
  private var sceneView: SceneView? = null
  /** The file of the scene is read, its meshes being made: the bar shows under "Preparing the 3D scene". */
  private var scenePreparing = false
  /** The scene shown rather than its photo (false after "Photo (2D)"). */
  private var sceneChosen = true
  /** The lines the panel keeps for the scene: the honesty sentence, the room to move, the flags of the file. */
  private var sceneDetails: List<String> = emptyList()

  // Gaussian splat of another tool, see showSplat and SplatStage (lot S5)
  /**
   * The splat in the world, made at onSceneReady. Not held by [sceneHold]: no object of the SDK itself, it keeps its
   * entity in its own session, which onSpatialShutdown shuts down (no call on the entity from then on) before letting
   * the stage go.
   */
  private var splatStage: SplatStage? = null
  /** The file of the splat is read, weighed and reduced, or loading: the bar shows under "Preparing the splat". */
  private var splatPreparing = false
  /** The lines the panel keeps for the splat: what the file is, its reduction, or why it is not shown. */
  private var splatDetails: List<String> = emptyList()
  /** "Gaussian splat (experimental)" and the words on the API of the splats passed once in this viewer. */
  private var splatNoticeShown = false
  /**
   * The opening asked for the splat module (the Gaussian splats setting), read in onCreate before super.onCreate
   * registers the features; true until then.
   */
  private var splatModuleWanted = true
  /**
   * The feature of the splat module was registered with this viewer. False, a splat is refused at once with the reason
   * (SplatGate.viewerRefusal) instead of an entity whose load event never comes.
   */
  private var splatModuleRunning = false
  /** The buttons held on the controllers at the last frame, for the glide of the left thumbstick. */
  private var heldButtons = 0
  /** The uptime of the last frame in nanoseconds, 0 before the first one. */
  private var lastFrameNanos = 0L

  // 360° panorama generated beyond the edges of a photo, see GeneratedPanorama and PanoramaOutline
  /** What the head of the photo on the sphere says, null for any other photo and until it is read. */
  private var panoramaHead: PanoramaHead? = null
  /** The head of the photo on the sphere was read (whatever it said): no second read from its downloaded copy. */
  private var panoramaHeadRead = false
  /** The lines the panel keeps for such a panorama: the honesty sentence and the flags of the file. */
  private var panoramaDetails: List<String> = emptyList()
  /** Its sentence passed and its outline showed, once per photo, when its first image was on the sphere. */
  private var panoramaAnnounced = false
  /** The outline of the photo, hidden but for a few seconds at the opening of such a panorama. */
  private var outlineEntity: Entity? by sceneHold.ref()
  /** Its triangles and the scene mesh made of them, written by the mesh creator (volatile in [SpatialHold]). */
  private var outlineTriangles: TriangleMesh? by sceneHold.ref()
  private var outlineSceneMesh: SceneMesh? by sceneHold.ref()
  /** The photo the outline is for, written once its mesh is there. */
  private var outlineRegion: PhotoRegion? = null
  /** The outline is written for the photo shown. */
  private var outlineWritten = false
  /** The white pixel its material samples: the colours of its vertices make it dark or light. */
  private var outlineTexture: SceneTexture? by sceneHold.ref()
  /** Hides the outline once the sentence went. */
  private var outlineJob: Job? = null

  // Info panel views
  private var titleView: TextView? = null
  private var statusView: TextView? = null
  /** Indeterminate bar under the status line while a relief is made. */
  private var reliefProgressView: ProgressBar? = null
  private var hintView: TextView? = null
  /** The lines of a 3D scene under the controller mapping, see [sceneDetails]. */
  private var sceneDetailsView: TextView? = null
  private var navigationRow: View? = null
  private var resetButton: Button? = null
  private var stereoView: Button? = null
  private var coverageView: Button? = null
  /** Turns the sphere by 90 degrees; hidden for a spatial photo, which has no sphere. */
  private var turnButton: View? = null
  private var playPauseButton: Button? = null
  /** Time bar row of a video: 10 seconds back, the bar, the time, 10 seconds forward. Hidden for a photo. */
  private var seekRow: View? = null
  private var seekBar: SeekBar? = null
  private var timeView: TextView? = null
  private var seekBackButton: ImageButton? = null
  private var seekForwardButton: ImageButton? = null
  private var previousButton: Button? = null
  private var nextButton: Button? = null
  /** The Size and the Distance of a movable flat screen, in place of previous and next, see [updateScreenControls]. */
  private var sizeRow: View? = null
  private var sizeView: TextView? = null
  private var sizeLessButton: Button? = null
  private var sizeMoreButton: Button? = null
  private var distanceRow: View? = null
  private var distanceView: TextView? = null
  private var distanceLessButton: Button? = null
  private var distanceMoreButton: Button? = null

  // Kiosk mode, see KioskSession and runKiosk
  /** The kiosk of the opening shown, null for any other opening. */
  private var kiosk: KioskSession? = null
  /** The opening [kiosk] belongs to: a restart keeps it, a new opening from the app gets a kiosk of its own. */
  private var kioskOpeningId: Long? = null
  /** Hands, controllers and the pointer are hidden, see [applyKioskPresentation]. */
  private var kioskPresentation = false
  /**
   * The panel of the exit notice, the end card and the error card, hidden otherwise. Made at the first kiosk opening
   * of this viewer ([ensureKioskPanel]): no panel, layout nor texture for the other openings.
   */
  private var kioskPanelEntity: Entity? by sceneHold.ref()
  private var kioskPanelView: View? = null
  private var kioskTextView: TextView? = null
  /** The text of the kiosk panel, kept for a panel bound after it was asked for. */
  private var kioskText = ""
  /** The exit notice waits for the first head pose, to show in front of the operator. */
  private var pendingKioskNotice: String? = null
  /** Fades the exit notice out, see [showKioskNotice]. */
  private var kioskNoticeJob: Job? = null
  /** What the error card says: the error the viewer could not get around, from [showError]. */
  private var kioskErrorText = ""
  /** The end card or the error card is on: the notice no longer takes the panel. */
  private var kioskCardShown = false

  // Feedback panel
  private var feedbackView: TextView? = null
  /** The text of the feedback panel, kept for a panel bound after it was asked for. */
  private var feedbackText = ""
  /** Hides the feedback panel FEEDBACK_SHOW_MS after its last text. */
  private var feedbackJob: Job? = null
  /** The feedback line shows a notice (see [showNotice]) rather than the answer to a thumbstick. */
  private var noticeShowing = false
  /** Notices waiting for the one on the feedback line to go and the panel to hide, see [queueNotice]. */
  private val pendingNotices = ArrayDeque<String>()

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
  /** The message of a lens tried against the decoder list, shown once its first stitched frame is drawn. */
  private var pendingFirstFrameMessage: RawMessage? = null
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
  private var videoSurface: Surface? by sceneHold.ref()
  private var currentVideoUrl: String? = null
  private var videoFallbackTried = false
  /**
   * The copy plays because the original of this media could not stream (VideoStartRule.Start.FALLBACK) and the
   * original was not tried: beyond the decoder, the copy gives way to it once (VideoStartRule.OverLimit.ORIGINAL).
   */
  private var originalLeftForCopy = false
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
  /**
   * What the viewer does when the video stops in the middle, see [PlaybackRecovery]: one restart where it stopped,
   * the picture that does not come said with the details of the video.
   */
  private val recovery = PlaybackRecovery()
  /** Reads the player every PlaybackRecovery.TICK_MS while a video is loaded, see [watchPicture]. */
  private var recoveryJob: Job? = null
  /** The restart that waits for the media service, see [restartPlayback]; PlaybackRecovery.restartPending meanwhile. */
  private var restartJob: Job? = null
  /**
   * The notice of a picture missing ([sayNoPicture]), shown in place of the details while this url plays, until its
   * frames move again ([pictureBack]).
   */
  private var noPictureNotice: String? = null
  /**
   * A notice the first READY of the url shows in place of its details, the panel in front for a while: the restart
   * of a video, or its switch to the transcoded stream when no picture came.
   */
  private var playbackNotice: String? = null
  /** The frames the video renderer of the current player rendered and dropped at the last read of [watchPicture]. */
  private var watchedFrames = 0
  private var watchedDroppedFrames = 0

  override fun registerFeatures(): List<SpatialFeature> = listOfNotNull(VRFeature(this), splatFeature())

  /**
   * The feature of the splat module (lot S5), registered before any splat entity is made as Meta's SplatSample does:
   * in the quest flavour only, never in the store build (SplatBuild, FreeKC's decision of 30 October 2026), not on a
   * Quest 2 or Pro, which the module does not run on, and only when the opening asked for it (the Gaussian splats
   * setting, see [SplatGate.registers]); null otherwise or when it could not be made, the splats then saying at once
   * that the module is not running.
   */
  private fun splatFeature(): SpatialFeature? {
    splatModuleRunning = false
    val inThisBuild = SplatBuild.offersSplats(this)
    if (!SplatGate.registers(SplatEngines.available, Build.DEVICE, splatModuleWanted, inThisBuild)) {
      val why =
        when {
          !inThisBuild -> "not in this build"
          !splatModuleWanted -> "turned off"
          else -> "not in this APK or headset"
        }
      Log.i(TAG, "splat module not registered: $why")
      return null
    }
    return try {
      SplatEngines.feature(spatialContext, systemManager).also { splatModuleRunning = it != null }
    } catch (e: Throwable) {
      Log.e(TAG, "splat module not registered", e)
      null
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    // super.onCreate registers the features: whether the splat module is wanted is read first, from the media of a
    // recreation or else from the intent that opens the viewer
    splatModuleWanted = gaussianSplatsOf(savedInstanceState?.getBundle(STATE_REQUEST) ?: intent?.extras)
    super.onCreate(savedInstanceState)
    Log.i(TAG, "immersive viewer onCreate, max heap ${Runtime.getRuntime().maxMemory() / 1048576} MB")
    HttpClientManager.initialize(applicationContext)
    cacheDir.listFiles()?.filter { it.name.startsWith(ORIGINAL_PREFIX) || it.name.startsWith(SPLAT_PREFIX) }
      ?.forEach { it.delete() }
    // A recreation goes on with the media shown last: the system hands back the intent that first started the viewer,
    // which knows neither a previous or next media nor a fresh open received in onNewIntent
    val saved = savedInstanceState?.getBundle(STATE_REQUEST)?.let(::requestOf)
    request = saved ?: parse(intent)
    // A spatial photo comes back in 3D or 2D and as wide as the user left it, which showStereoPhoto would reset
    if (savedInstanceState != null && saved != null && savedInstanceState.containsKey(STATE_STEREO_ANGLE_DEG)) {
      restoredStereoChoices =
        StereoPhotoChoices(
          saved.url,
          saved.openingId,
          threeD = savedInstanceState.getBoolean(STATE_STEREO_3D, true),
          angleDeg = savedInstanceState.getFloat(STATE_STEREO_ANGLE_DEG),
          mesh25d = savedInstanceState.getBoolean(STATE_STEREO_25D, false),
        )
    }
    liveViewer = this
  }

  /**
   * Keeps the media shown now for a recreation (see onCreate), with the 3D layout and the field of view on screen (the
   * user's corrections), for a video the position it reached and for a spatial photo its 3D, 2.5D or 2D choice and the
   * width of its quad, so that the new viewer carries on with the same opening as if nothing happened.
   */
  override fun onSaveInstanceState(outState: Bundle) {
    super.onSaveInstanceState(outState)
    val media = request ?: return
    val shown =
      media.copy(
        stereoLayout = shownStereoLayout(media),
        coverage = shownCoverage(media),
        // A kiosk starts again from 0:00: the position is the previous visitor's, see KioskSession.savedStartPositionMs
        startPositionMs = KioskSession.savedStartPositionMs(media.kiosk != null, currentPositionMs(media)),
      )
    outState.putBundle(STATE_REQUEST, extrasOf(shown))
    // The choices on screen once its showStereoPhoto ran (before, they are those of another photo or the defaults),
    // else those of a recreation that did not show it yet
    val choices =
      when {
        !media.isStereoPhoto -> null
        stereoChoicesFor == media.url to media.openingId ->
          StereoPhotoChoices(media.url, media.openingId, stereo3d, stereoAngleDeg, stereo25d)
        else -> restoredStereoChoices?.forPhoto(media.url, media.openingId, media.screenAngleBounds)
      }
    if (choices != null) {
      outState.putBoolean(STATE_STEREO_3D, choices.threeD)
      outState.putFloat(STATE_STEREO_ANGLE_DEG, choices.angleDeg)
      outState.putBoolean(STATE_STEREO_25D, choices.mesh25d)
    }
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
    // Never into a scene gone: the frame loop of the SDK stops with it
    if (sceneHold.isDown) return
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
      createStereoQuad()
      createReliefMesh()
      createSceneMeshes()
      createPanoramaOutline()
      splatStage = SplatStage(SplatEngines, systemManager, mainHandler, splatUprightMemory(), SplatListener())
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
      // The kiosk notice and cards: a few lines, at the same 1 m for 720 dp as the info panel. Its entity, hence its
      // layout and its texture, comes with the first kiosk opening only (ensureKioskPanel)
      LayoutXMLPanelRegistration(
        R.id.immersive_kiosk_panel,
        layoutIdCreator = { R.layout.immersive_kiosk_panel },
        settingsCreator = {
          UIPanelSettings(
            shape = QuadShapeOptions(width = KIOSK_PANEL_WIDTH_M, height = KIOSK_PANEL_HEIGHT_M),
            style = PanelStyleOptions(themeResourceId = R.style.ImmersivePanelTheme),
            display = DpDisplayOptions(width = KIOSK_PANEL_WIDTH_DP, height = KIOSK_PANEL_HEIGHT_DP, dpi = 260),
          )
        },
        panelSetupWithRootView = { rootView, _, _ -> bindKioskPanel(rootView) },
      ),
      // 360 video: equirectangular compositor layer, as in MediaPlayerSample. Created mono, with the coverage of
      // the first media, a stereoscopic video or another coverage reshapes the layer afterwards (applyVideoShape).
      VideoSurfacePanelRegistration(
        R.id.immersive_video_panel,
        surfaceConsumer = { _, surface ->
          Log.i(TAG, "video surface ready")
          videoSurface = surface
          // A flat 3D video plays on the flat video screen, see activeVideoSurface
          player?.let { if (request?.isFlatVideo != true) attachVideoSurface(it, surface) }
          // A video that played without it had its frames skipped, no proof of a decoder problem: watched again
          if (currentVideoUrl != null && request?.isFlatVideo != true) recovery.onSurface()
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
      // Flat video screen (a flat 3D video, a video on the big screen): a quad compositor layer in front of the user,
      // as MediaPlayerSample shows its 3D films, with the quality filters of the compositor (super sampling and
      // sharpening, as Gaurav Mukherjee set them on his flat layers) while Sharper flat screens is on, and behind the
      // panels, as the sphere. Created mono at 16:9; the stereo mode, the size and the filters of each video follow
      // (applyFlatVideoShape). The frame is scaled to the surface, the quad gives each eye its shape back.
      VideoSurfacePanelRegistration(
        R.id.immersive_flat_video_panel,
        surfaceConsumer = { _, surface ->
          Log.i(TAG, "flat video surface ready")
          flatVideoSurface = surface
          player?.let { if (request?.isFlatVideo == true) attachVideoSurface(it, surface) }
          // As for the sphere: a flat video that played without its screen had its frames skipped, watched again
          if (currentVideoUrl != null && request?.isFlatVideo == true) recovery.onSurface()
        },
        settingsCreator = {
          val (width, height) =
            FlatStereo.screenSize(16f / 9f, FlatScreenGeometry.FIT_WIDTH_DEG, FlatScreenGeometry.DEFAULT_DISTANCE_M)
          MediaPanelSettings(
            shape = QuadShapeOptions(width = width, height = height),
            display = PixelDisplayOptions(width = FLAT_VIDEO_PANEL_WIDTH_PX, height = FLAT_VIDEO_PANEL_HEIGHT_PX),
            rendering =
              MediaPanelRenderOptions(
                stereoMode = StereoMode.None,
                layerFilters = FlatScreenLayer.filters(request?.sharpFlatScreens != false),
                zIndex = -1,
              ),
          )
        },
        panelSetup = { panel, _ ->
          flatVideoPanel = panel
          // After the panel creation returns: the flat 3D video waits for this panel
          scope.launch(Dispatchers.Main) {
            applyLayerFilters(panel)
            applyFlatVideoShape()
          }
        },
      ),
      // Photo layer: the photos of a flat screen drawn on the Surface of a quad compositor layer (see drawPhotoLayer),
      // which the compositor samples once, straight to the display, with its quality filters, where the quad mesh goes
      // through the eye buffer first: a sharper photo. An idea and a first version of Gaurav Mukherjee
      // (gmfun/Immuch360, branch quest/flat-3d). Behind the panels, as the sphere; made at the first such photo, shaped
      // for each one (applyPhotoLayerShape).
      VideoSurfacePanelRegistration(
        R.id.immersive_photo_layer_panel,
        surfaceConsumer = { _, surface ->
          Log.i(TAG, "photo layer surface ready")
          runOnUiThread {
            // Posted: the scene may be gone by then
            if (sceneHold.isDown) return@runOnUiThread
            photoLayerSurface = surface
            // A new Surface holds nothing: the photo goes on it again
            photoLayerDrawn = false
            drawPhotoLayer()
          }
        },
        settingsCreator = {
          MediaPanelSettings(
            shape = QuadShapeOptions(width = 1f, height = 0.75f),
            display =
              PixelDisplayOptions(width = FlatScreenLayer.SURFACE_WIDTH_PX, height = FlatScreenLayer.SURFACE_HEIGHT_PX),
            rendering =
              MediaPanelRenderOptions(
                stereoMode = StereoMode.None,
                layerFilters = FlatScreenLayer.filters(request?.sharpFlatScreens != false),
                zIndex = -1,
              ),
          )
        },
        panelSetup = { panel, _ ->
          Log.i(TAG, "photo layer ready")
          photoLayerPanel = panel
          // After the panel creation returns: the photo waits for this panel
          scope.launch(Dispatchers.Main) {
            applyLayerFilters(panel)
            drawPhotoLayer()
          }
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
    // Nothing once the scene is gone: a media would go into entities of no scene
    if (sceneHold.isDown) return
    val media = request
    syncKiosk(media)
    loadJob?.cancel()
    dropRelief()
    dropScene()
    dropSplat()
    dropPanorama()
    reliefLabelJob?.cancel()
    reliefLabelJob = null
    hideInfoJob?.cancel()
    hideInfoJob = null
    endNavigation()
    userSeeking = false
    deferredHideMs = null
    lastKnownPositionMs = null
    rawEffectFailed = false
    rawPlanOverride = null
    pendingRawMessage = null
    pendingFirstFrameMessage = null
    reprepareOnReturn = false
    flat3dAnnounced = false
    // Each media places its own flat screen
    screenPlace = null
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
    if (media.isStereoPhoto) Log.i(TAG, "stereo photo, on the stereo quad: ${media.stereoKind ?: "JSON unreadable"}")
    if (media.isFlatVideo) {
      val what = if (media.isBigScreenVideo) "video on the big screen" else "flat 3D video, ${media.flatVideo}"
      Log.i(TAG, "$what, on the flat video screen")
    }
    titleView?.text = media.title
    updateVideoControls()
    updateStereoView()
    updateCoverageView()
    updateTurnButton()
    updateSceneControls()
    updateScreenControls()
    if (revealInfo) setInfoVisible(true, reposition = true)
    when {
      media.isVideo -> showVideo(media)
      media.isStereoPhoto -> showStereoPhoto(media)
      else -> showPhoto(media)
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Info panel

  private fun bindInfoPanel(root: View) {
    titleView = root.findViewById(R.id.immersive_title)
    statusView = root.findViewById(R.id.immersive_status)
    reliefProgressView = root.findViewById(R.id.immersive_relief_progress)
    setReliefProgress(reliefRun?.running == true || scenePreparing)
    hintView = root.findViewById(R.id.immersive_hint)
    sceneDetailsView = root.findViewById(R.id.immersive_scene_details)
    navigationRow = root.findViewById(R.id.immersive_navigation_row)
    resetButton = root.findViewById(R.id.immersive_reset)
    stereoView = root.findViewById(R.id.immersive_stereo)
    coverageView = root.findViewById(R.id.immersive_coverage)
    turnButton = root.findViewById(R.id.immersive_turn)
    playPauseButton = root.findViewById(R.id.immersive_play_pause)
    seekRow = root.findViewById(R.id.immersive_seek_row)
    seekBar = root.findViewById(R.id.immersive_seek_bar)
    timeView = root.findViewById(R.id.immersive_time)
    seekBackButton = root.findViewById(R.id.immersive_seek_back)
    seekForwardButton = root.findViewById(R.id.immersive_seek_forward)
    previousButton = root.findViewById(R.id.immersive_previous)
    nextButton = root.findViewById(R.id.immersive_next)
    sizeRow = root.findViewById(R.id.immersive_size_row)
    sizeView = root.findViewById(R.id.immersive_size)
    sizeLessButton = root.findViewById(R.id.immersive_size_less)
    sizeMoreButton = root.findViewById(R.id.immersive_size_more)
    distanceRow = root.findViewById(R.id.immersive_distance_row)
    distanceView = root.findViewById(R.id.immersive_distance)
    distanceLessButton = root.findViewById(R.id.immersive_distance_less)
    distanceMoreButton = root.findViewById(R.id.immersive_distance_more)
    root.findViewById<Button>(R.id.immersive_back)?.setOnClickListener { close() }
    // A click from the controller ray or a hand pinch: the panel is on screen, it stays where it is, and a pending
    // auto hide starts again so that the panel does not vanish while the user is using it
    onPanelClick(playPauseButton) { togglePlayPause() }
    onPanelClick(stereoView) { cycleStereoLayout(1, fromPanel = true) }
    onPanelClick(coverageView) { toggleCoverage() }
    onPanelClick(turnButton) { if (request?.isSplat == true) turnSplatUpright() else rotateSphere(YAW_STEP_DEGREES) }
    onPanelClick(seekBackButton) { seekBy(-1) }
    onPanelClick(seekForwardButton) { seekBy(1) }
    onPanelClick(resetButton) { resetScene() }
    onPanelClick(sizeLessButton) { changeScreenSize(-1) }
    onPanelClick(sizeMoreButton) { changeScreenSize(1) }
    onPanelClick(distanceLessButton) { changeScreenDistance(-1) }
    onPanelClick(distanceMoreButton) { changeScreenDistance(1) }
    // Previous and next handle the auto hide themselves: the panel stays until Flutter answers
    previousButton?.setOnClickListener { navigate(-1) }
    nextButton?.setOnClickListener { navigate(1) }
    seekBar?.setOnSeekBarChangeListener(seekBarListener)
    request?.let { media -> titleView?.text = media.title }
    updateVideoControls()
    updateNavigationButtons()
    updateStereoView()
    updateCoverageView()
    updateTurnButton()
    updateSceneControls()
    updateScreenControls()
  }

  /**
   * The rows of a 3D scene in the info panel: its controller mapping in place of the general one, its lines (see
   * [sceneDetails]) under it, Reset once the scene shows; previous and next are not offered there, the left thumbstick
   * gliding instead. A panorama generated beyond the edges of a photo keeps its lines there too (see
   * [panoramaDetails]). A flat screen the grips move and resize gets its own controller mapping; any other media the
   * panel as before.
   */
  private fun updateSceneControls() {
    val media = request
    val scene = media?.isScene == true
    // A splat has the controls of a scene: the glide, Reset, no previous or next (lot S5)
    val splat = media?.isSplat == true
    hintView?.text =
      when {
        scene || splat -> SceneTexts.label(media?.stereoLabels.orEmpty(), SceneTexts.LABEL_HINT)
        // A flat screen the grips move and resize has its own mapping
        media?.isMovableScreen == true -> getString(R.string.immersive_screen_hint)
        else -> getString(R.string.immersive_hint)
      }
    sceneDetailsView?.let { view ->
      val details =
        when {
          scene -> sceneDetails
          splat -> splatDetails
          else -> panoramaDetails
        }
      view.text = details.joinToString("\n")
      view.visibility = if (details.isNotEmpty()) View.VISIBLE else View.GONE
    }
    navigationRow?.visibility = if (scene || splat) View.GONE else View.VISIBLE
    resetButton?.let { button ->
      button.text = SceneTexts.label(media?.stereoLabels.orEmpty(), SceneTexts.LABEL_RESET)
      button.visibility = if (scene || splat) View.VISIBLE else View.GONE
      button.isEnabled = (scene && sceneView?.isReady == true && sceneChosen) || (splat && splatStage?.isShown == true)
    }
  }

  /**
   * The turn button is there for the media shown on a sphere, and for a splat, where it reads "Turn upright" (the next
   * orientation of the file, see SplatUpright) once the splat shows.
   */
  private fun updateTurnButton() {
    val media = request
    val button = turnButton ?: return
    if (media?.isSplat == true) {
      (button as? TextView)?.text = SplatTexts.label(media.stereoLabels, SplatTexts.LABEL_UPRIGHT)
      button.isEnabled = splatStage?.isShown == true
      button.visibility = View.VISIBLE
      return
    }
    (button as? TextView)?.text = getString(R.string.immersive_turn)
    button.isEnabled = true
    val flat = media?.let { it.isStereoPhoto || it.isFlatVideo } == true
    button.visibility = if (flat) View.GONE else View.VISIBLE
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
    // A stitched frame is mono, and so is an ordinary photo or video on the big screen: the layout would change nothing
    if (media == null || media.isRawVideo || media.isBigScreen || media.isSplat) {
      view.visibility = View.GONE
      return
    }
    if (media.isScene) {
      // What shows now, the scene or its photo; greyed while the scene is prepared, and for a scene that stays flat
      val ready = sceneView?.isReady == true
      val key = if (ready && sceneChosen) SceneTexts.LABEL_SCENE_3D else SceneTexts.LABEL_PHOTO_2D
      view.text = SceneTexts.label(media.stereoLabels, if (ready) key else SceneTexts.LABEL_SCENE_3D)
      view.isEnabled = ready
      view.visibility = View.VISIBLE
      return
    }
    view.isEnabled = true
    if (media.isFlatVideo) {
      // 3D, or the first eye for both: what the flat video screen shows now
      val key = if (stereo3d) StereoComposer.LABEL_3D else StereoComposer.LABEL_2D
      view.text = StereoComposer.label(media.stereoLabels, key)
      view.visibility = View.VISIBLE
      return
    }
    if (media.isStereoPhoto) {
      // 3D, 2.5D or 2D (left eye, or the original itself): what the quad shows now; "Stop relief" while a relief runs
      val key =
        if (reliefRun?.running == true) StereoComposer.LABEL_RELIEF_STOP
        else StereoComposer.viewLabelKey(stereoView(), media.stereoKind?.leftEyeIsOriginal == true)
      view.text = StereoComposer.label(media.stereoLabels, key)
      view.visibility = View.VISIBLE
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
    // A stitched frame covers the full sphere, a spatial photo or a flat 3D video no sphere at all
    if (media == null || media.isRawVideo || media.isStereoPhoto || media.isFlatVideo) {
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
    val kiosk = kiosk
    if (kiosk != null) {
      // No panel in a kiosk: the error goes on the card, and the next visitor gets a new try. Often called from the
      // error callback of the player, which the card releases
      Log.w(TAG, "kiosk: $text")
      kioskErrorText = text
      runKioskLater(kiosk.onError())
      return
    }
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
    // A kiosk never shows the panel: no transport over the film, nothing for a visitor to point at
    val show = visible && kiosk == null
    if (!show) {
      // A hidden panel has nothing left to hide, and the drag of its time bar is over even if the bar never reports
      // the end of the touch: a drag left on would hold every later auto hide back
      cancelInfoHide()
      userSeeking = false
    }
    // The panel says it all: the feedback line below it would only cover its buttons
    if (show) hideFeedback()
    val panel = infoEntity ?: return
    if (show && reposition) placeInfoInFront()
    panel.setComponent(Visible(show && infoPlaced))
    infoVisible = show
    updateProgressTicker()
    if (!visible) {
      showScreenHintOnce()
      flushNotices()
    }
  }

  /** Puts the info panel in front of the user, like SplatSample.positionPanelInFrontOfUser. */
  private fun placeInfoInFront() {
    if (infoEntity == null) return
    val head = lastHeadPosition ?: return
    val forward = lastHeadForward ?: Vector3(0f, 0f, 1f)
    infoAnchor = Vector3(head.x, head.y, head.z) to Vector3(forward.x, forward.y, forward.z)
    placeInfo()
  }

  /**
   * The info panel in front of the eyes and the gaze of [infoAnchor], INFO_DISTANCE away and INFO_DROP below the
   * eyes, or nearer than a flat screen brought nearer than that and scaled down to cover the same angles (see
   * FlatScreenGeometry.panelInFront): never behind the screen whose Size and Distance it holds.
   */
  private fun placeInfo() {
    val panel = infoEntity ?: return
    val (head, forward) = infoAnchor ?: return
    val (place, scale) =
      FlatScreenGeometry.panelInFront(head, forward, INFO_DISTANCE, INFO_DROP, nearScreenDistance())
    panel.setComponent(Transform(Pose(place.center, Quaternion.lookRotation(place.direction))))
    if (scale != infoScale) {
      panel.setComponent(Scale(Vector3(scale, scale, 1f)))
      infoScale = scale
      Log.i(TAG, "info panel at ${place.distance} m, scaled $scale, before a flat screen")
    }
    infoQuad = UprightQuad(place, INFO_PANEL_WIDTH_M * scale, INFO_PANEL_HEIGHT_M * scale)
  }

  /** The distance of the movable flat screen of the media shown, null for any other media. */
  private fun nearScreenDistance(): Float? = screenPlace?.distance?.takeIf { request?.isMovableScreen == true }

  /**
   * Every frame: the info panel and the feedback line shown come nearer than a flat screen brought nearer than them
   * (the Distance buttons, a new screen at the distance kept), and go back to their distance once it is farther again,
   * where they were put.
   */
  private fun keepPanelsBeforeScreen() {
    val screen = nearScreenDistance()
    val info = infoQuad
    if (infoVisible && info != null && FlatScreenGeometry.panelDistance(INFO_DISTANCE, screen) != info.place.distance) {
      placeInfo()
    }
    val feedback = feedbackEntity
    if (feedbackJob != null && feedback != null &&
      FlatScreenGeometry.panelDistance(FEEDBACK_DISTANCE, screen) != feedbackDistance
    ) {
      placeFeedback(feedback)
    }
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
  private fun showFeedback(text: String, holdMs: Long = FEEDBACK_SHOW_MS) {
    if (text.isBlank()) return
    feedbackText = text
    feedbackView?.text = text
    val panel = feedbackEntity ?: return
    placeFeedbackInFront(panel)
    feedbackView?.animate()?.cancel()
    feedbackView?.alpha = 1f
    panel.setComponent(Visible(infoPlaced))
    feedbackJob?.cancel()
    noticeShowing = holdMs > FEEDBACK_SHOW_MS
    feedbackJob =
      scope.launch {
        delay(holdMs)
        // A notice fades out, as the passing texts do (TransientText); the answer to a thumbstick just goes
        if (holdMs > FEEDBACK_SHOW_MS) {
          feedbackView?.animate()?.alpha(0f)?.setDuration(TransientText.FADE_OUT_MS)
          delay(TransientText.FADE_OUT_MS)
        }
        feedbackJob = null
        hideFeedback()
        flushNotices()
      }
  }

  /**
   * [text] as a notice on the feedback line, after the one it shows now if any: notices come one after the other, each
   * for TransientText.HOLD_MS, while the info panel is hidden (see [flushNotices]).
   */
  private fun queueNotice(text: String) {
    pendingNotices.addLast(text)
    flushNotices()
  }

  /** The next notice waiting, once the feedback line shows none and the info panel is hidden. */
  private fun flushNotices() {
    if (noticeShowing || infoVisible || closing) return
    pendingNotices.removeFirstOrNull()?.let(::showNotice)
  }

  /**
   * [text] on the feedback panel in front of the user while the info panel is hidden, held TransientText.HOLD_MS then
   * fading out: what a 3D scene says on entering it and at the edge of its zone.
   */
  private fun showNotice(text: String) = showFeedback(text, TransientText.HOLD_MS)

  private fun hideFeedback() {
    feedbackJob?.cancel()
    feedbackJob = null
    noticeShowing = false
    feedbackView?.animate()?.cancel()
    feedbackView?.alpha = 1f
    feedbackEntity?.setComponent(Visible(false))
  }

  /** Like [placeInfoInFront], at FEEDBACK_DISTANCE and FEEDBACK_DROP below the eyes. */
  private fun placeFeedbackInFront(panel: Entity) {
    val head = lastHeadPosition ?: return
    val forward = lastHeadForward ?: Vector3(0f, 0f, 1f)
    feedbackAnchor = Vector3(head.x, head.y, head.z) to Vector3(forward.x, forward.y, forward.z)
    placeFeedback(panel)
  }

  /** Like [placeInfo], for the feedback line at its [feedbackAnchor]. */
  private fun placeFeedback(panel: Entity) {
    val (head, forward) = feedbackAnchor ?: return
    val (place, scale) =
      FlatScreenGeometry.panelInFront(head, forward, FEEDBACK_DISTANCE, FEEDBACK_DROP, nearScreenDistance())
    panel.setComponent(Transform(Pose(place.center, Quaternion.lookRotation(place.direction))))
    if (scale != feedbackScale) {
      panel.setComponent(Scale(Vector3(scale, scale, 1f)))
      feedbackScale = scale
    }
    feedbackDistance = place.distance
  }

  // ---------------------------------------------------------------------------------------------
  // Kiosk mode

  /**
   * Follows the kiosk of [media]: a kiosk opening gets its [KioskSession] (a restart of the same opening keeps it,
   * another opening gets a new one), any other opening none. Hands, controllers and the pointer follow.
   */
  private fun syncKiosk(media: MediaRequest?) {
    if (media == null || media.kiosk == null) {
      if (kiosk != null) Log.i(TAG, "kiosk mode over")
      kiosk = null
      kioskOpeningId = null
      pendingKioskNotice = null
      hideKioskPanel()
    } else if (kiosk == null || kioskOpeningId != media.openingId) {
      Log.i(TAG, "kiosk mode: ${if (media.isVideo) "film" else "photo"} for visitors, B or Y held one second leaves")
      val session = KioskSession(media.isVideo)
      kiosk = session
      kioskOpeningId = media.openingId
      ensureKioskPanel()
      hideKioskPanel()
      runKiosk(session.start())
    }
    applyKioskPresentation(kiosk != null)
  }

  /**
   * Makes the kiosk panel, hidden, at the first kiosk opening of this viewer (syncKiosk runs once the scene is ready).
   * Its layout is inflated and bound ([bindKioskPanel]) when the panel system meets the new entity; the text asked for
   * before that is kept in [kioskText]. Nothing once the scene is down, whoever calls.
   */
  private fun ensureKioskPanel() {
    // The panel reads null from the shutdown on: Entity.create would run on the cleared EntityContext and throw
    if (sceneHold.isDown) return
    if (kioskPanelEntity != null) return
    kioskPanelEntity =
      Entity.createPanelEntity(
        R.id.immersive_kiosk_panel,
        Transform(Pose(Vector3(0f, DEFAULT_EYE_HEIGHT, KIOSK_DISTANCE), Quaternion(0f, 0f, 0f))),
        Visible(false),
      )
    Log.i(TAG, "kiosk: panel made")
  }

  /**
   * [runKiosk] once the callback of the player that reported the event returns: the player is released there, never
   * from within its own listener.
   */
  private fun runKioskLater(commands: List<KioskSession.Command>) {
    if (commands.isEmpty()) return
    mainHandler.post { if (!isDestroyed) runKiosk(commands) }
  }

  /** Does what the kiosk decided, see [KioskSession]. */
  private fun runKiosk(commands: List<KioskSession.Command>) {
    // A post or a headset event may come once the scene is gone: nothing left to show or to restart
    if (sceneHold.isDown) return
    for (command in commands) {
      when (command) {
        KioskSession.Command.SHOW_EXIT_NOTICE -> {
          val hint = request?.kiosk?.exitHint.orEmpty()
          if (hint.isBlank()) continue
          // Before the first head pose the panel would show at a default place, maybe behind the operator
          if (infoPlaced) showKioskNotice(hint) else pendingKioskNotice = hint
        }
        KioskSession.Command.RELEASE_PLAYER -> releaseKioskPlayer()
        KioskSession.Command.RESTART -> restartKiosk()
        KioskSession.Command.SHOW_END_CARD -> showKioskCard(request?.kiosk?.endText.orEmpty())
        KioskSession.Command.SHOW_ERROR_CARD -> showKioskCard(kioskErrorText)
        KioskSession.Command.EXIT -> {
          Log.i(TAG, "kiosk: B or Y held, back to the app")
          close()
        }
      }
    }
  }

  /**
   * The headset came off, or the film is over: the film stops and its player goes, decoders and memory back to the
   * headset (the exhibition builds met a decoder that no longer recovered after a long run). [restartKiosk] builds a
   * new one for the next visitor.
   */
  private fun releaseKioskPlayer() {
    loadJob?.cancel()
    rememberPosition()
    stopProgressTicker()
    stopRecoveryWatch()
    cancelRestart()
    cancelInfoHide()
    playOnReturn = false
    reprepareOnReturn = false
    currentVideoUrl = null
    releasePlayer()
    videoRevealed = false
    videoEntity?.setComponent(Visible(false))
    Log.i(TAG, "kiosk: player released")
  }

  /** The next visitor: the card goes, the media shows again from the start, a film on a new player. */
  private fun restartKiosk() {
    hideKioskPanel()
    val media = request ?: return
    Log.i(TAG, "kiosk: the next visitor, ${if (media.isVideo) "the film from 0:00" else "the photo again"}")
    request = media.copy(startPositionMs = 0L)
    if (sceneReady) showRequest(revealInfo = false)
  }

  /**
   * The end card, or the error card with [text]: a dark sphere all around, nothing of the media left (neither the last
   * frame of the film nor the photo), and the card in the direction the visitor looks, until the next restart.
   */
  private fun showKioskCard(text: String) {
    kioskNoticeJob?.cancel()
    kioskNoticeJob = null
    pendingKioskNotice = null
    loadJob?.cancel()
    hideFeedback()
    videoRevealed = false
    videoEntity?.setComponent(Visible(false))
    hideStereoQuad()
    try {
      val dark = Bitmap.createBitmap(16, 8, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLACK) }
      applySkyboxBitmap(dark)
    } catch (e: Exception) {
      Log.e(TAG, "kiosk: the dark sphere failed, the card shows over what is there", e)
    }
    halfSphereEntity?.setComponent(Visible(false))
    skyboxEntity?.setComponent(Visible(true))
    kioskCardShown = true
    setKioskText(text)
    kioskPanelView?.animate()?.cancel()
    kioskPanelView?.alpha = 1f
    placeKioskPanel(followGaze = true)
    kioskPanelEntity?.setComponent(Visible(true))
    Log.i(TAG, "kiosk: card shown until the next visitor puts the headset on")
  }

  /**
   * The exit notice at the start of a kiosk: in front of the operator, a little below the line of sight, held
   * TransientText.HOLD_MS, then fading out.
   */
  private fun showKioskNotice(text: String) {
    if (kioskCardShown) return
    setKioskText(text)
    kioskPanelView?.animate()?.cancel()
    kioskPanelView?.alpha = 1f
    placeKioskPanel(followGaze = false)
    kioskPanelEntity?.setComponent(Visible(true))
    kioskNoticeJob?.cancel()
    kioskNoticeJob =
      scope.launch {
        delay(TransientText.HOLD_MS)
        kioskPanelView?.animate()?.alpha(0f)?.setDuration(TransientText.FADE_OUT_MS)
        delay(TransientText.FADE_OUT_MS)
        kioskNoticeJob = null
        if (!kioskCardShown) hideKioskPanel()
      }
  }

  private fun hideKioskPanel() {
    kioskNoticeJob?.cancel()
    kioskNoticeJob = null
    kioskCardShown = false
    kioskPanelView?.animate()?.cancel()
    kioskPanelView?.alpha = 1f
    kioskPanelEntity?.setComponent(Visible(false))
  }

  /**
   * Puts the kiosk panel KIOSK_DISTANCE away from the eyes: in the very direction they look for a card
   * ([followGaze]), upwards or downwards included, or level and KIOSK_NOTICE_DROP lower for the notice. A default
   * place before any head pose.
   */
  private fun placeKioskPanel(followGaze: Boolean) {
    val panel = kioskPanelEntity ?: return
    val head = lastHeadPosition ?: Vector3(0f, DEFAULT_EYE_HEIGHT, 0f)
    val forward = lastHeadForward ?: Vector3(0f, 0f, 1f)
    val direction =
      if (followGaze) {
        val length = sqrt(forward.x * forward.x + forward.y * forward.y + forward.z * forward.z)
        if (length < 1e-3f) Vector3(0f, 0f, 1f) else Vector3(forward.x / length, forward.y / length, forward.z / length)
      } else {
        val flat = sqrt(forward.x * forward.x + forward.z * forward.z)
        if (flat < 1e-3f) Vector3(0f, 0f, 1f) else Vector3(forward.x / flat, 0f, forward.z / flat)
      }
    val position = head + (direction * KIOSK_DISTANCE)
    if (!followGaze) position.y = head.y - KIOSK_NOTICE_DROP
    panel.setComponent(Transform(Pose(position, Quaternion.lookRotation(direction))))
  }

  private fun bindKioskPanel(root: View) {
    kioskPanelView = root
    kioskTextView = root.findViewById(R.id.immersive_kiosk_text)
    kioskTextView?.text = kioskText
  }

  private fun setKioskText(text: String) {
    kioskText = text
    kioskTextView?.text = text
  }

  /**
   * Hands and controllers hidden ([AvatarSystem]) and no pointer ([IsdkSystem] inactive) in a kiosk, both back for any
   * other opening. The exhibition builds turned the same two off and kept B or Y for their exit, read from the
   * Controller components that [ImmersiveInputSystem] polls, as here.
   */
  private fun applyKioskPresentation(on: Boolean) {
    if (on == kioskPresentation) return
    kioskPresentation = on
    try {
      systemManager.findSystem<AvatarSystem>().apply {
        setShowHands(!on)
        setShowControllers(!on)
      }
    } catch (e: Exception) {
      Log.w(TAG, "kiosk: hands and controllers left as they are", e)
    }
    try {
      systemManager.findSystem<IsdkSystem>().active = !on
    } catch (e: Exception) {
      Log.w(TAG, "kiosk: pointer left as it is", e)
    }
    Log.i(TAG, "kiosk: hands, controllers and pointer ${if (on) "hidden" else "shown"}")
  }

  /** A kiosk plays its film once (its end shows the card), any other video loops as before. */
  private fun repeatModeFor(media: MediaRequest?): Int =
    if (media?.kiosk != null) Player.REPEAT_MODE_OFF else Player.REPEAT_MODE_ONE

  // ---------------------------------------------------------------------------------------------
  // Frame and input

  override fun onButtonsHeld(controllerBits: Int) {
    heldButtons = controllerBits
    // The only way out of a kiosk: B or Y held, see KioskSession.onExitButtons
    val kiosk = kiosk ?: return
    runKiosk(kiosk.onExitButtons((controllerBits and KIOSK_EXIT_BITS) != 0, SystemClock.uptimeMillis()))
  }

  override fun wantsControllerRays(): Boolean = gripsFollowed

  override fun onControllerRays(rays: Map<GripSide, Pose>) {
    controllerRays = rays
  }

  override fun onFrame(head: Pose?) {
    val now = System.nanoTime()
    val seconds = if (lastFrameNanos == 0L) 0.0 else (now - lastFrameNanos) / 1e9
    lastFrameNanos = now
    if (head != null && (head.t.x != 0f || head.t.y != 0f || head.t.z != 0f)) {
      lastHeadPosition = Vector3(head.t.x, head.t.y, head.t.z)
      lastHeadForward = head.forward()
      centerSpheresOnHead(head.t)
      // A spatial photo shown before the first head pose goes in front of the user once it is known
      if (!stereoPlacedWithHead && stereoEyeSize != null && request?.isStereoPhoto == true) placeStereoQuad()
      // So does the flat video screen
      if (!flatPlacedWithHead && request?.isFlatVideo == true) placeFlatVideo()
      if (reliefMeshShown) followHeadWithRelief(head.t)
      // A 3D scene: the glide, the edge, its root fixed in the world, laid at the head at its first frame
      sceneView?.onFrame(head, heldButtons, seconds)
      // A splat: the glide, Reset and Turn upright (lot S5)
      splatStage?.onFrame(head, heldButtons, seconds)
    }
    followScreenGrips()
    keepPanelsBeforeScreen()
    if (infoPlaced) return
    if (lastHeadPosition != null || ++framesWithoutHead > 180) {
      if (lastHeadPosition == null) Log.w(TAG, "no head pose after 180 frames, default info panel position")
      infoPlaced = true
      setInfoVisible(infoVisible, reposition = true)
      pendingKioskNotice?.let {
        pendingKioskNotice = null
        showKioskNotice(it)
      }
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
    // The outline turns with the photo: its frame is the panorama with the centre column ahead (see PanoramaOutline)
    outlineEntity?.setComponent(
      Transform(Pose(Vector3(center.x, center.y, center.z), Quaternion(0f, photoYaw - SKYBOX_YAW_DEGREES, 0f))),
    )
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
    if (media.isRawVideo || media.isBigScreen) return
    if (media.isStereoPhoto) {
      toggleStereoPhotoMode(fromPanel)
      return
    }
    if (media.isFlatVideo) {
      // 3D, or the first eye for both
      stereo3d = !stereo3d
      Log.i(TAG, "flat 3D video is now in ${if (stereo3d) "3D" else "2D"}")
      applyFlatVideoShape()
      updateStereoView()
      showControlChange(fromPanel)
      return
    }
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
    if (media.isRawVideo || media.isStereoPhoto || media.isFlatVideo) return
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
    if (kiosk != null) {
      // A kiosk takes no press: no play or pause, no panel, no turn, no seek, no other media. B or Y held one second
      // leaves (onButtonsHeld). A press still proves the input focus, as below
      if (!focused) {
        Log.w(TAG, "button press while the session was not reported focused: taken as focused (resumed=$resumed)")
        focused = true
        resumeHeldPlayback()
      }
      return
    }
    val actions =
      ImmersiveControls.actionsFor(
        controllerBits,
        handBits,
        infoVisible,
        scene = request?.isExplorable == true,
        // A flat screen leaves its grips to ScreenGrip, and a hand that holds it moves it nearer or farther
        screenGrabbable = gripsFollowed,
        screenHeld = screenGrip.grabbing != null || screenGrip.stretching,
      )
    if (!focused) {
      Log.w(TAG, "button press while the session was not reported focused: taken as focused (resumed=$resumed)")
      focused = true
      // The trigger of this very press decides about the held video itself: resuming it here would make the same
      // press pause it again
      if (ImmersiveControls.Action.PLAY_PAUSE in actions) playOnReturn = false else resumeHeldPlayback()
    }
    val isVideo = request?.isVideo == true
    // A spatial photo has no sphere to turn: the thumbstick sizes and places its quad instead
    val isStereoPhoto = request?.isStereoPhoto == true
    // Nor has a flat 3D video: the right thumbstick brings its screen in front instead, up and down seek as for any
    // video
    val isFlatVideo = request?.isFlatVideo == true
    for (action in actions) {
      when (action) {
        ImmersiveControls.Action.CLOSE -> {
          close()
          return
        }
        ImmersiveControls.Action.PREVIOUS -> navigate(-1, fromThumbstick = true)
        ImmersiveControls.Action.NEXT -> navigate(1, fromThumbstick = true)
        ImmersiveControls.Action.TURN_LEFT,
        ImmersiveControls.Action.TURN_RIGHT ->
          if (isStereoPhoto) {
            placeStereoQuad()
          } else if (isFlatVideo) {
            placeFlatVideo()
          } else {
            val reversed = request?.reverseThumbstickTurn == true
            turnFromThumbstick(ImmersiveControls.snapTurnDegrees(action, SNAP_TURN_DEGREES, reversed))
          }
        ImmersiveControls.Action.STICK_UP ->
          when {
            isVideo -> seekFromThumbstick(1)
            isStereoPhoto -> if (request?.isMovableScreen == true) changeScreenSize(1) else resizeStereoQuad(1)
            else -> turnFromThumbstick(YAW_STEP_DEGREES)
          }
        ImmersiveControls.Action.STICK_DOWN ->
          when {
            isVideo -> seekFromThumbstick(-1)
            isStereoPhoto -> if (request?.isMovableScreen == true) changeScreenSize(-1) else resizeStereoQuad(-1)
            else -> turnFromThumbstick(-YAW_STEP_DEGREES)
          }
        ImmersiveControls.Action.SCREEN_FARTHER -> changeScreenDistance(1)
        ImmersiveControls.Action.SCREEN_NEARER -> changeScreenDistance(-1)
        ImmersiveControls.Action.TOGGLE_PANEL -> {
          // A panel opened by the user stays until the user hides it
          cancelInfoHide()
          setInfoVisible(!infoVisible, reposition = true)
        }
        ImmersiveControls.Action.SHOW_PANEL -> setInfoVisible(true, reposition = true)
        ImmersiveControls.Action.PLAY_PAUSE -> togglePlayPause()
        ImmersiveControls.Action.RESET -> resetScene()
      }
    }
  }

  @Deprecated("Deprecated in Java")
  override fun onBackPressed() {
    if (kiosk != null) {
      Log.i(TAG, "kiosk: Back ignored, B or Y held one second leaves")
      return
    }
    close()
  }

  // ---------------------------------------------------------------------------------------------
  // Flat screens: moved with a grip held on them, resized with both grips or the Size buttons, brought nearer or
  // farther with the thumbstick while held or the Distance buttons (FreeKC's mapping of 29 October, on an idea and a
  // first version of Gaurav Mukherjee, gmfun/Immuch360 branch quest/flat-3d)

  /**
   * Every frame: the grips of the movable flat screen shown (see [ScreenGrip]), what they start or end, the screen
   * following the ray of the grip that holds it, or the spread of both hands. The grips start again from what they
   * hold when such a screen comes or goes, so that a press made elsewhere does nothing here.
   */
  private fun followScreenGrips() {
    val place = screenPlace
    val size = screenSize()
    val follow = place != null && size != null
    if (follow != gripsFollowed) {
      gripsFollowed = follow
      handleGripEvents(screenGrip.reset(heldButtons))
      if (!follow) controllerRays = emptyMap()
      Log.i(TAG, if (follow) "flat screen shown, the grips move it" else "no flat screen to move")
      if (follow) showScreenHintOnce()
    }
    if (place == null || size == null) return
    val now = SystemClock.uptimeMillis()
    val events = screenGrip.update(now, heldButtons) { side -> pointsAtScreen(side, place, size) }
    handleGripEvents(events)
    moveWithGrip()
    stretchWithGrips()
  }

  /**
   * Whether the ray of the controller of [side] points at the screen at [place], [size] meters, and not at the info
   * panel shown: a finger resting on the grip while the trigger clicks Size or Distance drags nothing.
   */
  private fun pointsAtScreen(side: GripSide, place: ScreenPlace, size: Pair<Float, Float>): Boolean {
    val ray = controllerRays[side] ?: return false
    val panel = infoQuad?.takeIf { infoVisible && infoPlaced }
    return FlatScreenGeometry.grabs(UprightQuad(place, size.first, size.second), ray.t, ray.forward(), panel)
  }

  private fun handleGripEvents(events: List<ScreenGrip.Event>) {
    for (event in events) {
      when (event) {
        ScreenGrip.Event.TogglePanel -> {
          // As A or X: a panel opened by the user stays until the user hides it
          cancelInfoHide()
          setInfoVisible(!infoVisible, reposition = true)
        }
        is ScreenGrip.Event.GrabStart -> startDrag(event.side)
        is ScreenGrip.Event.GrabEnd -> endDrag()
        ScreenGrip.Event.StretchStart -> {
          // Started once both rays are known, see stretchWithGrips
          stretchStarted = false
          stretchPendingAngle = null
        }
        ScreenGrip.Event.StretchEnd -> endStretch()
      }
    }
  }

  /** The grip of [side] holds the screen: it follows that ray from now on, see [ScreenDrag]. */
  private fun startDrag(side: GripSide) {
    val place = screenPlace ?: return
    val ray = controllerRays[side] ?: return
    screenDrag = ScreenDrag(place, ray.t, ray.forward())
    screenDragSide = side
    Log.i(TAG, "flat screen grabbed with the ${side.name.lowercase()} grip at $place")
  }

  private fun endDrag() {
    if (screenDrag == null) return
    screenDrag = null
    screenDragSide = null
    Log.i(TAG, "flat screen let go at $screenPlace")
  }

  /** While a grip holds the screen, the screen where its ray points now. */
  private fun moveWithGrip() {
    val drag = screenDrag ?: return
    val ray = controllerRays[screenDragSide ?: return] ?: return
    screenPlace = drag.place(ray.t, ray.forward()) ?: return
    applyScreenPlace()
  }

  /**
   * While both grips are held: the width of the screen follows the spread of the hands (see [ScreenStretch]), to the
   * degree. Each new width reshapes a compositor layer, so one at most every STRETCH_INTERVAL_MS; the last one waits
   * for the release of a grip if need be.
   */
  private fun stretchWithGrips() {
    if (!screenGrip.stretching) return
    val left = controllerRays[GripSide.LEFT] ?: return
    val right = controllerRays[GripSide.RIGHT] ?: return
    val place = screenPlace ?: return
    val angle = currentScreenAngle() ?: return
    val spread = left.t.distanceTo(right.t)
    if (!stretchStarted) {
      screenStretch.start(spread, FlatScreenGeometry.width(angle, place.distance))
      stretchStarted = true
      Log.i(TAG, "flat screen stretched, hands $spread m apart")
      return
    }
    val width = screenStretch.width(spread) ?: return
    val wanted =
      FlatScreenGeometry.angleForWidth(width, place.distance)
        .coerceIn(screenAngleBounds())
        .roundToInt()
        .toFloat()
    if (abs(wanted - angle) < 1f) {
      stretchPendingAngle = null
      return
    }
    val now = SystemClock.uptimeMillis()
    if (now - stretchAppliedAt < STRETCH_INTERVAL_MS) {
      stretchPendingAngle = wanted
      return
    }
    stretchAppliedAt = now
    stretchPendingAngle = null
    setScreenAngle(wanted)
  }

  private fun endStretch() {
    screenStretch.end()
    stretchStarted = false
    stretchPendingAngle?.let { setScreenAngle(it) }
    stretchPendingAngle = null
  }

  /**
   * Width and height in meters of the movable flat screen shown, null when none shows: a photo once decoded, a video
   * once its first frame is on the screen.
   */
  private fun screenSize(): Pair<Float, Float>? {
    val media = request ?: return null
    val place = screenPlace ?: return null
    if (!media.isMovableScreen) return null
    if (media.isFlatVideo) {
      if (!videoRevealed) return null
      val aspect = flatVideoLook()?.second ?: return null
      return FlatStereo.screenSize(aspect, flatVideoAngle(aspect), place.distance)
    }
    val (eyeWidth, eyeHeight) = stereoEyeSize ?: return null
    return FlatScreenLayer.quadSize(stereoAngleDeg, eyeWidth, eyeHeight, place.distance)
  }

  /** The angular width of the movable flat screen shown ("Size 48°"), null when none shows. */
  private fun currentScreenAngle(): Float? {
    val media = request ?: return null
    if (!media.isMovableScreen || screenPlace == null) return null
    return when {
      media.isFlatVideo -> flatVideoLook()?.let { flatVideoAngle(it.second) }
      stereoEyeSize != null -> stereoAngleDeg
      else -> null
    }
  }

  /**
   * The angular widths of the screen shown, the same for the Size buttons, the thumbstick, the stretch and a change of
   * distance: 30 to 90 degrees for a photo of two eyes (60 at most for an estimated relief), 15 to 110 for one picture
   * and the flat video screen (see FlatScreenGeometry.angleBounds).
   */
  private fun screenAngleBounds(): ClosedFloatingPointRange<Float> =
    request?.screenAngleBounds ?: FlatScreenGeometry.ONE_PICTURE_ANGLES

  /** The screen shown [angleDeg] wide, where it is; said on the panel or the feedback line with [report]. */
  private fun setScreenAngle(angleDeg: Float, report: Boolean = true) {
    val media = request ?: return
    when {
      media.isFlatVideo -> {
        flatVideoAngleDeg = angleDeg
        applyFlatVideoShape()
      }
      stereoEyeSize != null -> {
        stereoAngleDeg = angleDeg
        applyStereoScale()
      }
      else -> return
    }
    Log.i(TAG, "flat screen is now $angleDeg degrees wide")
    updateScreenControls()
    if (report) reportScreenChange(sizeText(angleDeg))
  }

  /** The Size buttons and the thumbstick up or down on a photo: a larger ([step] 1) or smaller (-1) screen. */
  private fun changeScreenSize(step: Int) {
    val angle = currentScreenAngle() ?: return
    setScreenAngle(FlatScreenGeometry.nextAngle(angle, step, screenAngleBounds()))
  }

  /**
   * The Distance buttons and the thumbstick up or down while a grip holds the screen: the screen farther ([step] 1) or
   * nearer (-1) on the line it stands on, the same width in meters, so that it looks larger nearer. The distance is
   * kept for the next flat screens, and a grab in progress goes on from there.
   */
  private fun changeScreenDistance(step: Int) {
    val place = screenPlace ?: return
    val angle = currentScreenAngle() ?: return
    val distance = FlatScreenGeometry.nextDistance(place.distance, step)
    if (distance != place.distance) {
      val moved = place.at(distance)
      screenPlace = moved
      screenDistanceM = distance
      val kept = FlatScreenGeometry.angleAtDistance(angle, place.distance, distance, screenAngleBounds())
      setScreenAngle(kept, report = false)
      applyScreenPlace()
      screenDragSide?.let { side ->
        controllerRays[side]?.let { ray -> screenDrag = ScreenDrag(moved, ray.t, ray.forward()) }
      }
      Log.i(TAG, "flat screen is now $distance m away")
    }
    updateScreenControls()
    reportScreenChange(distanceText(distance))
  }

  /** The screen shown at [screenPlace]: the flat video screen, or the photo layer or the quad mesh. */
  private fun applyScreenPlace() {
    val place = screenPlace ?: return
    if (request?.isFlatVideo == true) placeFlatScreen(place) else applyStereoPlacement()
  }

  /** A change of the flat screen on the status line of the panel, or on the feedback line when the panel is hidden. */
  private fun reportScreenChange(text: String) {
    if (infoVisible) setStatus(text) else showFeedback(text)
  }

  /** "Size 48°". */
  private fun sizeText(angleDeg: Float): String = getString(R.string.immersive_size, angleDeg.roundToInt())

  /** "Distance 1.5 m", the number as the language of the headset writes it. */
  private fun distanceText(distance: Float): String =
    getString(R.string.immersive_distance, FlatScreenGeometry.meters(distance, Locale.getDefault()))

  /**
   * The Size and Distance rows take the place of previous and next for a movable flat screen (which plays on its own,
   * the thumbstick still saying so), once it shows; a minus or plus button at its bound is disabled.
   */
  private fun updateScreenControls() {
    val movable = request?.isMovableScreen == true
    previousButton?.visibility = if (movable) View.GONE else View.VISIBLE
    nextButton?.visibility = if (movable) View.GONE else View.VISIBLE
    val angle = currentScreenAngle()
    val place = screenPlace
    if (angle == null || place == null) {
      sizeRow?.visibility = View.GONE
      distanceRow?.visibility = View.GONE
      return
    }
    sizeView?.text = sizeText(angle)
    distanceView?.text = distanceText(place.distance)
    val bounds = screenAngleBounds()
    sizeLessButton?.isEnabled = angle > bounds.start + 1e-3f
    sizeMoreButton?.isEnabled = angle < bounds.endInclusive - 1e-3f
    distanceLessButton?.isEnabled = place.distance > FlatScreenGeometry.DISTANCES_M.first() + 1e-3f
    distanceMoreButton?.isEnabled = place.distance < FlatScreenGeometry.DISTANCES_M.last() - 1e-3f
    sizeRow?.visibility = View.VISIBLE
    distanceRow?.visibility = View.VISIBLE
  }

  /**
   * "Hold a grip on the screen to move it, both grips to resize it" once in this viewer, on the feedback line for
   * TransientText.HOLD_MS, the first time a movable flat screen shows with the panel hidden (the panel says the whole
   * mapping meanwhile).
   */
  private fun showScreenHintOnce() {
    if (screenHintShown || infoVisible || closing || !gripsFollowed) return
    screenHintShown = true
    queueNotice(getString(R.string.immersive_screen_hint_short))
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
    val shown = request
    if (shown != null && (shown.isFlatVideo || shown.isBigScreen)) {
      // Opened alone from the app: said rather than asked
      val key =
        if (shown.isBigScreen) StereoComposer.LABEL_BIG_SCREEN_NO_NAVIGATION
        else StereoComposer.LABEL_FLAT3D_NO_NAVIGATION
      val text = StereoComposer.label(shown.stereoLabels, key)
      Log.i(TAG, "no previous or next from a flat video or the big screen (step $step)")
      if (fromThumbstick && !infoVisible) showFeedback(text) else setStatus(text)
      return
    }
    if (shown != null && shown.isStereoPhoto) {
      // Flutter finds no spatial or 3D photo before or after this one yet: said rather than asked
      val key =
        when (shown.stereoKind) {
          is StereoPhotoKind.Sbs,
          is StereoPhotoKind.Flat,
          is StereoPhotoKind.DepthRelief,
          is StereoPhotoKind.VolumetricScene -> StereoComposer.LABEL_NO_NAVIGATION_3D
          else -> StereoComposer.LABEL_NO_NAVIGATION
        }
      val text = StereoComposer.label(shown.stereoLabels, key)
      Log.i(TAG, "no previous or next from a spatial photo (step $step)")
      if (fromThumbstick && !infoVisible) showFeedback(text) else setStatus(text)
      return
    }
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
    stereoPair: String?,
    sourceNotice: String? = null,
    sourceRefusal: String? = null,
  ): Boolean {
    if (closing || isFinishing || isDestroyed || sceneHold.isDown) {
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
        stereoPairJson = stereoPair,
        reverseThumbstickTurn = current.reverseThumbstickTurn,
        sharpFlatScreens = current.sharpFlatScreens,
        sourceNotice = sourceNotice,
        sourceRefusal = sourceRefusal,
        gaussianSplats = current.gaussianSplats,
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
    releaseRelief()
    dropScene()
    dropPanorama()
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
        if (sceneHold.isDown) return@runOnUiThread
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
        if (sceneHold.isDown) return@runOnUiThread
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
   * the skybox otherwise (360° photos, and the idle sky while the first image loads). Nothing changes for a video, nor
   * for a spatial photo, which has black around its quad: the half sphere material may only be ready after it shows.
   */
  private fun showPhotoSphere() {
    if (request?.isVideo == true || request?.isStereoPhoto == true) return
    val half = coverage == ImmersiveSphereCoverage.HALF && photoTexture != null && halfSphereMaterial != null
    halfSphereEntity?.setComponent(Visible(half))
    skyboxEntity?.setComponent(Visible(!half))
  }

  /** Uploads the bitmap as the skybox texture, recycles it, destroys the previous photo texture. */
  private fun applySkyboxBitmap(bitmap: Bitmap) {
    if (sceneHold.isDown) {
      bitmap.recycle()
      return
    }
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

  // ---------------------------------------------------------------------------------------------
  // Spatial photos: stereo quad

  /**
   * The flat quad of the spatial photos: the unit quad of SceneMesh.singleSidedQuad (normal +z, u along +x) with an
   * unlit material made like the half sphere one, so that its stereo mode works as the skybox one does: the SDK default
   * vertex shader samples uv * (0.5, 1) + viewIndex * (0.5, 0) under LeftRight, the left half for both eyes under
   * MonoLeft. Sized by its Scale component, placed by [placeStereoQuad], hidden until a spatial photo is shown.
   */
  private fun createStereoQuad() {
    registerMeshCreator(STEREO_QUAD_MESH) { entity ->
      // The user faces the side opposite to the +z normal (see StereoComposer.quadRotation), the side a front sided
      // material may cull: the SDK sets a sidedness per material (its cylinder panels set FRONT_SIDED on the front
      // material and BACK_SIDED on the back one, and its shaders call the faces turned away "normally culled"), and
      // which winding its native renderer takes as the front does not show from Kotlin. Double sided, the quad shows
      // whatever that winding is; seen from behind its eyes would be mirrored, but it is placed facing the user at
      // every photo and every recentering.
      val material =
        entity.getComponent<Material>().generateSceneMaterial(entity, this).apply {
          setSidedness(MaterialSidedness.DOUBLE_SIDED)
        }
      SceneMesh.singleSidedQuad(0.5f, 0.5f, material)
    }
    val entity =
      Entity.create(
        listOf(
          Mesh(Uri.parse(STEREO_QUAD_MESH), hittable = MeshCollision.NoCollision),
          Material().apply { unlit = true },
          Transform(Pose(Vector3(0f, DEFAULT_EYE_HEIGHT, StereoComposer.DISTANCE_M), Quaternion(0f, 0f, 0f))),
          Scale(Vector3(1f, 1f, 1f)),
          Visible(false),
        ),
      )
    stereoQuadEntity = entity
    systemManager.findSystem<SceneObjectSystem>().getSceneObject(entity)?.thenAccept { sceneObject ->
      runOnUiThread {
        if (sceneHold.isDown) return@runOnUiThread
        val material = sceneObject.mesh?.materials?.firstOrNull()
        if (material == null) {
          Log.e(TAG, "stereo quad material not found, spatial photos cannot be displayed")
          return@runOnUiThread
        }
        Log.i(TAG, "stereo quad material ready")
        stereoQuadMaterial = material
        // A spatial photo decoded before the material was there
        pendingStereo?.let {
          pendingStereo = null
          if (request?.isStereoPhoto == true) applyStereoTexture(it) else it.bitmap.recycle()
        }
      }
    } ?: Log.e(TAG, "stereo quad scene object not available")
  }

  /**
   * The mesh of the 2.5D view of a relief (see [ReliefMesh]): one TriangleMesh of ReliefMesh.MAX_VERTICES vertices and
   * MAX_INDICES indices, made once as the lines of the SDK make theirs (TriangleMesh, updateGeometry, updatePrimitives,
   * SceneMesh.fromTriangleMesh, then updateWithTriangleMesh after each change), with an unlit material made like the
   * quad one, double sided too. Nothing drawn until a relief shows in 2.5D: every triangle has no area, and two
   * vertices give it bounds as wide as any relief. Its texture is the one of the quad, read with the stereo mode None:
   * the mesh itself gives each eye its view.
   */
  private fun createReliefMesh() {
    registerMeshCreator(RELIEF_MESH) { entity ->
      val material =
        entity.getComponent<Material>().generateSceneMaterial(entity, this).apply {
          setSidedness(MaterialSidedness.DOUBLE_SIDED)
          setStereoMode(StereoMode.None)
        }
      try {
        val triangles =
          TriangleMesh(
            ReliefMesh.MAX_VERTICES,
            ReliefMesh.MAX_INDICES,
            intArrayOf(0, ReliefMesh.MAX_INDICES),
            arrayOf(material),
          )
        val bounds =
          FloatArray(3 * ReliefMesh.MAX_VERTICES).apply {
            floatArrayOf(-10f, -10f, ReliefMesh.MIN_DEPTH_M.toFloat()).copyInto(this, 0)
            floatArrayOf(10f, 10f, ReliefMesh.MAX_DEPTH_M.toFloat()).copyInto(this, 3)
          }
        triangles.updateGeometry(
          0,
          bounds,
          RELIEF_MESH_NORMALS,
          FloatArray(2 * ReliefMesh.MAX_VERTICES),
          IntArray(ReliefMesh.MAX_VERTICES) { WHITE },
        )
        triangles.updatePrimitives(0, IntArray(ReliefMesh.MAX_INDICES))
        SceneMesh.fromTriangleMesh(triangles, false).also {
          reliefTriangles = triangles
          reliefSceneMesh = it
        }
      } catch (e: Throwable) {
        // Without its triangles the entity stays hidden and the reliefs in 3D
        Log.e(TAG, "relief mesh could not be made, reliefs stay in 3D", e)
        SceneMesh.singleSidedQuad(0.5f, 0.5f, material)
      }
    }
    val entity =
      Entity.create(
        listOf(
          Mesh(Uri.parse(RELIEF_MESH), hittable = MeshCollision.NoCollision),
          Material().apply { unlit = true },
          Transform(Pose(Vector3(0f, DEFAULT_EYE_HEIGHT, 0f), Quaternion(0f, 0f, 0f))),
          Visible(false),
        ),
      )
    reliefMeshEntity = entity
    systemManager.findSystem<SceneObjectSystem>().getSceneObject(entity)?.thenAccept { sceneObject ->
      runOnUiThread {
        if (sceneHold.isDown) return@runOnUiThread
        val material = sceneObject.mesh?.materials?.firstOrNull()
        if (material == null) {
          Log.e(TAG, "relief mesh material not found, reliefs stay in 3D")
          return@runOnUiThread
        }
        Log.i(TAG, "relief mesh ready, ${ReliefMesh.MAX_VERTICES} vertices")
        reliefMeshMaterial = material
        // A relief may wait for it in 2.5D
        if (reliefMesh != null && stereo25d) {
          applyStereoMode()
          applyStereoPlacement()
          updateStereoView()
        }
      }
    } ?: Log.e(TAG, "relief mesh scene object not available")
  }

  /**
   * Shows [media] on the stereo quad: no sphere around (black), its file read whole (a few MB: the bridge or the
   * server original, or the file on the headset), both eyes decoded and set side by side on one texture: the two
   * items of an Apple spatial photo (see [decodeStereo]), the two halves of a side by side photo (see [SbsPhoto]), or
   * a flat photo and the right eye the headset makes of it (see [showReliefPhoto]). A JSON that does not read, a kind
   * this build does not know, or a second eye that does not decode, shows the photo in 2D.
   */
  private fun showStereoPhoto(media: MediaRequest) {
    stopVideo()
    resetSkyboxToIdle()
    skyboxEntity?.setComponent(Visible(false))
    halfSphereEntity?.setComponent(Visible(false))
    hideStereoQuad()
    val kind = media.stereoKind
    val spec = media.stereoPair
    // A new photo starts in 3D at the width its field of view gives; the photo of a recreation as the user left it
    val restored = restoredStereoChoices?.forPhoto(media.url, media.openingId, media.screenAngleBounds)
    restoredStereoChoices = null
    stereo3d = restored?.threeD ?: true
    // A relief first shows as its request says, 3D or 2.5D; the photo of a recreation as the user left it
    stereo25d =
      restored?.mesh25d ?: ((kind as? StereoPhotoKind.DepthRelief)?.spec?.mode == ReliefViewMode.MESH_25D)
    stereoHasSecondEye = false
    stereoAngleDeg =
      restored?.angleDeg
        ?: StereoComposer.initialAngle(spec?.horizontalFovDeg).coerceIn(media.screenAngleBounds)
    stereoSizeFromPicture = kind == StereoPhotoKind.BigScreen && restored == null
    stereoChoicesFor = media.url to media.openingId
    if (kind is StereoPhotoKind.VolumetricScene) {
      showScene(media, kind.spec)
      return
    }
    if (kind is StereoPhotoKind.GaussianSplat) {
      showSplat(media, kind.spec)
      return
    }
    updateStereoView()
    setStatus(getString(R.string.immersive_loading))
    loadJob =
      scope.launch {
        // The server preview first, cut and shown as the original will be, while the original downloads and decodes
        // (an idea of Gaurav Mukherjee, gmfun/Immuch360 branch quest/flat-3d): a photo of several MB, or a large PNG,
        // takes seconds before its first pixel otherwise. Not for an Apple spatial photo, whose preview holds one eye,
        // nor for a relief or a scene, which read the original itself; never for a photo on the headset
        var previewShown = false
        try {
          val local = ImmersiveMedia.localFileFor(media.url)
          val previewUrl =
            if (local == null && showsPreviewFirst(kind)) ImmersiveMedia.previewUrlFor(media.url) else null
          if (previewUrl != null) previewShown = showStereoPreview(previewUrl, kind, spec)
          val started = SystemClock.elapsedRealtime()
          val bytes = if (local != null) withContext(Dispatchers.IO) { local.readBytes() } else download(media.url)
          val read = SystemClock.elapsedRealtime()
          Log.i(TAG, "stereo photo: ${bytes.size} bytes in ${read - started} ms")
          if (kind is StereoPhotoKind.DepthRelief) {
            showReliefPhoto(media, kind.spec, bytes)
            return@launch
          }
          val texture =
            decodeStereoPhoto(bytes, kind, spec) ?: throw IOException("this image cannot be read or decoded")
          Log.i(TAG, "stereo photo: decoded in ${SystemClock.elapsedRealtime() - read} ms")
          // Over the preview, where the user may have moved or resized it already
          applyStereoTexture(texture, place = !previewShown)
        } catch (e: CancellationException) {
          throw e
        } catch (e: Throwable) {
          Log.e(TAG, "stereo photo failed", e)
          val reason = e.message ?: e.javaClass.simpleName
          if (previewShown) {
            // The preview stays, said to be one, as on the sphere
            showStatus(getString(R.string.immersive_preview_only, reason))
            scheduleInfoHide()
          } else {
            showError(getString(R.string.immersive_error_photo, reason))
          }
        }
      }
  }

  /**
   * Whether a photo of [kind] shows the server preview of its file first: one whose picture the preview holds whole,
   * cut the same way (a side by side photo, a flat 3D photo), and an ordinary photo on the big screen.
   */
  private fun showsPreviewFirst(kind: StereoPhotoKind?): Boolean =
    kind is StereoPhotoKind.Sbs || kind is StereoPhotoKind.Flat || kind == StereoPhotoKind.BigScreen

  /**
   * Downloads the server preview at [previewUrl] and shows it as the photo of [kind] (see [applyStereoTexture]); true
   * once it shows. A preview that fails is only logged: the original comes next.
   */
  private suspend fun showStereoPreview(previewUrl: String, kind: StereoPhotoKind?, spec: StereoPairSpec?): Boolean {
    try {
      val started = SystemClock.elapsedRealtime()
      val texture = decodeStereoPhoto(download(previewUrl), kind, spec) ?: return false
      val elapsed = SystemClock.elapsedRealtime() - started
      Log.i(TAG, "stereo photo: preview ${texture.eyeWidth}x${texture.eyeHeight} in $elapsed ms")
      applyStereoTexture(texture, preview = true)
      return true
    } catch (e: CancellationException) {
      throw e
    } catch (e: Throwable) {
      Log.w(TAG, "stereo photo: preview failed: ${e.message}", e)
      return false
    }
  }

  /**
   * Both eyes of the photo of [bytes] of [kind] on one texture, off the main thread and one decode at a time: the two
   * halves of a side by side photo ([decodeSbs]), the eyes of a flat 3D photo ([decodeFlat]), an ordinary photo alone
   * for the big screen ([decodeBigScreen]), or the eyes of an Apple spatial photo, the photo alone without [spec]
   * ([decodeStereo]). Null when the image does not decode. The texture is the caller's; a load cancelled meanwhile
   * recycles it.
   */
  private suspend fun decodeStereoPhoto(
    bytes: ByteArray,
    kind: StereoPhotoKind?,
    spec: StereoPairSpec?,
  ): StereoTexture? {
    val holder = AtomicReference<StereoTexture?>()
    // A photo for the layer keeps no more pixels than its Surface takes
    val forLayer = request?.photoOnLayer == true
    try {
      decodeMutex.withLock {
        withContext(Dispatchers.Default) {
          holder.set(
            when (kind) {
              is StereoPhotoKind.Sbs -> decodeSbs(bytes, kind.spec)
              is StereoPhotoKind.Flat -> decodeFlat(bytes, kind.spec)
              is StereoPhotoKind.BigScreen -> decodeBigScreen(bytes)
              else -> decodeStereo(bytes, spec)
            }
          )
          if (forLayer) holder.get()?.let { holder.set(fitForLayer(it)) }
        }
      }
      coroutineContext.ensureActive()
      return holder.getAndSet(null)
    } finally {
      holder.getAndSet(null)?.bitmap?.recycle()
    }
  }

  /**
   * A flat photo whose relief the headset makes (the depthRelief JSON, design-final 2026-10-26, section 3.4): decoded
   * upright by [ImmersiveMedia.decodeForRelief] (EXIF orientation, the user's quarter turns, transparency on black),
   * shown flat on the quad at once, then handed to the relief job (see [startRelief]).
   */
  private suspend fun showReliefPhoto(media: MediaRequest, spec: DepthReliefSpec, bytes: ByteArray) {
    val photo = AtomicReference<Bitmap?>()
    val flat = AtomicReference<StereoTexture?>()
    try {
      decodeMutex.withLock {
        withContext(Dispatchers.Default) {
          val decoded = ImmersiveMedia.decodeForRelief(bytes, spec.quarterTurns) ?: return@withContext
          photo.set(decoded)
          val crop = StereoComposer.Crop(0, 0, decoded.width)
          val texture = StereoComposer.compose(decoded, decoded, crop)
          flat.set(StereoTexture(texture, decoded.width, decoded.height, hasSecondEye = false))
        }
      }
      coroutineContext.ensureActive()
      val texture = flat.getAndSet(null) ?: throw IOException("this image cannot be read or decoded")
      Log.i(TAG, "relief photo: ${texture.eyeWidth}x${texture.eyeHeight}, shown flat, ${spec.quarterTurns} turns")
      applyStereoTexture(texture)
      startRelief(media, spec, photo.getAndSet(null) ?: return)
    } finally {
      photo.getAndSet(null)?.recycle()
      flat.getAndSet(null)?.bitmap?.recycle()
    }
  }

  /**
   * Hands [photo], shown flat, to the relief job of this viewer (made at its first relief, with the watch of the heat):
   * the stages go to the status line under the indeterminate bar, the panel stays on screen, the 3D button reads
   * "Stop relief". The job owns [photo] from now on.
   */
  private fun startRelief(media: MediaRequest, spec: DepthReliefSpec, photo: Bitmap) {
    val job =
      reliefJob
        ?: run {
          val watch = ThermalWatch(this) { status -> reliefJob?.onThermalStatus(status) }
          thermalWatch = watch
          watch.start()
          ReliefHost.newJob(this, mainHandler, watch).also { reliefJob = it }
        }
    val request =
      ReliefRequest(File(spec.model), spec.modelSize, spec.modelId, spec.cacheKey, spec.parallax, spec.convergence)
    cancelInfoHide()
    reliefRun = job.start(request, BitmapReliefPhoto(photo), ::BitmapReliefEye, ReliefViewListener(media))
    setReliefProgress(true)
    updateStereoView()
  }

  /** What the relief job says of the photo of [media], on the main thread; nothing once another media is shown. */
  private inner class ReliefViewListener(private val media: MediaRequest) :
    ReliefListener<BitmapReliefPhoto, BitmapReliefEye> {
    private val shown: Boolean
      get() = request === media && !closing && !sceneHold.isDown

    override fun onStage(stage: ReliefStage) {
      if (!shown) return
      setReliefProgress(true)
      setStatus(StereoComposer.label(media.stereoLabels, StereoComposer.reliefStageLabelKey(stage)))
    }

    override fun onDone(result: ReliefResult<BitmapReliefPhoto, BitmapReliefEye>) {
      reliefRun = null
      if (!shown) {
        result.photo.release()
        result.eye.release()
        return
      }
      showRelief(media, result)
    }

    override fun onFlat(reason: ReliefStop, detail: String) {
      reliefRun = null
      if (!shown) return
      setReliefProgress(false)
      updateStereoView()
      val text = StereoComposer.reliefStopText(media.stereoLabels, reason, detail)
      Log.i(TAG, "relief: the photo stays flat ($reason)")
      if (text == null) {
        setStatus(stereoStatus)
        scheduleInfoHide()
      } else {
        // The reason comes and goes, as the honesty label does
        showPassing(text)
        scheduleInfoHide(TransientText.HOLD_MS)
      }
    }
  }

  /**
   * Both eyes of a finished relief on the quad in place of the flat photo, where the quad is now, and the mesh of its
   * 2.5D view made from its depth map: shown at once when 2.5D comes first, else at the 3D button.
   */
  private fun showRelief(media: MediaRequest, result: ReliefResult<BitmapReliefPhoto, BitmapReliefEye>) {
    reliefApplyJob?.cancel()
    reliefApplyJob =
      scope.launch {
        val holder = AtomicReference<StereoTexture?>()
        var mesh: ReliefMesh? = null
        try {
          decodeMutex.withLock {
            withContext(Dispatchers.Default) {
              val left = result.photo.bitmap
              val texture = StereoComposer.compose(left, result.eye.bitmap, StereoComposer.Crop(0, 0, left.width))
              holder.set(StereoTexture(texture, left.width, left.height, hasSecondEye = true))
              // The relief stays in 3D without it: the 3D button then goes to 2D as for any stereo photo
              mesh =
                try {
                  ReliefMesh(result.map)
                } catch (e: Throwable) {
                  Log.e(TAG, "relief: no 2.5D mesh for this photo", e)
                  null
                }
            }
          }
          ensureActive()
          val source = if (result.fromCache) "the cache" else "the model on ${result.path}"
          val made = mesh?.let { "${it.columns}x${it.rows} mesh" } ?: "no mesh"
          // 2.5D only with its mesh and a scene ready for it: the quad shows the 3D otherwise
          val shownIn = if (stereo25d && mesh != null && reliefMeshReady) "2.5D" else "3D"
          Log.i(TAG, "relief shown in $shownIn, depth map from $source, $made")
          reliefMesh = mesh
          reliefMeshWritten = false
          reliefAttenuation = 1.0
          setReliefProgress(false)
          applyStereoTexture(holder.getAndSet(null) ?: return@launch, place = false)
        } catch (e: CancellationException) {
          throw e
        } catch (e: Throwable) {
          Log.e(TAG, "relief: the eyes could not be put on the quad", e)
          setReliefProgress(false)
          updateStereoView()
          val reason = if (e is OutOfMemoryError) ReliefStop.NOT_ENOUGH_MEMORY else ReliefStop.FAILED
          StereoComposer.reliefStopText(media.stereoLabels, reason, e.message ?: e.javaClass.simpleName)?.let {
            showPassing(it)
          }
          scheduleInfoHide(TransientText.HOLD_MS)
        } finally {
          holder.getAndSet(null)?.bitmap?.recycle()
          result.photo.release()
          result.eye.release()
        }
      }
  }

  /** The indeterminate bar under the status line, while a relief or a 3D scene is made. */
  private fun setReliefProgress(visible: Boolean) {
    reliefProgressView?.visibility = if (visible) View.VISIBLE else View.GONE
  }

  /** Another media, or the end of the viewer: the relief of the photo shown is dropped without a word. */
  private fun dropRelief() {
    reliefApplyJob?.cancel()
    reliefApplyJob = null
    reliefRun = null
    reliefJob?.cancel()
    setReliefProgress(false)
  }

  /** The end of the viewer: the relief dropped, the model closed, its thread ended, the heat no longer watched. */
  private fun releaseRelief() {
    dropRelief()
    thermalWatch?.stop()
    thermalWatch = null
    reliefJob?.close()
    reliefJob = null
  }

  // ---------------------------------------------------------------------------------------------
  // 3D scene of a photo, see SceneView

  /**
   * The mesh creator of the scenes (see [SceneView.createMesh]), registered once with the scene. An entity of a scene
   * gone, or one whose mesh the SDK could not make, gets a quad too small to see, and stays hidden anyway.
   */
  private fun createSceneMeshes() {
    registerMeshCreator(SceneView.MESH_URI) { entity: Entity, uri: Uri ->
      sceneView?.createMesh(entity, uri)
        ?: SceneMesh.singleSidedQuad(
          0.001f,
          0.001f,
          entity.getComponent<Material>().generateSceneMaterial(entity, this),
        )
    }
  }

  /**
   * [media], a photo that carries a 3D scene (design-final 2026-10-27, section 3.2): its file read whole into the cache
   * (or where it is, on the headset), its preview flat on the quad at once under "Preparing the 3D scene" and the bar;
   * then, off the main thread, the scene opened from the file (the packet at its head wins over [json]), weighed by
   * the gate of this headset, its textures decoded in sRGB at the sizes the gate allows. [SceneView] makes its meshes
   * and replaces the preview once they are there. A scene the gate or the file refuses leaves the preview flat with
   * its reason for a few seconds; the panel keeps it too.
   */
  private fun showScene(media: MediaRequest, json: VolumetricSceneSpec) {
    val labels = media.stereoLabels
    stereoAngleDeg = StereoComposer.initialAngle(json.fovDegrees.toFloat())
    sceneChosen = true
    scenePreparing = true
    sceneDetails = SceneTexts.detailLines(labels, json, null)
    cancelInfoHide()
    setReliefProgress(true)
    setStatus(SceneTexts.label(labels, SceneTexts.LABEL_PREPARING))
    updateStereoView()
    updateSceneControls()
    val options = readSceneOptions()
    val caps = SceneGate.capsFor(Build.DEVICE)
    loadJob =
      scope.launch {
        val local = ImmersiveMedia.localFileFor(media.url)
        val file = local ?: File(cacheDir, "$ORIGINAL_PREFIX${System.nanoTime()}")
        val flat = AtomicReference<StereoTexture?>()
        val made = AtomicReference<Pair<ScenePrepared, List<Bitmap>>?>()
        var previewShown = false
        try {
          if (local == null) Log.i(TAG, "scene: ${downloadTo(media.url, file)} bytes downloaded")
          else Log.i(TAG, "scene: ${file.length()} bytes on the headset")
          decodeMutex.withLock {
            withContext(Dispatchers.Default) { ImmersiveMedia.decodeFile(file)?.let { flat.set(flatTexture(it)) } }
          }
          ensureActive()
          applyStereoTexture(flat.getAndSet(null) ?: throw IOException("this image cannot be read or decoded"))
          previewShown = true
          val opening =
            decodeMutex.withLock {
              withContext(Dispatchers.Default) {
                val opened =
                  RandomAccessFile(file, "r").use { access ->
                    SceneOpener.open(SceneSource.of(access), json, caps, { availableMemory() }, { thermalStatus() })
                  }
                if (opened is SceneOpening.Ready) {
                  SceneView.decodeTextures(opened.scene, opened.open.sampleSizes)?.let { bitmaps ->
                    made.set(ScenePrepared.of(opened) to bitmaps)
                  }
                }
                opened
              }
            }
          ensureActive()
          when (opening) {
            is SceneOpening.Stopped -> sceneStopped(media, opening.stop)
            is SceneOpening.Ready -> {
              sceneDetails = SceneTexts.detailLines(labels, opening.spec, opening.hiddenFraction)
              updateSceneControls()
              val (prepared, bitmaps) = made.getAndSet(null) ?: (null to null)
              if (prepared == null || bitmaps == null) {
                sceneStopped(media, SceneStop.Failed("a texture does not decode"))
              } else {
                attachScene(media, prepared, bitmaps, options)
              }
            }
          }
        } catch (e: CancellationException) {
          throw e
        } catch (e: Throwable) {
          Log.e(TAG, "scene failed", e)
          val reason = e.message ?: e.javaClass.simpleName
          when {
            !previewShown -> {
              scenePreparing = false
              sceneDetails = emptyList()
              setReliefProgress(false)
              updateSceneControls()
              showError(getString(R.string.immersive_error_photo, reason))
            }
            e is OutOfMemoryError ->
              sceneStopped(media, SceneStop.Refused(SceneVerdict.Refused(SceneRefusal.NOT_ENOUGH_MEMORY)))
            else -> sceneStopped(media, SceneStop.Failed(reason))
          }
        } finally {
          flat.getAndSet(null)?.bitmap?.recycle()
          made.getAndSet(null)?.second?.forEach { it.recycle() }
          if (local == null) file.delete()
        }
      }
  }

  /** The textures of [prepared] uploaded from [bitmaps], which are recycled, and the scene handed to a [SceneView]. */
  private fun attachScene(
    media: MediaRequest,
    prepared: ScenePrepared,
    bitmaps: List<Bitmap>,
    options: SceneViewerOptions,
  ) {
    val textures = mutableListOf<SceneTexture>()
    try {
      for (bitmap in bitmaps) {
        textures +=
          SceneTexture(
            bitmap,
            SamplerConfig(
              Filter.LINEAR,
              Filter.LINEAR,
              Filter.LINEAR,
              AddressMode.CLAMP_TO_EDGE,
              AddressMode.CLAMP_TO_EDGE,
              0f,
            ),
          )
      }
    } catch (e: Throwable) {
      Log.e(TAG, "scene: a texture could not be uploaded", e)
      textures.forEach { runCatching { it.destroy() } }
      sceneStopped(media, SceneStop.Failed(e.message ?: e.javaClass.simpleName))
      return
    } finally {
      bitmaps.forEach { it.recycle() }
    }
    val view = SceneView(this, systemManager, mainHandler, sceneHold, prepared, textures, options, SceneListener(media))
    sceneView = view
    view.attach()
  }

  /** What the scene of [media] says, on the main thread; nothing once another media is shown. */
  private inner class SceneListener(private val media: MediaRequest) : SceneView.Listener {
    private val current: Boolean
      get() = request === media && !closing && !sceneHold.isDown

    override fun onSceneShown() {
      if (!current) return
      scenePreparing = false
      setReliefProgress(false)
      if (sceneChosen) stereoQuadEntity?.setComponent(Visible(false))
      stereoStatus = SceneTexts.label(media.stereoLabels, SceneTexts.LABEL_SCENE_3D)
      updateStereoView()
      updateSceneControls()
      // The honesty sentence comes and goes (FreeKC's rule of 25 October), and stays written in the panel
      val honesty = SceneTexts.label(media.stereoLabels, SceneTexts.LABEL_HONESTY)
      Log.i(TAG, "scene: reconstructed from one photo, said for ${TransientText.HOLD_MS} ms")
      if (infoVisible) {
        showPassing(honesty)
        scheduleInfoHide(TransientText.HOLD_MS)
      } else {
        showNotice(honesty)
      }
    }

    override fun onSceneFailed(reason: String) {
      if (!current) return
      dropScene()
      stereoQuadEntity?.setComponent(Visible(true))
      sceneStopped(media, SceneStop.Failed(reason))
    }

    override fun onSceneEdge() {
      if (!current) return
      val text = SceneTexts.label(media.stereoLabels, SceneTexts.LABEL_EDGE)
      if (infoVisible) showPassing(text) else showNotice(text)
    }
  }

  /**
   * The scene of [media] is not shown, for [stop]: its preview stays flat, the reason comes and goes on the status
   * line and stays written in the panel, where the 3D button is greyed.
   */
  private fun sceneStopped(media: MediaRequest, stop: SceneStop) {
    if (request !== media || closing) return
    val text = SceneTexts.stopText(media.stereoLabels, stop)
    scenePreparing = false
    sceneDetails = listOf(text)
    setReliefProgress(false)
    updateStereoView()
    updateSceneControls()
    Log.i(TAG, "scene: the photo stays flat ($stop)")
    showPassing(text)
    scheduleInfoHide(TransientText.HOLD_MS)
  }

  /** Another media, or the end of the viewer: the scene shown goes, without a word. */
  private fun dropScene() {
    sceneView?.destroy()
    sceneView = null
    scenePreparing = false
    sceneChosen = true
    sceneDetails = emptyList()
  }

  /** Reset, from the panel or a click of a thumbstick: the camera of the photo at the head again, the scene whole. */
  private fun resetScene() {
    if (request?.isSplat == true) {
      splatStage?.reset()
      return
    }
    val view = sceneView ?: return
    if (!view.isReady || !sceneChosen) return
    view.reset()
  }

  /** The 3D button of a scene: its photo (2D) on the quad in front of the user, or the scene again. */
  private fun toggleScenePhoto(fromPanel: Boolean) {
    val view = sceneView ?: return
    if (!view.isReady) return
    sceneChosen = !sceneChosen
    view.setVisible(sceneChosen)
    if (sceneChosen) {
      stereoQuadEntity?.setComponent(Visible(false))
    } else {
      placeStereoQuad()
      stereoQuadEntity?.setComponent(Visible(true))
    }
    Log.i(TAG, "scene: ${if (sceneChosen) "the scene" else "the photo (2D)"} shows")
    updateStereoView()
    updateSceneControls()
    showControlChange(fromPanel)
  }

  /** The free memory Android reports (ActivityManager.MemoryInfo.availMem), null when unknown. */
  private fun availableMemory(): Long? {
    val manager = getSystemService(ACTIVITY_SERVICE) as? ActivityManager ?: return null
    return try {
      ActivityManager.MemoryInfo().also(manager::getMemoryInfo).availMem
    } catch (e: Exception) {
      null
    }
  }

  /** PowerManager.currentThermalStatus, null when unknown (before Android 10). */
  private fun thermalStatus(): Int? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
    val power = getSystemService(POWER_SERVICE) as? PowerManager ?: return null
    return try {
      power.currentThermalStatus
    } catch (e: Exception) {
      null
    }
  }

  /**
   * [media], a Gaussian splat file of another tool (lot S5): its file read where it is on the headset, else downloaded
   * into the cache, under "Preparing the splat" and the bar; then, off the main thread, its head read again (it wins
   * over [spec]), the gate of this headset (SplatGate), the reduction to the strongest gaussians when it holds more
   * than the request allows, and the bounds of its positions (SplatPreparer). [SplatStage] then makes its entity, which
   * the splat module loads; it shows fixed in the world, placed in front of the user or around the user. A splat the
   * gate refuses says why for a few seconds, and the panel keeps the reason; one that comes to a viewer the module did
   * not start with says so at once, before anything is read or downloaded. Every file of the cache the stage did not
   * take goes at the end (SplatCacheFiles), a cancellation after a ready preparation included.
   */
  private fun showSplat(media: MediaRequest, spec: GaussianSplatSpec) {
    val labels = media.stereoLabels
    val stage = splatStage
    if (stage == null || !stage.prepare()) return
    splatPreparing = true
    splatDetails = emptyList()
    stereoStatus = ""
    cancelInfoHide()
    setReliefProgress(true)
    setStatus(SplatTexts.label(labels, SplatTexts.LABEL_PREPARING))
    updateStereoView()
    updateSceneControls()
    updateTurnButton()
    val refusal =
      SplatGate.viewerRefusal(SplatEngines.available, Build.DEVICE, splatModuleRunning, SplatBuild.offersSplats(this))
    if (refusal != null) {
      splatStopped(media, SplatTexts.refusalText(labels, refusal))
      return
    }
    val local = ImmersiveMedia.localFileFor(media.url)
    if (local == null && !SplatGate.roomForDownload(spec.fileBytes, freeCacheBytes())) {
      splatStopped(media, SplatTexts.refusalText(labels, SplatVerdict.Refused(SplatRefusal.NOT_ENOUGH_SPACE)))
      return
    }
    val options = readSplatOptions()
    val cap = spec.maxGaussians
    loadJob =
      scope.launch {
        val download = if (local == null) File(cacheDir, "$SPLAT_PREFIX${System.nanoTime()}.part") else null
        val files = SplatCacheFiles(download)
        try {
          val source =
            if (local != null) {
              Log.i(TAG, "splat: ${local.length()} bytes on the headset")
              local
            } else {
              Log.i(TAG, "splat: ${downloadTo(media.url, download!!)} bytes downloaded")
              download
            }
          val started = SystemClock.elapsedRealtime()
          val preparation =
            withContext(Dispatchers.IO) {
              // Remembered inside the block: a cancellation as it returns would lose a ready file otherwise
              files.prepared(
                SplatPreparer.prepare(
                  source,
                  sourceOwned = local == null,
                  cap = cap,
                  engine = SplatEngines.available,
                  device = Build.DEVICE,
                  availableMemory = { availableMemory() },
                  thermalStatus = { thermalStatus() },
                  cacheDir = cacheDir,
                  prefix = SPLAT_PREFIX,
                  cancelled = { !isActive },
                  freeCache = { freeCacheBytes() },
                )
              )
            }
          ensureActive()
          Log.i(TAG, "splat: prepared in ${SystemClock.elapsedRealtime() - started} ms")
          when (preparation) {
            is SplatPreparation.Stopped -> splatStopped(media, SplatTexts.refusalText(labels, preparation.verdict))
            is SplatPreparation.Ready -> {
              files.handOver()
              splatDetails = SplatTexts.detailLines(labels, preparation.head, preparation.verdict)
              updateSceneControls()
              stage.show(preparation, spec, options) { lastHeadPosition to lastHeadForward }
              announceSplat(media, preparation.verdict)
            }
          }
        } catch (e: CancellationException) {
          throw e
        } catch (e: Throwable) {
          Log.e(TAG, "splat failed", e)
          // A file found damaged while it is read says so as the probe would, translated (SplatTexts.errorText)
          splatStopped(media, SplatTexts.errorText(labels, e))
        } finally {
          // The download, the reduced or renamed copy: whatever the stage did not take goes
          files.release()
        }
      }
  }

  /** The free space of the cache of the viewer, null when it cannot be read */
  private fun freeCacheBytes(): Long? =
    try {
      cacheDir.takeIf { it.isDirectory }?.usableSpace
    } catch (e: SecurityException) {
      null
    }

  /** What the splat of [media] says once read: reduced, large; the words go after TransientText.HOLD_MS */
  private fun announceSplat(media: MediaRequest, verdict: SplatVerdict.Open) {
    if (request !== media || closing || sceneHold.isDown) return
    val labels = media.stereoLabels
    val lines = mutableListOf<String>()
    verdict.keep?.let { lines += SplatTexts.reducedLine(labels, it, verdict.gaussians) }
    if (verdict.large) lines += SplatTexts.label(labels, SplatTexts.LABEL_LARGE)
    if (lines.isEmpty()) return
    val text = lines.joinToString("\n")
    Log.i(TAG, "splat: \"$text\" said for ${TransientText.HOLD_MS} ms")
    if (infoVisible) showPassing(text) else queueNotice(text)
  }

  /** What the splat says, on the main thread; nothing once another media is shown */
  private inner class SplatListener : SplatStage.Listener {
    override fun onSplatShown() {
      val media = request ?: return
      if (!media.isSplat || closing || sceneHold.isDown) return
      splatPreparing = false
      setReliefProgress(false)
      stereoStatus = ""
      updateSceneControls()
      updateTurnButton()
      // What is experimental is said once, and the words go (FreeKC's rule of 25 October), with the words that Meta
      // neither supports nor warrants the API of the splats (his decision of 30 October)
      if (!splatNoticeShown) {
        splatNoticeShown = true
        val notice = SplatTexts.noticeText(media.stereoLabels)
        Log.i(TAG, "splat: \"$notice\" said for ${TransientText.HOLD_MS} ms")
        if (infoVisible) {
          showPassing(notice)
          scheduleInfoHide(TransientText.HOLD_MS)
        } else {
          showNotice(notice)
        }
      } else {
        setStatus("")
        scheduleInfoHide(TransientText.HOLD_MS)
      }
    }

    override fun onSplatFailed(reason: String) {
      val media = request ?: return
      if (!media.isSplat || closing || sceneHold.isDown) return
      splatStopped(media, SplatTexts.failedText(media.stereoLabels, reason))
    }
  }

  /** The splat of [media] is not shown, for [text]: said for a few seconds, kept in the panel */
  private fun splatStopped(media: MediaRequest, text: String) {
    if (request !== media || closing || sceneHold.isDown) return
    splatPreparing = false
    splatDetails = listOf(text)
    setReliefProgress(false)
    updateSceneControls()
    updateTurnButton()
    Log.i(TAG, "splat: not shown ($text)")
    showPassing(text)
    scheduleInfoHide(TransientText.HOLD_MS)
  }

  /** Another media, or the end of the viewer: the splat goes, without a word */
  private fun dropSplat() {
    splatStage?.drop()
    splatPreparing = false
    splatDetails = emptyList()
  }

  /** Turn upright, from the panel: the next orientation of the splat, remembered for its file */
  private fun turnSplatUpright() {
    val upright = splatStage?.turnUpright() ?: return
    Log.i(TAG, "splat: turned upright, ${upright.key}")
  }

  /** The orientation of each splat file, kept in the preferences of the viewer */
  private fun splatUprightMemory(): SplatUprightMemory {
    val preferences = getSharedPreferences(SPLAT_PREFERENCES, MODE_PRIVATE)
    return SplatUprightMemory(
      object : SplatUprightStore {
        override fun read(key: String): String? = preferences.getString(key, null)

        override fun write(key: String, value: String) {
          preferences.edit().putString(key, value).apply()
        }
      }
    )
  }

  /** The options a measuring session pushed to the headset (see [SplatViewerOptions]), the defaults otherwise */
  private fun readSplatOptions(): SplatViewerOptions {
    val folder = getExternalFilesDir(null) ?: return SplatViewerOptions()
    val file = File(folder, SplatViewerOptions.FILE_NAME)
    if (!file.isFile) return SplatViewerOptions()
    return try {
      SplatViewerOptions.parse(file.readText()).also { Log.i(TAG, "splat options from ${file.name}: $it") }
    } catch (e: Exception) {
      Log.w(TAG, "splat options unreadable: ${e.message}")
      SplatViewerOptions()
    }
  }

  /** The options a measuring session pushed to the headset (see [SceneViewerOptions]), the defaults otherwise. */
  private fun readSceneOptions(): SceneViewerOptions {
    val folder = getExternalFilesDir(null) ?: return SceneViewerOptions()
    val file = File(folder, SceneViewerOptions.FILE_NAME)
    if (!file.isFile) return SceneViewerOptions()
    return try {
      SceneViewerOptions.parse(file.readText()).also { Log.i(TAG, "scene options from ${file.name}: $it") }
    } catch (e: Exception) {
      Log.w(TAG, "scene options unreadable: ${e.message}")
      SceneViewerOptions()
    }
  }

  /**
   * [single] as the texture of a flat photo on the quad, the same picture for both eyes, within the size of an eye
   * (StereoHeicDecoder.MAX_EYE_WIDTH x MAX_EYE_HEIGHT), off the main thread; [single] is recycled.
   */
  private fun flatTexture(single: Bitmap): StereoTexture {
    val (width, height) =
      StereoComposer.fitWithin(
        single.width,
        single.height,
        StereoHeicDecoder.MAX_EYE_WIDTH,
        StereoHeicDecoder.MAX_EYE_HEIGHT,
      )
    val eye =
      if (width != single.width || height != single.height) {
        Bitmap.createScaledBitmap(single, width, height, true).also { if (it !== single) single.recycle() }
      } else {
        single
      }
    try {
      val crop = StereoComposer.Crop(0, 0, eye.width)
      return StereoTexture(StereoComposer.compose(eye, eye, crop), eye.width, eye.height, hasSecondEye = false)
    } finally {
      eye.recycle()
    }
  }

  /**
   * An ordinary photo of [bytes] for the big screen, off the main thread: upright as its EXIF says (see
   * ImmersiveMedia.decodeUpright), as wide as the Surface of the photo layer at most, alone in its cell on black (its
   * transparency on black), one picture for both eyes. Null when it does not decode.
   */
  private fun decodeBigScreen(bytes: ByteArray): StereoTexture? {
    val photo =
      ImmersiveMedia.decodeUpright(bytes, FlatScreenLayer.SURFACE_WIDTH_PX, StereoHeicDecoder.MAX_EYE_HEIGHT)
        ?: ImmersiveMedia.decodeBytes(bytes)
        ?: return null
    try {
      val (width, height) =
        StereoComposer.fitWithin(
          photo.width,
          photo.height,
          FlatScreenLayer.SURFACE_WIDTH_PX,
          StereoHeicDecoder.MAX_EYE_HEIGHT,
        )
      val gutter = StereoComposer.GUTTER
      val cell = Bitmap.createBitmap(width + 2 * gutter, height + 2 * gutter, Bitmap.Config.ARGB_8888)
      cell.eraseColor(Color.BLACK)
      val target = Rect(gutter, gutter, gutter + width, gutter + height)
      Canvas(cell).drawBitmap(photo, null, target, Paint(Paint.FILTER_BITMAP_FLAG))
      Log.i(TAG, "big screen photo: ${photo.width}x${photo.height}, shown ${width}x$height")
      return StereoTexture(cell, width, height, hasSecondEye = false, single = true)
    } finally {
      photo.recycle()
    }
  }

  /**
   * [texture] as the photo layer keeps it, off the main thread: each eye no larger than its region of the Surface
   * (see FlatScreenLayer.keptEyeSize), so that the lines or the columns the Surface drops anyway are not kept for the
   * life of the photo (a portrait photo of 4096 x 4088 on the big screen kept 64 MiB, 32 MiB of which never showed);
   * [texture] recycled once copied. The eye size stays that of the picture, which gives the layer its shape and the
   * panel its numbers; on the quad mesh, should the layer fail, the same picture shows in the same shape.
   */
  private fun fitForLayer(texture: StereoTexture): StereoTexture {
    val (width, height) = FlatScreenLayer.keptEyeSize(texture.cellWidth, texture.cellHeight, texture.hasSecondEye)
    if (width == texture.cellWidth && height == texture.cellHeight) return texture
    val gutter = StereoComposer.GUTTER
    val cells = if (texture.single) 1 else 2
    var kept: Bitmap? = null
    try {
      val bitmap = Bitmap.createBitmap(cells * (width + 2 * gutter), height + 2 * gutter, Bitmap.Config.ARGB_8888)
      kept = bitmap
      bitmap.eraseColor(Color.BLACK)
      val canvas = Canvas(bitmap)
      val paint = Paint(Paint.FILTER_BITMAP_FLAG)
      for (eye in 0 until cells) {
        val source = FlatScreenLayer.sourceRegion(eye, texture.cellWidth, texture.cellHeight)
        val target = FlatScreenLayer.sourceRegion(eye, width, height)
        canvas.drawBitmap(texture.bitmap, rectOf(source), rectOf(target), paint)
      }
    } catch (e: Throwable) {
      // No room for the copy: the photo shows as decoded
      Log.w(TAG, "photo layer keeps the photo as decoded, ${texture.cellWidth}x${texture.cellHeight} per eye", e)
      kept?.recycle()
      return texture
    }
    val copy = kept ?: return texture
    Log.i(TAG, "photo layer keeps ${width}x$height of ${texture.cellWidth}x${texture.cellHeight} per eye")
    texture.bitmap.recycle()
    return StereoTexture(
      copy,
      texture.eyeWidth,
      texture.eyeHeight,
      texture.hasSecondEye,
      texture.single,
      cellWidth = width,
      cellHeight = height,
    )
  }

  /** Both eyes of the side by side photo of [bytes] on one texture, off the main thread, see [SbsPhoto.decode]. */
  private fun decodeSbs(bytes: ByteArray, spec: SbsPhotoSpec): StereoTexture? {
    val (texture, split) = SbsPhoto.decode(bytes, spec) ?: return null
    return StereoTexture(texture, split.eyeWidth, split.eyeHeight, hasSecondEye = true)
  }

  /** Both eyes of the flat 3D photo of [bytes] on one texture, off the main thread, see [FlatStereoPhoto.decode]. */
  private fun decodeFlat(bytes: ByteArray, spec: FlatStereoSpec): StereoTexture? {
    val (texture, split) = FlatStereoPhoto.decode(bytes, spec.format) ?: return null
    return StereoTexture(texture, split.eyeWidth, split.eyeHeight, hasSecondEye = true)
  }

  /**
   * Both eyes of a spatial photo of [bytes] on one texture, off the main thread: the left eye, then the right one by
   * the pitm patch, else by the index of MediaMetadataRetriever when the platform gave the left eye again (their
   * difference tells), else none. Without a [spec], or without a right eye, the left eye goes in both halves. Logs the
   * item ids, the sizes, the path that gave the right eye and the difference, for the headset checks.
   */
  private fun decodeStereo(bytes: ByteArray, spec: StereoPairSpec?): StereoTexture? {
    if (spec == null) return flatTexture(ImmersiveMedia.decodeBytes(bytes) ?: return null)
    val left = StereoHeicDecoder.decodeEye(bytes, spec, spec.leftItemId)
    Log.i(TAG, "spatial photo: left eye item ${spec.leftItemId} decoded ${left.width}x${left.height}")
    var right: Bitmap? = null
    try {
      try {
        val patched = StereoHeicDecoder.decodeEye(bytes, spec, spec.rightItemId)
        val sized =
          if (patched.width != left.width || patched.height != left.height) {
            Log.w(TAG, "spatial photo: right eye ${patched.width}x${patched.height}, scaled to the left one")
            Bitmap.createScaledBitmap(patched, left.width, left.height, true).also {
              if (it !== patched) patched.recycle()
            }
          } else {
            patched
          }
        val difference = StereoHeicDecoder.meanDifference(left, sized)
        Log.i(TAG, "spatial photo: right eye item ${spec.rightItemId} by pitm patch, difference $difference")
        if (difference >= StereoHeicDecoder.SAME_IMAGE_DIFFERENCE) right = sized else sized.recycle()
      } catch (e: Exception) {
        Log.w(TAG, "spatial photo: pitm patch failed: ${e.message}")
      }
      if (right == null) {
        Log.i(TAG, "spatial photo: the pitm patch gave the left eye again, trying the images by index")
        right = StereoHeicDecoder.decodeRightByIndex(bytes, left)
        val found = if (right != null) "found" else "not found, shown in 2D"
        Log.i(TAG, "spatial photo: right eye by image index $found")
      }
      val crop =
        if (right != null) StereoComposer.crop(left.width, spec.disparityAdjustment)
        else StereoComposer.Crop(0, 0, left.width)
      Log.i(
        TAG,
        "spatial photo: eyes ${crop.width}x${left.height} (disparity ${spec.disparityAdjustment}, left from " +
          "${crop.leftStart}, right from ${crop.rightStart}), rotation ${spec.rotation}",
      )
      val texture = StereoComposer.compose(left, right ?: left, crop)
      return StereoTexture(texture, crop.width, left.height, hasSecondEye = right != null)
    } finally {
      left.recycle()
      right?.recycle()
    }
  }

  /**
   * Shows [stereo] with the mode and the size of this photo, in front of the user unless [place] is false (the eyes of
   * a relief replace the flat photo where the quad is; the full photo replaces its preview where the user left it):
   * on the photo layer for the photos [FlatScreenLayer.showsOnLayer] takes while Sharper flat screens is on, which
   * keeps its bitmap to draw it again on a new Surface; else as the texture of the quad mesh, its bitmap recycled and
   * the previous texture destroyed, kept for later while the material is not ready. [preview] is the server preview of
   * the photo while its original loads (see [showStereoPhoto]): the panel says so, and stays.
   */
  private fun applyStereoTexture(stereo: StereoTexture, place: Boolean = true, preview: Boolean = false) {
    if (sceneHold.isDown) {
      stereo.bitmap.recycle()
      return
    }
    val media = request
    val onLayer = media?.photoOnLayer == true
    if (onLayer) {
      showOnLayer(stereo)
    } else if (!showOnMesh(stereo)) {
      return
    }
    stereoEyeSize = stereo.eyeWidth to stereo.eyeHeight
    stereoHasSecondEye = stereo.hasSecondEye
    stereoSingle = stereo.single
    if (stereoSizeFromPicture) {
      stereoSizeFromPicture = false
      stereoAngleDeg = FlatScreenGeometry.fittingAngle(stereo.eyeWidth.toFloat() / stereo.eyeHeight.coerceAtLeast(1))
    }
    applyStereoMode()
    if (place || !stereoPlacedWithHead) placeStereoQuad() else applyStereoScale()
    if (onLayer) drawPhotoLayer() else stereoQuadEntity?.setComponent(Visible(true))
    updateStereoView()
    updateScreenControls()
    if (preview) {
      // The original still loads: the panel says so and stays until it is there
      stereoStatus = getString(R.string.immersive_preview_loading_full, stereo.eyeWidth, stereo.eyeHeight)
      setStatus(stereoStatus)
      return
    }
    stereoStatus = getString(R.string.immersive_full_resolution, stereo.eyeWidth, stereo.eyeHeight)
    if (media?.stereoPair != null && !stereo.hasSecondEye) {
      // Shown at once and longer, as the decoder warning: the user expected 3D
      showStatus(StereoComposer.label(media.stereoLabels, StereoComposer.LABEL_SECOND_EYE_FAILED))
      scheduleInfoHide(DECODER_WARNING_HIDE_MS)
    } else if (media?.stereoKind is StereoPhotoKind.DepthRelief && !stereo.hasSecondEye) {
      // The flat photo while its relief is made: the panel stays for the stages, see startRelief
      setStatus(stereoStatus)
    } else if (media?.isScene == true && scenePreparing) {
      // The preview of a scene while the scene is made: the panel stays for the bar, see showScene
      setStatus(SceneTexts.label(media.stereoLabels, SceneTexts.LABEL_PREPARING))
    } else if (stereo3d) {
      setStatus(stereoStatus)
      showReliefEstimated()
      scheduleInfoHide()
      if (media != null) announceFlat3d(media)
    } else {
      setStatus(stereoStatus)
      scheduleInfoHide()
    }
  }

  /**
   * [stereo] as the texture of the quad mesh: its bitmap recycled, the previous texture destroyed, the photo layer
   * emptied. False, [stereo] kept for later, while the material is not ready; false too when the texture cannot be
   * made, which the panel says.
   */
  private fun showOnMesh(stereo: StereoTexture): Boolean {
    val material = stereoQuadMaterial
    if (material == null) {
      Log.w(TAG, "stereo quad not ready yet, keeping the spatial photo for later")
      pendingStereo?.bitmap?.recycle()
      pendingStereo = stereo
      return false
    }
    val bitmap = stereo.bitmap
    val texture =
      try {
        SceneTexture(
          bitmap,
          SamplerConfig(
            Filter.LINEAR,
            Filter.LINEAR,
            Filter.LINEAR,
            AddressMode.CLAMP_TO_EDGE,
            AddressMode.CLAMP_TO_EDGE,
            0f,
          ),
        )
      } catch (e: Throwable) {
        Log.e(TAG, "stereo texture creation failed for ${bitmap.width}x${bitmap.height}", e)
        null
      } finally {
        bitmap.recycle()
      }
    if (texture == null) {
      showError(getString(R.string.immersive_error_photo, "texture"))
      return false
    }
    material.setAlbedoTexture(texture)
    // The mesh of the 2.5D view reads the same texture: never the one destroyed below
    reliefMeshMaterial?.setAlbedoTexture(texture)
    stereoTexture?.destroy()
    stereoTexture = texture
    dropPhotoLayer()
    return true
  }

  /**
   * [stereo] for the photo layer: kept there in place of the previous one (recycled) until the next photo, drawn by
   * [drawPhotoLayer] once the layer and its Surface are there; the quad mesh hides meanwhile. Once the scene is down
   * no layer is made and the bitmap of [stereo] is recycled, whoever calls.
   */
  private fun showOnLayer(stereo: StereoTexture) {
    // The layer reads null from the shutdown on: Entity.create would run on the cleared EntityContext and throw
    if (sceneHold.isDown) {
      stereo.bitmap.recycle()
      return
    }
    photoLayerTexture?.bitmap?.takeIf { it !== stereo.bitmap }?.recycle()
    photoLayerTexture = stereo
    photoLayerDrawn = false
    stereoQuadEntity?.setComponent(Visible(false))
    if (photoLayerEntity == null) {
      photoLayerEntity =
        Entity.create(
          // Never hit by the controller ray: it would stand in front of the info panel and take its clicks, and the
          // grips find the screen by their own ray test (see pointsAtScreen)
          Panel(R.id.immersive_photo_layer_panel, MeshCollision.NoCollision),
          Transform(Pose(Vector3(0f, DEFAULT_EYE_HEIGHT, StereoComposer.DISTANCE_M), Quaternion(0f, 0f, 0f))),
          Visible(false),
        )
      Log.i(TAG, "photo layer created")
    }
  }

  /**
   * Draws the photo of the layer on its Surface once the photo, the layer and the Surface are all there: each eye
   * stretched over its half, or one picture over the whole Surface (see FlatScreenLayer.eyeRegions), the quad giving
   * it its shape back (see [applyPhotoLayerShape]); then the layer shows. A Surface that cannot be drawn on gives the
   * photo to the quad mesh instead. True once drawn.
   */
  private fun drawPhotoLayer(): Boolean {
    val texture = photoLayerTexture ?: return false
    if (photoLayerDrawn) return true
    val surface = photoLayerSurface ?: return false
    if (photoLayerPanel == null || !surface.isValid || texture.bitmap.isRecycled) return false
    val drawn =
      try {
        val canvas = surface.lockHardwareCanvas()
        try {
          canvas.drawColor(Color.BLACK)
          val twoEyes = texture.hasSecondEye
          val (left, right) = FlatScreenLayer.eyeRegions(twoEyes)
          val paint = Paint(Paint.FILTER_BITMAP_FLAG)
          for ((eye, target) in if (twoEyes) listOf(0 to left, 1 to right) else listOf(0 to left)) {
            val source = FlatScreenLayer.sourceRegion(eye, texture.cellWidth, texture.cellHeight)
            canvas.drawBitmap(texture.bitmap, rectOf(source), rectOf(target), paint)
          }
        } finally {
          surface.unlockCanvasAndPost(canvas)
        }
        true
      } catch (e: Exception) {
        Log.e(TAG, "photo layer could not be drawn, the quad mesh shows the photo", e)
        false
      }
    if (!drawn) {
      photoLayerTexture = null
      photoLayerEntity?.setComponent(Visible(false))
      if (showOnMesh(texture)) {
        applyStereoMode()
        applyStereoScale()
        stereoQuadEntity?.setComponent(Visible(true))
      }
      return false
    }
    photoLayerDrawn = true
    applyPhotoLayerShape()
    applyStereoPlacement()
    photoLayerEntity?.setComponent(Visible(true))
    Log.i(
      TAG,
      "photo layer drawn: ${if (texture.hasSecondEye) "two eyes" else "one picture"} of " +
        "${texture.eyeWidth}x${texture.eyeHeight}, sharp ${request?.sharpFlatScreens != false}",
    )
    return true
  }

  /**
   * The stereo mode and the size of the photo layer for the photo on it: LeftRight in 3D, MonoLeft in 2D, the whole
   * Surface for one picture (see FlatScreenLayer.stereoMode), as wide as [stereoAngleDeg] at the distance of the screen
   * and as high as the picture. Nothing while the layer shows nothing.
   */
  private fun applyPhotoLayerShape() {
    val texture = photoLayerTexture ?: return
    val panel = photoLayerPanel ?: return
    val config = panel.panelShapeConfig ?: return
    val distance = screenPlace?.distance ?: screenDistanceM
    val mode = FlatScreenLayer.stereoMode(texture.hasSecondEye, stereoView() == StereoView.THREE_D)
    val (width, height) = FlatScreenLayer.quadSize(stereoAngleDeg, texture.eyeWidth, texture.eyeHeight, distance)
    if (config.stereoMode == mode && abs(config.width - width) < 1e-3f && abs(config.height - height) < 1e-3f) return
    try {
      config.stereoMode = mode
      config.width = width
      config.height = height
      panel.reshape(config)
      Log.i(TAG, "photo layer is now $mode, ${width}x$height m")
    } catch (e: Exception) {
      Log.e(TAG, "could not set the photo layer to $mode, ${width}x$height m", e)
    }
  }

  /** The photo layer shows nothing any more: hidden, its bitmap recycled. */
  private fun dropPhotoLayer() {
    photoLayerEntity?.setComponent(Visible(false))
    photoLayerTexture?.bitmap?.recycle()
    photoLayerTexture = null
    photoLayerDrawn = false
  }

  /** The photo is on the photo layer rather than on the quad mesh. */
  private val photoOnLayer: Boolean
    get() = photoLayerTexture != null

  private fun rectOf(region: FlatStereo.Region): Rect =
    Rect(region.x, region.y, region.x + region.width, region.y + region.height)

  /**
   * "Relief estimated by AI" on the status line while an estimated relief shows in 3D, then the line goes back to what
   * it said: the label comes and goes (FreeKC's rule of 25 October, djilink/TransientText.kt), at each new photo and
   * each return to 3D. Nothing for any other photo, which makes no such claim.
   */
  private fun showReliefEstimated() {
    val media = request ?: return
    if (media.stereoKind?.isEstimatedRelief != true || stereoView() == StereoView.TWO_D) return
    val label = StereoComposer.label(media.stereoLabels, StereoComposer.LABEL_RELIEF_ESTIMATED)
    Log.i(TAG, "stereo photo: relief estimated by AI, said for ${TransientText.HOLD_MS} ms")
    showPassing(label)
  }

  /** [text] on the status line for TransientText.HOLD_MS, then the line of the stereo photo again. */
  private fun showPassing(text: String) {
    setStatus(text)
    reliefLabelJob?.cancel()
    reliefLabelJob =
      scope.launch {
        delay(TransientText.HOLD_MS)
        reliefLabelJob = null
        if (statusView?.text?.toString() == text) showStatus(stereoStatus)
      }
  }

  /** The label goes with the 3D it describes. */
  private fun hideReliefEstimated() {
    val job = reliefLabelJob ?: return
    job.cancel()
    reliefLabelJob = null
    setStatus(stereoStatus)
  }

  /**
   * What is experimental about [media] when it first shows, said once (FreeKC's rule of 25 October: what is
   * experimental is said, and the words go): "3D told by the file name (experimental)" for a media told 3D by its file
   * name, at each such media; "Sharper flat screen (experimental)" for the first flat screen of this viewer the
   * compositor filters (see FlatScreenLayer). On the status line while the panel is up, which then stays as long, else
   * on the feedback line, for TransientText.HOLD_MS.
   */
  private fun announceFlat3d(media: MediaRequest) {
    if (request !== media || closing) return
    val lines = mutableListOf<String>()
    if (!flat3dAnnounced && media.isFlat3d) {
      flat3dAnnounced = true
      lines += StereoComposer.label(media.stereoLabels, StereoComposer.LABEL_FLAT3D_NOTICE)
    }
    if (!sharpNoticeShown && media.sharpFlatScreens && (photoOnLayer || media.isFlatVideo)) {
      sharpNoticeShown = true
      lines += StereoComposer.label(media.stereoLabels, StereoComposer.LABEL_SHARP_NOTICE)
    }
    if (lines.isEmpty()) return
    val text = lines.joinToString("\n")
    Log.i(TAG, "experimental: \"$text\" said for ${TransientText.HOLD_MS} ms")
    if (infoVisible) {
      // The status line comes back once the words went
      stereoStatus = statusView?.text?.toString().orEmpty()
      showPassing(text)
      if (hideInfoJob?.isActive == true) scheduleInfoHide(TransientText.HOLD_MS)
    } else {
      queueNotice(text)
    }
  }

  /**
   * What the quad shows now: 3D when the photo has both eyes and the user left it in 3D, 2.5D when a relief has its
   * mesh and 2.5D was chosen, 2D otherwise.
   */
  private fun stereoView(): StereoView =
    when {
      reliefMeshShown -> StereoView.MESH_25D
      stereo3d && stereoHasSecondEye -> StereoView.THREE_D
      else -> StereoView.TWO_D
    }

  /**
   * LeftRight in 3D, each eye its half of the texture; MonoLeft in 2D or without a second eye, and in 2.5D, where the
   * quad is the backdrop of the mesh. The mesh shows in 2.5D only. [applyStereoPlacement] puts both where they go.
   */
  private fun applyStereoMode() {
    val view = stereoView()
    // One picture alone in its cell (a photo on the big screen) shows whole, never its left half
    val mode =
      when {
        view == StereoView.THREE_D -> StereoMode.LeftRight
        stereoSingle -> StereoMode.None
        else -> StereoMode.MonoLeft
      }
    stereoQuadMaterial?.setStereoMode(mode)
    applyPhotoLayerShape()
    if (view == StereoView.MESH_25D) showReliefMesh() else reliefMeshEntity?.setComponent(Visible(false))
    // A mesh the SDK could not write went back to 3D, whose mode the call within writeReliefMesh set and said
    if (stereoView() != view) return
    val backdrop = if (view == StereoView.MESH_25D) ", backdrop of the 2.5D mesh" else ""
    Log.i(TAG, "stereo quad mode is now $mode$backdrop")
  }

  /**
   * The 3D button on a spatial photo: 3D, or the left eye in 2D; a relief made in the headset goes through 2.5D between
   * them (see StereoComposer.nextView). Nothing to switch without a second eye. While a relief is made it reads "Stop
   * relief", and stops it: the photo stays flat.
   */
  private fun toggleStereoPhotoMode(fromPanel: Boolean) {
    if (request?.isScene == true) {
      toggleScenePhoto(fromPanel)
      return
    }
    val run = reliefRun
    if (run != null && run.running) {
      Log.i(TAG, "relief: Stop relief")
      reliefJob?.stop(run)
      return
    }
    if (!stereoHasSecondEye) {
      Log.i(TAG, "spatial photo without a second eye: stays in 2D")
      return
    }
    val next = StereoComposer.nextView(stereoView(), meshAvailable = reliefMesh != null && reliefMeshReady)
    stereo3d = next != StereoView.TWO_D
    stereo25d = next == StereoView.MESH_25D
    // The mesh is exact from the pose the quad was placed at, not from where the head is now: showReliefMesh fades the
    // relief with the distance of the head from that pose (ReliefMesh.attenuation), flat from FLAT_M away
    applyStereoMode()
    applyStereoPlacement()
    updateStereoView()
    if (next != StereoView.TWO_D) showReliefEstimated() else hideReliefEstimated()
    showControlChange(fromPanel)
  }

  /**
   * Puts the quad 2 m in front of where the user looks, at the height of the eyes, facing them the way the info panel
   * does (see StereoComposer.quadRotation): the horizontal gaze. Before the first head pose, in front of the default
   * eye position; [onFrame] places it again once the pose is known.
   */
  private fun placeStereoQuad() {
    if (stereoQuadEntity == null) return
    val head = lastHeadPosition
    val eyes = head ?: Vector3(0f, DEFAULT_EYE_HEIGHT, 0f)
    val forward = lastHeadForward ?: Vector3(0f, 0f, 1f)
    val flat = sqrt(forward.x * forward.x + forward.z * forward.z)
    val direction = if (flat < 1e-3f) Vector3(0f, 0f, 1f) else Vector3(forward.x / flat, 0f, forward.z / flat)
    stereoEyes = Vector3(eyes.x, eyes.y, eyes.z)
    stereoGaze = direction
    stereoPlacedWithHead = head != null
    // A flat screen the user may move goes at the distance the user chose last (see ScreenPlace)
    screenPlace = if (request?.isMovableScreen == true) ScreenPlace.inFront(eyes, forward, screenDistanceM) else null
    // A 2.5D view starts again from here: the whole relief
    if (reliefMeshShown) {
      reliefAttenuation = 1.0
      writeReliefMesh(withTriangles = false)
    }
    applyStereoPlacement()
    updateScreenControls()
    Log.i(
      TAG,
      "stereo quad placed in front of $eyes, gaze $direction, head ${if (head != null) "known" else "unknown"}",
    )
  }

  /**
   * The quad at the start pose [placeStereoQuad] took last: 2 m along the gaze, at the height of the eyes, as wide as
   * its angle. In 2.5D the mesh has its eyes at that pose, and the quad goes just behind the farthest vertex of the
   * mesh, as wide to the eyes: a backdrop that shows the photo through the gaps the breaks of the mesh leave, so that
   * nothing is missing from the start pose, and that comes back to the plane of the quad as the relief fades.
   */
  private fun applyStereoPlacement() {
    val entity = stereoQuadEntity ?: return
    val place = screenPlace
    if (place != null && request?.isMovableScreen == true) {
      placeScreenPhoto(place)
      return
    }
    val eyes = stereoEyes ?: return
    val gaze = stereoGaze ?: return
    val (eyeWidth, eyeHeight) = stereoEyeSize ?: return
    val rotation = StereoComposer.quadRotation(gaze)
    val view = if (reliefMeshShown) reliefView() else null
    val mesh = reliefMesh
    val distance =
      if (view != null && mesh != null) {
        (mesh.farthest(view, reliefAttenuation) * (1 + BACKDROP_MARGIN) + BACKDROP_MARGIN_M).toFloat()
      } else {
        StereoComposer.DISTANCE_M
      }
    entity.setComponent(Transform(Pose(eyes + (gaze * distance), rotation)))
    val (width, height) = StereoComposer.quadSize(stereoAngleDeg, eyeWidth, eyeHeight, distance)
    entity.setComponent(Scale(Vector3(width, height, 1f)))
    if (view != null) reliefMeshEntity?.setComponent(Transform(Pose(eyes, rotation)))
  }

  /**
   * A photo of a flat screen at [place]: the photo layer, or the quad mesh as wide as its angle at that distance (see
   * [ScreenPlace]), both upright and facing the eyes it was placed from.
   */
  private fun placeScreenPhoto(place: ScreenPlace) {
    val pose = Pose(place.center, StereoComposer.quadRotation(place.direction))
    if (photoOnLayer) {
      photoLayerEntity?.setComponent(Transform(pose))
      applyPhotoLayerShape()
      return
    }
    val entity = stereoQuadEntity ?: return
    val (eyeWidth, eyeHeight) = stereoEyeSize ?: return
    entity.setComponent(Transform(pose))
    val (width, height) = StereoComposer.quadSize(stereoAngleDeg, eyeWidth, eyeHeight, place.distance)
    entity.setComponent(Scale(Vector3(width, height, 1f)))
  }

  /** The size of the quad for the angular width chosen and the eyes of the photo shown; the mesh too in 2.5D. */
  private fun applyStereoScale() {
    if (reliefMeshShown) {
      writeReliefMesh(withTriangles = false)
      applyStereoPlacement()
      return
    }
    screenPlace?.let { place ->
      if (request?.isMovableScreen == true) {
        placeScreenPhoto(place)
        return
      }
    }
    val (eyeWidth, eyeHeight) = stereoEyeSize ?: return
    val (width, height) = StereoComposer.quadSize(stereoAngleDeg, eyeWidth, eyeHeight)
    stereoQuadEntity?.setComponent(Scale(Vector3(width, height, 1f)))
  }

  /** The thumbstick up ([step] 1) or down (-1) on a spatial photo: a wider or narrower quad, where it is. */
  private fun resizeStereoQuad(step: Int) {
    val maxAngleDeg = request?.screenAngleBounds?.endInclusive ?: StereoComposer.MAX_ANGLE_DEG
    stereoAngleDeg = StereoComposer.nextAngle(stereoAngleDeg, step, maxAngleDeg)
    applyStereoScale()
    Log.i(TAG, "stereo quad is now $stereoAngleDeg degrees wide")
    val text = "${stereoAngleDeg.roundToInt()}°"
    if (infoVisible) setStatus(text) else showFeedback(text)
  }

  /** The scene made the mesh of the 2.5D view and its material. */
  private val reliefMeshReady: Boolean
    get() = reliefMeshMaterial != null && reliefTriangles != null && reliefSceneMesh != null

  /** The relief shown is on its mesh: 2.5D chosen, its mesh made, the scene ready, the texture of its eyes there. */
  private val reliefMeshShown: Boolean
    get() = stereo25d && stereoHasSecondEye && reliefMesh != null && reliefMeshReady

  /** The photo of the quad as the mesh sees it, with the settings of relief-v1 of its request. */
  private fun reliefView(): ReliefView? {
    val (eyeWidth, eyeHeight) = stereoEyeSize ?: return null
    val spec = (request?.stereoKind as? StereoPhotoKind.DepthRelief)?.spec ?: return null
    return ReliefView.forQuad(stereoAngleDeg, eyeWidth, eyeHeight, spec.parallax, spec.convergence)
  }

  /**
   * The mesh of the relief shown, in 2.5D: the texture of the quad on it, its triangles and texture coordinates written
   * once for this photo, its vertices for where the head is now (see [writeReliefMesh]), then visible.
   */
  private fun showReliefMesh() {
    val material = reliefMeshMaterial ?: return
    val texture = stereoTexture ?: return
    material.setAlbedoTexture(texture)
    material.setStereoMode(StereoMode.None)
    val eyes = stereoEyes
    val head = lastHeadPosition
    reliefAttenuation =
      if (eyes != null && head != null) ReliefMesh.attenuation(head.distanceTo(eyes).toDouble()) else 1.0
    if (!writeReliefMesh(withTriangles = !reliefMeshWritten)) return
    reliefMeshEntity?.setComponent(Visible(true))
  }

  /**
   * Writes the vertices of the mesh for [reliefAttenuation] and the photo of the quad as it is now, and with
   * [withTriangles] its texture coordinates and its triangles too. A failure of the SDK leaves the relief in 3D, said
   * in the log: false then.
   */
  private fun writeReliefMesh(withTriangles: Boolean): Boolean {
    val mesh = reliefMesh ?: return false
    val triangles = reliefTriangles ?: return false
    val sceneMesh = reliefSceneMesh ?: return false
    val view = reliefView() ?: return false
    val (eyeWidth, eyeHeight) = stereoEyeSize ?: return false
    return try {
      val positions = mesh.positions(view, reliefAttenuation, meshPositions ?: FloatArray(3 * ReliefMesh.MAX_VERTICES))
      meshPositions = positions
      val textureCoordinates =
        if (withTriangles) {
          val out = meshTextureCoordinates ?: FloatArray(2 * ReliefMesh.MAX_VERTICES)
          meshTextureCoordinates = out
          mesh.textureCoordinates(eyeWidth, eyeHeight, out)
        } else {
          null
        }
      triangles.updateGeometry(0, positions, RELIEF_MESH_NORMALS, textureCoordinates, null)
      if (withTriangles) triangles.updatePrimitives(0, mesh.indices())
      sceneMesh.updateWithTriangleMesh(triangles, false)
      if (withTriangles) {
        reliefMeshWritten = true
        Log.i(TAG, "relief mesh written: ${mesh.columns}x${mesh.rows} vertices, ${view.width}x${view.height} m")
      }
      true
    } catch (e: Throwable) {
      Log.e(TAG, "relief: the 2.5D mesh could not be written, shown in 3D", e)
      reliefMesh = null
      stereo25d = false
      reliefMeshEntity?.setComponent(Visible(false))
      applyStereoMode()
      applyStereoPlacement()
      updateStereoView()
      false
    }
  }

  /**
   * In 2.5D, at each frame with a head pose: the relief fades as the head moves away from the start pose (see
   * ReliefMesh.attenuation), the vertices and the backdrop moving again before a change could show.
   */
  private fun followHeadWithRelief(head: Vector3) {
    val eyes = stereoEyes ?: return
    val attenuation = ReliefMesh.attenuation(head.distanceTo(eyes).toDouble())
    if (!ReliefMesh.needsUpdate(reliefAttenuation, attenuation)) return
    if (attenuation == 0.0 || attenuation == 1.0) {
      Log.i(TAG, "relief: the 2.5D relief is now ${if (attenuation == 0.0) "flat" else "whole"}")
    }
    reliefAttenuation = attenuation
    if (writeReliefMesh(withTriangles = false)) applyStereoPlacement()
  }

  /**
   * Any other media: the quad goes away (its texture stays until the next spatial photo replaces it), and the mesh of
   * a relief and the photo layer with it.
   */
  private fun hideStereoQuad() {
    stereoQuadEntity?.setComponent(Visible(false))
    dropPhotoLayer()
    reliefMeshEntity?.setComponent(Visible(false))
    reliefMesh = null
    reliefMeshWritten = false
    stereo25d = false
    pendingStereo?.bitmap?.recycle()
    pendingStereo = null
    stereoPlacedWithHead = false
    // The eyes of the next photo are not known yet: until then nothing places the quad, and no grip finds a screen
    stereoEyeSize = null
  }

  private fun showPhoto(media: MediaRequest) {
    stopVideo()
    hideStereoQuad()
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
        // A panorama generated beyond the edges of a photo opens with the photo where the user looks: its head is read
        // beside the preview, and waited for only before the first image goes on the sphere (P4-review, m1: any 360°
        // photo would otherwise wait for one more request before its preview starts)
        val headRead = async { readPanoramaHead(media) }
        var shown = false
        // A photo on the headset has no preview: the file itself is right there
        val isLocal = ImmersiveMedia.localFileFor(media.url) != null
        val previewUrl = if (isLocal) null else ImmersiveMedia.previewUrlFor(media.url)
        if (previewUrl != null) {
          try {
            val bytes = download(previewUrl)
            headRead.await()
            decodeAndApply { ImmersiveMedia.decodeBytes(bytes) }?.let { (w, h) ->
              shown = true
              setPhotoStatus(getString(R.string.immersive_preview_loading_full, w, h))
              announcePanorama(media)
            }
          } catch (e: CancellationException) {
            throw e
          } catch (e: Throwable) {
            Log.w(TAG, "preview failed: ${e.message}", e)
          }
        }
        try {
          headRead.await()
          val (w, h) = loadFullResolution(media)
          setPhotoStatus(getString(R.string.immersive_full_resolution, w, h))
          announcePanorama(media)
          scheduleInfoHide(photoHideDelayMs())
        } catch (e: CancellationException) {
          throw e
        } catch (e: Throwable) {
          Log.e(TAG, "full resolution failed", e)
          if (shown) {
            // A failure notice shows at once, even while a previous/next request holds the other statuses back
            showStatus(getString(R.string.immersive_preview_only, e.message ?: e.javaClass.simpleName))
            scheduleInfoHide(photoHideDelayMs())
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
      // Its head could not be read before: its copy tells a generated panorama, the sphere left where it is
      if (!panoramaHeadRead) readPanoramaHeadFrom(media, file)
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

  // ---------------------------------------------------------------------------------------------
  // 360° panorama generated beyond the edges of a photo, see GeneratedPanorama and PanoramaOutline

  /**
   * Reads our packet at the head of the photo of [media] before its first image (see [GeneratedPanorama]): a panorama
   * generated beyond the edges of a photo then opens with the photo where the user looks, and its outline is written.
   * From the file on the headset, else the first bytes of its url by a range (a server that ignores the range sends
   * the start of the file, read no further). A read that fails or takes too long leaves the head unread: the
   * downloaded copy is read instead (see [loadFullResolution]).
   */
  private suspend fun readPanoramaHead(media: MediaRequest) {
    val bytes =
      try {
        withTimeoutOrNull(PANORAMA_HEAD_TIMEOUT_MS) { headBytesOf(media.url) }
      } catch (e: CancellationException) {
        throw e
      } catch (e: Throwable) {
        Log.w(TAG, "panorama: the head of the photo could not be read: ${e.message}")
        null
      }
    if (bytes == null) {
      Log.i(TAG, "panorama: the head of the photo was not read, its copy will be")
      return
    }
    val head = withContext(Dispatchers.Default) { GeneratedPanorama.readHead(bytes) }
    applyPanoramaHead(media, head, turn = true)
  }

  /** [readPanoramaHead] from the copy of the photo of [media] downloaded to [file], once its first image may show. */
  private suspend fun readPanoramaHeadFrom(media: MediaRequest, file: File) {
    val head =
      try {
        withContext(Dispatchers.IO) {
          file.inputStream().use { GeneratedPanorama.readHead(readUpTo(it, GeneratedPanorama.HEAD_BYTES)) }
        }
      } catch (e: CancellationException) {
        throw e
      } catch (e: Throwable) {
        Log.w(TAG, "panorama: the head of the downloaded photo could not be read: ${e.message}")
        return
      }
    applyPanoramaHead(media, head, turn = false)
  }

  /** The first bytes of the file at [url], at most GeneratedPanorama.HEAD_BYTES. */
  private suspend fun headBytesOf(url: String): ByteArray {
    ImmersiveMedia.localFileFor(url)?.let { local ->
      return withContext(Dispatchers.IO) { local.inputStream().use { readUpTo(it, GeneratedPanorama.HEAD_BYTES) } }
    }
    return fetch(httpRequest(url, range = "bytes=0-${GeneratedPanorama.HEAD_BYTES - 1}")) { response ->
      if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
      val input = response.body?.byteStream() ?: throw IOException("empty response")
      input.use { readUpTo(it, GeneratedPanorama.HEAD_BYTES) }
    }
  }

  /** At most [count] bytes of [input], fewer at its end. */
  private fun readUpTo(input: InputStream, count: Int): ByteArray {
    val buffer = ByteArray(count)
    var total = 0
    while (total < count) {
      val read = input.read(buffer, total, count - total)
      if (read < 0) break
      total += read
    }
    return if (total == count) buffer else buffer.copyOf(total)
  }

  /**
   * What the head of the photo of [media] says ([head], null for a photo without our packet of a panorama): the lines
   * of the panel, and for a panorama we generated whose photo this build reads, the outline, and with [turn] the yaw
   * of the sphere that brings the photo where the user looks now. Said once an image of it is on the sphere (see
   * [announcePanorama]), the full one when the head was read from the downloaded copy.
   */
  private fun applyPanoramaHead(media: MediaRequest, head: PanoramaHead?, turn: Boolean) {
    if (request !== media || closing) return
    panoramaHeadRead = true
    panoramaHead = head
    panoramaDetails = GeneratedPanorama.detailLines(head, media.stereoLabels)
    updateSceneControls()
    if (head == null) return
    val region = head.readableRegion
    Log.i(TAG, "panorama: ${head.kind}, origin ${head.origin}, photo ${region ?: "unknown"}, flags ${head.flags}")
    if (!head.isGenerated || region == null) return
    if (turn) {
      val forward = lastHeadForward
      val gaze =
        if (forward == null) 0.0 else GeneratedPanorama.gazeYawDegrees(forward.x.toDouble(), forward.z.toDouble())
      photoYaw = GeneratedPanorama.openingYaw(gaze, region, SKYBOX_YAW_DEGREES)
      applySphereTransforms()
      Log.i(TAG, "panorama: sphere at ${photoYaw.toInt()} degrees, its photo where the user looks (${gaze.toInt()})")
    }
    // Not on a 3D version: its relief brings things nearer than the outline, which would cut them
    if (!head.drawsOutline) return
    outlineRegion = region
    writeOutline(region)
  }

  /**
   * Once the first image of [media] is on the sphere, its sentence passes (on the status line while the panel is on
   * screen, the panel then staying as long, on the feedback panel otherwise) and its outline shows as long: once per
   * photo, for a panorama we generated or the 3D version of a 360° photo (see GeneratedPanorama.noticeOnSphere).
   */
  private fun announcePanorama(media: MediaRequest) {
    if (request !== media || closing || panoramaAnnounced || !panoramaHeadRead) return
    val text = GeneratedPanorama.noticeOnSphere(panoramaHead, media.stereoLabels, stereoLayout, coverage) ?: return
    panoramaAnnounced = true
    Log.i(TAG, "panorama: \"$text\" said for ${TransientText.HOLD_MS} ms, layout $stereoLayout, coverage $coverage")
    if (infoVisible) {
      // The status line comes back once the sentence went
      stereoStatus = statusView?.text?.toString().orEmpty()
      showPassing(text)
      if (hideInfoJob?.isActive == true) scheduleInfoHide(TransientText.HOLD_MS)
    } else {
      showNotice(text)
    }
    if (panoramaHead?.drawsOutline == true) showOutline()
  }

  /** The status line of a photo on a sphere, held under the sentence of a generated panorama while it passes. */
  private fun setPhotoStatus(text: String) {
    if (reliefLabelJob?.isActive == true) stereoStatus = text else setStatus(text)
  }

  /** The panel of a photo stays as long as the sentence of a generated panorama passes, the usual delay otherwise. */
  private fun photoHideDelayMs(): Long =
    if (reliefLabelJob?.isActive == true) TransientText.HOLD_MS else INFO_AUTO_HIDE_MS

  /**
   * The mesh of the outline of the photo on a panorama we generated ([PanoramaOutline]): one TriangleMesh made once as
   * the 2.5D one is, an unlit material, double sided, white (a texture of one white pixel: the colours of the vertices
   * make the dark and the light ribbons). Nothing drawn until such a panorama: every triangle has no area, and two
   * vertices give it bounds as wide as any outline.
   */
  private fun createPanoramaOutline() {
    registerMeshCreator(OUTLINE_MESH) { entity ->
      val material =
        entity.getComponent<Material>().generateSceneMaterial(entity, this).apply {
          setSidedness(MaterialSidedness.DOUBLE_SIDED)
        }
      try {
        val triangles =
          TriangleMesh(
            PanoramaOutline.VERTICES,
            PanoramaOutline.INDICES,
            intArrayOf(0, PanoramaOutline.INDICES),
            arrayOf(material),
          )
        val bounds =
          FloatArray(3 * PanoramaOutline.VERTICES).apply {
            floatArrayOf(-OUTLINE_BOUND_M, -OUTLINE_BOUND_M, -OUTLINE_BOUND_M).copyInto(this, 0)
            floatArrayOf(OUTLINE_BOUND_M, OUTLINE_BOUND_M, OUTLINE_BOUND_M).copyInto(this, 3)
          }
        triangles.updateGeometry(
          0,
          bounds,
          OUTLINE_NORMALS,
          FloatArray(2 * PanoramaOutline.VERTICES),
          IntArray(PanoramaOutline.VERTICES) { PanoramaOutline.LIGHT },
        )
        triangles.updatePrimitives(0, IntArray(PanoramaOutline.INDICES))
        SceneMesh.fromTriangleMesh(triangles, false).also {
          outlineTriangles = triangles
          outlineSceneMesh = it
        }
      } catch (e: Throwable) {
        // Without its triangles the entity stays hidden: the sentence alone tells a generated panorama
        Log.e(TAG, "panorama outline could not be made", e)
        SceneMesh.singleSidedQuad(0.001f, 0.001f, material)
      }
    }
    val entity =
      Entity.create(
        listOf(
          Mesh(Uri.parse(OUTLINE_MESH), hittable = MeshCollision.NoCollision),
          Material().apply { unlit = true },
          Transform(Pose(Vector3(0f, 0f, 0f), Quaternion(0f, photoYaw - SKYBOX_YAW_DEGREES, 0f))),
          Visible(false),
        ),
      )
    outlineEntity = entity
    systemManager.findSystem<SceneObjectSystem>().getSceneObject(entity)?.thenAccept { sceneObject ->
      runOnUiThread {
        if (sceneHold.isDown) return@runOnUiThread
        val material = sceneObject.mesh?.materials?.firstOrNull()
        if (material == null) {
          Log.e(TAG, "panorama outline material not found, the sentence alone tells a generated panorama")
          return@runOnUiThread
        }
        try {
          val white = Bitmap.createBitmap(intArrayOf(WHITE), 1, 1, Bitmap.Config.ARGB_8888)
          outlineTexture = SceneTexture(white).also { material.setAlbedoTexture(it) }
          white.recycle()
        } catch (e: Throwable) {
          Log.w(TAG, "panorama outline: no white texture, the default one stays", e)
        }
        Log.i(TAG, "panorama outline ready, ${PanoramaOutline.VERTICES} vertices")
        // A panorama of ours may wait for it
        val region = outlineRegion
        if (region != null && !outlineWritten) writeOutline(region)
      }
    } ?: Log.e(TAG, "panorama outline scene object not available")
  }

  /** Writes the outline of the photo of [region] in its mesh; a failure of the SDK leaves the sentence alone. */
  private fun writeOutline(region: PhotoRegion) {
    val triangles = outlineTriangles ?: return
    val sceneMesh = outlineSceneMesh ?: return
    try {
      val mesh = PanoramaOutline.mesh(region)
      triangles.updateGeometry(0, mesh.positions, OUTLINE_NORMALS, null, mesh.colors)
      triangles.updatePrimitives(0, mesh.indices)
      sceneMesh.updateWithTriangleMesh(triangles, false)
      outlineWritten = true
      Log.i(TAG, "panorama outline written for $region")
    } catch (e: Throwable) {
      Log.e(TAG, "panorama outline could not be written, the sentence alone tells it", e)
      outlineWritten = false
    }
  }

  /** The outline shows while the sentence passes, then goes with it (TransientText: held, then faded out). */
  private fun showOutline() {
    val entity = outlineEntity ?: return
    if (!outlineWritten) return
    entity.setComponent(Visible(true))
    outlineJob?.cancel()
    outlineJob =
      scope.launch {
        delay(TransientText.HOLD_MS + TransientText.FADE_OUT_MS)
        outlineJob = null
        // Read again rather than kept from above: null once the scene is gone
        outlineEntity?.setComponent(Visible(false))
      }
  }

  /** Another media, or the end of the viewer: what a generated panorama said and showed goes. */
  private fun dropPanorama() {
    panoramaHead = null
    panoramaHeadRead = false
    panoramaDetails = emptyList()
    panoramaAnnounced = false
    outlineRegion = null
    outlineWritten = false
    outlineJob?.cancel()
    outlineJob = null
    outlineEntity?.setComponent(Visible(false))
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
      pendingFirstFrameMessage = plan.firstFrameMessage
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
        it.repeatMode = repeatModeFor(media)
        it.addListener(playerListener)
        playbackStats = PlaybackStatsLogger(TAG, lens?.streams.orEmpty()).also(it::addAnalyticsListener)
        // Each lens renderer gets its own Surface of the compositor, never the player's surface API
        lens?.bindRendererOutputs()
        activeVideoSurface()?.let { surface -> attachVideoSurface(it, surface) }
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
      if (playback == null || playback !== twoLens) return
      recovery.onFrame()
      // A lens renderer's first frame is not on the panel yet: the compositor's is
      revealVideo()
      // The lens tried against the decoder list plays: the viewer reads why half of the sphere stays black, once
      pendingFirstFrameMessage?.let {
        pendingFirstFrameMessage = null
        showRawWarning(it)
      }
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
    if (p === player) playerOnFlatScreen = surface === flatVideoSurface
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

  /**
   * Whether the headset decodes [instances] streams like [track] at once, unknown when the JSON cannot tell. A refusal
   * says whether it is certain (a missing profile, no decoder for the codec), see [RawDecoderVerdict.of].
   */
  private fun canDecodeRaw(track: RawTrack, instances: Int): RawDecoderVerdict {
    val codec = track.codecs ?: track.codec ?: return RawDecoderVerdict.Unknown
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
    return RawDecoderVerdict.of(verdict.supported, verdict.reason, verdict.missingProfile)
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

  /** The message of [plan], if it has one, see the other [showRawWarning]. */
  private fun showRawWarning(plan: RawPlan) {
    showRawWarning(plan.message ?: return)
  }

  /** [message] on the status line for a while, like the decoder warning. */
  private fun showRawWarning(message: RawMessage) {
    val text =
      when (message) {
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
          // Only a kiosk plays a video once, the others loop. Its player goes then: out of this callback of its own
          Player.STATE_ENDED -> kiosk?.let { kiosk -> runKioskLater(kiosk.onEnded()) }
          Player.STATE_READY -> {
            // Normally the first frame did it already; a video that renders no frame still shows its panel. A lens
            // player's panel waits for the compositor's first frame, see LensListener
            if (twoLens == null) revealVideo()
            // Only the end of the loading hides the panel: a seek also goes through BUFFERING and READY, and the panel
            // the user is seeking on must not vanish
            val firstReady = hideWhenReady
            hideWhenReady = false
            val format = player?.videoFormat
            if (format != null) {
              Log.i(
                TAG,
                "video format: ${format.sampleMimeType} ${format.codecs ?: ""} ${format.width}x${format.height}, " +
                  "${format.frameRate} fps, ${format.bitrate} bit/s",
              )
            } else {
              Log.i(TAG, "video format: no video track")
            }
            // The codec, the size, the frame rate and the bit rate, as the details of the app tell them
            val description = format?.let(::videoLine) ?: "no video track"
            val warning = noPictureNotice ?: decoderWarning
            // The restart of the video, or its switch for a picture that did not come, says so once it plays again
            val notice = if (firstReady) playbackNotice.also { playbackNotice = null } else null
            // A video held until the viewer is back in front (playOnReturn) starts then: its loading is over all the
            // same. A video the user paused keeps the panel
            val starting = player?.playWhenReady == true || playOnReturn
            // During a drag or a pending previous or next request scheduleInfoHide holds the hide back, and setStatus
            // keeps "Looking for the next media" on screen
            if (notice != null) {
              setStatus(notice)
              if (starting) scheduleInfoHide(DECODER_WARNING_HIDE_MS)
            } else if (warning != null) {
              // Keeps the warning on screen for its own, longer delay, counted from the moment the video plays
              setStatus(warning)
              if (firstReady && starting) scheduleInfoHide(DECODER_WARNING_HIDE_MS)
            } else {
              // Under the words of a flat 3D video while they pass (see announceFlat3d), which the panel waits for
              setPhotoStatus(description.trim())
              if (firstReady && starting) scheduleInfoHide(photoHideDelayMs())
            }
            // A seek during a drag also ends with READY: the bar stays under the pointer until the drag ends
            if (!userSeeking) updateProgress()
          }
          else -> Unit
        }
      }

      override fun onRenderedFirstFrame() {
        // A lens renderer's first frame is still to be stitched: the compositor reveals the panel, see LensListener
        if (twoLens == null) {
          recovery.onFrame()
          revealVideo()
        }
      }

      override fun onPositionDiscontinuity(
        oldPosition: Player.PositionInfo,
        newPosition: Player.PositionInfo,
        reason: Int,
      ) {
        // A seek or a loop: the frames after the jump take a moment, the wait for a picture starts again
        recovery.onSeek()
      }

      override fun onTracksChanged(tracks: Tracks) {
        if (twoLens != null) checkLensDecoders(tracks) else selectedVideoFormat(tracks)?.let(::checkDecoderLimit)
      }

      override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (videoSize.width <= 0 || videoSize.height <= 0 || request?.isFlatVideo != true) return
        // The display size of the frame: an anamorphic video stores narrower pixels
        flatVideoSize = (videoSize.width * videoSize.pixelWidthHeightRatio).roundToInt() to videoSize.height
        applyFlatVideoShape()
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
        // A kiosk film that fails in its last seconds has as good as ended: the visitor gets the end card rather than
        // an error (the decoder crash at a fixed point near the end of a film of the exhibition builds). Earlier, the
        // fallbacks below go first, and what is left reaches the card through showError
        kiosk?.let { kiosk ->
          val p = player
          val commands = kiosk.onPlaybackFailure(p?.currentPosition ?: 0L, p?.duration ?: C.TIME_UNSET)
          if (commands.isNotEmpty()) {
            Log.w(TAG, "kiosk: ${error.errorCodeName} in the last seconds of the film, shown as its end")
            runKioskLater(commands)
            return
          }
        }
        // The player being replaced by a restart that waits: its errors are those of the failure it restarts from
        if (recovery.restartPending) return
        // The notice of an earlier restart or stream switch would show over what comes now; a restart says its own
        playbackNotice = null
        val plan = playerPlan
        if (plan?.mode == RawMode.EFFECT_SIDE_BY_SIDE && DualFisheyeEffect.isStitchingError(error) &&
          playWithoutStitching()
        ) {
          return
        }
        // A decoder or the media server that fails in the middle of the video: a new player plays the same url again
        // from where it stopped, once per media, before the ladder and the transcoded stream (PlaybackRecovery)
        val durationMs = player?.duration ?: C.TIME_UNSET
        when (val recovered = recovery.onFailure(error.errorCode, player?.currentPosition ?: 0L, durationMs)) {
          is PlaybackRecovery.Action.Restart -> {
            restartPlayback(recovered, error, durationMs)
            return
          }
          // Beyond the decoder: a new player, or the transcoded stream of a file, would meet the same frames
          is PlaybackRecovery.Action.Undecodable -> {
            stopUndecodable(recovered)
            return
          }
          PlaybackRecovery.Action.None -> return
          else -> Unit
        }
        if (plan?.mode == RawMode.LENSES) {
          // The ladder replaces the fallback of other videos: a lens player shows the error once it has nothing left
          val next = if (isDecoderError(error)) rawDecoderFailurePlan() else rawSourceFailurePlan(plan, error)
          if (!replanRaw(next)) failVideo(error)
          return
        }
        val fallback = currentVideoUrl?.let(::fallbackFor)
        if (!videoFallbackTried && fallback != null) {
          videoFallbackTried = true
          setStatus(getString(R.string.immersive_video_fallback, error.errorCodeName))
          playUrl(fallback, resumePositionMs())
        } else {
          failVideo(error)
        }
      }
    }

  /** Media3 errors of a decoder that cannot run (or no longer runs) the lens streams: the ladder's decoder step. */
  private fun isDecoderError(error: PlaybackException): Boolean =
    error.errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ||
      error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ||
      error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ||
      error.errorCode == PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED

  /**
   * The error the viewer shows for the current video, written to the Logs page of the app too with what the player
   * saw of it: nothing is left to try.
   */
  private fun failVideo(error: PlaybackException) {
    reportPlayback(PlaybackDetails.errorEvent(errorText(error)))
    showError(errorMessageFor(error))
  }

  /**
   * What the viewer says of [error]: in our words for a decoder that failed, a decoder that gives no picture (the stuck
   * checks of Media3) or a video too slow to come (see PlaybackErrors), with the codec and the size; else its own
   * message with the name of the error. Never the text of Media3 ("Player stuck playing with no progress for 10000
   * ms").
   */
  @OptIn(UnstableApi::class)
  private fun errorMessageFor(error: PlaybackException): String {
    val p = player
    val format = videoFormatForReport()
    val gotMedia = (p?.totalBufferedDuration ?: 0L) >= StreamingLoadControl.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS
    val kind = PlaybackErrors.kindOf(error, videoKnown = format != null, decoderGotMedia = gotMedia)
    val labels = request?.stereoLabels.orEmpty()
    val text =
      kind?.let {
        PlaybackDetails.errorText(
          labels,
          it,
          VideoDecoders.codecName(format?.sampleMimeType),
          format?.width ?: 0,
          format?.height ?: 0,
        )
      }
    return text ?: getString(R.string.immersive_error_video, error.errorCodeName)
  }

  /** The name of [error] and its cause, for a report. */
  private fun errorText(error: PlaybackException): String =
    error.errorCodeName + (error.cause?.let { " (${it.javaClass.simpleName}: ${it.message})" } ?: "")

  /**
   * Plays the current url again on a new player (see [PlaybackRecovery]): after the wait of [action] for the media
   * service, from its resume position, or for a decoder failure from the next sync frame of the file past it
   * ([nextSyncFrameMs], read during the wait; PlaybackRecovery.resumeAt) in a video of [durationMs]. The old player and
   * its decoders go just before the new one comes; the panel stays shown with the last frame its surface holds and
   * the notice says at once where the video stopped and where it plays again (not in a kiosk, which never shows the
   * panel: its visitors see the film go on). The failure goes to the Logs page. Never run from within the listener of
   * the player being replaced; [error] is null for a picture that stopped.
   */
  private fun restartPlayback(action: PlaybackRecovery.Action.Restart, error: PlaybackException?, durationMs: Long) {
    val media = request
    val url = currentVideoUrl
    if (media == null || url == null) {
      recovery.cancelRestart()
      return
    }
    val position = ImmersiveMedia.formatTime(action.positionMs)
    Log.w(
      TAG,
      "playback ${action.cause} at ${action.positionMs} ms: a new player from ${action.resumeMs} ms in " +
        "${action.delayMs} ms${action.syncFromMs?.let { ", or the next sync frame from $it ms" } ?: ""}",
    )
    // Said at once: the last frame stays on screen while the media service comes back
    cancelInfoHide()
    showStatus(PlaybackDetails.restartNotice(media.stereoLabels, position, ImmersiveMedia.formatTime(action.resumeMs)))
    setInfoVisible(true, reposition = true)
    val syncFrom = action.syncFromMs
    val nextSync = syncFrom?.let { from -> scope.async(Dispatchers.IO) { nextSyncFrameMs(url, from) } }
    restartJob?.cancel()
    restartJob =
      scope.launch(Dispatchers.Main) {
        delay(action.delayMs)
        val syncMs = nextSync?.let { withTimeoutOrNull(SYNC_LOOKUP_EXTRA_MS) { it.await() } }
        nextSync?.cancel()
        restartJob = null
        if (isDestroyed || request !== media || currentVideoUrl != url) {
          recovery.cancelRestart()
          return@launch
        }
        val resumeMs =
          if (syncFrom != null) PlaybackRecovery.resumeAt(action.positionMs, action.cause, durationMs, syncMs)
          else action.resumeMs
        val resume = ImmersiveMedia.formatTime(resumeMs)
        reportPlayback(
          if (error != null) PlaybackDetails.restartEvent(errorText(error), position, resume, action.delayMs)
          else PlaybackDetails.stoppedEvent(position)
        )
        // The same url: what was checked and said of it stays
        val checked = decoderChecked
        val lensChecked = lensDecodersChecked
        val warning = decoderWarning
        releasePlayer()
        if (ensurePlayer(media.url, media) == null) {
          recovery.cancelRestart()
          showError(getString(R.string.immersive_error_video, "player"))
          return@launch
        }
        // The messages of the plan were said for this url already: not again over the notice
        pendingRawMessage = null
        pendingFirstFrameMessage = null
        val notice = PlaybackDetails.restartNotice(media.stereoLabels, position, resume)
        Log.w(TAG, "shown to the user: $notice, from $resumeMs ms")
        playbackNotice = notice
        playUrl(url, resumeMs)
        decoderChecked = checked
        lensDecodersChecked = lensChecked
        decoderWarning = warning
        // Until the video plays and the first READY holds it on screen for a while
        cancelInfoHide()
        showStatus(notice)
        setInfoVisible(true, reposition = true)
      }
  }

  /** Drops the restart that waits, if any: the media changed or stopped. */
  private fun cancelRestart() {
    restartJob?.cancel()
    restartJob = null
    recovery.cancelRestart()
  }

  /**
   * The time of the first sync frame of the video track of [url] at or after [fromMs], from the index of the file read
   * through the same data sources as the player (the session of the app for a server url): a new decoder starts on a
   * whole picture there. Null when the file does not tell (no index, no video track, nothing after) or cannot be read.
   * Blocking: off the main thread.
   */
  @OptIn(UnstableApi::class)
  private fun nextSyncFrameMs(url: String, fromMs: Long): Long? {
    var opened: MediaExtractorCompat? = null
    return try {
      val dataSourceFactory = DefaultDataSource.Factory(this, HttpClientManager.createDataSourceFactory(emptyMap()))
      val extractor = MediaExtractorCompat(DefaultExtractorsFactory(), dataSourceFactory).also { opened = it }
      extractor.setDataSource(Uri.parse(url), 0L)
      val track =
        (0 until extractor.trackCount).firstOrNull {
          extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
        } ?: return null
      extractor.selectTrack(track)
      extractor.seekTo(fromMs * 1000L, MediaExtractorCompat.SEEK_TO_NEXT_SYNC)
      val timeUs = extractor.sampleTime
      Log.i(TAG, "next sync frame from $fromMs ms: ${if (timeUs >= 0L) "${timeUs / 1000L} ms" else "none"}")
      if (timeUs >= 0L) timeUs / 1000L else null
    } catch (e: Throwable) {
      // Never a crash of the restart that waits for it: it starts 3 s past the failure instead
      Log.w(TAG, "the next sync frame from $fromMs ms could not be read", e)
      null
    } finally {
      opened?.release()
    }
  }

  /**
   * Reads the player every PlaybackRecovery.TICK_MS while a video is loaded: its position, and the frames its video
   * renderer rendered, so that a video whose sound plays without picture is caught (see [PlaybackRecovery.onTick]).
   */
  private fun startRecoveryWatch() {
    if (recoveryJob?.isActive == true) return
    recoveryJob =
      scope.launch {
        while (true) {
          delay(PlaybackRecovery.TICK_MS)
          watchPicture()
        }
      }
  }

  private fun stopRecoveryWatch() {
    recoveryJob?.cancel()
    recoveryJob = null
  }

  /** One read of the player for [PlaybackRecovery.onTick], and what it decides. */
  @OptIn(UnstableApi::class)
  private fun watchPicture() {
    val p = player ?: return
    // While a restart waits, the old player has nothing to tell and the last read stays for the report
    if (currentVideoUrl == null || recovery.restartPending || rawReplanPending) return
    // A lens player draws through its compositor, whose frames the counters of the player do not see
    if (twoLens != null) return
    if (!PlaybackRecovery.watches(p.videoFormat?.frameRate ?: Format.NO_VALUE.toFloat())) return
    val counters = p.videoDecoderCounters
    counters?.ensureUpdated()
    watchedFrames = counters?.renderedOutputBufferCount ?: 0
    watchedDroppedFrames = counters?.droppedBufferCount ?: 0
    // A decoder that cannot keep up keeps Media3 ready, or waiting with more buffered than its load control asks: it
    // has data all the same. Less than that, still loading, is a wait for the network (the share bridge included)
    val fed =
      PlaybackRecovery.decoderFed(
        p.playWhenReady,
        p.playbackState,
        p.totalBufferedDuration,
        p.isLoading,
        StreamingLoadControl.playbackBufferMs(playerStreamed, rebuffering = true).toLong(),
      )
    when (
      val action = recovery.onTick(p.isPlaying, p.currentPosition, watchedFrames, SystemClock.elapsedRealtime(), fed)
    ) {
      is PlaybackRecovery.Action.Restart -> restartPlayback(action, null, p.duration)
      is PlaybackRecovery.Action.NoPicture -> sayNoPicture(action)
      is PlaybackRecovery.Action.Undecodable -> stopUndecodable(action)
      PlaybackRecovery.Action.PictureBack -> pictureBack(p)
      else -> Unit
    }
  }

  /**
   * Frames came again after the notice of a picture missing (a surface given late, a decoder that caught up): the
   * notice goes, the status line tells the video again, and the Logs page says so after its report.
   */
  private fun pictureBack(p: ExoPlayer) {
    val notice = noPictureNotice ?: return
    noPictureNotice = null
    Log.i(TAG, "the picture came back at ${p.currentPosition} ms")
    reportPlayback(PlaybackDetails.pictureBackEvent(ImmersiveMedia.formatTime(p.currentPosition)))
    if (statusView?.text?.toString() == notice) {
      setStatus(decoderWarning ?: p.videoFormat?.let(::videoLine) ?: "no video track")
    }
  }

  /**
   * No picture came for PlaybackRecovery.NO_PICTURE_MS while the sound played: the transcoded stream once when there
   * is one (from where the video is), otherwise the notice with the codec, the size, the frame rate and the bit rate
   * of the video, held on the panel like the decoder warning. Either way the Logs page gets the report, which is what
   * a user of a headset we do not have can send. Without the surface of the video panel no stream would show either:
   * the notice and the report then, which say so.
   */
  private fun sayNoPicture(action: PlaybackRecovery.Action.NoPicture) {
    val media = request ?: return
    val url = currentVideoUrl ?: return
    reportPlayback(PlaybackDetails.noPictureEvent(ImmersiveMedia.formatTime(action.positionMs), action.framesBefore))
    val video = videoFormatForReport()?.let(::videoLine) ?: "no video track"
    val fallback = fallbackFor(url)
    if (activeVideoSurface() != null && !videoFallbackTried && fallback != null) {
      videoFallbackTried = true
      val notice = PlaybackDetails.text(media.stereoLabels, PlaybackDetails.LABEL_NO_PICTURE_SWITCH, "video" to video)
      Log.w(TAG, "shown to the user: $notice")
      playbackNotice = notice
      playUrl(fallback, resumePositionMs())
      cancelInfoHide()
      showStatus(notice)
      setInfoVisible(true, reposition = true)
      return
    }
    val notice = PlaybackDetails.text(media.stereoLabels, PlaybackDetails.LABEL_NO_PICTURE, "video" to video)
    Log.w(TAG, "shown to the user: $notice")
    // Kept in place of the details while this url plays, like the decoder warning, until frames move again
    noPictureNotice = notice
    hideInfoJob?.cancel()
    showStatus(notice)
    setInfoVisible(true, reposition = true)
    scheduleInfoHide(DECODER_WARNING_HIDE_MS)
  }

  /** "HEVC (hvc1.2.4.L153) • 7680 x 3840 • 29.97 fps • 120 Mbit/s", see [PlaybackDetails.line]. */
  private fun videoLine(format: Format): String =
    PlaybackDetails.line(
      VideoDecoders.codecName(format.sampleMimeType),
      format.codecs,
      format.width,
      format.height,
      format.frameRate,
      format.bitrate,
      request?.stereoLabels.orEmpty(),
      Locale.getDefault(),
    )

  /**
   * The video format a report tells: the one the player decodes, else the first video track of the file, which the
   * player left aside when no decoder of the headset takes it.
   */
  private fun videoFormatForReport(): Format? {
    val p = player ?: return null
    p.videoFormat?.let {
      return it
    }
    for (group in p.currentTracks.groups) {
      if (group.type == C.TRACK_TYPE_VIDEO && group.length > 0) return group.getTrackFormat(0)
    }
    return null
  }

  /**
   * Writes [event] of the current video to the Logs page of the app (AppHealth), with the video, the decoder, the
   * frames, the video surface and the headset (see [PlaybackDetails.report]). Not the URL, which may hold a token.
   */
  @OptIn(UnstableApi::class)
  private fun reportPlayback(event: String) {
    val url = currentVideoUrl
    val counters = player?.videoDecoderCounters
    counters?.ensureUpdated()
    val soc =
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) ", SoC ${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}" else ""
    val device =
      "${Build.MANUFACTURER} ${Build.MODEL}$soc, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), " +
        "build ${Build.DISPLAY}"
    AppHealth.report(
      "video",
      PlaybackDetails.report(
        event = event,
        title = request?.title,
        source = url?.let { PlaybackDetails.sourceOf(it, isFallback = it == request?.fallbackUrl) } ?: "no URL",
        video = videoFormatForReport()?.let(::videoLine),
        decoder = playbackStats?.decoderName,
        // The counters go with the renderer, which a failure disables: the last read then tells
        renderedFrames = counters?.renderedOutputBufferCount ?: watchedFrames,
        droppedFrames = counters?.droppedBufferCount ?: watchedDroppedFrames,
        surfaceReady = activeVideoSurface() != null,
        device = device,
      ),
    )
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
   * A video above what the headset decodes plays at a fraction of its frame rate, with block artifacts, or not at all
   * (one frame in 19.6 s for the H.264 5760 x 2880 of 30 October): H.264 above 4096 x 2304 on the Quest 3, whatever
   * its decoder list says, or anything the list refuses (see VideoDecoders). Flutter chose the file decodability first
   * and this checks what the player found (see [VideoStartRule.overLimit]): the transcoded stream Flutter sent, once;
   * else a server video stops at once and says what to change in Immich; else (a file of the headset or of a network
   * share) the warning says a re-encode plays, and the rule of [PlaybackRecovery.onOverLimit] stops a decoder that
   * gives no frame for 3 s.
   */
  private fun checkDecoderLimit(format: Format) {
    val url = currentVideoUrl ?: return
    val media = request ?: return
    if (decoderChecked || format.width <= 0 || format.height <= 0) return
    decoderChecked = true
    val verdict = VideoDecoders.canDecode(format)
    if (verdict.supported) return
    val codec = VideoDecoders.codecName(format.sampleMimeType)
    val size = "${format.width}x${format.height}"
    Log.w(TAG, "$codec $size is above what the headset decodes (${verdict.reason})")
    val fallback = media.fallbackUrl?.takeIf { it != url }
    // A server video whose original came downloaded is still a server video: its server can make a copy that plays
    val fromServer = !ImmersiveMedia.isFileMedia(media.url)
    val originalLeft = originalLeftForCopy && url == media.fallbackUrl
    originalLeftForCopy = false
    when (
      VideoStartRule.overLimit(
        fallbackLeft = !videoFallbackTried && fallback != null,
        fromServer = fromServer,
        originalLeft = originalLeft,
      )
    ) {
      VideoStartRule.OverLimit.SWITCH -> {
        videoFallbackTried = true
        setStatus(getString(R.string.immersive_video_decoder_switch, "$codec $size"))
        playUrl(fallback ?: return, resumePositionMs())
      }
      VideoStartRule.OverLimit.ORIGINAL -> playOriginalOverCopy(media, "$codec $size")
      VideoStartRule.OverLimit.REFUSE -> {
        val message =
          if (verdict.maxWidth > 0 && verdict.maxHeight > 0) {
            PlaybackDetails.undecodableText(
              media.stereoLabels,
              codec,
              format.width,
              format.height,
              verdict.maxWidth,
              verdict.maxHeight,
            )
          } else {
            getString(R.string.immersive_codec_too_large, codec, format.width, format.height)
          }
        val event = PlaybackDetails.refusedEvent(codec, format.width, format.height, verdict.maxWidth, verdict.maxHeight)
        refuseVideo(message, event)
      }
      VideoStartRule.OverLimit.WARN -> {
        val warning = getString(R.string.immersive_codec_too_large_file, codec, format.width, format.height)
        Log.w(TAG, "shown to the user: $warning")
        decoderWarning = warning
        recovery.onOverLimit(SystemClock.elapsedRealtime())
        hideInfoJob?.cancel()
        // At once, like an error: held back under a pending request, the answer would overwrite it unread
        showStatus(warning)
        setInfoVisible(true, reposition = true)
        scheduleInfoHide(DECODER_WARNING_HIDE_MS)
      }
    }
  }

  /**
   * The copy of [media] that played because its original could not stream is beyond the decoder ([copy], its codec and
   * size): the original, which Flutter could not compare with it (the head of the copy unread), is downloaded with its
   * progress on the status line and played instead, once; streamed as it is when it cannot be downloaded. Beyond the
   * decoder too, it stops at its own first tracks with what to change in Immich (no fallback left).
   */
  private fun playOriginalOverCopy(media: MediaRequest, copy: String) {
    Log.w(TAG, "the copy $copy is beyond the decoder, downloading the original")
    stopVideo()
    loadJob?.cancel()
    loadJob =
      scope.launch {
        val url = downloadOriginal(media) ?: media.url
        if (request !== media) return@launch
        playUrl(url, media.startPositionMs)
      }
  }

  /**
   * A decoder beyond its limit gave no frame for 3 s while it had data, or failed ([PlaybackRecovery.onOverLimit]):
   * the video stops with the warning it got at its first tracks, rather than Media3's own check after 10 s, and no
   * restart nor stream switch follows.
   */
  private fun stopUndecodable(action: PlaybackRecovery.Action.Undecodable) {
    if (request == null) return
    val format = videoFormatForReport()
    val codec = VideoDecoders.codecName(format?.sampleMimeType)
    val width = format?.width ?: 0
    val height = format?.height ?: 0
    val message =
      decoderWarning ?: getString(R.string.immersive_codec_too_large_file, codec, width, height)
    Log.w(TAG, "no frame from the decoder beyond its limit at ${action.positionMs} ms, stopped")
    val position = ImmersiveMedia.formatTime(action.positionMs)
    refuseVideo(message, PlaybackDetails.noPictureEvent(position, action.framesBefore) + ", beyond the decoder")
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

  /** The Surface the player draws on: the flat video screen for a flat 3D video, the sphere for any other video. */
  private fun activeVideoSurface(): Surface? = if (request?.isFlatVideo == true) flatVideoSurface else videoSurface

  /**
   * The entity of the flat video screen, made at the first flat 3D video, hidden until its first frame; null once the
   * scene is down, whoever calls.
   */
  private fun ensureFlatVideoEntity(): Entity? {
    // The screen reads null from the shutdown on: Entity.create would run on the cleared EntityContext and throw
    if (sceneHold.isDown) return null
    return flatVideoEntity
      ?: Entity.create(
          // Never hit by the controller ray, as the photo layer (see showOnLayer)
          Panel(R.id.immersive_flat_video_panel, MeshCollision.NoCollision),
          Transform(Pose(Vector3(0f, DEFAULT_EYE_HEIGHT, StereoComposer.DISTANCE_M), Quaternion(0f, 0f, 0f))),
          Visible(false),
        )
        .also {
          flatVideoEntity = it
          Log.i(TAG, "flat video screen created")
        }
  }

  /**
   * The stereo mode and the size of the flat video screen for the video shown: for a flat 3D video, each
   * eye its half of the frame in 3D, the first eye for both in 2D (see [FlatStereo.stereoModeFor]); for an ordinary
   * video on the big screen, its whole frame for both eyes. As wide as [flatVideoAngle] at the distance of the screen,
   * as high as one eye once the player told the frame size, 16:9 until then. Like the sphere (see [applyVideoShape]),
   * the layer is made again by PanelSceneObject.reshape on the same swapchain while the video plays. Nothing for any
   * other media, nor before the panel exists (its setup calls this again).
   */
  private fun applyFlatVideoShape() {
    val panel = flatVideoPanel ?: return
    val media = request ?: return
    if (!media.isFlatVideo) return
    val config = panel.panelShapeConfig
    if (config == null) {
      Log.w(TAG, "flat video panel without a shape config, ${media.flatVideo ?: "big screen"} not applied")
      return
    }
    val (mode, aspect) = flatVideoLook() ?: return
    val distance = screenPlace?.distance ?: screenDistanceM
    val (width, height) = FlatStereo.screenSize(aspect, flatVideoAngle(aspect), distance)
    val same = config.stereoMode == mode && abs(config.width - width) < 1e-3f && abs(config.height - height) < 1e-3f
    // A grab calls this at every frame: the shape, and the Size and Distance rows of the panel, only once changed
    if (same) return
    try {
      config.stereoMode = mode
      config.width = width
      config.height = height
      panel.reshape(config)
      val what = media.flatVideo ?: "big screen"
      Log.i(TAG, "flat video screen is now $mode, ${width}x$height m ($what, frame $flatVideoSize)")
    } catch (e: Exception) {
      Log.e(TAG, "could not set the flat video screen to $mode, ${width}x$height m", e)
    }
    updateScreenControls()
  }

  /**
   * The stereo mode of the flat video screen and the aspect of an eye (width over height, 0 until the player told the
   * frame size) for the video shown: a flat 3D video, each eye its half of the frame in 3D, the first eye for both in
   * 2D, its eyes said full by the name alone squeezed when the frame says so (a share page asks before its player knows
   * the size); an ordinary video on the big screen, its whole frame for both eyes. Null for any other media.
   */
  private fun flatVideoLook(): Pair<StereoMode, Float>? {
    val media = request ?: return null
    if (!media.isFlatVideo) return null
    val frame = flatVideoSize
    val spec = media.flatVideo
    if (spec == null) {
      val aspect = if (frame == null) 0f else frame.first.toFloat() / frame.second
      return StereoMode.None to aspect
    }
    val format = if (frame == null) spec.format else FlatStereo.videoFormat(spec.format, frame.first, frame.second)
    val aspect = if (frame == null) 0f else FlatStereo.eyeAspect(format, frame.first, frame.second)
    return FlatStereo.stereoModeFor(format, stereo3d) to aspect
  }

  /**
   * The angular width of the flat video screen for an eye of [aspect] (width over height, 0 while unknown): the one
   * the user gave this video, else as wide as fits its shape (see FlatScreenGeometry.fittingAngle).
   */
  private fun flatVideoAngle(aspect: Float): Float = flatVideoAngleDeg ?: FlatScreenGeometry.fittingAngle(aspect)

  /**
   * The compositor filters of the flat screen [panel] for the media shown (see [FlatScreenLayer.filters]): those of
   * Sharper flat screens while it is on, none otherwise. Set again at each media, the opening that made the panel
   * having possibly said otherwise, and never at each frame of a grab.
   */
  private fun applyLayerFilters(panel: PanelSceneObject) {
    val sharp = request?.sharpFlatScreens != false
    try {
      panel.layer?.setFilters(FlatScreenLayer.filters(sharp))
    } catch (e: Exception) {
      Log.w(TAG, "could not set the filters of a flat screen layer (sharp $sharp)", e)
    }
  }

  /**
   * Puts the flat video screen in front of where the user looks, at the distance the user chose last for a flat screen
   * (2 m until then, see [ScreenPlace]), at the height of the eyes, facing them, as the stereo quad (see
   * [placeStereoQuad]). Before the first head pose, in front of the default eye position; [onFrame] places it again
   * once the pose is known. The right thumbstick left or right calls it too.
   */
  private fun placeFlatVideo() {
    if (flatVideoEntity == null) return
    val head = lastHeadPosition
    val eyes = head ?: Vector3(0f, DEFAULT_EYE_HEIGHT, 0f)
    val forward = lastHeadForward ?: Vector3(0f, 0f, 1f)
    val place = ScreenPlace.inFront(eyes, forward, screenDistanceM)
    screenPlace = place
    placeFlatScreen(place)
    flatPlacedWithHead = head != null
  }

  /** The flat video screen at [place], as wide as its angle at that distance. */
  private fun placeFlatScreen(place: ScreenPlace) {
    flatVideoEntity?.setComponent(Transform(Pose(place.center, Quaternion.lookRotation(place.direction))))
    applyFlatVideoShape()
  }

  private fun showVideo(media: MediaRequest) {
    hideStereoQuad()
    resetSkyboxToIdle()
    skyboxEntity?.setComponent(Visible(false))
    halfSphereEntity?.setComponent(Visible(false))
    // Hidden until the first frame of this video: the surface still holds the last frame of the previous one
    videoRevealed = false
    videoEntity?.setComponent(Visible(false))
    flatVideoEntity?.setComponent(Visible(false))
    if (media.isFlatVideo) {
      // A flat 3D video starts in 3D, at 16:9 until the player tells its frame size, in front of the user
      ensureFlatVideoEntity()
      stereo3d = true
      flatVideoSize = null
      flatVideoAngleDeg = null
      flatPlacedWithHead = false
      // The filters of this opening, once per video: a reshape keeps them
      flatVideoPanel?.let(::applyLayerFilters)
      applyFlatVideoShape()
      placeFlatVideo()
      updateStereoView()
    }
    player?.stop()
    // playUrl decides again for this video whether it starts now or once the viewer is back in front
    playOnReturn = false
    // No video until playUrl: the time bar must not show the duration of the previous one meanwhile
    currentVideoUrl = null
    updateProgress()
    applyVideoShape()
    videoFallbackTried = false
    originalLeftForCopy = false
    cancelRestart()
    recovery.onMedia()
    // The word of Flutter on the file it chose, said once the video plays (see the READY state)
    playbackNotice = media.sourceNotice
    setStatus(getString(R.string.immersive_loading))
    val videoPlayer = ensurePlayer(media.url, media)
    if (videoPlayer == null) {
      showError(getString(R.string.immersive_error_video, "player"))
      return
    }
    // A player kept from the video before may draw on the other layer: the flat screen for a flat 3D video, else the
    // sphere. A surface not there yet takes the player once it is, see registerPanels
    if (twoLens == null && playerOnFlatScreen != media.isFlatVideo) {
      activeVideoSurface()?.let { attachVideoSurface(videoPlayer, it) }
    }
    loadJob =
      scope.launch {
        // Flutter sends the copy as the fallback only when the headset decodes it (decodability first)
        val playback = fallbackFor(media.url)
        // A raw plan may start on the transcoded stream, a lens plan opens its own urls
        var url = plannedUrl(media)
        val refusal = media.sourceRefusal
        val plain = playerPlan?.mode != RawMode.LENSES
        val original = url == media.url
        val streamed = StreamingLoadControl.isStreamed(media.url)
        val fileMedia = ImmersiveMedia.isFileMedia(media.url)
        val streamable =
          !VideoStartRule.probes(refusal != null, plain, original, streamed, fileMedia) || isStreamable(media)
        when (VideoStartRule.start(refusal != null, plain, original, streamed, fileMedia, playback != null, streamable)) {
          VideoStartRule.Start.REFUSE -> {
            refuseVideo(refusal.orEmpty(), PlaybackDetails.refusedEvent(null, 0, 0, 0, 0))
            return@launch
          }
          VideoStartRule.Start.FALLBACK -> {
            // No Range support on /original and the MP4 index at the end: the whole file would have to
            // download before the first frame, the transcoded stream streams
            Log.i(TAG, "original not streamable, using the transcoded stream")
            videoFallbackTried = true
            originalLeftForCopy = playback != null
            url = playback ?: url
          }
          VideoStartRule.Start.DOWNLOAD -> {
            // The same, with a copy the headset cannot decode (or none): the original comes whole first, then plays
            Log.i(TAG, "original not streamable and no copy to play, downloading it")
            url = downloadOriginal(media) ?: url
          }
          VideoStartRule.Start.URL -> Unit
        }
        if (request !== media) return@launch
        playUrl(url, media.startPositionMs)
      }
  }

  /**
   * Downloads the original of [media], a server original that cannot stream and whose copy is no fallback (see
   * [VideoStartRule]), to the cache with its progress on the status line, and gives its file url. Null when the server
   * tells no size, when the cache has no room for it (see [VideoStartRule.fits]) or when the download fails: the
   * original then streams as it is, Media3 reading the whole file before its first frame. Only one original is kept
   * there (the one of the video before goes), and the viewer removes it when it finishes; a cancellation (the next
   * media, the viewer closing) removes the partial file.
   */
  private suspend fun downloadOriginal(media: MediaRequest): String? {
    val dir = File(cacheDir, DOWNLOAD_DIR).apply { mkdirs() }
    val name = "original-${Integer.toHexString(media.url.hashCode())}.mp4"
    val target = File(dir, name)
    val partial = File(dir, "$name.part")
    dir.listFiles()?.filter { it.name != name }?.forEach { it.delete() }
    return try {
      fetch(httpRequest(media.url)) { response ->
        if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
        val body = response.body ?: throw IOException("empty response")
        val total = body.contentLength()
        if (total > 0 && target.length() == total) {
          Log.i(TAG, "original already downloaded: $total bytes")
          return@fetch target
        }
        val free = dir.usableSpace + target.length()
        if (!VideoStartRule.fits(total, free)) {
          Log.w(TAG, "original of $total bytes not downloaded, $free bytes free in the cache: streaming it")
          return@fetch null
        }
        target.delete()
        var done = 0L
        var shown = -1
        body.byteStream().use { input ->
          partial.outputStream().use { output ->
            val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
            while (true) {
              ensureActive()
              val read = input.read(buffer)
              if (read < 0) break
              output.write(buffer, 0, read)
              done += read
              val percent = VideoStartRule.percent(done, total) ?: 0
              if (percent != shown) {
                shown = percent
                runOnUiThread { if (request === media && !isDestroyed) setStatus(downloadLine(media, percent)) }
              }
            }
          }
        }
        if (done != total) throw IOException("the download ended at $done of $total bytes")
        if (!partial.renameTo(target)) throw IOException("the download could not be kept")
        Log.i(TAG, "original downloaded: $total bytes")
        target
      }?.let { Uri.fromFile(it).toString() }
    } catch (e: CancellationException) {
      partial.delete()
      throw e
    } catch (e: Exception) {
      partial.delete()
      Log.w(TAG, "the original could not be downloaded, streaming it", e)
      null
    }
  }

  /** The status line of a download at [percent], with the word of Flutter on the file chosen when it sent one. */
  private fun downloadLine(media: MediaRequest, percent: Int): String {
    val line = PlaybackDetails.downloadingText(media.stereoLabels, percent)
    return media.sourceNotice?.let { "$line\n$it" } ?: line
  }

  /**
   * Stops the video of the current media and says [message] instead, held on the panel as an error: a video nothing
   * the server has decodes (the refusal of Flutter, or a format beyond the decoder at its first tracks with no copy to
   * go to), or a decoder beyond its limit that gave no frame. The Logs page gets [event] in its report. Previous and
   * next stay, a new media plays as any other.
   */
  private fun refuseVideo(message: String, event: String) {
    reportPlayback(event)
    stopVideo()
    showError(message)
  }

  /** Shows the video panel once the current video has a frame on it, see [videoRevealed]. */
  private fun revealVideo() {
    val media = request
    if (videoRevealed || media?.isVideo != true || currentVideoUrl == null) return
    videoRevealed = true
    (if (media.isFlatVideo) flatVideoEntity else videoEntity)?.setComponent(Visible(true))
    updateScreenControls()
    announceFlat3d(media)
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
    noPictureNotice = null
    notSeekableShown = false
    hideWhenReady = true
    val kind =
      when {
        url == request?.fallbackUrl || url.contains("/video/playback") -> "playback"
        !url.startsWith("http") -> "local copy"
        else -> "original"
      }
    Log.i(TAG, "play $kind from $startPositionMs ms")
    recovery.onPlay()
    watchedFrames = 0
    watchedDroppedFrames = 0
    startRecoveryWatch()
    // The same player may serve a kiosk opening after another one
    p.repeatMode = repeatModeFor(request)
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
    playbackNotice = null
    stopProgressTicker()
    stopRecoveryWatch()
    cancelRestart()
    player?.let {
      it.stop()
      it.clearMediaItems()
    }
    videoRevealed = false
    videoEntity?.setComponent(Visible(false))
    flatVideoEntity?.setComponent(Visible(false))
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

  /** The headset was put on: a kiosk gives the next visitor its film from the start, see [KioskSession.onMounted]. */
  override fun onHMDMounted() {
    super.onHMDMounted()
    Log.i(TAG, "headset on")
    // The player lives on the main thread
    runOnUiThread { kiosk?.let { runKiosk(it.onMounted()) } }
  }

  /** The headset was taken off: a kiosk lets the player of its film go, see [KioskSession.onUnmounted]. */
  override fun onHMDUnmounted() {
    super.onHMDUnmounted()
    Log.i(TAG, "headset off")
    runOnUiThread { kiosk?.let { runKiosk(it.onUnmounted()) } }
  }

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
    val sceneState = if (sceneHold.isDown) "already shut down" else "up"
    Log.i(TAG, "immersive viewer onDestroy, finishing $isFinishing, scene $sceneState")
    // Last chance for the closed event when the viewer is finishing (onStop already sent it when it was stopped first).
    // A destroy that is not a finish (a recreation for a configuration change the manifest does not list, or the system
    // tearing down the stopped viewer while keeping its record) is no close: the viewer comes back from its saved
    // state under the same opening, and sends the event when it closes
    if (isFinishing) {
      reportClosed()
      // The original downloaded to play a video that cannot stream: as large as the video, kept only while it shows
      File(cacheDir, DOWNLOAD_DIR).listFiles()?.forEach { it.delete() }
    }
    pendingRequestId = null
    navigationTimeoutJob?.cancel()
    navigationTimeoutJob = null
    if (liveViewer === this) liveViewer = null
    // A viewer that finished at its onPause or at its onStop had its onSpatialShutdown there (the SDK runs it from
    // either once the viewer is finishing): the objects of the scene read null, and these drops only let the jobs and
    // the bitmaps go. Any other viewer, destroyed without a finish or finished while already stopped, drops its scene
    // here, before the shutdown that super.onDestroy runs
    releaseRelief()
    dropScene()
    dropSplat()
    dropPhotoLayer()
    scope.cancel()
    super.onDestroy()
  }

  /**
   * The scene of the SDK goes: VrActivity.destroy runs this method, then destroys the scene and clears EntityContext,
   * at the first of onPause, onStop or onDestroy that finds the viewer finishing, else at its onDestroy. So a viewer
   * finishing at its onPause gets it from super.onPause, before the rest of its onPause, its onStop and its onDestroy;
   * one finished between its onPause and its onStop, from super.onStop, at the end of its onStop; any other viewer
   * (destroyed without a finish, or finished while already stopped), from super.onDestroy, after the body of its
   * onDestroy. First of all every object of the scene is let go (see [SpatialHold]): nothing that runs from here on,
   * the drops of onDestroy, a coroutine, a post or a callback, reaches an entity, a panel or a texture of a scene gone.
   */
  override fun onSpatialShutdown() {
    sceneHold.shutDown()
    Log.i(TAG, "immersive viewer shutdown")
    rememberPosition()
    stopProgressTicker()
    pendingRequestId = null
    navigationTimeoutJob?.cancel()
    navigationTimeoutJob = null
    releaseRelief()
    // The entities of a scene are let go without a call to the SDK, its textures go with the scene as the others do
    sceneView?.abandon()
    sceneView = null
    // So does the entity of a splat: no call on it from now on, whatever comes later (lot S5)
    splatStage?.shutDown()
    splatStage = null
    scope.cancel()
    // The player first, then the lens compositor, before the panel goes
    releasePlayer()
    pendingBitmap?.recycle()
    pendingBitmap = null
    pendingStereo?.bitmap?.recycle()
    pendingStereo = null
    // The bitmap of the photo layer recycled. The layer, the textures still bound to the materials and the triangles
    // go with the scene, as in the samples: sceneHold.shutDown let go of them
    dropPhotoLayer()
    reliefMesh = null
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
    /** The JSON of the two eyes of an Apple spatial photo, absent for any other media; put by ImmersiveApiImpl.open */
    internal const val EXTRA_STEREO_PAIR = "app.alextran.immich.immersive.STEREO_PAIR"
    private const val EXTRA_REVERSE_THUMBSTICK_TURN = "app.alextran.immich.immersive.REVERSE_THUMBSTICK_TURN"
    private const val EXTRA_SHARP_FLAT_SCREENS = "app.alextran.immich.immersive.SHARP_FLAT_SCREENS"
    /** The Gaussian splats setting of the opening, see MediaRequest.gaussianSplats */
    private const val EXTRA_GAUSSIAN_SPLATS = "app.alextran.immich.immersive.GAUSSIAN_SPLATS"
    /** The kiosk JSON of a kiosk opening (see [KioskOptions]), absent for any other opening */
    private const val EXTRA_KIOSK = "app.alextran.immich.immersive.KIOSK"
    /** What to tell of the file chosen for a video, and the refusal of a video nothing decodes, see [MediaRequest] */
    private const val EXTRA_SOURCE_NOTICE = "app.alextran.immich.immersive.SOURCE_NOTICE"
    private const val EXTRA_SOURCE_REFUSAL = "app.alextran.immich.immersive.SOURCE_REFUSAL"
    /** The folder of the cache the original of a video that cannot stream is downloaded to, see downloadOriginal */
    private const val DOWNLOAD_DIR = "immersive_video"
    private const val DOWNLOAD_BUFFER_BYTES = 256 * 1024
    /** The media shown, in the saved state of a recreation, with the same keys as the extras of [intent]. */
    private const val STATE_REQUEST = "app.alextran.immich.immersive.REQUEST"
    /** The 3D or 2D choice and the angular width of the spatial photo shown, in the saved state of a recreation. */
    private const val STATE_STEREO_3D = "app.alextran.immich.immersive.STEREO_3D"
    private const val STATE_STEREO_ANGLE_DEG = "app.alextran.immich.immersive.STEREO_ANGLE_DEG"
    private const val STATE_STEREO_25D = "app.alextran.immich.immersive.STEREO_25D"
    private const val ORIGINAL_PREFIX = "immersive_original_"
    /** The copies of the splat files in the cache: a download, a reduction, a file named after its format */
    private const val SPLAT_PREFIX = "immersive_splat_"
    /** The orientation chosen for each splat file, see SplatUprightMemory */
    private const val SPLAT_PREFERENCES = "immersive_splat"
    private const val INFO_DISTANCE = 1.3f
    /** The info panel stands this much below the eyes, at INFO_DISTANCE. */
    private const val INFO_DROP = 0.3f
    private const val INFO_AUTO_HIDE_MS = 4000L
    private const val DECODER_WARNING_HIDE_MS = 10000L
    /**
     * How long a restart after a decoder failure waits for the next sync frame of the file once its own wait is over
     * (PlaybackRecovery.RESTART_DELAY_MS): past it, 3 s past the failure.
     */
    private const val SYNC_LOOKUP_EXTRA_MS = 1500L

    /** The stretch of both grips resizes the flat screen at most this often: each new size reshapes a layer. */
    private const val STRETCH_INTERVAL_MS = 100L

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
     * The kiosk panel (exit notice, end card, error card): a few lines at the same 1 m for 720 dp as the info panel,
     * KIOSK_DISTANCE from the eyes, the notice KIOSK_NOTICE_DROP below the line of sight.
     */
    private const val KIOSK_PANEL_WIDTH_DP = 900f
    private const val KIOSK_PANEL_HEIGHT_DP = 450f
    private const val KIOSK_PANEL_WIDTH_M = INFO_PANEL_WIDTH_M * KIOSK_PANEL_WIDTH_DP / INFO_PANEL_WIDTH_DP
    private const val KIOSK_PANEL_HEIGHT_M = INFO_PANEL_WIDTH_M * KIOSK_PANEL_HEIGHT_DP / INFO_PANEL_WIDTH_DP
    private const val KIOSK_DISTANCE = 2.0f
    private const val KIOSK_NOTICE_DROP = 0.35f

    /** The buttons that leave a kiosk once held, see KioskSession.onExitButtons. */
    private val KIOSK_EXIT_BITS = ButtonBits.ButtonB or ButtonBits.ButtonY

    /**
     * Size of the swapchain of the video panel. A player that stitches draws into it with OpenGL and is told this size
     * (see attachVideoSurface); the decoder of any other video writes its own size there.
     */
    private const val VIDEO_PANEL_WIDTH_PX = 3840
    private const val VIDEO_PANEL_HEIGHT_PX = 1920

    /** Swapchain of the flat video screen: a flat 3D frame is scaled to it, the quad gives it its shape back. */
    private const val FLAT_VIDEO_PANEL_WIDTH_PX = 3840
    private const val FLAT_VIDEO_PANEL_HEIGHT_PX = 2160

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

    /** Mesh of the stereo quad of the spatial photos: a unit quad, sized with its Scale component. */
    private const val STEREO_QUAD_MESH = "mesh://immuch_stereo_quad"

    /** Mesh of the 2.5D view of a relief, see [ReliefMesh]. */
    private const val RELIEF_MESH = "mesh://immuch_relief_mesh"

    /** The normals of the mesh, towards the user (an unlit material does not read them), and its vertex colour. */
    private val RELIEF_MESH_NORMALS by lazy {
      FloatArray(3 * ReliefMesh.MAX_VERTICES).also { normals ->
        for (k in 0 until ReliefMesh.MAX_VERTICES) normals[3 * k + 2] = -1f
      }
    }
    private const val WHITE = -1

    /** Mesh of the outline of the photo on a panorama we generated, see [PanoramaOutline]. */
    private const val OUTLINE_MESH = "mesh://immuch_panorama_outline"

    /** The outline lies within this distance of the eye on each axis: the bounds of its mesh. */
    private const val OUTLINE_BOUND_M = 300f

    /** The normals of the outline (an unlit material does not read them). */
    private val OUTLINE_NORMALS by lazy {
      FloatArray(3 * PanoramaOutline.VERTICES).also { normals ->
        for (k in 0 until PanoramaOutline.VERTICES) normals[3 * k + 2] = -1f
      }
    }

    /**
     * Longest wait for the head of a photo shown on a sphere, read for our packet of a generated panorama: past it, the
     * photo loads as any other and its downloaded copy is read instead.
     */
    private const val PANORAMA_HEAD_TIMEOUT_MS = 4000L

    /**
     * The backdrop of the 2.5D view, the quad, goes this much behind the farthest vertex of the mesh, in part of its
     * distance and in meters: never in the mesh, and on the plane of the quad but 6 cm when the relief is flat.
     */
    private const val BACKDROP_MARGIN = 0.02
    private const val BACKDROP_MARGIN_M = 0.02

    /** Eye height used to place the quad before the first head pose. */
    private const val DEFAULT_EYE_HEIGHT = 1.6f

    /**
     * Starting rotation of the photo sphere and of the video sphere around the vertical axis, for every
     * new media. Not verified on a headset: turn the image with the Turn button (or the thumbstick up or
     * down on a photo) until its center faces you, then use the value logged as "photo yaw is now ..." or
     * "video yaw is now ...". A panorama Immuch360 generated is turned from there so that its photo opens where the
     * user looks (GeneratedPanorama.openingYaw), and its outline (PanoramaOutline) counts on this value too.
     */
    private const val SKYBOX_YAW_DEGREES = 0f
    private const val VIDEO_YAW_DEGREES = 0f
    private const val YAW_STEP_DEGREES = 90f

    /**
     * The turn of one push of the right thumbstick: a snap turn of the size most headset apps use, small enough to
     * keep the bearings and repeated while the stick is held, so that looking behind takes one long push.
     */
    private const val SNAP_TURN_DEGREES = 30f

    /**
     * The distance of the flat screens, as the user left it last (the Distance buttons, the thumbstick while a grip
     * holds the screen): the next flat screen opens there. Lives as long as the process, as the choices of the app do
     * until it closes.
     */
    private var screenDistanceM = FlatScreenGeometry.DEFAULT_DISTANCE_M

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
      stereoPair: String? = null,
      sourceNotice: String? = null,
      sourceRefusal: String? = null,
    ): Boolean {
      val viewer = liveViewer
      if (viewer == null) {
        Log.i(TAG, "adjacent media for request $requestId refused, no immersive viewer")
        return false
      }
      return viewer.applyAdjacent(
        requestId,
        url,
        isVideo,
        title,
        stereoLayout,
        coverage,
        fallbackUrl,
        rawProjection,
        stereoPair,
        sourceNotice,
        sourceRefusal,
      )
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
      reverseThumbstickTurn: Boolean,
      sharpFlatScreens: Boolean = true,
      kiosk: String? = null,
      sourceNotice: String? = null,
      sourceRefusal: String? = null,
      gaussianSplats: Boolean = true,
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
          reverseThumbstickTurn = reverseThumbstickTurn,
          sharpFlatScreens = sharpFlatScreens,
          kioskJson = kiosk,
          sourceNotice = sourceNotice,
          sourceRefusal = sourceRefusal,
          gaussianSplats = gaussianSplats,
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
        putString(EXTRA_STEREO_PAIR, media.stereoPairJson)
        putBoolean(EXTRA_REVERSE_THUMBSTICK_TURN, media.reverseThumbstickTurn)
        putBoolean(EXTRA_SHARP_FLAT_SCREENS, media.sharpFlatScreens)
        putString(EXTRA_KIOSK, media.kioskJson)
        putString(EXTRA_SOURCE_NOTICE, media.sourceNotice)
        putString(EXTRA_SOURCE_REFUSAL, media.sourceRefusal)
        putBoolean(EXTRA_GAUSSIAN_SPLATS, media.gaussianSplats)
      }
    }

    /** The Gaussian splats setting of the extras of an opening or of a recreation; on when they do not say */
    private fun gaussianSplatsOf(extras: Bundle?): Boolean = extras?.getBoolean(EXTRA_GAUSSIAN_SPLATS, true) ?: true

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
        stereoPairJson = extras.getString(EXTRA_STEREO_PAIR)?.takeIf { it.isNotBlank() },
        reverseThumbstickTurn = extras.getBoolean(EXTRA_REVERSE_THUMBSTICK_TURN, false),
        sharpFlatScreens = extras.getBoolean(EXTRA_SHARP_FLAT_SCREENS, true),
        kioskJson = extras.getString(EXTRA_KIOSK)?.takeIf { it.isNotBlank() },
        sourceNotice = extras.getString(EXTRA_SOURCE_NOTICE)?.takeIf { it.isNotBlank() },
        sourceRefusal = extras.getString(EXTRA_SOURCE_REFUSAL)?.takeIf { it.isNotBlank() },
        gaussianSplats = gaussianSplatsOf(extras),
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
