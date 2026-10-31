import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/library/share_versions_button.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/desktop/window/hover_chevrons.dart';
import 'package:immich_mobile/domain/models/ai_immersive/generated_panorama.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_viewer_labels.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/view_rotation.dart';
import 'package:immich_mobile/domain/services/ai_immersive/quest_relief.dart';
import 'package:immich_mobile/domain/services/ai_immersive/share_versions.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/relief_button.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/scene_button.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/tiff_views.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_tiff_image.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_back_button.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkPhotoPage');

/// Largest side the flat view decodes a photo at: a large panorama would not fit in memory at its full size
const _maxFlatSize = 4096;

/// The image of a photo of a share for the flat view, through the media bridge at [url]. A TIFF on a device without
/// TIFF decoder is decoded in Dart (see NetworkTiffImage).
ImageProvider networkPhotoImage(Uri url) => isDartTiffUrl(url)
    ? NetworkTiffImage(url, maxSide: _maxFlatSize)
    : ResizeImage(
        NetworkImage(url.toString()),
        width: _maxFlatSize,
        height: _maxFlatSize,
        policy: ResizeImagePolicy.fit,
      );

/// The image of a photo of a share for the 360° viewer, through the media bridge at [url]: at most 8192 x 4096 pixels,
/// the largest texture most phones take (see textureDecodeSize), or 4096 x 2048 on a TV that Android calls a low RAM
/// device ([lowRam]: 32 MB instead of 128). A TIFF on a device without TIFF decoder is decoded in Dart, its long side
/// at most the width of that texture.
ImageProvider networkPanoramaImage(Uri url, {bool lowRam = false}) {
  final width = (lowRam ? lowRamTextureSize.width : 8192).toInt() - 1;
  final height = (lowRam ? lowRamTextureSize.height : 4096).toInt() - 1;
  if (isDartTiffUrl(url)) {
    return NetworkTiffImage(url, maxSide: width);
  }
  return ResizeImage(NetworkImage(url.toString()), width: width, height: height, policy: ResizeImagePolicy.fit);
}

/// A photo of a share and its media bridge URL
typedef _Photo = ({NetworkEntry entry, Uri url});

/// A photo of a network share, shown straight from it through the media bridge: pinch or double tap to zoom. A photo
/// whose file declares a 360° projection gets a 360° button, and any photo can be viewed as 360° from the menu: in
/// the panorama viewer, or in the immersive viewer on a Meta Quest, which goes from there to the previous and next
/// 360° photos and videos of [folder]. The menu also sends the photo to the Immich server, when there is one.
///
/// A raw dual fisheye photo of an Insta360 camera (.insp, or a photo ending with the trailer of the camera) is 360°:
/// the panorama viewer stitches it, and for the immersive viewer it is stitched into a picture of the cache first, with
/// the calibration read from the share.
///
/// On a Meta Quest, an Apple spatial photo (a HEIF file holding a stereo pair, see [NetworkMediaInfo.stereoPair]) gets
/// a "View in 3D" button, which shows both eyes in the immersive viewer. So does a flat photo holding two eyes side by
/// side (see [NetworkMediaInfo.stereoPhoto]): the 3D photos a computer makes, those of other tools. An ordinary photo
/// whose folder holds a 3D version of it (see findShareVersions) gets "View the 3D version", which opens that version
/// the same way, without any AI on the headset. An ordinary photo also gets "AI relief" (see AiReliefButton), which
/// opens it on the same quad with a relief the headset estimates, greyed with its reason where the headset cannot.
/// A photo that carries a 3D scene (see [NetworkMediaInfo.scene]) gets "Explore the 3D scene", and an original whose
/// folder holds one of its scenes "View the 3D scene" (see AiSceneButton), each greyed with its reason where the gate
/// of the headset refuses the scene. An original whose folder holds a 360° panorama a computer generated beyond its
/// edges gets "View the 360° version", which opens the newest one (its 3D version, top and bottom, when it is newer)
/// on the sphere of the immersive viewer; the viewer reads the packet of the panorama itself and says so.
@RoutePage()
class NetworkPhotoPage extends ConsumerStatefulWidget {
  const NetworkPhotoPage({super.key, required this.sourceId, required this.path, this.folder});

  final String sourceId;

  /// Absolute inside the share, "/" separated, starting with "/"
  final String path;

  /// The photos and videos of the folder the photo was opened from, null when it was opened on its own
  final NetworkFolderMedia? folder;

  @override
  ConsumerState<NetworkPhotoPage> createState() => _NetworkPhotoPageState();
}

class _NetworkPhotoPageState extends ConsumerState<NetworkPhotoPage> {
  late Future<_Photo> _photo = _load();

  /// What the file declares, null until read
  NetworkMediaInfo? _info;

  /// The photo once found on the share, for the keys
  _Photo? _current;

  /// Reads the file straight from the share, for the calibration of a raw photo; null until the share is open
  ByteRangeReader? _shareReader;

  /// The versions of the photo in its folder (3D photos, 3D scenes, panoramas), the newest first: looked for on a Meta
  /// Quest once the photo is known to be an ordinary one, null until then
  List<ShareVersion>? _versions;

  // The size of the photo, once the flat view decoded it (scaled down, but with its aspect ratio): the 3D layout of
  // the immersive viewer is guessed from it
  ImageStream? _imageStream;
  late final _imageListener = ImageStreamListener(_onImage, onError: (_, _) {});
  Size? _imageSize;

  final _transformation = TransformationController();
  Offset? _doubleTapPosition;

  /// The page itself, which takes the keys of a remote while no button has the focus
  final _rootFocus = FocusNode(debugLabel: 'Network photo');

  /// Around the app bar: where OK goes, and what Back leaves first on a TV
  final _appBarFocus = FocusNode(debugLabel: 'Network photo app bar', canRequestFocus: false, skipTraversal: true);
  final _actionsFocus = FocusNode(debugLabel: 'Network photo actions', canRequestFocus: false, skipTraversal: true);

  /// Around the view of an error that has a Retry button: where Down and OK go, since the page itself, which keeps the
  /// focus, has nothing else to do with them then
  final _errorFocus = FocusNode(debugLabel: 'Network photo error', canRequestFocus: false, skipTraversal: true);

  @override
  void initState() {
    super.initState();
    // Back on a TV depends on where the focus is
    _appBarFocus.addListener(_onAppBarFocus);
  }

  void _onAppBarFocus() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Down from a button of the app bar goes back to the photo, or to Retry in place of a photo that could not be read
  KeyEventResult _onAppBarKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (isRemotePress(event)) {
      (_errorFocus.traversalDescendants.firstOrNull ?? _rootFocus).requestFocus();
    }
    return KeyEventResult.handled;
  }

  /// The keys of a remote control, a keyboard or a game pad while the photo itself has the focus: left and right go to
  /// the previous or next file of the folder, OK and Up to the app bar (360°, the menu); in place of a photo that could
  /// not be read, Down and OK go to Retry. Next and previous keys work from anywhere on the page.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final press = isRemotePress(event);
    if (remoteNextItemKeys.contains(key) || remotePreviousItemKeys.contains(key)) {
      if (press) {
        _openNeighbour(remoteNextItemKeys.contains(key) ? 1 : -1);
      }
      return KeyEventResult.handled;
    }
    // The one-key rotation, from anywhere on the page: the yellow and blue keys of a remote, R and Shift R
    final rotation = isRemoteRotateClockwise(event)
        ? 1
        : isRemoteRotateCounterClockwise(event)
        ? -1
        : 0;
    final photo = _current;
    if (rotation != 0 && photo != null && _canRotate) {
      if (press) {
        _rotate(photo, rotation);
      }
      return KeyEventResult.handled;
    }
    if (!node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      if (press) {
        _openNeighbour(key == LogicalKeyboardKey.arrowRight ? 1 : -1);
      }
      return KeyEventResult.handled;
    }
    final retry = _errorFocus.traversalDescendants.firstOrNull;
    if (retry != null && (remoteOkKeys.contains(key) || key == LogicalKeyboardKey.arrowDown)) {
      if (press) {
        retry.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (remoteOkKeys.contains(key) || key == LogicalKeyboardKey.arrowUp) {
      if (press) {
        (_actionsFocus.traversalDescendants.firstOrNull ?? _appBarFocus.traversalDescendants.firstOrNull)
            ?.requestFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Whether the page offers "View in 3D" for a photo whose name says it holds two eyes one above the other: on a Meta
  /// Quest with "3D by file name (experimental)" on, set by [build]. Anywhere else such a photo is an ordinary one.
  bool _flat3dByName = false;

  /// Whether the photo turns with the one-key rotation: once its file was read, when it is neither 360° nor a stereo
  /// pair nor two eyes side by side nor two eyes one above the other by its name where the page offers them in 3D (see
  /// [_stackedFormat]) nor the raw file of a 360° camera nor the preview of a 3D scene. Those keep their views, which
  /// turn the camera rather than the picture, or hold their eyes or their scene where they are.
  bool get _canRotate {
    final info = _info;
    return info != null &&
        !info.is360 &&
        info.stereoPair == null &&
        info.stereoPhoto == null &&
        info.scene == null &&
        info.rawKind == null &&
        !isRawPhotoName(_name) &&
        _stackedFormat == null;
  }

  /// How the photo packs its eyes when its name says they are one above the other (see stackedPhotoFormatOf), on a
  /// Meta Quest with the switch on ([_flat3dByName]), once its file was read and found neither 360° nor holding a
  /// stereo pair, two eyes side by side or a 3D scene; null otherwise
  FlatStereoFormat? get _stackedFormat {
    final info = _info;
    if (!_flat3dByName ||
        info == null ||
        info.is360 ||
        info.stereoPair != null ||
        info.stereoPhoto != null ||
        info.scene != null) {
      return null;
    }
    return stackedPhotoFormatOf(_name);
  }

  /// The quarter turns kept on this device for [photo], 0 for a photo that does not turn
  int _turnsOf(_Photo photo) {
    if (!_canRotate) {
      return 0;
    }
    final entry = photo.entry;
    return ref.watch(
      viewRotationsProvider.select(
        (entries) => viewRotationShareTurnsOf(
          entries,
          widget.sourceId,
          widget.path,
          size: entry.size,
          modifiedMs: entry.modified?.millisecondsSinceEpoch,
        ),
      ),
    );
  }

  /// Turns [photo] by [delta] quarter turns clockwise, kept on this device for its file, and shows it whole again
  void _rotate(_Photo photo, int delta) {
    final entry = photo.entry;
    unawaited(
      ref
          .read(viewRotationsProvider.notifier)
          .rotateShare(
            widget.sourceId,
            widget.path,
            delta,
            size: entry.size,
            modifiedMs: entry.modified?.millisecondsSinceEpoch,
          ),
    );
    _transformation.value = Matrix4.identity();
  }

  /// The previous or next photo or video of the folder, in place of this page: a TV user does not go back to the grid
  /// between files. Nothing without a folder.
  void _openNeighbour(int step) {
    final route = networkFolderNeighbourRoute(widget.sourceId, widget.folder, widget.path, step);
    if (route != null) {
      unawaited(context.replaceRoute(route));
    }
  }

  String get _name => widget.path.split('/').last;

  Future<_Photo> _load() async {
    // Read before the first await: the page may be gone by then
    final connections = ref.read(networkConnectionsProvider);
    final service = ref.read(networkMediaServiceProvider);
    final client = ref.read(networkBridgeClientProvider);
    final isHorizonOs = ref.read(isHorizonOsProvider.future);
    final fileSystem = await connections.fileSystem(widget.sourceId);
    final entry = await fileSystem.stat(widget.path);
    final url = await connections.mediaUrl(widget.sourceId, widget.path);
    _shareReader = networkFileReader(fileSystem, widget.path);
    unawaited(_detect(service, entry, httpRangeReader(client, url), fileSystem, isHorizonOs));
    return _current = (entry: entry, url: url);
  }

  // Through the media bridge, with range requests, like the players read the file. Then, on a Meta Quest, the 3D
  // versions of an ordinary photo, straight from the share.
  Future<void> _detect(
    NetworkMediaService service,
    NetworkEntry entry,
    ByteRangeReader read,
    NetworkFileSystem fileSystem,
    Future<bool> isHorizonOs,
  ) async {
    final info = await service.detect(entry, read, thorough: true);
    if (info != null && mounted) {
      setState(() => _info = info);
    }
    final ordinary =
        info != null &&
        !info.is360 &&
        info.stereoPair == null &&
        info.stereoPhoto == null &&
        info.scene == null &&
        info.rawKind == null;
    if (ordinary && entry.isImage && await isHorizonOs.catchError((_) => false)) {
      await _findVersions(entry, fileSystem);
    }
  }

  /// Looks for the versions of [entry] among the files of its folder: those of the folder the page was opened
  /// from, else the listing of the folder
  Future<void> _findVersions(NetworkEntry entry, NetworkFileSystem fileSystem) async {
    try {
      final neighbours = widget.folder?.entries ?? await fileSystem.list(shareFolderOf(entry.path));
      final versions = await findShareVersions(
        entry,
        neighbours,
        readerOf: (neighbour) => networkFileReader(fileSystem, neighbour.path),
      );
      if (versions.isNotEmpty && mounted) {
        setState(() => _versions = versions);
      }
    } catch (error) {
      _log.info('Could not look for the versions of ${entry.name}: $error');
    }
  }

  void _retry() {
    // Retry leaves with the error: the page takes the keys again
    if (_errorFocus.hasFocus) {
      _rootFocus.requestFocus();
    }
    setState(() {
      _current = null;
      _versions = null;
      _photo = _load();
    });
  }

  void _listenToImage(ImageProvider image) {
    if (_imageStream != null) {
      return;
    }
    _imageStream = image.resolve(ImageConfiguration.empty)..addListener(_imageListener);
  }

  void _onImage(ImageInfo info, bool _) {
    final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
    info.dispose();
    if (mounted && size != _imageSize) {
      setState(() => _imageSize = size);
    }
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_imageListener);
    _transformation.dispose();
    _appBarFocus.removeListener(_onAppBarFocus);
    _rootFocus.dispose();
    _appBarFocus.dispose();
    _actionsFocus.dispose();
    _errorFocus.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    final position = _doubleTapPosition;
    if (_transformation.value.getMaxScaleOnAxis() > 1.01 || position == null) {
      _transformation.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    // Zooms in on where the user tapped
    _transformation.value = Matrix4.identity()
      ..translateByDouble(-position.dx * (scale - 1), -position.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  Future<void> _open360(_Photo photo) async {
    final client = ref.read(networkBridgeClientProvider);
    final isHorizonOs = await ref.read(isHorizonOsProvider.future);
    if (!mounted) {
      return;
    }
    final view = (_info ?? const NetworkMediaInfo()).sphereView(
      photo.entry.name,
      width: _imageSize?.width.round(),
      height: _imageSize?.height.round(),
    );
    if (isHorizonOs) {
      return _openImmersive(photo, view);
    }
    final device = ref.read(tvDeviceProvider);
    final PanoramaSource source = (
      image: networkPanoramaImage(photo.url, lowRam: device.isTelevision && device.isLowRamDevice),
      name: photo.entry.name,
      length: photo.entry.size,
      read: httpRangeReader(client, photo.url),
    );
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => PanoramaViewerPage.source(source: source)));
  }

  /// Shows both eyes of the photo of the share at [path] in the immersive viewer, as [stereo] describes them (an
  /// Apple spatial photo, two eyes side by side, a relief the headset estimates, a 3D scene): read through the media
  /// bridge at [url], or at the URL of [path] when none is given, like any photo of a share. No previous or next from
  /// there yet: the viewer says so itself.
  Future<void> _openStereo(String path, StereoPhotoRequest stereo, {Uri? url}) async {
    // Read before the first await: the page may be gone by then
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorMessage = context.t.immersive_viewer_open_failed;
    final stereoLabels = stereoPhotoViewerLabels(context.t);
    final connections = ref.read(networkConnectionsProvider);
    final name = path.split('/').last;
    try {
      final request = ImmersiveRequest(
        url: (url ?? await connections.mediaUrl(widget.sourceId, path)).toString(),
        isVideo: false,
        title: name,
        view: stereoPhotoSphereView,
        stereoPair: stereo.toImmersiveJson(),
      );
      await openImmersiveUrl(ref, request: request, stereoLabels: stereoLabels);
    } catch (error) {
      _log.warning('Could not open $name in 3D: $error');
      messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  /// Opens [version], a 360° panorama a computer generated beyond the edges of this photo, on the sphere of the
  /// immersive viewer: mono, or top and bottom for its 3D version, over the whole sphere; previous and next go from it
  /// through the folder, as from any 360° photo of it
  Future<void> _openPanoramaVersion(ShareVersion version) async {
    // Read before the first await: the page may be gone by then
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorMessage = context.t.immersive_viewer_open_failed;
    final stereoLabels = sphereViewerLabels(context.t);
    final connections = ref.read(networkConnectionsProvider);
    final entry = version.entry;
    try {
      final url = widget.folder?.urls[entry.path] ?? await connections.mediaUrl(widget.sourceId, entry.path);
      final SphereView view = (
        layout: version.kind == ImmersiveKind.stereoPanorama360 ? StereoLayout.topBottom : StereoLayout.mono,
        coverage: SphereCoverage.full,
        coverageGuess: SphereCoverage.full,
      );
      final request = ImmersiveRequest(url: url.toString(), isVideo: false, title: entry.name, view: view);
      if (!mounted) {
        return;
      }
      final around = widget.folder?.around(entry, url) ?? (items: [(entry: entry, url: url)], index: 0);
      final navigator = FolderImmersiveNavigator.read(ref, items: around.items, index: around.index, request: request);
      await openImmersiveUrl(ref, request: request, stereoLabels: stereoLabels, navigator: navigator);
    } catch (error) {
      _log.warning('Could not open the 360° version ${entry.name}: $error');
      messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  Future<void> _openImmersive(_Photo photo, SphereView view) async {
    // Read before the first await: the page may be gone by then
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorMessage = context.t.immersive_viewer_open_failed;
    final stereoLabels = sphereViewerLabels(context.t);
    final isRaw = _info?.rawKind == RawMediaKind.insta360Photo || isRawPhotoName(photo.entry.name);
    final raw = isRaw ? RawImmersiveMedia.read(ref, forAssets: false) : null;
    final read = _shareReader ?? httpRangeReader(ref.read(networkBridgeClientProvider), photo.url);
    try {
      // The viewer opens a raw photo stitched, from a picture of the cache
      final request = raw != null
          ? await raw.sharedMedia(photo.entry, photo.url, read: read)
          : ImmersiveRequest(url: photo.url.toString(), isVideo: false, title: photo.entry.name, view: view);
      if (!mounted) {
        return;
      }
      final around = widget.folder?.around(photo.entry, photo.url) ?? (items: [photo], index: 0);
      // Given the request too: the photo shows again as it opens now, whatever its file declares
      final navigator = FolderImmersiveNavigator.read(ref, items: around.items, index: around.index, request: request);
      await openImmersiveUrl(ref, request: request, stereoLabels: stereoLabels, navigator: navigator);
    } catch (error) {
      _log.warning('Could not open the immersive viewer: $error');
      messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Asked early, so that the 360° button knows where to open the photo right away
    final isHorizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    // A TV is a viewer: nothing is sent from it
    final tvMode = ref.watch(tvModeProvider);
    final canUpload = !tvMode && ref.watch(hasServerProvider);
    final isUploading = ref.watch(networkUploadProvider.select((upload) => upload.isRunning));
    // The page covers the screen, under the app bar too: from the menu, Left would land on it rather than on the Back
    // button. Out of the directional moves while the app bar has the focus (set here, not while the focus changes);
    // Down and Back go back to it.
    _rootFocus.skipTraversal = _appBarFocus.hasFocus;
    // The flat 3D media told by their file name, experimental and on by default (Settings, Advanced), on a Meta Quest
    // only: read before the rotation, which leaves such a photo alone there
    _flat3dByName = isHorizonOs && ref.watch(appConfigProvider.select((config) => config.viewer.flat3dByName));
    // Watched here, in the build of this page: the photo is known once the file was read, which rebuilds the page
    final current = _current;
    final turns = current == null ? 0 : _turnsOf(current);
    // Immuch360 Desktop: "Make 3D (AI)" in the menu, as for a photo of the library
    // (lib/desktop/ai/ui/share_conversion.dart)
    final makeImmersive = CurrentPlatform.isDesktop && current != null && !tvMode
        ? watchShareMakeImmersive(
            ref,
            context.t,
            current.entry,
            _info,
            width: _info?.frameWidth ?? _imageSize?.width.round(),
            height: _info?.frameHeight ?? _imageSize?.height.round(),
          )
        : null;
    // "AI relief" on a Meta Quest, for an ordinary photo once its file was read: the photos that turn are those
    final reliefGate = isHorizonOs && current != null && _canRotate ? ref.watch(reliefGateProvider) : ReliefGate.hidden;
    // The view a relief first shows in, read with the gate: a page without the button reads no setting
    final reliefMode = reliefGate.visible
        ? ref.watch(appConfigProvider.select((config) => config.aiImmersive.questMode))
        : ReliefViewMode.stereo;
    final page = FutureBuilder<_Photo>(
      future: _photo,
      builder: (context, snapshot) {
        final photo = snapshot.data;
        final is360 = _info?.is360 ?? false;
        final stereoPair = isHorizonOs ? _info?.stereoPair : null;
        // Two eyes side by side: "View in 3D", greyed with its reason for a file of a newer format
        final stereoPhoto = isHorizonOs && stereoPair == null ? _info?.stereoPhoto : null;
        final sbsRequest = stereoPhoto?.request;
        // Two eyes one above the other by the file name (_TB, _OU, _HTB...): "View in 3D" too
        final stackedFormat = _stackedFormat;
        // The newest 3D photo a computer saved next to this photo; the other kinds have their own entries
        final version = isHorizonOs ? _versions?.where((found) => found.photo != null).firstOrNull : null;
        final versionRequest = version?.photo?.request;
        // A photo that carries a 3D scene, and the newest scene a computer saved next to an original
        final scene = isHorizonOs ? _info?.scene : null;
        final sceneVersion = isHorizonOs
            ? _versions
                  ?.where((found) => found.kind == ImmersiveKind.volumetricScene && found.xmp is SceneXmp)
                  .firstOrNull
            : null;
        // The newest panorama a computer generated beyond the edges of this photo, or its 3D version
        final panoramaVersion = isHorizonOs
            ? _versions?.where((found) => GeneratedPanoramaInfo.of(found.xmp)?.isGenerated ?? false).firstOrNull
            : null;
        final appBar = AppBar(
          backgroundColor: Colors.black38,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          // On a TV, Back on the app bar only returns to the photo: the Back button leaves the page itself
          leading: tvMode ? remoteBackButton(context) : null,
          title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            Focus(
              focusNode: _actionsFocus,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // First, so that OK from the photo lands on it on a TV, and each OK turns the photo again
                  if (photo != null && _canRotate)
                    GestureDetector(
                      onLongPress: () => _rotate(photo, -1),
                      child: IconButton(
                        key: const Key('network_photo_rotate'),
                        icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
                        tooltip: context.t.editor_rotate_right,
                        onPressed: () => _rotate(photo, 1),
                      ),
                    ),
                  if (photo != null && stereoPair != null)
                    IconButton(
                      key: const Key('apple_spatial_view_3d'),
                      icon: const Icon(Icons.view_in_ar_rounded),
                      tooltip: context.t.apple_spatial_view_3d,
                      onPressed: () =>
                          unawaited(_openStereo(photo.entry.path, StereoPhotoRequest.heic(stereoPair), url: photo.url)),
                    ),
                  if (photo != null && stereoPhoto != null)
                    IconButton(
                      key: const Key('apple_spatial_view_3d'),
                      icon: const Icon(Icons.view_in_ar_rounded),
                      tooltip: sbsRequest != null
                          ? context.t.apple_spatial_view_3d
                          : context.t.ai_immersive_newer_version,
                      onPressed: sbsRequest == null
                          ? null
                          : () => unawaited(
                              _openStereo(photo.entry.path, StereoPhotoRequest.sbs(sbsRequest), url: photo.url),
                            ),
                    ),
                  if (photo != null && stackedFormat != null)
                    IconButton(
                      key: const Key('apple_spatial_view_3d'),
                      icon: const Icon(Icons.view_in_ar_rounded),
                      tooltip: context.t.apple_spatial_view_3d,
                      onPressed: () => unawaited(
                        _openStereo(
                          photo.entry.path,
                          StereoPhotoRequest.flat3d(Flat3dRequest(stackedFormat)),
                          url: photo.url,
                        ),
                      ),
                    ),
                  if (photo != null && version != null)
                    IconButton(
                      key: const Key('ai_immersive_view_3d_version'),
                      icon: const Icon(Icons.view_in_ar_outlined),
                      tooltip: versionRequest != null
                          ? context.t.ai_immersive_view_3d_version
                          : context.t.ai_immersive_newer_version,
                      onPressed: versionRequest == null
                          ? null
                          : () => unawaited(
                              _openStereo(
                                version.entry.path,
                                StereoPhotoRequest.sbs(versionRequest),
                                url: widget.folder?.urls[version.entry.path],
                              ),
                            ),
                    ),
                  if (photo != null && scene != null)
                    AiSceneButton(
                      xmp: scene,
                      fileSize: photo.entry.size,
                      open: (stereo) => _openStereo(photo.entry.path, stereo, url: photo.url),
                    ),
                  if (photo != null && sceneVersion != null)
                    AiSceneButton(
                      xmp: sceneVersion.xmp as SceneXmp,
                      fromOriginal: true,
                      fileSize: sceneVersion.entry.size,
                      open: (stereo) => _openStereo(
                        sceneVersion.entry.path,
                        stereo,
                        url: widget.folder?.urls[sceneVersion.entry.path],
                      ),
                    ),
                  if (photo != null && panoramaVersion != null)
                    IconButton(
                      key: const Key('ai_immersive_view_360_version'),
                      icon: const Icon(Icons.panorama_photosphere_outlined),
                      tooltip: context.t.ai_immersive_view_360_version,
                      onPressed: () => unawaited(_openPanoramaVersion(panoramaVersion)),
                    ),
                  if (photo != null && reliefGate.visible)
                    AiReliefButton(
                      gate: reliefGate,
                      mode: reliefMode,
                      target: ReliefTarget(
                        identity: () async => reliefIdentityOfShareFile(
                          sourceId: widget.sourceId,
                          path: widget.path,
                          size: photo.entry.size,
                          modified: photo.entry.modified,
                        ),
                        quarterTurns: () async => turns,
                        open: (stereo) => _openStereo(photo.entry.path, stereo, url: photo.url),
                      ),
                    ),
                  if (photo != null && is360)
                    IconButton(
                      icon: const Icon(Icons.threesixty_rounded),
                      tooltip: '360°',
                      onPressed: () => unawaited(_open360(photo)),
                    ),
                  // Immuch360 Desktop: the versions of the photo on its share, and its original for a version
                  // (lib/desktop/ai/library/share_versions_button.dart)
                  if (CurrentPlatform.isDesktop && photo != null)
                    DesktopShareVersionsButton(
                      key: ValueKey('versions:${photo.entry.path}'),
                      entry: photo.entry,
                      neighbours: widget.folder?.entries,
                    ),
                  // Immuch360 Desktop: the window in full screen (lib/desktop/window/full_screen.dart)
                  if (CurrentPlatform.isDesktop) const DesktopFullScreenButton(),
                  if (photo != null && (!is360 || canUpload || makeImmersive != null))
                    PopupMenuButton<void>(
                      tooltip: context.t.more,
                      itemBuilder: (context) => [
                        if (!is360)
                          PopupMenuItem<void>(
                            onTap: () => unawaited(_open360(photo)),
                            child: ListTile(
                              leading: const Icon(Icons.threesixty_rounded),
                              title: Text(context.t.view_as_360),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        if (canUpload)
                          PopupMenuItem<void>(
                            // One upload from the shares at a time
                            enabled: !isUploading,
                            onTap: () =>
                                unawaited(uploadNetworkEntries(this.context, ref, widget.sourceId, [photo.entry])),
                            child: ListTile(
                              leading: const Icon(Icons.backup_outlined),
                              title: Text(context.t.network_upload_action),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        if (makeImmersive != null)
                          desktopShareMakeImmersiveMenuItem(
                            context,
                            makeImmersive,
                            onOpen: () =>
                                unawaited(ref.read(shareConversionOpenerProvider)(this.context, [photo.entry])),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
        return Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: PreferredSize(
            preferredSize: appBar.preferredSize,
            child: Focus(focusNode: _appBarFocus, onKeyEvent: _onAppBarKey, child: appBar),
          ),
          body: photo != null
              // Immuch360 Desktop: previous and next for the mouse (lib/desktop/window/hover_chevrons.dart)
              ? CurrentPlatform.isDesktop
                    ? withDesktopPageChevrons(
                        _buildPhoto(photo, turns),
                        canNavigate: (step) =>
                            networkFolderNeighbourRoute(widget.sourceId, widget.folder, widget.path, step) != null,
                        onNavigate: _openNeighbour,
                      )
                    : _buildPhoto(photo, turns)
              : snapshot.connectionState != ConnectionState.done
              ? const NetworkLoadingView(color: Colors.white70)
              : Focus(
                  focusNode: _errorFocus,
                  child: NetworkErrorView(
                    error: snapshot.error ?? 'unknown error',
                    onRetry: _retry,
                    color: Colors.white70,
                  ),
                ),
        );
      },
    );

    return PopScope(
      // On a TV, Back from the app bar goes back to the photo first
      canPop: !tvMode || !_appBarFocus.hasFocus,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _rootFocus.requestFocus();
        }
      },
      child: Focus(focusNode: _rootFocus, autofocus: true, onKeyEvent: _onKey, child: page),
    );
  }

  Widget _buildPhoto(_Photo photo, int turns) {
    final image = networkPhotoImage(photo.url);
    _listenToImage(image);
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformation,
        maxScale: 8,
        child: SizedBox.expand(
          // Turned as a layout (the one-key rotation): the screen's box goes to the image with its sides swapped for
          // an odd number of turns, so that the turned photo fits it whole; no decode, no copy
          child: RotatedBox(
            quarterTurns: turns,
            child: Image(
              image: image,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              // A TIFF decoded on the device says so while its file comes and decodes
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : image is NetworkTiffImage
                  ? TiffDecodingView(progress: progress, color: Colors.white70)
                  : const NetworkLoadingView(color: Colors.white70),
              errorBuilder: (context, error, _) => NetworkErrorView(error: error, color: Colors.white70),
            ),
          ),
        ),
      ),
    );
  }
}
