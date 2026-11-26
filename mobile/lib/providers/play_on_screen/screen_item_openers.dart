// What a big screen opens for a play of each kind besides a Plex film (release 52): an Immich photo or video in the
// asset viewer, a file of a share in the network photo or video page, a Jellyfin or Emby item in the network video
// page. Each with the screen's own access to the source, never one that came with the play.
//
// Immich: the screen asks its own server, with its own session, for the asset the phone named. Its server decides
// what its account may see (the owner, a partner, a shared album). The phone's user id and the hashes of its server
// addresses only choose the sentence of a refusal: the same user is the same server for sure; another user at an
// address the phone uses too is another account; else another server. A locked asset never opens on a screen (its session has no PIN
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
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/asset_extensions.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_native_viewers.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_play_no_loop.provider.dart';
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

  /// The 360° photo viewer on [asset] alone (as the 360° button opens it)
  PageRouteInfo panoramaRouteOf(RemoteAsset asset);

  /// Whether this screen has a 360° view for [asset]: the 360° photo viewer for a photo; for a video the 360° player
  /// where the platform has one, the immersive viewer on the Meta Quest
  bool canSphere(RemoteAsset asset);

  /// Asks the asset viewer that is about to show [asset] to open its 360° view (ScreenPlaySphereOpener)
  void openSphere(RemoteAsset asset);
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
  final own = {for (final endpoint in screenEndpoints) ?immichEndpointHash(endpoint)};
  if (target.endpointHashes.any(own.contains)) {
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
    // A phone's video plays once: its end moves the phone's slideshow on
    _ref.read(screenPlayNoLoopAssetProvider.notifier).state = asset.isVideo ? asset.id : null;
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

  @override
  PageRouteInfo panoramaRouteOf(RemoteAsset asset) => PanoramaViewerRoute(asset: asset);

  @override
  bool canSphere(RemoteAsset asset) => _ref.read(can360ViewProvider(asset));

  @override
  void openSphere(RemoteAsset asset) =>
      _ref.read(screenPlaySphereRequestProvider.notifier).state = asset.id.toLowerCase();
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

/// The IPv4 address a host name has on the home network, null when none answers: the lookup of the phone and of the
/// screen (release 53), replaced in the tests
final playHostResolverProvider = Provider<Future<String?> Function(String host)>((_) => lookupIPv4);

/// The source of this screen [target] names (release 53): its identity as both devices write it, else a share of the
/// same protocol, port and share on the same machine known by another name, an address on one device and a name on
/// the other. The same machine is an address the phone found for its host, or the address this screen finds for
/// either name with [resolve]: private IPv4 addresses only, compared, never a password.
Future<NetworkSource?> matchPlayShareSource(
  Iterable<NetworkSource> sources,
  SharePlayTarget target, {
  required Future<String?> Function(String host) resolve,
}) async {
  final exact = findPlayShareSource(sources, target);
  final targetHost = target.host?.toLowerCase();
  if (exact != null || targetHost == null) {
    return exact;
  }
  final candidates = [
    for (final source in sources)
      if (playShareTypeOf(source.type) == target.type &&
          (source.discoveryId == null || source.discoveryId!.isEmpty || source.type != NetworkSourceType.dlna))
        if (playShareSourceKey(source) case final key?)
          if (SharePlayTarget(type: target.type, source: key, path: '/').sourceWithoutHost == target.sourceWithoutHost)
            source,
  ];
  if (candidates.isEmpty) {
    return null;
  }
  Future<String?> addressOf(String host) async {
    if (isPrivatePairingIPv4(host)) {
      return host;
    }
    final found = await resolve(host).catchError((Object _) => null);
    return found != null && isPrivatePairingIPv4(found) ? found : null;
  }

  final wanted = {...target.hostAddresses, ?await addressOf(targetHost)};
  if (wanted.isEmpty) {
    return null;
  }
  for (final source in candidates) {
    final address = await addressOf(source.host.toLowerCase());
    if (address != null && wanted.contains(address)) {
      _log.info('Play from a phone: a share matched by its address');
      return source;
    }
  }
  return null;
}

/// The Jellyfin or Emby server of this screen [target] names
NetworkSource? findPlayMediaServerSource(Iterable<NetworkSource> sources, MediaServerPlayTarget target) => sources
    .where(
      (source) =>
          source.type == NetworkSourceType.jellyfin &&
          (source.discoveryId?.toLowerCase() == target.server ||
              source.jellyfin?.serverId.toLowerCase() == target.server),
    )
    .firstOrNull;
