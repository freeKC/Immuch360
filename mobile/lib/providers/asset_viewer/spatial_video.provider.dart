import 'dart:async';
import 'dart:math' as math;

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('SpatialVideo');

/// The stereo layouts the user picked in the Spatial 2.5D player, per asset (see [spatialLayoutKey]), kept in the
/// Store of the device only. A remembered layout wins over the guess (see [guessSpatialLayout]), Auto included.
class SpatialLayoutOverrides {
  const SpatialLayoutOverrides(this._store, {this.maxEntries = 1000});

  final StoreService _store;

  /// Past this many assets, the layouts picked first are forgotten
  final int maxEntries;

  Map<String, SpatialStereoLayout> _read() => decodeSpatialLayouts(_store.tryGet(StoreKey.spatialLayoutOverrides));

  /// The layout picked for the asset of [key], or null when the user never picked one
  SpatialStereoLayout? get(String key) => _read()[key];

  /// Remembers [layout] for the asset of [key]
  Future<void> set(String key, SpatialStereoLayout layout) async {
    // Removed first, so that the asset moves to the end, as the most recent choice
    final layouts = _read()..remove(key);
    layouts[key] = layout;
    while (layouts.length > maxEntries) {
      layouts.remove(layouts.keys.first);
    }
    await _store.put(StoreKey.spatialLayoutOverrides, encodeSpatialLayouts(layouts));
  }

  /// Forgets the layout picked for the asset of [key]: the guess applies again
  Future<void> remove(String key) async {
    final layouts = _read();
    if (layouts.remove(key) == null) {
      return;
    }
    await _store.put(StoreKey.spatialLayoutOverrides, encodeSpatialLayouts(layouts));
  }
}

final spatialLayoutOverridesProvider = Provider<SpatialLayoutOverrides>(
  (ref) => SpatialLayoutOverrides(ref.watch(storeServiceProvider)),
);

typedef _SpatialPlayback = ({
  BaseAsset asset,
  SpatialStereoLayout layout,
  SpatialStereoLayout guess,
  SphereCoverage coverage,
  SphereCoverage coverageGuess,
  VideoPlayerNotifier player,
});

/// Follows the Spatial 2.5D player from its opening to its closing, and then gives the asset viewer its video back
/// where the player left it.
///
/// The native player calls [closed] on the [SpatialVideoEvents] Flutter API, without saying which asset it played:
/// [start] tells, right before the player opens. One player at most is open at a time, full screen.
class SpatialVideoSession implements SpatialVideoEvents {
  SpatialVideoSession(this._overrides, this._coverageOverrides);

  final SpatialLayoutOverrides _overrides;
  final SphereCoverageOverrides _coverageOverrides;
  _SpatialPlayback? _playback;

  /// Whether a player is open, as far as this session knows
  bool get isOpen => _playback != null;

  /// The player opens on [asset] with [layout], the remembered one or else [guess] (see [guessSpatialLayout]), and
  /// with [coverage] of the sphere, the remembered one or else [coverageGuess] (see [resolveSphereView]), while
  /// [player], the viewer's player, waits suspended (see [VideoPlayerNotifier.suspendForExternalPlayer]).
  void start({
    required BaseAsset asset,
    required SpatialStereoLayout layout,
    required SpatialStereoLayout guess,
    required SphereCoverage coverage,
    required SphereCoverage coverageGuess,
    required VideoPlayerNotifier player,
  }) {
    _playback = (
      asset: asset,
      layout: layout,
      guess: guess,
      coverage: coverage,
      coverageGuess: coverageGuess,
      player: player,
    );
  }

  /// The player could not open: nothing will close
  void cancel() => _playback = null;

  @override
  void closed(int positionMs, bool wasPlaying, SpatialStereoLayout layout, SpatialProjection projection) {
    final playback = _playback;
    _playback = null;
    if (playback == null) {
      _log.warning('The Spatial 2.5D player closed, but no playback was started');
      return;
    }
    unawaited(_close(playback, Duration(milliseconds: math.max(0, positionMs)), wasPlaying, layout, projection));
  }

  Future<void> _close(
    _SpatialPlayback playback,
    Duration position,
    bool wasPlaying,
    SpatialStereoLayout layout,
    SpatialProjection projection,
  ) async {
    // The viewer may be gone, if the user left it some other way than through the player
    if (playback.player.mounted) {
      await playback.player.resumeAfterExternalPlayerAt(position, play: wasPlaying);
    }

    // A flat projection says nothing of the coverage of the sphere. Like the layout, only a coverage the user changed
    // is remembered, see SphereCoverageOverrides.remember.
    final coverage = sphereCoverageOfSpatialProjection(projection);
    if (coverage != null) {
      try {
        await _coverageOverrides.remember(
          playback.asset,
          coverage,
          opened: playback.coverage,
          guess: playback.coverageGuess,
        );
      } catch (error, stackTrace) {
        _log.warning('Could not remember the coverage $coverage', error, stackTrace);
      }
    }

    // Only a layout the user changed is remembered. Going back to the guess forgets the previous choice; any other
    // layout is stored, Auto included, so that it beats a wrong guess next time.
    if (layout == playback.layout) {
      return;
    }
    final layoutKey = spatialLayoutKey(playback.asset);
    try {
      if (layout == playback.guess) {
        await _overrides.remove(layoutKey);
      } else {
        await _overrides.set(layoutKey, layout);
      }
    } catch (error, stackTrace) {
      _log.warning('Could not remember the stereo layout $layout', error, stackTrace);
    }
  }
}

/// The session of the Spatial 2.5D player. Reading it the first time registers it as the [SpatialVideoEvents]
/// handler, which openSpatialVideo does before it opens the player.
final spatialVideoSessionProvider = Provider<SpatialVideoSession>((ref) {
  final session = SpatialVideoSession(
    ref.read(spatialLayoutOverridesProvider),
    ref.read(sphereCoverageOverridesProvider.notifier),
  );
  SpatialVideoEvents.setUp(session);
  ref.onDispose(() {
    SpatialVideoEvents.setUp(null);
    session.cancel();
  });
  return session;
});
