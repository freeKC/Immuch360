// Spatial 2.5D (experimental, off by default): stereoscopic videos open in a native full screen player that turns the
// two eyes into depth and follows the head of the user with the front camera, on the device only. SpatialVideoActivity
// on Android, SpatialVideoViewController on iOS, never on a Meta Quest. The viewer's own player stays as it is, and
// takes the video back where the Spatial player left it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/setting.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spatial_video.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/setting.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart' show appConfigProvider;
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_file_path.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('SpatialViewer');

/// Plays [asset], a video, full screen in the Spatial 2.5D player, from where and as the viewer plays it.
///
/// The file is the one the viewer plays: the file a video opened with "Open with" came as, else the copy on the
/// phone when there is one, else the server's original when the settings ask for it, else its transcoded playback.
/// The stereo layout is the one the user picked for this asset last time, else a guess (see [guessSpatialLayout]);
/// a 360° video opens through a viewport, over the whole sphere or its front half (VR180): the coverage the user
/// picked for the asset, else the one the file declares or a guess (see [resolveSphereView]). The coverage picked in
/// the player is remembered for the asset.
///
/// When the device cannot run the player, a message says so and the viewer's player goes on untouched. Otherwise
/// that player is stopped meanwhile (see [VideoPlayerNotifier.suspendForExternalPlayer]), and takes the video back
/// where the Spatial player left it, see [SpatialVideoSession]. Any failure to open gives the viewer its video back
/// where and as it was.
Future<void> openSpatialVideo(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  // Read before the first await: the viewer may be gone by then
  final api = ref.read(spatialVideoApiProvider);
  final session = ref.read(spatialVideoSessionProvider);
  final overrides = ref.read(spatialLayoutOverridesProvider);
  final coverageOverrides = ref.read(sphereCoverageOverridesProvider.notifier);
  final probeService = ref.read(sphericalProbeServiceProvider);
  final storage = ref.read(storageRepositoryProvider);
  // A video opened with "Open with" that is not in the library plays from a temporary copy (see AssetPage)
  final viewIntentPath = ref.read(timelineServiceProvider).origin == TimelineOrigin.deepLink
      ? ref.read(viewIntentFilePathProvider)
      : null;
  final player = ref.read(videoPlayerProvider(asset.id).notifier);
  final playback = ref.read(videoPlayerProvider(asset.id));
  final loadOriginalVideo = ref.read(appConfigProvider).viewer.loadOriginalVideo;
  final debugOverlay = ref.read(settingsProvider.notifier).get(Setting.advancedTroubleshooting);
  final isEquirectangular = ref.read(isEquirectangularProvider(asset));
  final messenger = ScaffoldMessenger.maybeOf(context);
  final labels = spatialLabels(context.t);
  final unavailableMessage = context.t.spatial_unavailable;
  final errorMessage = context.t.spatial_open_failed;

  final layoutKey = spatialLayoutKey(asset);
  final wasPlaying = playback.status == VideoPlaybackStatus.playing || playback.status == VideoPlaybackStatus.buffering;

  final SpatialCapabilities capabilities;
  try {
    capabilities = await api.capabilities();
  } catch (error) {
    // No player on this platform
    _log.warning('Cannot ask whether the Spatial 2.5D player runs here: $error');
    messenger?.showSnackBar(SnackBar(content: Text(unavailableMessage)));
    return;
  }
  if (!capabilities.supported) {
    _log.info('The Spatial 2.5D player does not run here: ${capabilities.reason ?? 'no reason given'}');
    messenger?.showSnackBar(SnackBar(content: Text(unavailableMessage)));
    return;
  }

  final remoteId = asset.remoteId;
  final localId = asset.localId;
  // Whether this call stopped the viewer's player, and so has to give it back on a failure
  var suspended = false;

  try {
    final remoteUrl = remoteId == null
        ? null
        : '${Store.get(StoreKey.serverEndpoint)}/assets/$remoteId/${loadOriginalVideo ? 'original' : 'video/playback'}';
    File? localFile = viewIntentPath != null ? File(viewIntentPath) : null;
    String? url = localFile?.uri.toString() ?? remoteUrl;
    if (viewIntentPath == null && localId != null) {
      try {
        // The native player reads file:// URIs too, and ignores the headers for them
        localFile = await storage.getFileForAsset(localId);
        url = localFile?.uri.toString() ?? remoteUrl;
      } catch (error) {
        _log.warning('Copy on the device of ${asset.name} unreadable, playing the server copy: $error');
      }
    }
    if (url == null) {
      throw StateError('No file to play for ${asset.name}');
    }

    // Only a 360° video has a coverage that its file may declare. The coverage of a flat one only counts when the
    // user turns it into a 360° one in the player.
    final sphereView = resolveSphereView(
      fileName: asset.name,
      width: asset.width,
      height: asset.height,
      probe: isEquirectangular ? await probeService.probe(asset, localFile: localFile) : null,
      chosenCoverage: coverageOverrides.get(asset),
    );
    final projection = isEquirectangular ? sphereView.coverage.toSpatialProjection() : SpatialProjection.flat;
    final guess = guessSpatialLayout(
      width: asset.width,
      height: asset.height,
      fileName: asset.name,
      projection: projection,
    );
    final layout = overrides.get(layoutKey) ?? guess;

    session.start(
      asset: asset,
      layout: layout,
      guess: guess,
      coverage: sphereView.coverage,
      coverageGuess: sphereView.coverageGuess,
      player: player,
    );
    // Stopped before the viewer goes to the background: it neither plays nor buffers behind the Spatial player
    suspended = true;
    await player.suspendForExternalPlayer();
    await api.open(
      SpatialOpenRequest(
        url: url,
        headers: ApiService.getRequestHeaders(),
        title: asset.name,
        layout: layout,
        projection: projection,
        startPositionMs: playback.position.inMilliseconds,
        autoplay: wasPlaying,
        debugOverlay: debugOverlay,
        labels: labels,
      ),
    );
  } catch (error, stackTrace) {
    _log.severe('Cannot open the Spatial 2.5D player for ${asset.name}', error, stackTrace);
    session.cancel();
    // Nothing else would bring the viewer's player back. It comes back where and as it was, not stopped at its start.
    // Only when this call stopped it: a player that still plays would go back to that position.
    if (suspended) {
      await player.resumeAfterExternalPlayerAt(playback.position, play: wasPlaying);
    }
    messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
  }
}
