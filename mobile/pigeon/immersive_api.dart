import 'package:pigeon/pigeon.dart';

// Android only: Meta Quest (Horizon OS) immersive viewer for 360 photos and videos.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/immersive_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/immersive/Immersive.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.immersive'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// How the two eyes of a stereoscopic (3D) 360° media are laid out in the frame: one above the other (left eye on
/// top) or side by side (left eye on the left). [mono] is a regular 360° media. Same values as the player API.
enum ImmersiveStereoLayout { mono, topBottom, leftRight }

/// How much of the sphere the image covers: all of it (360°), or the front half (180°, VR180 files)
enum ImmersiveSphereCoverage { full, half }

@HostApi()
abstract class ImmersiveApi {
  /// True on a Meta Quest headset (Horizon OS).
  bool isHorizonOs();

  /// Whether this build offers the Gaussian splats (lot S5, FreeKC's decision of 30 October 2026): true in the GitHub
  /// builds and in the debug builds of a developer's machine; in the build of the Meta Horizon Store and with a
  /// certificate the app does not know or cannot read, what SPLATS_IN_STORE_BUILD of SplatBuild.kt says (true since 30
  /// October 2026), told apart by the certificates the APK is signed with. False, the app shows no splat tile, no
  /// Open a splat file and no Gaussian splats setting, and its licences page does not list the splat module as active;
  /// the viewer never registers the module either.
  bool splatsInThisBuild();

  /// Opens the immersive head tracked viewer for an equirectangular photo or video. [stereoLayout] is the layout
  /// Flutter guessed from the media dimensions; the headset shows each eye its own half of a stereoscopic media,
  /// and the user can change the layout in the viewer. [stereoLabels] are the translated labels of the 3D control,
  /// keyed "stereo", "mono", "topBottom", "leftRight", and for a spatial photo "spatial3d", "spatial2d",
  /// "spatialNoNavigation", "spatialSecondEyeFailed".
  /// [rawProjection] is null for an equirectangular media, or the JSON of a dual fisheye calibration (docs
  /// 16-dual-fisheye-spec.md section 5) for a raw camera video whose frame holds the two fisheye circles; raw photos
  /// arrive already stitched as a file.
  /// [startPositionMs] is where a video starts (0 from the beginning), so the immersive view carries on from
  /// where the flat player was. [openingId] identifies this opening: the viewer sends it back with every event,
  /// so that Flutter ignores the events of a viewer it is no longer following (a closed event can arrive long
  /// after the user left through the system). Previous and next never go through open: the viewer asks with
  /// [ImmersiveEvents.requestAdjacent] and Flutter answers with [showAdjacent]. Calling open while the viewer is
  /// already in front replaces the media in place as a fresh opening. [fallbackUrl] is the server's transcoded
  /// stream of a video, played instead of [url] when the headset's decoder cannot take the original (checked at
  /// the first frames) or when the original fails; null when there is none or when the user chose to always play
  /// the original. [stereoPair] is null, or the JSON of an Apple spatial photo (docs
  /// 18-design-build19-sources-and-spatial.md section 5.6): the viewer then shows both eyes on a flat quad in front of
  /// the user instead of a sphere. [reverseThumbstickTurn] is the "Reverse thumbstick turn" setting: false, the right
  /// thumbstick turns the view the way it is pushed, as in most headset apps; true, the other way. Previous and next
  /// keep the value of the opening. [sharpFlatScreens] is the "Sharper flat screens" setting: true, the photos of a
  /// flat screen are drawn on a compositor quad layer, and that layer and the flat video screen get the quality super
  /// sampling and sharpening of the compositor; false, the photos go on the quad mesh and no filter applies. Previous
  /// and next keep the value of the opening. [kiosk] is null, or the JSON of the kiosk mode (Settings, Advanced,
  /// "Kiosk mode", lot quest-kiosk): `{"endText": ..., "exitHint": ...}` in the language of the app; the viewer then
  /// plays the media for visitors, restarting a film each time the headset is put on, with no panel, no hands and no
  /// pointer, and only B or Y held one second leaves (see KioskSession). [sourceNotice] is what to tell of the file
  /// chosen for a video, decodability first (the server's copy as the original is beyond the decoder of the headset, or
  /// the original as the copy is), shown once it plays; [sourceRefusal] what to say instead of playing a video nothing
  /// the server has decodes on the headset (its codec, its size, the limit and what to change in Immich). Both in the
  /// language of the app, null for nothing (lot fix-decoder-limit). [gaussianSplats] is the "Gaussian splats" setting
  /// (experimental, on by default; lot S5): the viewer registers the splat module of the Meta Spatial SDK as it opens
  /// only when it is true, so that the module never runs for a user who turned the splats off; previous and next keep
  /// the value of the opening. [watchMinDurationMs] is the threshold of "Remember where I stopped" in milliseconds, -1
  /// with it off (FreeKC's rule of 31 October 2026, see WatchReport): a video of at least that long is a film, which
  /// plays once, and whose position the viewer reports with [ImmersiveEvents.progress]; previous and next keep the value
  /// of the opening, the kiosk ignores it. [startNotice] is what to say once the video plays, in the language of the app
  /// ("Resumed at 42:10" for a film that starts where it was left), null for nothing.
  void open(
    String url,
    Map<String, String> headers,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    ImmersiveSphereCoverage coverage,
    int startPositionMs,
    int openingId,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair,
    bool reverseThumbstickTurn,
    bool sharpFlatScreens, {
    String? kiosk,
    String? sourceNotice,
    String? sourceRefusal,
    bool gaussianSplats = true,
    int watchMinDurationMs = -1,
    String? startNotice,
  });

  /// Answers [ImmersiveEvents.requestAdjacent]: shows [url] in place of the media of the viewer that asked, identified
  /// by [requestId]. Returns false, and shows nothing, when that viewer is gone, closing, or no longer waiting for
  /// this request (the user pressed Back, or the request timed out meanwhile), so that Flutter does not count the
  /// media as shown. Never starts the viewer. [stereoPair] is the JSON of an Apple spatial photo, [sourceNotice] and
  /// [sourceRefusal] the words on the file of a video, as for [open]. [startPositionMs] is where a video starts, where a
  /// film was left (0 from the beginning), with [startNotice] said once it plays.
  bool showAdjacent(
    int requestId,
    String url,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair, {
    String? sourceNotice,
    String? sourceRefusal,
    int startPositionMs = 0,
    String? startNotice,
  });
}

/// Events from the immersive viewer towards Flutter, attached to the engine of the app UI (the viewer is its own
/// activity, the app window keeps running behind it).
@FlutterApi()
abstract class ImmersiveEvents {
  /// The user asked for the media [step] places away from the one shown (+1 next, -1 previous), in the viewer of
  /// [openingId] (Flutter answers false for an opening it no longer follows). [stereoLayout] and
  /// [coverage] are what the viewer shows now (the user's corrections, to remember before moving on). Flutter looks
  /// for the nearest media that can be shown immersively in that direction, shows it with
  /// [ImmersiveApi.showAdjacent] with the same [requestId] and returns true; false when there is none or when the
  /// search gave up (Flutter searches for at most 12 seconds), the viewer then keeps the current media and says so.
  @async
  bool requestAdjacent(
    int openingId,
    int requestId,
    int step,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
  );

  /// The immersive viewer of [openingId] left the screen (Back, or closed by the system; Flutter ignores an opening
  /// it no longer follows). [url] is the media shown last, so that
  /// the corrections and the position are attributed to the right asset: [stereoLayout] and [coverage] are what it
  /// showed last, [positionMs] the playback position of a video (0 for a photo). A search still running for that
  /// viewer stops.
  void closed(
    int openingId,
    String url,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
    int positionMs,
  );

  /// The film at [url] in the viewer of [openingId] is at [positionMs] of [durationMs] (its duration once it ended):
  /// every 5 s while it plays, when the viewer goes behind the system, before a request for another media, at its end
  /// and as the viewer closes, for a film only (see open's watchMinDurationMs), never in the kiosk. The app keeps it as
  /// the in-app player does (see WatchProgressStore): the film resumes there next time, in the headset or in the app.
  void progress(int openingId, String url, int positionMs, int durationMs);
}
