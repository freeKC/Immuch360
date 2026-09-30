// Meta Quest (Horizon OS): 360 photos and videos open in a native immersive activity with head
// tracking (ImmersiveViewerActivity, Meta Spatial SDK). Phones keep the in-app panorama viewer.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:logging/logging.dart';

final _log = Logger('ImmersiveViewer');

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
Future<void> openImmersiveViewer(WidgetRef ref, BaseAsset asset) async {
  final remoteUrl = immersiveMediaUrl(asset);
  if (remoteUrl == null) {
    throw StateError('The asset is not on the server');
  }
  // Read before the first await: the viewer may be gone by then
  final api = ref.read(immersiveApiProvider);
  final storage = ref.read(storageRepositoryProvider);
  final player = asset.isVideo ? ref.read(videoPlayerProvider(asset.id).notifier) : null;
  final localId = asset.isVideo ? asset.localId : null;

  var url = remoteUrl;
  if (localId != null) {
    try {
      // The immersive player reads file:// URIs too
      final localFile = await storage.getFileForAsset(localId);
      url = localFile?.uri.toString() ?? remoteUrl;
    } catch (error) {
      _log.warning('Copy on the device of ${asset.name} unreadable, playing the server original: $error');
    }
  }

  // Stopped before the panel goes to the background: it neither plays nor buffers behind the immersive
  // view. The viewer lifts this when the app resumes.
  await player?.suspendForExternalPlayer();
  try {
    await api.open(url, ApiService.getRequestHeaders(), asset.isVideo, asset.name);
  } catch (_) {
    // Nothing else would bring the viewer's player back
    await player?.resumeAfterExternalPlayer();
    rethrow;
  }
}
