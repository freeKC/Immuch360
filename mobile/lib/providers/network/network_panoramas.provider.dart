// The 360° photos and videos of the network shares, for the 360° list (see NetworkPanoramaFile): recorded as the app
// reads the files of the shares, kept in the Store across starts, forgotten with their share.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_panorama_file.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkPanoramas');

class NetworkPanoramasNotifier extends Notifier<List<NetworkPanoramaFile>> {
  @override
  List<NetworkPanoramaFile> build() {
    // A share removed takes its files along, here and in the Store
    ref.listen(networkSourcesProvider, (_, sources) => _keepSourcesOf(sources));
    final StoreService store;
    try {
      store = ref.watch(storeServiceProvider);
    } on UnsupportedError catch (error) {
      // The store is not initialised: nothing was recorded
      _log.fine('No store for the 360° files of the shares: $error');
      return const [];
    }
    final stored = NetworkPanoramaFile.decodeList(store.tryGet(StoreKey.networkPanoramaFiles));
    final ids = {for (final source in ref.read(networkSourcesProvider)) source.id};
    final kept = stored.where((file) => ids.contains(file.sourceId)).toList();
    if (kept.length != stored.length) {
      // Removed while nothing watched this list
      unawaited(_save(store, kept));
    }
    return List.unmodifiable(kept);
  }

  /// [entry] of a share was read and found to be 360° or not: the list follows (see [withNetworkPanorama]), and the
  /// Store when it changed
  void record(NetworkEntry entry, {required bool is360}) {
    final next = withNetworkPanorama(state, entry, is360: is360);
    if (identical(next, state)) {
      return;
    }
    state = next;
    unawaited(_saveState());
  }

  void _keepSourcesOf(List<NetworkSource> sources) {
    final ids = {for (final source in sources) source.id};
    if (state.every((file) => ids.contains(file.sourceId))) {
      return;
    }
    state = List.unmodifiable(state.where((file) => ids.contains(file.sourceId)));
    unawaited(_saveState());
  }

  Future<void> _saveState() async {
    final StoreService store;
    try {
      store = ref.read(storeServiceProvider);
    } on UnsupportedError {
      return;
    }
    await _save(store, state);
  }

  Future<void> _save(StoreService store, List<NetworkPanoramaFile> files) async {
    try {
      if (files.isEmpty) {
        await store.delete(StoreKey.networkPanoramaFiles);
      } else {
        await store.put(StoreKey.networkPanoramaFiles, NetworkPanoramaFile.encodeList(files));
      }
    } catch (error, stackTrace) {
      _log.warning('Could not keep the 360° files of the shares', error, stackTrace);
    }
  }
}

final networkPanoramasProvider = NotifierProvider<NetworkPanoramasNotifier, List<NetworkPanoramaFile>>(
  NetworkPanoramasNotifier.new,
);

/// The 360° files of the shares that the filters of the 360° page let through, newest first. The filters of the
/// period and of photos or videos apply (the period to the date of the file); 3D, VR180 and the cameras are not known
/// for a file of a share, so none shows while one of those is picked. Where the media are (server, device, shared)
/// concerns the other entries of the page.
final panorama360ShareFilesProvider = Provider.autoDispose<List<NetworkPanoramaFile>>((ref) {
  final filter = ref.watch(panorama360FilterProvider);
  if (filter.traits.isNotEmpty || filter.cameras.isNotEmpty) {
    return const [];
  }
  bool kindMatches(NetworkPanoramaFile file) =>
      filter.kinds.isEmpty || filter.kinds.contains(file.isVideo ? Panorama360Kind.video : Panorama360Kind.photo);
  bool periodMatches(NetworkPanoramaFile file) {
    final period = filter.period;
    final modified = file.modified?.toLocal();
    if (period == null) {
      return true;
    }
    return modified != null && period.contains(DateTime(modified.year, modified.month, modified.day));
  }

  return newestNetworkPanoramasFirst([
    for (final file in ref.watch(networkPanoramasProvider))
      if (kindMatches(file) && periodMatches(file)) file,
  ]);
});

/// The media bridge URL of a file of a share, which opens its share on first use; an error when the share cannot be
/// reached
final networkFileUrlProvider = FutureProvider.autoDispose.family<Uri, ({String sourceId, String path})>(
  (ref, file) => ref.read(networkConnectionsProvider).mediaUrl(file.sourceId, file.path),
);
