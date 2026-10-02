// Meta Quest (Horizon OS): 360 photos and videos open in a native immersive activity with head
// tracking (ImmersiveViewerActivity, Meta Spatial SDK). Phones keep the in-app panorama viewer.

import 'dart:io';
import 'dart:ui';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
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

/// Stops the in-app video player, then opens the asset in the immersive viewer. A video plays from the copy on the
/// device when there is one, like in the in-app player, else from its original on the server. A photo opens from its
/// original on the server, and an asset only on the device (no server, or not uploaded) from its file there, photo or
/// video alike. A media opened with "Open with" that is not in the library opens from its temporary copy. Throws when
/// there is no file to open.
///
/// The headset shows each eye its own half of a 3D media, over the whole sphere or its front half (VR180): the
/// coverage the user picked for the asset, else the layout and the coverage the file declares for a video (see
/// [SphericalProbeService]), else guesses from the asset dimensions and name (see [resolveSphereView]), until the user
/// picks others with the controls of the viewer, labelled with [stereoLabels] (see [sphereViewerLabels]). Like the
/// phone viewer, a partial panorama stays mono whatever its aspect ratio, and covers what its GPano crop says: for a
/// photo that looks 3D, the GPano crop the server copies into the preview's XMP tells, or for a photo only on the
/// device the one in its file. The guess stands when that read fails.
Future<void> openImmersiveViewer(WidgetRef ref, BaseAsset asset, {required Map<String, String> stereoLabels}) async {
  final remoteUrl = immersiveMediaUrl(asset);
  // Read before the first await: the viewer may be gone by then
  final api = ref.read(immersiveApiProvider);
  final storage = ref.read(storageRepositoryProvider);
  final coverageOverrides = ref.read(sphereCoverageOverridesProvider.notifier);
  final probeService = asset.isVideo ? ref.read(sphericalProbeServiceProvider) : null;
  final player = asset.isVideo ? ref.read(videoPlayerProvider(asset.id).notifier) : null;
  // Opened with "Open with" and not in the library: its temporary copy (see AssetPage)
  final viewIntentPath = ref.read(timelineServiceProvider).origin == TimelineOrigin.deepLink
      ? ref.read(viewIntentFilePathProvider)
      : null;
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
  final gpanoClient = needsGPanoCrop && remoteUrl != null ? ref.read(immersiveGPanoClientProvider) : null;

  var localFile = viewIntentPath == null ? null : File(viewIntentPath);
  if (localFile == null && localId != null) {
    try {
      localFile = await storage.getFileForAsset(localId);
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
  if (gpanoClient != null && remoteId != null) {
    final gpano = await fetchGPano(
      gpanoClient,
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
  final sphereView = view(
    gpanoCrop: gpanoCrop,
    probe: await probeService?.probe(asset, localFile: localFile),
  );

  // Stopped before the panel goes to the background: it neither plays nor buffers behind the immersive
  // view. The viewer lifts this when the app resumes.
  await player?.suspendForExternalPlayer();
  try {
    await api.open(
      url,
      ApiService.getRequestHeaders(),
      asset.isVideo,
      asset.name,
      sphereView.layout.toImmersive(),
      stereoLabels,
      sphereView.coverage.toImmersive(),
    );
  } catch (_) {
    // Nothing else would bring the viewer's player back
    await player?.resumeAfterExternalPlayer();
    rethrow;
  }
}

/// Opens the photo or video at [url] in the immersive viewer, like [openImmersiveViewer] for a media that is no asset:
/// a file of a network share, streamed through the local media bridge for example. [title] names it, [layout] and
/// [coverage] are what the viewer opens with (see [resolveSphereView]), and [stereoLabels] label its controls (see
/// [sphereViewerLabels]); the user can change them there, and nothing is remembered.
///
/// Meanwhile [player], the page's own player for a video, is stopped (see
/// [VideoPlayerNotifier.suspendForExternalPlayer]): the page lifts this when the app resumes. A failure to open gives
/// it back right away, and is rethrown.
Future<void> openImmersiveUrl(
  WidgetRef ref, {
  required String url,
  Map<String, String> headers = const {},
  required bool isVideo,
  required String title,
  required StereoLayout layout,
  required SphereCoverage coverage,
  required Map<String, String> stereoLabels,
  VideoPlayerNotifier? player,
}) async {
  // Read before the first await: the page may be gone by then
  final api = ref.read(immersiveApiProvider);
  await player?.suspendForExternalPlayer();
  try {
    await api.open(url, headers, isVideo, title, layout.toImmersive(), stereoLabels, coverage.toImmersive());
  } catch (_) {
    await player?.resumeAfterExternalPlayer();
    rethrow;
  }
}
