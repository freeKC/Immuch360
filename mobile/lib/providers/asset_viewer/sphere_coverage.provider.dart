import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/player_events_hub.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('SphereCoverage');

/// The coverage of the sphere the user picked for the asset, see [SphereCoverageOverrides]; null when the user never
/// picked one
final sphereCoverageOverrideProvider = Provider.autoDispose.family<SphereCoverage?, BaseAsset>(
  (ref, asset) => ref.watch(sphereCoverageOverridesProvider.select((coverages) => _find(coverages, asset))),
);

// The asset is found under its id on the device too, so that a choice made before the upload holds after it
SphereCoverage? _find(Map<String, SphereCoverage> coverages, BaseAsset asset) {
  final localId = asset.localId;
  return coverages[spatialLayoutKey(asset)] ?? (localId == null ? null : coverages[localId]);
}

/// The coverages of the sphere the user picked in the 360° viewers, per asset, kept in the Store of the device only.
/// A remembered coverage wins over the guess (see [guessSphereCoverage]).
///
/// The state maps the keys of those assets, the same as for the stereo layouts (see [spatialLayoutKey]), to their
/// coverage, the latest choice last.
class SphereCoverageOverrides extends Notifier<Map<String, SphereCoverage>> {
  SphereCoverageOverrides({this.maxEntries = 1000});

  /// Past this many assets, the coverages picked first are forgotten
  final int maxEntries;

  @override
  Map<String, SphereCoverage> build() {
    try {
      return decodeSphereCoverages(ref.watch(storeServiceProvider).tryGet(StoreKey.sphereCoverageOverrides));
    } on UnsupportedError catch (error) {
      // The store is not initialised: nothing was picked yet
      _log.fine('No store for the coverages of the sphere: $error');
      return {};
    }
  }

  /// The coverage picked for [asset], or null when the user never picked one
  SphereCoverage? get(BaseAsset asset) => _find(state, asset);

  /// Remembers [coverage] for [asset]
  Future<void> set(BaseAsset asset, SphereCoverage coverage) async {
    final key = spatialLayoutKey(asset);
    // Removed first, so that the asset moves to the end, as the most recent choice
    final coverages = {...state}
      ..remove(key)
      ..remove(asset.localId);
    coverages[key] = coverage;
    while (coverages.length > maxEntries) {
      coverages.remove(coverages.keys.first);
    }
    await _save(coverages);
  }

  /// Forgets the coverage picked for [asset]: the guess applies again
  Future<void> clear(BaseAsset asset) async {
    if (get(asset) == null) {
      return;
    }
    await _save(
      {...state}
        ..remove(spatialLayoutKey(asset))
        ..remove(asset.localId),
    );
  }

  /// Remembers [coverage], which a viewer shows [asset] with after it opened with [opened]. Only a coverage the user
  /// changed is remembered: going back to [guess] forgets the previous choice, so that a better guess applies later.
  Future<void> remember(
    BaseAsset asset,
    SphereCoverage coverage, {
    required SphereCoverage opened,
    required SphereCoverage guess,
  }) async {
    if (coverage == opened) {
      return;
    }
    if (coverage == guess) {
      await clear(asset);
    } else {
      await set(asset, coverage);
    }
  }

  Future<void> _save(Map<String, SphereCoverage> coverages) async {
    final store = ref.read(storeServiceProvider);
    state = coverages;
    try {
      await store.put(StoreKey.sphereCoverageOverrides, encodeSphereCoverages(coverages));
    } catch (error, stackTrace) {
      // The choice still holds until the app restarts
      _log.warning('Could not remember the coverage of the sphere', error, stackTrace);
    }
  }
}

final sphereCoverageOverridesProvider = NotifierProvider<SphereCoverageOverrides, Map<String, SphereCoverage>>(
  SphereCoverageOverrides.new,
);

typedef _SphericalPlayback = ({BaseAsset asset, SphereCoverage coverage, SphereCoverage coverageGuess});

/// Follows the native 360° player from its opening to its closing, to remember the coverage of the sphere the user
/// picked there (see [SphereCoverageOverrides.remember]).
///
/// The native player calls [closed] on the [SphericalVideoEvents] Flutter API, without saying which asset it played:
/// [start] tells, right before the player opens. One player at most is open at a time, full screen. The stereo
/// layout it reports is not remembered: the player prefers the layout the file declares, and the guess comes again.
class SphericalVideoSession implements SphericalVideoEvents {
  SphericalVideoSession(this._overrides);

  final SphereCoverageOverrides _overrides;
  _SphericalPlayback? _playback;

  /// Whether a player is open, as far as this session knows
  bool get isOpen => _playback != null;

  /// The player opens on [asset] with [coverage], the remembered one or else [coverageGuess] (see
  /// [resolveSphereView])
  void start({required BaseAsset asset, required SphereCoverage coverage, required SphereCoverage coverageGuess}) {
    _playback = (asset: asset, coverage: coverage, coverageGuess: coverageGuess);
  }

  /// The player could not open: nothing will close
  void cancel() => _playback = null;

  @override
  void closed(StereoLayout stereoLayout, SphereCoverage coverage) {
    final playback = _playback;
    _playback = null;
    if (playback == null) {
      _log.warning('The 360° player closed, but no playback was started');
      return;
    }
    unawaited(_remember(playback, coverage));
  }

  Future<void> _remember(_SphericalPlayback playback, SphereCoverage coverage) async {
    try {
      await _overrides.remember(playback.asset, coverage, opened: playback.coverage, guess: playback.coverageGuess);
    } catch (error, stackTrace) {
      _log.warning('Could not remember the coverage $coverage', error, stackTrace);
    }
  }
}

/// The session of the native 360° player. Reading it the first time registers it as the [SphericalVideoEvents]
/// handler, which openPanoramaVideo does before it opens the player.
final sphericalVideoSessionProvider = Provider<SphericalVideoSession>((ref) {
  final session = SphericalVideoSession(ref.read(sphereCoverageOverridesProvider.notifier));
  // Through the hub, which the 360° player of the computers calls when it closes
  PlayerEventsHub.setUpSpherical(session);
  ref.onDispose(() {
    PlayerEventsHub.setUpSpherical(null);
    session.cancel();
  });
  return session;
});
