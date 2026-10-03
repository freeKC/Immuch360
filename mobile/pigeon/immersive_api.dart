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

  /// Opens the immersive head tracked viewer for an equirectangular photo or video. [stereoLayout] is the layout
  /// Flutter guessed from the media dimensions; the headset shows each eye its own half of a stereoscopic media,
  /// and the user can change the layout in the viewer. [stereoLabels] are the translated labels of the 3D control,
  /// keyed "stereo", "mono", "topBottom", "leftRight".
  /// [startPositionMs] is where a video starts (0 from the beginning), so the immersive view carries on from
  /// where the flat player was. [openingId] identifies this opening: the viewer sends it back with every event,
  /// so that Flutter ignores the events of a viewer it is no longer following (a closed event can arrive long
  /// after the user left through the system). Previous and next never go through open: the viewer asks with
  /// [ImmersiveEvents.requestAdjacent] and Flutter answers with [showAdjacent]. Calling open while the viewer is
  /// already in front replaces the media in place as a fresh opening.
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
  );

  /// Answers [ImmersiveEvents.requestAdjacent]: shows [url] in place of the media of the viewer that asked, identified
  /// by [requestId]. Returns false, and shows nothing, when that viewer is gone, closing, or no longer waiting for
  /// this request (the user pressed Back, or the request timed out meanwhile), so that Flutter does not count the
  /// media as shown. Never starts the viewer.
  bool showAdjacent(
    int requestId,
    String url,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
  );
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
}
