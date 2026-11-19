// Previous and next among the photos of the timeline for the flat screen of the immersive viewer of the Meta Quest
// (GitHub issue 19, point 1): from a photo opened on the big screen, in 3D (spatial, side by side, 3D by its name) or
// with an AI relief, the thumbstick and the panel go to the other photos of the album or of the timeline, which come
// at the size and the place the user set (the kept frame of the viewer). What each photo becomes is the rule of the
// top bar (see flat_screen_browse.dart); videos, 360° media, splats and scenes are passed over.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/quest_relief.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_photo_probe.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/apple_spatial/apple_spatial.service.dart';
import 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart';
import 'package:immich_mobile/domain/services/flat_screen_browse.dart';
import 'package:immich_mobile/domain/services/immersive_navigation.service.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/relief_button.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/scene_photo.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/splat/splat_photo.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('FlatScreenNavigator');

/// The request of the stereo quad for [choice], null for a photo left out
StereoPhotoRequest? stereoPhotoRequestOf(FlatScreenChoice choice) => switch (choice) {
  FlatScreenSkip() => null,
  FlatScreenHeic(:final pair) => StereoPhotoRequest.heic(pair),
  FlatScreenSbs(:final request) => StereoPhotoRequest.sbs(request),
  FlatScreenFlat3d(:final request) => StereoPhotoRequest.flat3d(request),
  FlatScreenRelief(:final request) => StereoPhotoRequest.relief(request),
  FlatScreenBigScreen() => const StereoPhotoRequest.bigScreen(),
};

/// An asset the flat screen shows: what it opened it with and its index in the timeline when last found there
typedef _ShownPhoto = ({BaseAsset asset, ImmersiveRequest request, int? index});

/// Previous and next among the photos of a timeline for the flat screen of the immersive viewer, opened from the asset
/// viewer on a photo of the stereo quad (see [flatScreenNavigatorFor]), with the contract of
/// [TimelineImmersiveNavigator]: the asset is found again by what it is around its last index, the timeline is looked
/// through a chunk at a time within immersiveTimelineSearchLimit and the deadline of the session, the buffer of the
/// asset viewer is loaded around its page again after each search, and the asset viewer shows the photo the viewer
/// showed last once it closes.
///
/// A chunk is first sorted out with what is at hand: the videos, the media the viewer shows as 360° (the user's
/// choice, a file on the device that declares it, [equirectangularRemoteIds] for what the server flags, a raw file of
/// a 360° camera) are left out. The photos left are then classified with [classify] (see [flatScreenRequestOf]),
/// nearest first, four at a time, and none past the first that shows.
class FlatScreenImmersiveNavigator implements ImmersiveNavigator {
  FlatScreenImmersiveNavigator({
    required this._resolver,
    required TimelineService timeline,
    required BaseAsset asset,
    required ImmersiveRequest request,
    required int? index,
    required this._classify,
    required this._forced,
    required this._localIds,
    required this._equirectangularRemoteIds,
    AssetViewerJump? jump,
  }) : _cursor = TimelineCursor(timeline, jump: jump),
       _start = (asset: asset, request: request, index: index),
       _current = (asset: asset, request: request, index: index);

  final ImmersiveAssetResolver _resolver;
  final TimelineCursor _cursor;
  final Future<FlatScreenChoice> Function(BaseAsset asset) _classify;
  final Set<String> _forced;
  final Set<String> _localIds;
  final Future<Set<String>> Function(Iterable<String> remoteIds) _equirectangularRemoteIds;
  final _ShownPhoto _start;
  _ShownPhoto _current;
  _ShownPhoto? _previous;
  // What the classification of the last chunk found, by asset, for the one the search picks
  final _choices = Map<BaseAsset, FlatScreenChoice>.identity();

  /// The photo the viewer shows, as far as this navigator knows
  BaseAsset get currentAsset => _current.asset;

  bool get _all360 => _cursor.timeline.origin == TimelineOrigin.panorama360;

  @override
  Future<bool> showAdjacent(ImmersiveAdjacentRequest request) async {
    try {
      return await _showAdjacent(request);
    } finally {
      _choices.clear();
      // Found or not, the search left the buffer of the timeline where it looked
      unawaited(_cursor.recenter());
    }
  }

  Future<bool> _showAdjacent(ImmersiveAdjacentRequest request) async {
    final shownIndex = await _cursor.locate(_current.asset, _current.index);
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
        length: _cursor.timeline.totalAssets,
        lookup: _cursor.lookup,
        isCapable: (assets) => _areCapable(assets, request),
        limit: budget,
        isCancelled: () => request.isCancelled,
      );
      if (found == null) {
        return false;
      }
      budget -= (found.index - from).abs();
      from = found.index;
      final choice = _choices[found.item];
      final stereo = choice == null ? null : stereoPhotoRequestOf(choice);
      if (stereo == null) {
        continue;
      }
      final ImmersiveRequest resolved;
      try {
        resolved = await _resolver.resolveStereoPhoto(found.item, stereo);
      } catch (error) {
        // A photo without a file to open, a copy on the device gone for example: the next one may do
        _log.warning('Skipping ${found.item.name} on the flat screen: $error');
        continue;
      }
      _log.info('${request.step > 0 ? 'Next' : 'Previous'} photo on the flat screen: ${found.item.name}, $choice');
      final shown = await request.show((requestId) => showImmersiveRequest(_resolver.api, requestId, resolved));
      if (shown) {
        // Only once the viewer said it shows it: what it reports on closing goes to the photo it shows
        _previous = _current;
        _current = (asset: found.item, request: resolved, index: found.index);
      }
      return shown;
    }
    return false;
  }

  Future<List<bool>> _areCapable(List<BaseAsset> assets, ImmersiveAdjacentRequest request) async {
    // What is at hand first: a 360° media keeps the sphere, a video its own screen
    bool isSphere(BaseAsset asset, Set<String> flagged) =>
        isImmersiveCandidate(
          asset,
          all360: _all360,
          forced: _forced,
          localIds: _localIds,
          equirectangularIds: flagged,
        ) ||
        _resolver.raw?.kindOf(asset) != null;
    final photos = [for (final asset in assets) asset.isImage && !isSphere(asset, const {})];
    final remoteIds = {
      for (var i = 0; i < assets.length; i++)
        if (photos[i]) ?assets[i].remoteId,
    };
    var flagged = const <String>{};
    if (remoteIds.isNotEmpty) {
      try {
        flagged = await _equirectangularRemoteIds(remoteIds);
      } catch (error, stackTrace) {
        _log.warning('Could not tell which assets the server flags as 360°', error, stackTrace);
      }
    }
    final candidates = [
      for (var i = 0; i < assets.length; i++)
        if (photos[i] && !isSphere(assets[i], flagged)) assets[i],
    ];
    final choices = await classifyNearestFirst(candidates, _classify, isCancelled: () => request.isCancelled);
    for (var i = 0; i < candidates.length; i++) {
      final choice = choices[i];
      if (choice != null) {
        _choices[candidates[i]] = choice;
        if (!choice.shows) {
          _log.fine('${candidates[i].name} passed over on the flat screen: $choice');
        }
      }
    }
    return [for (final asset in assets) _choices[asset]?.shows ?? false];
  }

  @override
  void onProgress(String url, int positionMs, int durationMs) {
    // Photos only: nothing plays
  }

  @override
  void onClosed(String url, ImmersiveStereoLayout stereoLayout, ImmersiveSphereCoverage coverage, int positionMs) {
    final shown = _shownAt(url);
    if (shown == null) {
      _log.info('The immersive viewer closed on a media this navigator did not show');
      unawaited(_cursor.recenter());
      return;
    }
    unawaited(_cursor.follow(shown.asset, shown.index));
  }

  /// The photo shown at [url]: the current one, else the one before it or the one the viewer opened on, which it may
  /// report when it closed as Flutter moved on; null for none of them
  _ShownPhoto? _shownAt(String url) {
    for (final shown in [_current, ?_previous, _start]) {
      if (shown.request.isShownAt(url)) {
        return shown;
      }
    }
    return null;
  }
}

/// What [flatScreenRequestOf] reads, through the services of the app and the settings now: [read] gives the
/// providers of the asset viewer the immersive viewer was opened from, captured at the opening (never a WidgetRef: the
/// navigator outlives the widget). The settings are read at each photo, so that a strength chosen in the viewer
/// applies to the next one; once those providers are gone, the settings read at the opening stand.
class ProviderFlatScreenFacts implements FlatScreenBrowseFacts {
  ProviderFlatScreenFacts(this._read)
    : _appleSpatial = _read(appleSpatialServiceProvider),
      _flatStereo = _read(flatStereoServiceProvider),
      _scenes = _read(scenePhotoServiceProvider),
      _splats = _read(splatPhotoServiceProvider),
      _storage = _read(storageRepositoryProvider),
      _components = _read(aiComponentsServiceProvider),
      _reliefComponents = _read(reliefComponentsProvider),
      _settings = _read(appConfigProvider),
      _gate = _read(reliefGateProvider);

  final ProviderReader _read;
  final AppleSpatialService _appleSpatial;
  final FlatStereoService _flatStereo;
  final ScenePhotoService _scenes;
  final SplatPhotoService _splats;
  final StorageRepository _storage;
  final AiComponentsService _components;
  final List<AiComponent> _reliefComponents;
  AppConfig _settings;
  ReliefGate _gate;

  T _now<T>(ProviderListenable<T> provider, T last) {
    try {
      return _read(provider);
    } catch (error) {
      // The asset viewer closed meanwhile: what was read last stands
      return last;
    }
  }

  @override
  Future<HeicStereoPair?> spatialPair(BaseAsset asset) async => (await _appleSpatial.detect(asset))?.photo;

  @override
  Future<FlatStereoPhoto?> sideBySide(BaseAsset asset) => _flatStereo.detect(asset);

  @override
  Future<bool> carriesScene(BaseAsset asset) async => await _scenes.detect(asset) != null;

  @override
  Future<bool> isSplat(BaseAsset asset) async {
    _settings = _now(appConfigProvider, _settings);
    if (!_settings.viewer.gaussianSplats) {
      return false;
    }
    return await _splats.detect(asset) is SplatPhotoFound;
  }

  @override
  bool get flat3dByName {
    _settings = _now(appConfigProvider, _settings);
    return _settings.viewer.flat3dByName;
  }

  @override
  Future<DepthReliefRequest?> relief(BaseAsset asset) async {
    _settings = _now(appConfigProvider, _settings);
    _gate = _now(reliefGateProvider, _gate);
    if (!_gate.visible || _gate.refusal != null) {
      return null;
    }
    final model = _reliefComponents.firstWhere((component) => component.kind == AiComponentKind.model);
    final file = await _components.verifiedFile(model);
    if (file == null) {
      return null;
    }
    final quarterTurns = await reliefQuarterTurnsWith(_read, asset);
    final identity = await reliefIdentityOfAsset(
      asset,
      file: () async {
        final localId = asset.localId;
        return localId == null ? null : _storage.getFileForAsset(localId);
      },
    );
    return questReliefRequest(
      modelPath: file.path,
      model: model,
      identity: identity,
      quarterTurns: quarterTurns,
      mode: _settings.aiImmersive.questMode,
      strength: _settings.aiImmersive.questStrength,
    );
  }
}

/// The navigator of a photo opened on the stereo quad as [stereo] from the asset viewer whose providers [read] gives,
/// for [openStereoPhotoViewer]; null for a photo that has no list around it (a 3D scene, a splat), and when the
/// providers cannot give one, the photo then opening on its own as before. Reads the providers now, before the first
/// await of the opener.
StereoPhotoNavigatorBuilder? flatScreenNavigatorFor(ProviderReader read, BaseAsset asset, StereoPhotoRequest stereo) {
  if (stereo is VolumetricSceneStereoPhotoRequest || stereo is GaussianSplatStereoPhotoRequest) {
    return null;
  }
  try {
    final timeline = read(timelineServiceProvider);
    // The asset viewer of this route, which follows the immersive viewer once it closes
    final jump = read(assetViewerJumpProvider);
    final forced = read(forcedPanoramaAssetsProvider);
    final localIds = read(localPanoramaIdsProvider);
    final remoteAssets = read(driftProvider).remoteAssetRepository;
    final index = timeline.getIndex(asset.heroTag) ?? jump.currentIndex;
    final facts = ProviderFlatScreenFacts(read);
    final relief = stereo is DepthReliefStereoPhotoRequest;
    return (resolver, request) => FlatScreenImmersiveNavigator(
      resolver: resolver,
      timeline: timeline,
      asset: asset,
      request: request,
      index: index,
      classify: (photo) => flatScreenRequestOf(photo, facts, relief: relief),
      forced: forced,
      localIds: localIds,
      equirectangularRemoteIds: remoteAssets.equirectangularRemoteIds,
      jump: jump,
    );
  } catch (error, stackTrace) {
    _log.warning('No previous or next for ${asset.name} on the flat screen', error, stackTrace);
    return null;
  }
}
