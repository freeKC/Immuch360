// "Play on..." of a photo or a video of the Immich library (release 52): the request of the asset the viewer shows
// (its id, the phone's account and the addresses of its server, never a session), the sheet, and the viewer followed
// while a screen or a Cast device shows one of its assets: a swipe to the next photo sends that one, 300 ms after
// the last swipe, so that three fast swipes send the last photo only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('PhonePlay');

/// The request of an asset of this phone's Immich server: null for an asset on this device only, or with no server
final playOnAssetRequestProvider = Provider<PlayOnRequest? Function(BaseAsset asset)>((ref) {
  return (asset) {
    final user = ref.read(currentUserProvider);
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    if (user == null || endpoint == null || endpoint.isEmpty) {
      return null;
    }
    final host = Uri.tryParse(endpoint)?.host;
    return PlayOnRequest.ofAsset(
      asset,
      userId: user.id,
      endpoints: ApiService.getServerUrls(),
      serverName: host == null || host.isEmpty ? endpoint : host,
    );
  };
});

/// Opens the "Play on..." sheet for [asset]; false when it has no request (on this device only)
Future<bool> showPlayOnSheetForAsset(BuildContext context, WidgetRef ref, BaseAsset asset) async {
  final request = ref.read(playOnAssetRequestProvider)(asset);
  if (request == null) {
    return false;
  }
  return showPlayOnSheet(context, request);
}

/// How long after the last swipe the viewer's asset is sent
const playOnFollowDelay = Duration(milliseconds: 300);

/// Follows the asset viewer while a screen or a Cast device shows one of its assets; watched by the dock, which lives
/// as long as the app
final playOnViewerFollowProvider = Provider<void>((ref) {
  Timer? timer;
  ref.onDispose(() => timer?.cancel());
  ref.listen(assetViewerProvider.select((state) => state.currentAsset), (previous, next) {
    final before = previous?.remoteId;
    if (next == null || before == null || next.remoteId == before) {
      return;
    }
    final remote = ref.read(remotePlaybackProvider);
    // The photo before is the one the screen shows, or one swiped past while the next was waiting to go
    final screenShows =
        remote != null && !remote.lost && !remote.ended && (remote.isOfAsset(before) || (timer?.isActive ?? false));
    if (!screenShows) {
      return;
    }
    timer?.cancel();
    timer = Timer(playOnFollowDelay, () {
      final request = ref.read(playOnAssetRequestProvider)(next);
      if (request == null) {
        // On this phone only: the screen keeps the one before
        return;
      }
      if (request.immich?.locked ?? false) {
        return;
      }
      _log.info('Play on: the viewer moved, the next item goes');
      unawaited(ref.read(remotePlaybackProvider.notifier).showNext(request));
    });
  });
});
