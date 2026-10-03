// Meta Quest (Horizon OS): 360 photos and videos open in a native immersive activity with head
// tracking (ImmersiveViewerActivity, Meta Spatial SDK). Phones keep the in-app panorama viewer.
//
// The viewer goes to the previous and next 360° media of the timeline or of the share folder it was opened from: it
// asks Flutter (see ImmersiveSession), which finds the media and shows it in place (ImmersiveApi.showAdjacent), with
// what the opener read from the providers when the viewer opened, the widget that opened it being possibly gone by
// then.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/immersive_navigation.service.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_file_path.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

final _log = Logger('ImmersiveViewer');

/// Client of the request for the GPano tags of a photo that looks 3D: the app's shared client, with its native SSL
/// setup. Tests replace it.
final immersiveGPanoClientProvider = Provider<http.Client>((_) => NetworkRepository.client);

/// URL on the server loaded by the immersive viewer, or null for an asset that is not on the server.
/// Photos: the original (the viewer shows the preview first and keeps it if the original fails).
/// Videos: always the original, whatever the viewer setting: the server transcode defaults to 720p H.264, too
/// blurry for 360°. The viewer falls back to the playback stream by itself when the original cannot stream or play.
String? immersiveMediaUrl(BaseAsset asset) {
  final remoteId = asset.remoteId;
  if (remoteId == null) {
    return null;
  }
  if (!asset.isVideo) {
    return getOriginalUrlForRemoteId(remoteId);
  }
  final videoId = (asset is RemoteAsset ? asset.livePhotoVideoId : null) ?? remoteId;
  return '${Store.get(StoreKey.serverEndpoint)}/assets/$videoId/original';
}

/// A media as the immersive viewer opens it: where it reads it ([url], with [headers]), whether it is a video, its
/// [title], and how it shows it at first ([view], see [resolveSphereView]), whose guessed coverage tells a correction
/// of the user from a return to the guess once the viewer closes.
class ImmersiveRequest {
  const ImmersiveRequest({
    required this.url,
    this.headers = const {},
    required this.isVideo,
    required this.title,
    required this.view,
  });

  final String url;
  final Map<String, String> headers;
  final bool isVideo;
  final String title;
  final SphereView view;

  @override
  String toString() => 'ImmersiveRequest(url: $url, isVideo: $isVideo, title: $title, view: $view)';
}

/// Opens [request] in the immersive viewer through [api], a video from [startPosition], with the controls labelled
/// with [stereoLabels] (see [sphereViewerLabels]), as the opening [openingId] (see [ImmersiveSession.start]), which
/// the viewer sends back with its events. This starts the viewer: a media found for previous or next is shown with
/// [showImmersiveRequest] instead.
Future<void> openImmersiveRequest(
  ImmersiveApi api,
  ImmersiveRequest request, {
  required Map<String, String> stereoLabels,
  required int openingId,
  Duration startPosition = Duration.zero,
}) => api.open(
  request.url,
  request.headers,
  request.isVideo,
  request.title,
  request.view.layout.toImmersive(),
  stereoLabels,
  request.view.coverage.toImmersive(),
  math.max(0, startPosition.inMilliseconds),
  openingId,
);

/// Shows [request] in place of the media of the immersive viewer that asked for another one with [requestId] (see
/// [ImmersiveAdjacentRequest.show]), through [api]. True when the viewer shows it; never starts the viewer.
Future<bool> showImmersiveRequest(ImmersiveApi api, int requestId, ImmersiveRequest request) => api.showAdjacent(
  requestId,
  request.url,
  request.isVideo,
  request.title,
  request.view.layout.toImmersive(),
  request.view.coverage.toImmersive(),
);

/// Turns assets into what the immersive viewer opens (see [resolve]) and opens them, with the services an opener
/// reads from the providers before the viewer opens (see [ImmersiveAssetResolver.read]): the viewer shows more assets
/// of the same timeline later, when the widget that opened it may be gone.
class ImmersiveAssetResolver {
  const ImmersiveAssetResolver({
    required this.api,
    required this.stereoLabels,
    required this.coverageOverrides,
    required this._storage,
    required this._probeService,
    required this._gpanoClient,
  });

  /// Reads the services from the providers. Call it before the first await of an opener: the widget may be gone after.
  factory ImmersiveAssetResolver.read(WidgetRef ref, {required Map<String, String> stereoLabels}) =>
      ImmersiveAssetResolver(
        api: ref.read(immersiveApiProvider),
        stereoLabels: stereoLabels,
        coverageOverrides: ref.read(sphereCoverageOverridesProvider.notifier),
        storage: ref.read(storageRepositoryProvider),
        probeService: ref.read(sphericalProbeServiceProvider),
        gpanoClient: ref.read(immersiveGPanoClientProvider),
      );

  final ImmersiveApi api;

  /// Labels of the controls of the viewer, see [sphereViewerLabels]
  final Map<String, String> stereoLabels;

  /// The coverages the user picked, which win over the guess, and where the one picked in the viewer goes
  final SphereCoverageOverrides coverageOverrides;

  final StorageRepository _storage;
  final SphericalProbeService _probeService;
  final http.Client _gpanoClient;

  /// What the viewer opens for [asset]. A video plays from the copy on the device when there is one, like in the
  /// in-app player, else from its original on the server. A photo opens from its original on the server, and an asset
  /// only on the device (no server, or not uploaded) from its file there, photo or video alike. [localPath] is the
  /// file of a media opened with "Open with" that is not in the library, which opens from there. Throws when there
  /// is no file to open.
  ///
  /// The headset shows each eye its own half of a 3D media, over the whole sphere or its front half (VR180): the
  /// coverage the user picked for the asset, else the layout and the coverage the file declares for a video (see
  /// [SphericalProbeService]), else guesses from the asset dimensions and name (see [resolveSphereView]), until the
  /// user picks others with the controls of the viewer. Like the phone viewer, a partial panorama stays mono whatever
  /// its aspect ratio, and covers what its GPano crop says: for a photo that looks 3D, the GPano crop the server copies
  /// into the preview's XMP tells, or for a photo only on the device the one in its file. The guess stands when that
  /// read fails.
  Future<ImmersiveRequest> resolve(BaseAsset asset, {String? localPath}) async {
    final remoteUrl = immersiveMediaUrl(asset);
    // A photo on the server opens from its original there
    final localId = asset.isVideo || remoteUrl == null ? asset.localId : null;
    SphereView view({Rect? gpanoCrop, SphericalProbe? probe}) => resolveSphereView(
      fileName: asset.name,
      width: asset.width,
      height: asset.height,
      gpanoCrop: gpanoCrop,
      probe: probe,
      chosenCoverage: coverageOverrides.get(asset),
    );
    // Only a photo that looks 3D needs its GPano crop
    final needsGPanoCrop = !asset.isVideo && view().layout != StereoLayout.mono;

    var localFile = localPath == null ? null : File(localPath);
    if (localFile == null && localId != null) {
      try {
        localFile = await _storage.getFileForAsset(localId);
      } catch (error) {
        _log.warning('Copy on the device of ${asset.name} unreadable: $error');
      }
    }
    // The immersive viewer reads file:// URIs too
    final url = localFile?.uri.toString() ?? remoteUrl;
    if (url == null) {
      throw StateError('No file to open for ${asset.name}');
    }

    Rect? gpanoCrop;
    final remoteId = asset.remoteId;
    if (needsGPanoCrop && remoteUrl != null && remoteId != null) {
      final gpano = await fetchGPano(
        _gpanoClient,
        Uri.parse(getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview)),
      );
      gpanoCrop = gpano?.crop;
    } else if (needsGPanoCrop && localFile != null) {
      try {
        final tags = await readGPanoFile(localFile).timeout(const Duration(seconds: 5));
        gpanoCrop = tags?.crop;
      } catch (error) {
        _log.info('Could not read the GPano tags of ${asset.name}: $error');
      }
    }
    if (gpanoCrop != null && isPartialSphere(gpanoCrop)) {
      _log.fine('${asset.name} is a partial panorama, shown mono');
    }

    return ImmersiveRequest(
      url: url,
      headers: ApiService.getRequestHeaders(),
      isVideo: asset.isVideo,
      title: asset.name,
      view: view(
        gpanoCrop: gpanoCrop,
        probe: asset.isVideo ? await _probeService.probe(asset, localFile: localFile) : null,
      ),
    );
  }

  /// Opens [request] in the viewer as the opening [openingId], see [openImmersiveRequest]
  Future<void> open(ImmersiveRequest request, {required int openingId, Duration startPosition = Duration.zero}) =>
      openImmersiveRequest(
        api,
        request,
        stereoLabels: stereoLabels,
        openingId: openingId,
        startPosition: startPosition,
      );
}

/// Stops the in-app video player, then opens the asset in the immersive viewer (see [ImmersiveAssetResolver.resolve]),
/// a video from where the in-app player was when it stopped. A media opened with "Open with" that is not in the
/// library opens from its temporary copy. Throws when there is no file to open or the viewer does not open, the
/// in-app player then given back where and as it was.
///
/// The viewer then goes to the previous and next 360° assets of the timeline on its own (see
/// [TimelineImmersiveNavigator]); once it closes, the asset viewer shows the asset it showed last, and the in-app
/// player of a video takes it back where the viewer left it.
Future<void> openImmersiveViewer(WidgetRef ref, BaseAsset asset, {required Map<String, String> stereoLabels}) async {
  // Read before the first await: the viewer may be gone by then
  final resolver = ImmersiveAssetResolver.read(ref, stereoLabels: stereoLabels);
  final session = ref.read(immersiveSessionProvider);
  final timeline = ref.read(timelineServiceProvider);
  // The asset viewer of this route, which follows the immersive viewer once it closes
  final jump = ref.read(assetViewerJumpProvider);
  final player = asset.isVideo ? ref.read(videoPlayerProvider(asset.id).notifier) : null;
  // Opened with "Open with" and not in the library: its temporary copy (see AssetPage)
  final viewIntentPath = timeline.origin == TimelineOrigin.deepLink ? ref.read(viewIntentFilePathProvider) : null;
  final forced = ref.read(forcedPanoramaAssetsProvider);
  final localIds = ref.read(localPanoramaIdsProvider);
  final remoteAssets = ref.read(driftProvider).remoteAssetRepository;
  final index = timeline.getIndex(asset.heroTag) ?? jump.currentIndex;
  // The viewer carries on from where the in-app player is, unless it reached the end: read right before the player
  // stops, the video playing on until then
  final playback = asset.isVideo ? ref.read(videoPlayerProvider(asset.id)) : null;
  final startPosition = playback == null || playback.status == VideoPlaybackStatus.completed
      ? Duration.zero
      : playback.position;

  // Stopped before the slow steps (the copy on the device, the GPano tags, the probe of a video) rather than once the
  // viewer opens: the video would play on meanwhile, past where the viewer starts. Nothing plays or buffers behind the
  // immersive view, and the viewer lifts this when the app resumes.
  await player?.suspendForExternalPlayer();
  int? openingId;
  try {
    final request = await resolver.resolve(asset, localPath: viewIntentPath);
    final navigator = TimelineImmersiveNavigator(
      resolver: resolver,
      timeline: timeline,
      asset: asset,
      request: request,
      index: index,
      forced: forced,
      localIds: localIds,
      equirectangularRemoteIds: remoteAssets.equirectangularRemoteIds,
      jump: jump,
      player: player,
    );
    openingId = session.start(navigator);
    await resolver.open(request, openingId: openingId, startPosition: startPosition);
  } catch (_) {
    if (openingId != null) {
      session.cancel(openingId);
    }
    // Nothing else would bring the viewer's player back. Stopped before the slow steps, the video goes on where and as
    // it was rather than from its start.
    if (player != null && playback != null) {
      final wasPlaying =
          playback.status == VideoPlaybackStatus.playing || playback.status == VideoPlaybackStatus.buffering;
      await player.resumeAfterExternalPlayerAt(playback.position, play: wasPlaying);
    }
    rethrow;
  }
}

/// Opens [request] in the immersive viewer, like [openImmersiveViewer] for a media that is no asset: a file of a
/// network share, streamed through the local media bridge for example. Its layout and coverage are what the viewer
/// opens with (see [resolveSphereView]), and [stereoLabels] label its controls (see [sphereViewerLabels]); the user can
/// change them there, and nothing is remembered. A video starts at [startPosition].
///
/// [navigator] goes to the previous and next media, and takes the closing of the viewer (see
/// [FolderImmersiveNavigator]); without one, the viewer has no previous or next.
///
/// Meanwhile [player], the page's own player for a video, is stopped (see
/// [VideoPlayerNotifier.suspendForExternalPlayer]): the page lifts this when the app resumes. A failure to open gives
/// it back right away, and is rethrown.
Future<void> openImmersiveUrl(
  WidgetRef ref, {
  required ImmersiveRequest request,
  required Map<String, String> stereoLabels,
  Duration startPosition = Duration.zero,
  VideoPlayerNotifier? player,
  ImmersiveNavigator? navigator,
}) async {
  // Read before the first await: the page may be gone by then
  final api = ref.read(immersiveApiProvider);
  final session = ref.read(immersiveSessionProvider);
  await player?.suspendForExternalPlayer();
  final openingId = session.start(navigator);
  try {
    await openImmersiveRequest(
      api,
      request,
      stereoLabels: stereoLabels,
      openingId: openingId,
      startPosition: startPosition,
    );
  } catch (_) {
    session.cancel(openingId);
    await player?.resumeAfterExternalPlayer();
    rethrow;
  }
}

/// An asset the immersive viewer shows: what it opened it with, its index in the timeline when last found there (null
/// when unknown), and the coverage the viewer shows it with as far as this app knows, the one it opened with until a
/// correction of the user is remembered
typedef _ShownAsset = ({BaseAsset asset, ImmersiveRequest request, int? index, SphereCoverage coverage});

/// Previous and next among the assets of a timeline, for the immersive viewer opened from the asset viewer (see
/// [openImmersiveViewer]). It skips the assets the viewer would not show as 360° (see [isImmersiveCandidate]): any
/// asset of the 360° timeline; elsewhere those the user chose to view as 360°, those whose file on the device declares
/// it ([forced] and [localIds], as they were when the viewer opened), and those the server flags (looked up with
/// [equirectangularRemoteIds], a chunk at a time).
///
/// The coverage the user picked in the viewer for an asset is remembered (see [SphereCoverageOverrides.remember]) when
/// the viewer moves on from it and when it closes on it. Once it closes, the asset viewer ([jump]) shows the asset it
/// showed last, and when that is the asset it opened on, a video, [player], the in-app player of that video, takes it
/// back where the viewer left it. Assets are told apart by what they are, the timeline moving under the viewer as
/// the app syncs.
///
/// The search reads the very timeline of the asset viewer, whose buffer the pages of the asset viewer are built from:
/// that buffer is loaded around the page on screen again after each search, and once the viewer closes (see
/// [AssetViewerJump]). A timeline of its own for the search would leave that buffer alone, but TimelineService keeps
/// its query to itself, and a second one would watch the buckets of the timeline in the database and load its first
/// assets for nothing.
class TimelineImmersiveNavigator implements ImmersiveNavigator {
  TimelineImmersiveNavigator({
    required this._resolver,
    required this._timeline,
    required BaseAsset asset,
    required ImmersiveRequest request,
    required int? index,
    required this._forced,
    required this._localIds,
    required this._equirectangularRemoteIds,
    this._jump,
    this._player,
  }) : _start = (asset: asset, request: request, index: index, coverage: request.view.coverage),
       _current = (asset: asset, request: request, index: index, coverage: request.view.coverage);

  // Assets on each side of its last known index loaded to find an asset again, which a sync may have moved by a few
  static const _locateMargin = 16;

  final ImmersiveAssetResolver _resolver;
  final TimelineService _timeline;
  final Set<String> _forced;
  final Set<String> _localIds;
  final Future<Set<String>> Function(Iterable<String> remoteIds) _equirectangularRemoteIds;
  final AssetViewerJump? _jump;
  final VideoPlayerNotifier? _player;
  final _ShownAsset _start;
  _ShownAsset _current;
  // The asset shown before the current one, see [_shownAt]
  _ShownAsset? _previous;

  /// The asset the viewer shows, as far as this navigator knows
  BaseAsset get currentAsset => _current.asset;

  bool get _all360 => _timeline.origin == TimelineOrigin.panorama360;

  @override
  Future<bool> showAdjacent(ImmersiveAdjacentRequest request) async {
    // The coverage the user picked for the asset shown is kept before moving on: the viewer only reports what it shows
    // when it closes, on another asset by then. It counts as what the asset shows with from now on, so that taking it
    // back to the guess later forgets it.
    final coverage = sphereCoverageOfImmersive(request.coverage);
    final shown = _current;
    unawaited(_remember(shown, coverage));
    _current = (asset: shown.asset, request: shown.request, index: shown.index, coverage: coverage);
    try {
      return await _showAdjacent(request);
    } finally {
      // Found or not, the search left the buffer of the timeline where it looked
      unawaited(_recenter());
    }
  }

  Future<bool> _showAdjacent(ImmersiveAdjacentRequest request) async {
    final shownIndex = await _locate(_current);
    if (shownIndex == null) {
      _log.info('${_current.asset.name} is not found in its timeline: no previous or next');
      return false;
    }
    var from = shownIndex;
    var budget = immersiveTimelineSearchLimit;
    while (budget > 0 && !request.isCancelled) {
      final found = await findAdjacentImmersive<BaseAsset>(
        index: from,
        step: request.step,
        length: _timeline.totalAssets,
        lookup: _lookup,
        isCapable: _areCapable,
        limit: budget,
        isCancelled: () => request.isCancelled,
      );
      if (found == null) {
        return false;
      }
      budget -= (found.index - from).abs();
      from = found.index;
      final ImmersiveRequest resolved;
      try {
        resolved = await _resolver.resolve(found.item);
      } catch (error) {
        // An asset without a file to open, a copy on the device gone for example: the next one may do
        _log.warning('Skipping ${found.item.name} in the immersive viewer: $error');
        continue;
      }
      final shown = await request.show((requestId) => showImmersiveRequest(_resolver.api, requestId, resolved));
      if (shown) {
        // Only once the viewer said it shows it: what it reports on closing goes to the asset it shows
        _previous = _current;
        _current = (asset: found.item, request: resolved, index: found.index, coverage: resolved.view.coverage);
      }
      return shown;
    }
    return false;
  }

  /// The index of [shown] in the timeline now: the timeline may have moved since it was found there, after a sync.
  /// Found by what it is, around its last known index; that index when it is no longer found there, null when it
  /// never was.
  Future<int?> _locate(_ShownAsset shown) async {
    final known = shown.index;
    final total = _timeline.totalAssets;
    var start = 0;
    var count = 0;
    if (known != null && total > 0) {
      // The timeline holds a part of its assets at a time, which getIndex looks in: that part goes around the index
      start = math.max(0, math.min(known, total - 1) - _locateMargin);
      count = math.min(2 * _locateMargin + 1, total - start);
      try {
        await _timeline.loadAssets(start, count);
      } catch (error) {
        _log.fine('Could not load the timeline around $known: $error');
        count = 0;
      }
    }
    final asset = shown.asset;
    final tagged = _timeline.getIndex(asset.heroTag);
    if (tagged != null) {
      return tagged;
    }
    // The hero tag changes once the copy on the device of an asset is known, or once it is uploaded
    for (var index = start; index < start + count; index++) {
      if (_timeline.getAssetSafe(index)?.refersToSameAsset(asset) ?? false) {
        return index;
      }
    }
    return known;
  }

  Future<List<BaseAsset?>> _lookup(int start, int count) async {
    try {
      return await _timeline.loadAssets(start, count);
    } catch (error) {
      // The timeline changed under the search, after a sync or a deletion: what is left of the range, one by one
      _log.fine('Could not load the assets $start to ${start + count - 1} at once: $error');
      return [for (var index = start; index < start + count; index++) await _timeline.getAssetAsync(index)];
    }
  }

  Future<List<bool>> _areCapable(List<BaseAsset> assets) async {
    bool isCapable(BaseAsset asset, [Set<String> equirectangularIds = const {}]) => isImmersiveCandidate(
      asset,
      all360: _all360,
      forced: _forced,
      localIds: _localIds,
      equirectangularIds: equirectangularIds,
    );

    // Only the assets that nothing at hand tells are asked to the database, all at once
    final remoteIds = {
      for (final asset in assets)
        if ((asset.isImage || asset.isVideo) && !isCapable(asset)) ?asset.remoteId,
    };
    var flagged = const <String>{};
    if (remoteIds.isNotEmpty) {
      try {
        flagged = await _equirectangularRemoteIds(remoteIds);
      } catch (error, stackTrace) {
        _log.warning('Could not tell which assets the server flags as 360°', error, stackTrace);
      }
    }
    return [for (final asset in assets) isCapable(asset, flagged)];
  }

  @override
  void onClosed(String url, ImmersiveStereoLayout stereoLayout, ImmersiveSphereCoverage coverage, int positionMs) {
    final shown = _shownAt(url);
    if (shown == null) {
      // Nothing is attributed to an asset the viewer may not have shown
      _log.info('The immersive viewer closed on a media this navigator did not show');
      unawaited(_recenter());
      return;
    }
    // Like the native 360° player, the layout is not remembered: the guess comes again, or what the file declares
    unawaited(_remember(shown, sphereCoverageOfImmersive(coverage)));
    final player = _player;
    if (shown.asset.refersToSameAsset(_start.asset) && shown.asset.isVideo && player != null && player.mounted) {
      // Paused: the user is back in the app, and the video waits for them where they left it
      unawaited(player.resumeAfterExternalPlayerAt(Duration(milliseconds: math.max(0, positionMs)), play: false));
    }
    unawaited(_follow(shown));
  }

  /// The asset shown at [url]: the current one, else the one before it or the one the viewer opened on, which it may
  /// report when it closed as Flutter moved on; null for none of them
  _ShownAsset? _shownAt(String url) {
    for (final shown in [_current, ?_previous, _start]) {
      if (shown.request.url == url) {
        return shown;
      }
    }
    return null;
  }

  /// The asset viewer shows [shown], where it is in the timeline now. It stays where it is when [shown] is not found
  /// there or cannot be shown, with the timeline loaded around its page again all the same (see
  /// [AssetViewerJump.jumpTo]): the searches and [_locate] left the buffer of the timeline elsewhere, where the page
  /// on screen would find no asset to show.
  Future<void> _follow(_ShownAsset shown) async {
    final jump = _jump;
    if (jump == null) {
      return;
    }
    int? index;
    try {
      index = await _locate(shown);
    } catch (error, stackTrace) {
      _log.warning('Could not find ${shown.asset.name} in its timeline again', error, stackTrace);
    }
    if (index == null) {
      return _recenter();
    }
    try {
      await jump.jumpTo(index);
    } catch (error, stackTrace) {
      _log.warning('Could not show ${shown.asset.name} in the asset viewer', error, stackTrace);
      await _recenter();
    }
  }

  Future<void> _recenter() async {
    try {
      await _jump?.recenter();
    } catch (error, stackTrace) {
      _log.warning('Could not load the timeline around the asset viewer again', error, stackTrace);
    }
  }

  Future<void> _remember(_ShownAsset shown, SphereCoverage coverage) async {
    try {
      await _resolver.coverageOverrides.remember(
        shown.asset,
        coverage,
        opened: shown.coverage,
        guess: shown.request.view.coverageGuess,
      );
    } catch (error, stackTrace) {
      _log.warning('Could not remember the coverage $coverage', error, stackTrace);
    }
  }
}

/// A photo or a video of a share folder, and the media bridge URL the immersive viewer reads it from
typedef ImmersiveFolderItem = ({NetworkEntry entry, Uri url});

/// Previous and next among the photos and videos of a share folder, [items] in the order the browser lists them, for
/// the immersive viewer opened with [request] on the one at [index], from a network page (see [openImmersiveUrl]).
///
/// It skips the files that declare no 360° projection (see [NetworkMediaService.detect]), except the one it opened on:
/// the user chose to view that one as 360° whatever it declares, and it shows again as it opened, with what the page
/// guessed from its frame size. What a file declares is read once: the files the browser or an earlier search read
/// answer from memory, the others are read through the media bridge with [client], one by one, for [fileTimeout] at
/// most each.
///
/// Nothing the user picks in the viewer is remembered, as on the pages. When the viewer closes on the video it opened
/// on, [player], the page's player, takes it back where the viewer left it.
class FolderImmersiveNavigator implements ImmersiveNavigator {
  FolderImmersiveNavigator({
    required this._api,
    required this._service,
    required this._client,
    required List<ImmersiveFolderItem> items,
    required int index,
    required ImmersiveRequest request,
    this._player,
    this.fileTimeout = immersiveFolderFileTimeout,
  }) : _items = List.unmodifiable(items),
       _start = index,
       _startRequest = request,
       _index = index;

  /// Reads the services from the providers. Call it before the first await of an opener: the page may be gone after.
  factory FolderImmersiveNavigator.read(
    WidgetRef ref, {
    required List<ImmersiveFolderItem> items,
    required int index,
    required ImmersiveRequest request,
    VideoPlayerNotifier? player,
  }) => FolderImmersiveNavigator(
    api: ref.read(immersiveApiProvider),
    service: ref.read(networkMediaServiceProvider),
    client: ref.read(networkBridgeClientProvider),
    items: items,
    index: index,
    request: request,
    player: player,
  );

  /// Longest wait for what a file declares, see [immersiveFolderFileTimeout]
  final Duration fileTimeout;

  final ImmersiveApi _api;
  final NetworkMediaService _service;
  final http.Client _client;
  final List<ImmersiveFolderItem> _items;
  final int _start;
  final ImmersiveRequest _startRequest;
  final VideoPlayerNotifier? _player;
  int _index;
  // The file shown before the current one, see [_indexAt]
  int? _previous;

  /// The file the viewer shows, as far as this navigator knows
  NetworkEntry get currentEntry => _items[_index].entry;

  @override
  Future<bool> showAdjacent(ImmersiveAdjacentRequest request) async {
    // What the files declare, kept from the search for the one it finds
    final infos = <int, NetworkMediaInfo>{};
    final found = await findAdjacentImmersiveInFolder<int>(
      items: [for (var index = 0; index < _items.length; index++) index],
      index: _index,
      step: request.step,
      isCapable: (index) async {
        if (index == _start) {
          return true;
        }
        final info = await _detect(_items[index], request);
        if (info != null) {
          infos[index] = info;
        }
        return info?.is360 ?? false;
      },
      isCancelled: () => request.isCancelled,
    );
    if (found == null) {
      return false;
    }
    final shownRequest = found.index == _start
        ? _startRequest
        : folderImmersiveRequest(_items[found.index], infos[found.index] ?? const NetworkMediaInfo());
    final shown = await request.show((requestId) => showImmersiveRequest(_api, requestId, shownRequest));
    if (shown) {
      // Only once the viewer said it shows it: what it reports on closing goes to the file it shows
      _previous = _index;
      _index = found.index;
    }
    return shown;
  }

  /// What [item] declares, null when that is unknown
  Future<NetworkMediaInfo?> _detect(ImmersiveFolderItem item, ImmersiveAdjacentRequest request) async {
    // Read already, by the browser or an earlier search: what was found stands without reading the file again, a quick
    // read of a video that found nothing included (the head of its moov box tells for nearly every file, see
    // NetworkMediaService.quickMoovLength), so that the files known flat cost nothing
    final known = _service.cached(item.entry);
    if (known != null || request.isCancelled) {
      return known;
    }
    try {
      // Through the media bridge, like the pages read their file
      return await _service
          .detect(item.entry, httpRangeReader(_client, item.url), thorough: true, isWanted: () => !request.isCancelled)
          .timeout(fileTimeout);
    } on TimeoutException {
      // Skipped: the read goes on, and what it finds is kept for the next search
      _log.info('${item.entry.name} took too long to read, skipped');
      return null;
    }
  }

  @override
  void onClosed(String url, ImmersiveStereoLayout stereoLayout, ImmersiveSphereCoverage coverage, int positionMs) {
    final index = _indexAt(url);
    if (index == null) {
      _log.info('The immersive viewer closed on a media this navigator did not show');
      return;
    }
    final player = _player;
    if (index == _start && _items[index].entry.isVideo && player != null && player.mounted) {
      // Paused: the user is back in the app, and the video waits for them where they left it
      unawaited(player.resumeAfterExternalPlayerAt(Duration(milliseconds: math.max(0, positionMs)), play: false));
    }
  }

  /// The index of the file shown at [url]: the current one, else the one before it or the one the viewer opened on,
  /// which it may report when it closed as Flutter moved on; null for none of them
  int? _indexAt(String url) {
    for (final index in [_index, ?_previous, _start]) {
      if (_urlOf(index) == url) {
        return index;
      }
    }
    return null;
  }

  // The URL the viewer was given for the file at [index]
  String _urlOf(int index) => index == _start ? _startRequest.url : _items[index].url.toString();
}

/// What the immersive viewer opens for [item], a file of a share whose file declares [info]: its layout and coverage
/// from what it declares and its name (see [NetworkMediaInfo.sphereView]), its frame size being unknown until a
/// player reads it
ImmersiveRequest folderImmersiveRequest(ImmersiveFolderItem item, NetworkMediaInfo info) => ImmersiveRequest(
  url: item.url.toString(),
  isVideo: item.entry.isVideo,
  title: item.entry.name,
  view: info.sphereView(item.entry.name),
);
