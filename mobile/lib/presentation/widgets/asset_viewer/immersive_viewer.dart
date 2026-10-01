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
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
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
/// device when there is one, like in the in-app player, else from its original on the server.
///
/// The headset shows each eye its own half of a 3D media, over the whole sphere or its front half (VR180): the
/// coverage the user picked for the asset, else the layout and the coverage the file declares for a video (see
/// [SphericalProbeService]), else guesses from the asset dimensions and name (see [resolveSphereView]), until the user
/// picks others with the controls of the viewer, labelled with [stereoLabels] (see [sphereViewerLabels]). Like the
/// phone viewer, a partial panorama stays mono whatever its aspect ratio, and covers what its GPano crop says: for a
/// photo that looks 3D, the GPano crop the server copies into the preview's XMP tells. The guess stands when that
/// request fails.
Future<void> openImmersiveViewer(WidgetRef ref, BaseAsset asset, {required Map<String, String> stereoLabels}) async {
  final remoteUrl = immersiveMediaUrl(asset);
  if (remoteUrl == null) {
    throw StateError('The asset is not on the server');
  }
  // Read before the first await: the viewer may be gone by then
  final api = ref.read(immersiveApiProvider);
  final storage = ref.read(storageRepositoryProvider);
  final coverageOverrides = ref.read(sphereCoverageOverridesProvider.notifier);
  final probeService = asset.isVideo ? ref.read(sphericalProbeServiceProvider) : null;
  final player = asset.isVideo ? ref.read(videoPlayerProvider(asset.id).notifier) : null;
  final localId = asset.isVideo ? asset.localId : null;
  SphereView view({Rect? gpanoCrop, SphericalProbe? probe}) => resolveSphereView(
    fileName: asset.name,
    width: asset.width,
    height: asset.height,
    gpanoCrop: gpanoCrop,
    probe: probe,
    chosenCoverage: coverageOverrides.get(asset),
  );
  // Only a photo that looks 3D needs its GPano crop
  final gpanoClient = !asset.isVideo && view().layout != StereoLayout.mono
      ? ref.read(immersiveGPanoClientProvider)
      : null;

  Rect? gpanoCrop;
  final remoteId = asset.remoteId;
  if (gpanoClient != null && remoteId != null) {
    final gpano = await fetchGPano(
      gpanoClient,
      Uri.parse(getThumbnailUrlForRemoteId(remoteId, type: AssetMediaSize.preview)),
    );
    gpanoCrop = gpano?.crop;
    if (gpanoCrop != null && isPartialSphere(gpanoCrop)) {
      _log.fine('${asset.name} is a partial panorama, shown mono');
    }
  }

  var url = remoteUrl;
  File? localFile;
  if (localId != null) {
    try {
      // The immersive player reads file:// URIs too
      localFile = await storage.getFileForAsset(localId);
      url = localFile?.uri.toString() ?? remoteUrl;
    } catch (error) {
      _log.warning('Copy on the device of ${asset.name} unreadable, playing the server original: $error');
    }
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
