// The sources of the originals a computer reads from elsewhere, as the app makes them: the original of a photo or a
// video of the Immich server, asked with the session of the app (a Range request for the download of a 3D video, which
// goes on where it stopped), and the file of a share through the media bridge. The conversion dialog makes them for a
// selection; the queue makes them again at the next start from what video_jobs.json kept of a 3D video whose original
// was being downloaded (ConversionTools.remoteVideoSource).

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/original_bytes.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/services/api.service.dart';

/// The original of the asset [remoteId] of the server at [endpoint], read with the session of the app
ServerOriginalSource desktopServerOriginalSource({
  required String name,
  required String remoteId,
  required String endpoint,
  ImmersiveExif exif = const ImmersiveExif(),
}) => ServerOriginalSource(
  name: name,
  remoteId: remoteId,
  endpoint: endpoint,
  exif: exif,
  fetch: (url) =>
      NetworkRepository.client.send(http.Request('GET', url)..headers.addAll(ApiService.getRequestHeaders())),
  fetchRange: (url, {offset = 0, abort}) => NetworkRepository.client.send(
    http.AbortableRequest('GET', url, abortTrigger: abort)
      ..headers.addAll(ApiService.getRequestHeaders())
      ..headers.addAll(rangeHeadersFrom(offset)),
  ),
);

/// The file of a share at [entry] through the media bridge of [connections] and [client]
ShareFileSource desktopShareFileSource(NetworkConnections connections, http.Client client, NetworkEntry entry) =>
    ShareFileSource(
      entry: entry,
      url: () => connections.mediaUrl(entry.sourceId, entry.path),
      // Aborted by a cancel, even while the share sends nothing
      fetch: (url, {abort}) => client.send(http.AbortableRequest('GET', url, abortTrigger: abort)),
      fetchRange: (url, {offset = 0, abort}) =>
          client.send(http.AbortableRequest('GET', url, abortTrigger: abort)..headers.addAll(rangeHeadersFrom(offset))),
    );

/// The source a descriptor kept in video_jobs.json names, made again: the original of the server the app is signed in
/// to now (null for another server or none), or the file of a share; null for anything else
DownloadableOriginal? desktopRemoteVideoSource(Ref ref, Map<String, Object?> descriptor) {
  final name = descriptor['name'];
  switch (descriptor['kind']) {
    case serverOriginalKind:
      final remoteId = descriptor['remoteId'];
      final endpoint = descriptor['endpoint'];
      if (name is! String || remoteId is! String || endpoint is! String) {
        return null;
      }
      // The session of the app is that of the server signed in to now: another server would refuse it
      if (Store.tryGet(StoreKey.serverEndpoint) != endpoint) {
        return null;
      }
      return desktopServerOriginalSource(name: name, remoteId: remoteId, endpoint: endpoint);
    case shareOriginalKind:
      final entry = shareEntryOfDescriptor(descriptor);
      if (entry == null) {
        return null;
      }
      return desktopShareFileSource(ref.read(networkConnectionsProvider), ref.read(networkBridgeClientProvider), entry);
  }
  return null;
}
