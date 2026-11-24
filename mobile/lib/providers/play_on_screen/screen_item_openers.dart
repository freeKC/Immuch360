// What a big screen opens for a play of each kind besides a Plex film (release 52): an Immich photo or video in the
// asset viewer, a file of a share in the network photo or video page, a Jellyfin or Emby item in the network video
// page. Each with the screen's own access to the source, never one that came with the play.
//
// Immich: the screen asks its own server, with its own session, for the asset the phone named. Its server decides
// what its account may see (the owner, a partner, a shared album). The phone's user id and server addresses only
// choose the sentence of a refusal: the same user is the same server for sure; another user at an address the phone
// uses too is another account; else another server. A locked asset never opens on a screen (its session has no PIN
// elevation, and the deep link code refuses one too); a hidden one (the motion part of a live photo) neither.
//
// Shares and media servers: the screen's source of the same identity (the DLNA UDN or Jellyfin/Emby server id the
// discovery gives, else "host[:port]/share" of a share typed by hand).

import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/asset_extensions.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' show ApiException;

final _log = Logger('ScreenPlayer');

/// What the screen found for an Immich play: the asset to open, or why not
typedef ScreenImmichResolution = ({RemoteAsset? asset, ScreenPlayReason? reason});

/// The screen's access to its own Immich server and asset viewer, replaced by a fake in the tests
abstract interface class ScreenImmichAccess {
  /// The asset [target] names, as the screen's account sees it
  Future<ScreenImmichResolution> resolve(ImmichPlayTarget target);

  /// The asset viewer on [asset] alone (as the deep link of an asset opens it)
  PageRouteInfo routeOf(RemoteAsset asset);

  /// Whether the asset viewer shows the asset [assetId] now
  bool showing(String assetId);
}

/// The reason a refusal of the screen's server gives, from who the phone is and where its server is
ScreenPlayReason immichRefusalReason({
  required String? screenUser,
  required List<String> screenEndpoints,
  required ImmichPlayTarget target,
}) {
  if (screenUser != null && screenUser.toLowerCase() == target.user) {
    // The same account: the same server, which no longer has the asset
    return ScreenPlayReason.notFound;
  }
  final own = {for (final endpoint in screenEndpoints) ?normaliseImmichEndpoint(endpoint)};
  if (target.endpoints.any(own.contains)) {
    return ScreenPlayReason.otherAccount;
  }
  return ScreenPlayReason.otherServer;
}

/// Why an asset the screen's account reached may still not open on a screen
ScreenPlayReason? immichScreenRefusal(RemoteAsset asset) => switch (asset.visibility) {
  AssetVisibility.locked => ScreenPlayReason.locked,
  AssetVisibility.hidden => ScreenPlayReason.notVisible,
  AssetVisibility.timeline || AssetVisibility.archive => null,
};

class AppScreenImmichAccess implements ScreenImmichAccess {
  AppScreenImmichAccess(this._ref);

  final Ref _ref;

  @override
  Future<ScreenImmichResolution> resolve(ImmichPlayTarget target) async {
    final user = _ref.read(currentUserProvider);
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    if (user == null || endpoint == null || endpoint.isEmpty) {
      return (asset: null, reason: ScreenPlayReason.notSignedIn);
    }
    RemoteAsset? asset;
    try {
      asset = await _ref.read(assetServiceProvider).getRemoteAsset(target.asset);
    } catch (error) {
      _log.fine('Play from a phone: the local database did not answer (${error.runtimeType})');
    }
    if (asset == null) {
      try {
        final dto = await _ref.read(apiServiceProvider).assetsApi.getAssetInfo(target.asset);
        asset = dto?.toDto();
      } on ApiException catch (error) {
        final inner = error.innerException;
        if (inner is SocketException || inner is IOException) {
          return (asset: null, reason: ScreenPlayReason.unreachable);
        }
        if (error.code == 400 || error.code == 401 || error.code == 403 || error.code == 404) {
          _log.info('Play from a phone: the server refused the asset (${error.code})');
          return (
            asset: null,
            reason: immichRefusalReason(
              screenUser: user.id,
              screenEndpoints: ApiService.getServerUrls(),
              target: target,
            ),
          );
        }
        return (asset: null, reason: ScreenPlayReason.unreachable);
      } on IOException {
        return (asset: null, reason: ScreenPlayReason.unreachable);
      }
    }
    if (asset == null) {
      return (asset: null, reason: ScreenPlayReason.notFound);
    }
    final refusal = immichScreenRefusal(asset);
    return refusal == null ? (asset: asset, reason: null) : (asset: null, reason: refusal);
  }

  @override
  PageRouteInfo routeOf(RemoteAsset asset) {
    final viewer = _ref.read(assetViewerProvider.notifier);
    viewer.reset();
    if (asset.isVideo) {
      viewer.setControls(false);
    }
    viewer.setAsset(asset);
    return AssetViewerRoute(
      initialIndex: 0,
      timelineService: _ref.read(timelineFactoryProvider).fromAssets([asset], TimelineOrigin.deepLink),
    );
  }

  @override
  bool showing(String assetId) {
    final router = _ref.read(appRouterProvider);
    final current = _ref.read(assetViewerProvider).currentAsset;
    return router.current.name == AssetViewerRoute.name && current is RemoteAsset && current.id == assetId;
  }
}

final screenImmichAccessProvider = Provider<ScreenImmichAccess>(AppScreenImmichAccess.new);

/// The identity a play gives of a share: the UDN of a DLNA server when the discovery gave one, else
/// "host[:port]/share" in lower case for the host, as both devices write it. Null for a source of another type.
String? playShareSourceKey(NetworkSource source) {
  if (source.type != NetworkSourceType.smb &&
      source.type != NetworkSourceType.webdav &&
      source.type != NetworkSourceType.dlna) {
    return null;
  }
  final discovered = source.discoveryId;
  if (source.type == NetworkSourceType.dlna && discovered != null && discovered.isNotEmpty) {
    return discovered;
  }
  final port = source.port == null ? '' : ':${source.port}';
  final share = source.share.startsWith('/') ? source.share.substring(1) : source.share;
  return '${source.host.toLowerCase()}$port/$share';
}

PlayShareType? playShareTypeOf(NetworkSourceType type) => switch (type) {
  NetworkSourceType.smb => PlayShareType.smb,
  NetworkSourceType.webdav => PlayShareType.webdav,
  NetworkSourceType.dlna => PlayShareType.dlna,
  _ => null,
};

/// The source of this screen [target] names
NetworkSource? findPlayShareSource(Iterable<NetworkSource> sources, SharePlayTarget target) => sources
    .where((source) => playShareTypeOf(source.type) == target.type && playShareSourceKey(source) == target.source)
    .firstOrNull;

/// The Jellyfin or Emby server of this screen [target] names
NetworkSource? findPlayMediaServerSource(Iterable<NetworkSource> sources, MediaServerPlayTarget target) => sources
    .where(
      (source) =>
          source.type == NetworkSourceType.jellyfin &&
          (source.discoveryId?.toLowerCase() == target.server ||
              source.jellyfin?.serverId.toLowerCase() == target.server),
    )
    .firstOrNull;
