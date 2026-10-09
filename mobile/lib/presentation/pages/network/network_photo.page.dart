import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/desktop/window/hover_chevrons.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_back_button.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkPhotoPage');

/// Largest side the flat view decodes a photo at: a large panorama would not fit in memory at its full size
const _maxFlatSize = 4096;

/// The image of a photo of a share for the flat view, through the media bridge at [url]
ImageProvider networkPhotoImage(Uri url) =>
    ResizeImage(NetworkImage(url.toString()), width: _maxFlatSize, height: _maxFlatSize, policy: ResizeImagePolicy.fit);

/// The image of a photo of a share for the 360° viewer, through the media bridge at [url]: at most 8192 x 4096 pixels,
/// the largest texture most phones take (see textureDecodeSize), or 4096 x 2048 on a TV that Android calls a low RAM
/// device ([lowRam]: 32 MB instead of 128)
ImageProvider networkPanoramaImage(Uri url, {bool lowRam = false}) => ResizeImage(
  NetworkImage(url.toString()),
  width: (lowRam ? lowRamTextureSize.width : 8192).toInt() - 1,
  height: (lowRam ? lowRamTextureSize.height : 4096).toInt() - 1,
  policy: ResizeImagePolicy.fit,
);

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
/// a "View in 3D" button, which shows both eyes in the immersive viewer.
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

  /// Reads the file straight from the share, for the calibration of a raw photo; null until the share is open
  ByteRangeReader? _shareReader;

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
    final fileSystem = await connections.fileSystem(widget.sourceId);
    final entry = await fileSystem.stat(widget.path);
    final url = await connections.mediaUrl(widget.sourceId, widget.path);
    _shareReader = networkFileReader(fileSystem, widget.path);
    unawaited(_detect(service, entry, httpRangeReader(client, url)));
    return (entry: entry, url: url);
  }

  // Through the media bridge, with range requests, like the players read the file
  Future<void> _detect(NetworkMediaService service, NetworkEntry entry, ByteRangeReader read) async {
    final info = await service.detect(entry, read, thorough: true);
    if (info != null && mounted) {
      setState(() => _info = info);
    }
  }

  void _retry() {
    // Retry leaves with the error: the page takes the keys again
    if (_errorFocus.hasFocus) {
      _rootFocus.requestFocus();
    }
    setState(() {
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

  /// Shows both eyes of [photo], an Apple spatial photo whose pair is [pair], in the immersive viewer: read through the
  /// media bridge, like any photo of a share. No previous or next from there yet: the viewer says so itself.
  Future<void> _openStereo(_Photo photo, HeicStereoPair pair) async {
    // Read before the first await: the page may be gone by then
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorMessage = context.t.immersive_viewer_open_failed;
    final stereoLabels = sphereViewerLabels(context.t);
    final request = ImmersiveRequest(
      url: photo.url.toString(),
      isVideo: false,
      title: photo.entry.name,
      view: stereoPhotoSphereView,
      stereoPair: pair.toImmersiveJson(),
    );
    try {
      await openImmersiveUrl(ref, request: request, stereoLabels: stereoLabels);
    } catch (error) {
      _log.warning('Could not open ${photo.entry.name} in 3D: $error');
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
    final page = FutureBuilder<_Photo>(
      future: _photo,
      builder: (context, snapshot) {
        final photo = snapshot.data;
        final is360 = _info?.is360 ?? false;
        final stereoPair = isHorizonOs ? _info?.stereoPair : null;
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
                  if (photo != null && stereoPair != null)
                    IconButton(
                      key: const Key('apple_spatial_view_3d'),
                      icon: const Icon(Icons.view_in_ar_rounded),
                      tooltip: context.t.apple_spatial_view_3d,
                      onPressed: () => unawaited(_openStereo(photo, stereoPair)),
                    ),
                  if (photo != null && is360)
                    IconButton(
                      icon: const Icon(Icons.threesixty_rounded),
                      tooltip: '360°',
                      onPressed: () => unawaited(_open360(photo)),
                    ),
                  // Immuch360 Desktop: the window in full screen (lib/desktop/window/full_screen.dart)
                  if (CurrentPlatform.isDesktop) const DesktopFullScreenButton(),
                  if (photo != null && (!is360 || canUpload))
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
                        _buildPhoto(photo),
                        canNavigate: (step) =>
                            networkFolderNeighbourRoute(widget.sourceId, widget.folder, widget.path, step) != null,
                        onNavigate: _openNeighbour,
                      )
                    : _buildPhoto(photo)
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

  Widget _buildPhoto(_Photo photo) {
    final image = networkPhotoImage(photo.url);
    _listenToImage(image);
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformation,
        maxScale: 8,
        child: SizedBox.expand(
          child: Image(
            image: image,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const NetworkLoadingView(color: Colors.white70),
            errorBuilder: (context, error, _) => NetworkErrorView(error: error, color: Colors.white70),
          ),
        ),
      ),
    );
  }
}
