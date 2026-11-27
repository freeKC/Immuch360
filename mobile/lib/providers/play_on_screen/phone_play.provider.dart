// "Play on..." on a phone or a tablet: the linked screens announced nearby, the session with the one a film plays on,
// its state followed by long poll for the mini controller, the commands of that controller, and "Add (server) to
// (screen)" for a screen that does not have the server yet.
//
// The play message names the film by the machine identifier of the Plex server and its rating key: the screen plays
// it with its own access to that server. The token moves only by the handover, after the check number that both
// devices show and both users accept, with the warning.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/pairing/big_screen_headers.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_file_system.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/presentation/pages/pairing/enter_code.page.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:immich_mobile/providers/pairing/phone_pairing.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_relay.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_item_openers.dart';
import 'package:logging/logging.dart';

final _log = Logger('PhonePlay');

/// Where a linked screen listens, as it announces itself
typedef PlayScreenAddress = ({String host, int port});

/// A debug build may find its linked screens at one address, for two emulators that reach each other only through
/// the host, where no announcement crosses (`--dart-define=IMMUCH_PLAY_ON_SCREEN=10.0.2.2:18363`, the TV emulator's
/// port 8363 redirected there); a release build ignores it, as IMMUCH_PAIRING_ADVERTISE
const _debugScreen = String.fromEnvironment('IMMUCH_PLAY_ON_SCREEN');

/// The address of [_debugScreen], null for none or one that is not a private IPv4 with a port
PlayScreenAddress? playOnDebugScreen(String value) {
  final colon = value.lastIndexOf(':');
  final port = colon > 0 ? int.tryParse(value.substring(colon + 1)) : null;
  final host = colon > 0 ? value.substring(0, colon) : '';
  return port != null && port > 0 && port < 65536 && isPrivatePairingIPv4(host) ? (host: host, port: port) : null;
}

/// The linked screens announced nearby, by id, while something watches it (the "Play on" sheet)
class NearbyPlayScreensNotifier extends AutoDisposeNotifier<Map<String, PlayScreenAddress>> {
  StreamSubscription<MdnsService>? _browse;
  final _stop = Completer<void>();

  @override
  Map<String, PlayScreenAddress> build() {
    final debug = kDebugMode ? playOnDebugScreen(_debugScreen) : null;
    if (debug != null) {
      unawaited(
        ref.read(linkedScreensProvider.future).then((screens) {
          state = {...state, for (final screen in screens) screen.id: debug};
        }, onError: (Object _) {}),
      );
    }
    final browse = ref.read(pairingBrowseProvider);
    _browse = browse(
      pairingServiceType,
      _stop.future,
    ).listen((service) => unawaited(_add(service)), onError: (Object _) {});
    ref.onDispose(() {
      if (!_stop.isCompleted) {
        _stop.complete();
      }
      unawaited(_browse?.cancel());
    });
    return const {};
  }

  Future<void> _add(MdnsService service) async {
    final id = service.attributes['id'];
    if (service.attributes['kind'] != playLinkKind || !isPlayLinkId(id) || service.lost) {
      return;
    }
    final host = isPrivatePairingIPv4(service.host) ? service.host : await lookupIPv4(service.host);
    if (host == null || !isPrivatePairingIPv4(host)) {
      return;
    }
    state = {...state, id!: (host: host, port: service.port)};
  }

  /// A screen found otherwise (the tests)
  @visibleForTesting
  void put(String id, PlayScreenAddress address) => state = {...state, id: address};
}

final nearbyPlayScreensProvider =
    NotifierProvider.autoDispose<NearbyPlayScreensNotifier, Map<String, PlayScreenAddress>>(
      NearbyPlayScreensNotifier.new,
    );

/// The servers each screen said it does not have, by screen id: its row offers "Add (server) to (screen)"
final screensWithoutServerProvider = StateProvider<Map<String, Set<String>>>((_) => const {});

/// The screens that said they are signed in to no Immich server: their row offers "Sign (screen) in to (server)"
final screensSignedOutProvider = StateProvider<Set<String>>((_) => const {});

/// How "Sign (screen) in to (server)" went
enum ScreenSignInOutcome {
  signedIn,

  /// The user of the screen said Not now, or did not answer in time
  declined,

  /// The screen is signed in to a server already: nothing changed
  alreadySignedIn,

  /// The screen could not reach the server at any address of this phone
  serverUnreachable,

  /// The server refused the session at the screen
  tokenRejected,

  /// The phone's server makes no session for another device (older than v1.133)
  serverTooOld,

  /// The phone could not reach its own server
  phoneOffline,

  /// The screen did not answer
  unreachable,
  failed,
}

/// The id of the Jellyfin or Emby item a path of its connection names (`/.items/(id)/(source)/(name)`), else null
String? playMediaServerItemOfPath(String path) {
  final segments = path.split('/').where((segment) => segment.isNotEmpty).toList();
  if (segments.length < 3 || '/${segments.first}' != JellyfinFileSystem.itemFolder) {
    return null;
  }
  final id = Uri.decodeComponent(segments[1]);
  return RegExp(r'^[0-9a-zA-Z-]{1,64}$').hasMatch(id) ? id : null;
}

/// The source key of every Immich request: the phone has one Immich server
const playOnImmichSource = 'immich';

/// The source key of a photo or a video on this phone only, which goes from the phone's relay (release 53)
const playOnLocalSource = 'local';

/// What the phone knows of an Immich asset it sends, for the Cast check and the viewer it follows
@immutable
class PlayOnImmichAsset {
  const PlayOnImmichAsset({
    required this.id,
    required this.video,
    this.fileName,
    this.durationMs,
    this.width,
    this.height,
    this.locked = false,
    this.archived = false,
    this.projection = PlayProjection.flat,
    this.asset,
  });

  /// The asset itself, for the probe of a video's codecs before a cast
  final BaseAsset? asset;

  final String id;
  final bool video;
  final String? fileName;
  final int? durationMs;
  final int? width;
  final int? height;
  final bool locked;
  final bool archived;
  final PlayProjection projection;
}

/// What an item to play on a screen is, as the page that offers "Play on..." knows it: a Plex film (the first
/// constructor, build 51), or any [PlayTarget] ([PlayOnRequest.forTarget])
class PlayOnRequest {
  const PlayOnRequest({
    required this.sourceId,
    required this.server,
    required this.serverName,
    required this.ratingKey,
    this.title,
    this.offsetMs = 0,
    this.audio,
    this.subtitle,
    this.path,
  }) : _target = null,
       immich = null,
       relay = null,
       localAssetId = null;

  PlayOnRequest.forTarget({
    required this.sourceId,
    required PlayTarget target,
    required this.serverName,
    this.title,
    this.offsetMs = 0,
    this.path,
    this.immich,
    this.relay,
    this.localAssetId,
  }) : _target = target,
       server = target.serverKey,
       ratingKey = target.itemKey,
       audio = null,
       subtitle = null;

  /// [relay], an item the phone sends from its relay (release 53): a photo or a video on this phone only
  /// ([localAssetId]), or an item of [sourceId] the screen cannot reach ([immich], [path]). Its lease is made when it
  /// is sent ([withLease]).
  PlayOnRequest.relayed({
    required this.sourceId,
    required PlayOnRelayItem this.relay,
    required this.serverName,
    this.title,
    this.path,
    this.immich,
    this.localAssetId,
  }) : _target = RelayPlayTarget(
         lease: '',
         port: 0,
         name: relay.name,
         mime: relay.media == PlayMedia.photo ? 'image/jpeg' : 'video/mp4',
         media: relay.media,
         projection: relay.projection,
       ),
       server = 'relay',
       ratingKey = '',
       offsetMs = 0,
       audio = null,
       subtitle = null;

  /// The same request, sent under [lease] of the relay with what [made] says of the item
  PlayOnRequest withLease(CastRelayLease lease, PlayOnRelayContent made) => PlayOnRequest.forTarget(
    sourceId: sourceId,
    target: RelayPlayTarget(
      lease: lease.id,
      port: lease.port,
      name: relay!.name,
      mime: made.mime,
      size: made.size,
      media: relay!.media,
      projection: relay!.projection,
    ),
    serverName: serverName,
    title: title,
    path: path,
    immich: immich,
    relay: relay,
    localAssetId: localAssetId,
  );

  /// What the relay sends, for a request the phone sends from its relay
  final PlayOnRelayItem? relay;

  /// The id of the asset on this device, for a photo or a video on this phone only
  final String? localAssetId;

  /// Whether it is an item of the phone's viewer, or of a selection or an album (Immich, or on this phone only)
  bool get ofViewer => sourceId == playOnImmichSource || sourceId == playOnLocalSource;

  /// The Immich asset [asset] of this phone's server, null for one that is on this device only. [userId] is the
  /// phone's account, [endpoints] the addresses it reaches its server at (only their hashes go), [serverName] what the
  /// sheet calls it (it stays on the phone).
  static PlayOnRequest? ofAsset(
    BaseAsset asset, {
    required String userId,
    required List<String> endpoints,
    required String serverName,
    PlayProjection projection = PlayProjection.flat,
  }) {
    final id = asset.remoteId;
    if (id == null || !asset.hasRemote || (!asset.isImage && !asset.isVideo)) {
      return null;
    }
    final visibility = asset is RemoteAsset ? asset.visibility : AssetVisibility.timeline;
    // The addresses as hashes: the screen compares them with its own, it never reads them
    final hashes = <String>[];
    for (final endpoint in endpoints) {
      final hash = immichEndpointHash(endpoint);
      if (hash != null && !hashes.contains(hash) && hashes.length < ImmichPlayTarget.maxEndpoints) {
        hashes.add(hash);
      }
    }
    final media = asset.isVideo ? PlayMedia.video : PlayMedia.photo;
    return PlayOnRequest.forTarget(
      sourceId: playOnImmichSource,
      target: ImmichPlayTarget(
        asset: id.toLowerCase(),
        user: userId.toLowerCase(),
        endpointHashes: hashes,
        media: media,
        projection: projection,
      ),
      serverName: serverName,
      title: asset.name.isEmpty ? null : asset.name,
      immich: PlayOnImmichAsset(
        id: id,
        video: asset.isVideo,
        fileName: asset.name.isEmpty ? null : asset.name,
        durationMs: asset.durationMs,
        width: asset.width,
        height: asset.height,
        locked: visibility == AssetVisibility.locked,
        archived: visibility == AssetVisibility.archive,
        projection: projection,
        asset: asset,
      ),
    );
  }

  /// A file of a share (SMB, WebDAV, DLNA) or an item of a Jellyfin or Emby server, at [path] of its connection on
  /// this phone; null for a source of another type, or a Jellyfin path that names no item
  static PlayOnRequest? ofShareFile({
    required NetworkSource source,
    required String path,
    required bool photo,
    String? title,
    int offsetMs = 0,
  }) {
    final media = photo ? PlayMedia.photo : PlayMedia.video;
    final PlayTarget target;
    if (source.type == NetworkSourceType.jellyfin) {
      final server = (source.discoveryId ?? source.jellyfin?.serverId)?.toLowerCase();
      final item = playMediaServerItemOfPath(path);
      if (server == null || item == null) {
        return null;
      }
      target = MediaServerPlayTarget(
        type: (source.jellyfin?.isEmby ?? false) ? PlayMediaServerType.emby : PlayMediaServerType.jellyfin,
        server: server,
        item: item,
        media: media,
      );
    } else {
      final type = playShareTypeOf(source.type);
      final key = playShareSourceKey(source);
      if (type == null || key == null || !isSafePlayPath(path)) {
        return null;
      }
      target = SharePlayTarget(type: type, source: key, path: path, media: media);
    }
    return PlayOnRequest.forTarget(
      sourceId: source.id,
      target: target,
      serverName: source.name,
      title: title,
      offsetMs: photo || offsetMs < 0 ? 0 : offsetMs,
      path: path,
    );
  }

  final PlayTarget? _target;

  /// What the play names
  PlayTarget get target => _target ?? PlexPlayTarget(server: server, item: ratingKey);

  PlayKind get kind => target.kind;
  bool get isPhoto => target.media == PlayMedia.photo;

  /// The source on this phone: a Plex source's id, [playOnImmichSource], [playOnLocalSource]
  final String sourceId;

  /// The machine identifier of a Plex server, else what stands for the source in the state
  final String server;
  final String serverName;

  /// The rating key of a Plex film, else the item's key
  final String ratingKey;

  /// The Immich asset, for an Immich request
  final PlayOnImmichAsset? immich;

  // Two requests of the same item are the same: the Cast check of the sheet is keyed by its request
  @override
  bool operator ==(Object other) =>
      other is PlayOnRequest &&
      other.kind == kind &&
      other.sourceId == sourceId &&
      other.server == server &&
      other.ratingKey == ratingKey &&
      other.path == path &&
      other.relay?.key == relay?.key;

  @override
  int get hashCode => Object.hash(kind, sourceId, server, ratingKey, path, relay?.key);
  final String? title;
  final int offsetMs;
  final PlayTrackChoice? audio;
  final PlayTrackChoice? subtitle;

  /// The path of the file on this phone's connection, for "Continue on this phone" on the same page
  final String? path;

  PlayItem get item => _target == null
      ? PlayItem(
          server: server,
          item: ratingKey,
          serverName: serverName,
          title: title,
          offsetMs: offsetMs,
          audio: audio,
          subtitle: subtitle,
        )
      // An Immich server's name is the host of the phone's address: it stays on the phone (the screen names its own)
      : PlayItem.of(
          _target,
          serverName: _target.kind == PlayKind.immich ? null : serverName,
          title: title,
          offsetMs: offsetMs,
        );

  /// The request for the source [sourceId] and the file at [path] of its open connection: null when the source is
  /// no Plex server, or the connection does not know the rating key of the file
  static PlayOnRequest? of({
    required NetworkSource? source,
    required PlexFileSystem? fileSystem,
    required String path,
    String? title,
    int offsetMs = 0,
    PlayTrackChoice? audio,
    PlayTrackChoice? subtitle,
  }) {
    final ratingKey = fileSystem?.ratingKeyOf(path);
    if (ratingKey == null) {
      return null;
    }
    return ofItem(
      source: source,
      ratingKey: ratingKey,
      title: title,
      offsetMs: offsetMs,
      audio: audio,
      subtitle: subtitle,
      path: path,
    );
  }

  /// The request for the item [ratingKey] of the source: the film page, which knows the item (its ratingKey, its
  /// title, where it was left) and the file Play opens as [path]; null when the source is no Plex server or does not
  /// know its machine identifier
  static PlayOnRequest? ofItem({
    required NetworkSource? source,
    required String ratingKey,
    String? title,
    int offsetMs = 0,
    PlayTrackChoice? audio,
    PlayTrackChoice? subtitle,
    String? path,
  }) {
    final server = source?.discoveryId;
    if (source == null || source.type != NetworkSourceType.plex || server == null || ratingKey.isEmpty) {
      return null;
    }
    return PlayOnRequest(
      sourceId: source.id,
      server: server.toLowerCase(),
      serverName: source.name,
      ratingKey: ratingKey,
      title: title,
      offsetMs: offsetMs < 0 ? 0 : offsetMs,
      audio: audio,
      subtitle: subtitle,
      path: path,
    );
  }
}

/// How a "Play on" went
enum PlayOnOutcome {
  playing,

  /// The screen has no such server: its row offers "Add (server) to (screen)"
  noSuchServer,

  /// The user of the screen said Not now
  declined,

  /// Not announced, or no answer: "Open Immuch360 on (screen), then try again"
  unreachable,

  /// The screen no longer knows this phone: link it again
  notLinked,

  /// The screen's token for the server is refused, or its server does not answer it
  screenCannotOpen,

  /// The server does not know that film
  notFound,

  /// The screen runs a build that plays Plex films only
  needsUpdate,

  /// Immich: the screen is signed in to no server
  notSignedIn,

  /// Immich: the screen's account on the same server may not see the asset
  otherAccount,

  /// Immich: the screen uses another server
  otherServer,

  /// The screen's account may not see it
  notVisible,

  /// Immich: a locked item
  locked,

  /// The screen has no source of that identity (a share, a Jellyfin or Emby server)
  noSuchSource,

  /// The phone could not send it from its relay, or the screen could not read it there (release 53)
  relayFailed,
  failed,
}

/// What the mini controller shows
@immutable
class RemotePlayback {
  const RemotePlayback({required this.screen, required this.request, required this.state, this.lost = false});

  final LinkedPeer screen;
  final PlayOnRequest request;
  final ScreenPlayState state;

  /// The screen stopped answering
  final bool lost;

  bool get ended =>
      state.phase == ScreenPlayPhase.idle ||
      state.phase == ScreenPlayPhase.ended ||
      state.phase == ScreenPlayPhase.failed;

  /// Whether this is the file at [path] of the source [sourceId] (its page shows the whole controller)
  bool isOf(String sourceId, String path) => request.sourceId == sourceId && request.path == path;

  /// Whether this is the asset [assetId] of the phone's viewer: an Immich asset by its id (sent from the phone or not),
  /// or one on this phone only by its id on the device
  bool isOfAsset(String assetId) {
    final id = assetId.toLowerCase();
    return (request.sourceId == playOnImmichSource && request.immich?.id.toLowerCase() == id) ||
        (request.sourceId == playOnLocalSource && request.localAssetId?.toLowerCase() == id);
  }

  /// Whether the screen still plays the file at [path] of [sourceId]: its page opened again leaves the phone's player
  /// waiting
  bool playsOnScreen(String sourceId, String path) => isOf(sourceId, path) && !ended && !lost;

  RemotePlayback withState(ScreenPlayState state, {bool lost = false}) =>
      RemotePlayback(screen: screen, request: request, state: state, lost: lost);
}

/// What the phone needs to talk to the screens, replaced in the tests
class PhonePlayEnvironment {
  const PhonePlayEnvironment({required this.client, required this.readToken, required this.learnedPublic});

  final Future<PlayLinkClient> Function() client;

  /// The token of a Plex source of this phone
  final Future<String?> Function(String sourceId) readToken;

  /// The address outside home the server of a source told, if any
  final ({String host, int port})? Function(NetworkSource source) learnedPublic;
}

final phonePlayEnvironmentProvider = Provider<PhonePlayEnvironment>((ref) {
  return PhonePlayEnvironment(
    client: () async => PlayLinkClient(phoneId: await phoneShareInstallId(ref.read(storeServiceProvider))),
    readToken: (sourceId) => ref.read(networkSourcesProvider.notifier).readPassword(sourceId),
    learnedPublic: (source) {
      final plex = source.plex;
      if (plex == null) {
        return null;
      }
      return plexPublicAddress(plex, PlexLearnedAddressStore(ref.read(storeServiceProvider)).read(source.id));
    },
  );
});

/// See the top of this file: the playback on a screen, null while nothing plays on one
class RemotePlaybackController extends Notifier<RemotePlayback?> {
  PlayLinkConnection? _connection;
  PlayScreenAddress? _address;
  int _generation = 0;

  /// How long one status request waits for a change
  static const statusWait = Duration(seconds: 20);

  /// Status requests in a row that may fail before the screen is taken as gone
  static const maxFailures = 3;

  @override
  RemotePlayback? build() {
    ref.onDispose(() {
      _generation++;
      unawaited(_connection?.close());
    });
    return null;
  }

  PhonePlayEnvironment get _environment => ref.read(phonePlayEnvironmentProvider);

  Future<PlayLinkConnection> _connect(LinkedPeer screen, PlayScreenAddress address) async {
    final current = _connection;
    if (current != null && current.screen.id == screen.id && current.address == '${address.host}:${address.port}') {
      return current;
    }
    unawaited(current?.close());
    _connection = null;
    final client = await _environment.client();
    return _connection = await client.connect(host: address.host, port: address.port, screen: screen);
  }

  /// Sends [request] to the screen that shows something of this phone now: the next photo or video of the viewer the
  /// user swiped to. Null when no screen shows anything of this phone.
  Future<PlayOnOutcome?> showNext(PlayOnRequest request) async {
    final playback = state;
    final address = _address;
    if (playback == null || address == null || playback.lost) {
      return null;
    }
    final outcome = await play(playback.screen, address, request);
    if (outcome != PlayOnOutcome.playing && identical(state, playback)) {
      // The screen keeps the item before on its screen, the dock says the new one did not go
      state = RemotePlayback(
        screen: playback.screen,
        request: request,
        state: playback.state.next(phase: ScreenPlayPhase.failed),
      );
    }
    return outcome;
  }

  /// Plays [request] on [screen] at [address]; an item the phone sends from its relay gets its lease first, for that
  /// screen alone and the sessions of this connection
  Future<PlayOnOutcome> play(LinkedPeer screen, PlayScreenAddress address, PlayOnRequest request) async {
    String? lease;
    var outcome = PlayOnOutcome.failed;
    try {
      final played = await _play(screen, address, request, (id) => lease = id);
      outcome = played;
      return played;
    } finally {
      if (lease case final id?) {
        ref.read(phoneRelayProvider.notifier).settle(id, playing: outcome == PlayOnOutcome.playing);
      }
    }
  }

  Future<PlayOnOutcome> _play(
    LinkedPeer screen,
    PlayScreenAddress address,
    PlayOnRequest original,
    void Function(String lease) leased,
  ) async {
    final generation = ++_generation;
    _address = address;
    var request = original;
    final ({String status, ScreenPlayState state}) answer;
    try {
      final connection = await _connect(screen, address);
      final relay = request.relay;
      if (relay != null) {
        final made = await ref
            .read(phoneRelayProvider.notifier)
            .lease(screenHost: address.host, screenName: screen.name, item: relay, macKeys: () => connection.relayKeys);
        if (made == null) {
          return PlayOnOutcome.relayFailed;
        }
        leased(made.lease.id);
        request = request.withLease(made.lease, made.made);
      }
      final message = await _playMessage(request);
      // Once the Quest asked its user: a minute and a half
      answer = await connection.command(message, timeout: const Duration(seconds: 90));
    } on PlayLinkException catch (error) {
      _log.info('Play on: the screen did not take it (${error.failure.name})');
      _connection = null;
      return switch (error.failure) {
        PlayLinkFailure.unreachable => PlayOnOutcome.unreachable,
        PlayLinkFailure.notLinked => PlayOnOutcome.notLinked,
        PlayLinkFailure.invalid => PlayOnOutcome.failed,
      };
    }
    final state = answer.state;
    final outcome = answer.status != 'ok'
        // A build 51 screen takes no other kind than a Plex film: its play answers "invalid"
        ? (answer.status == 'invalid' && request.kind != PlayKind.plex
              ? PlayOnOutcome.needsUpdate
              : PlayOnOutcome.failed)
        : playOnOutcomeOf(state);
    final without = ref.read(screensWithoutServerProvider.notifier);
    final missing = {...?without.state[screen.id]};
    if (outcome == PlayOnOutcome.noSuchServer ? missing.add(request.server) : missing.remove(request.server)) {
      without.state = {...without.state, screen.id: missing};
    }
    if (request.kind == PlayKind.immich) {
      final signedOut = ref.read(screensSignedOutProvider.notifier);
      if (outcome == PlayOnOutcome.notSignedIn) {
        signedOut.state = {...signedOut.state, screen.id};
      } else if (signedOut.state.contains(screen.id)) {
        signedOut.state = {...signedOut.state}..remove(screen.id);
      }
    }
    if (outcome != PlayOnOutcome.playing || generation != _generation) {
      return outcome;
    }
    this.state = RemotePlayback(screen: screen, request: request, state: state);
    unawaited(_follow(generation));
    return outcome;
  }

  /// The play message of [request]: a file of a share known by a host name carries the address this phone finds for
  /// it, so that a screen that knows the machine by its address finds its share (and the other way round)
  Future<Map<String, Object?>> _playMessage(PlayOnRequest request) async {
    final item = request.item;
    final target = item.target;
    final host = target is SharePlayTarget && target.hostAddresses.isEmpty ? target.host : null;
    if (target is SharePlayTarget && host != null && !isPrivatePairingIPv4(host)) {
      final found = await ref.read(playHostResolverProvider)(host).catchError((Object _) => null);
      if (found != null && isPrivatePairingIPv4(found)) {
        return {
          'type': 'play',
          ...PlayItem.of(
            target.withHostAddresses([found]),
            serverName: item.serverName,
            title: item.title,
            offsetMs: item.offsetMs,
          ).toJson(),
        };
      }
    }
    return {'type': 'play', ...item.toJson()};
  }

  /// The outcome a play's answer tells
  static PlayOnOutcome playOnOutcomeOf(ScreenPlayState state) => switch (state.reason) {
    ScreenPlayReason.noSuchServer => PlayOnOutcome.noSuchServer,
    ScreenPlayReason.declined => PlayOnOutcome.declined,
    ScreenPlayReason.tokenRefused || ScreenPlayReason.unreachable => PlayOnOutcome.screenCannotOpen,
    ScreenPlayReason.notFound => PlayOnOutcome.notFound,
    ScreenPlayReason.notSignedIn => PlayOnOutcome.notSignedIn,
    ScreenPlayReason.otherAccount => PlayOnOutcome.otherAccount,
    ScreenPlayReason.otherServer => PlayOnOutcome.otherServer,
    ScreenPlayReason.notVisible => PlayOnOutcome.notVisible,
    ScreenPlayReason.locked => PlayOnOutcome.locked,
    ScreenPlayReason.noSuchSource => PlayOnOutcome.noSuchSource,
    ScreenPlayReason.relayFailed => PlayOnOutcome.relayFailed,
    ScreenPlayReason.busy || ScreenPlayReason.failed => PlayOnOutcome.failed,
    null => state.phase == ScreenPlayPhase.failed ? PlayOnOutcome.failed : PlayOnOutcome.playing,
  };

  /// Follows the state of the screen until the playback ends or another starts
  Future<void> _follow(int generation) async {
    var failures = 0;
    while (generation == _generation) {
      final playback = state;
      final connection = _connection;
      if (playback == null || connection == null) {
        return;
      }
      try {
        final next = await connection.status(after: playback.state.seq, wait: statusWait);
        failures = 0;
        if (generation != _generation) {
          return;
        }
        state = playback.withState(next);
        if (next.phase == ScreenPlayPhase.idle && next.key == null) {
          return;
        }
        // Another phone played something else there: this phone's controller ends
        if (next.key != playback.request.ratingKey || next.server != playback.request.server) {
          _end();
          return;
        }
      } catch (error) {
        failures++;
        if (failures >= maxFailures) {
          if (generation == _generation) {
            state = playback.withState(playback.state, lost: true);
          }
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _send(Map<String, Object?> command) async {
    final connection = _connection;
    final playback = state;
    if (connection == null || playback == null) {
      return;
    }
    try {
      final answer = await connection.command(command);
      if (state != null && answer.state.seq > (state?.state.seq ?? -1)) {
        state = state!.withState(answer.state);
      }
    } on PlayLinkException catch (error) {
      _log.info('Play on: a command did not reach the screen (${error.failure.name})');
      state = playback.withState(playback.state, lost: true);
    }
  }

  Future<void> pause() => _send({'type': 'pause'});

  Future<void> resume() => _send({'type': 'resume'});

  /// Moves by [delta] from where the screen is
  Future<void> seekBy(Duration delta) {
    final playback = state;
    if (playback == null) {
      return Future.value();
    }
    var target = playback.state.positionMs + delta.inMilliseconds;
    final duration = playback.state.durationMs;
    if (duration != null && target > duration) {
      target = duration;
    }
    return seekTo(Duration(milliseconds: target < 0 ? 0 : target));
  }

  Future<void> seekTo(Duration position) => _send({'type': 'seek', 'positionMs': position.inMilliseconds});

  /// Chooses a track of the screen; a null [id] turns the subtitles off
  Future<void> track(PlayTrackKind kind, String? id) => _send({'type': 'track', 'kind': kind.wire, 'id': id});

  /// Stops the film on the screen; gives where it was
  Future<Duration> stop() async {
    final position = Duration(milliseconds: state?.state.positionMs ?? 0);
    await _send({'type': 'stop'});
    _end();
    return position;
  }

  /// The controller goes, the screen plays on: the screen went, or it plays another phone's film
  void _end() {
    _generation++;
    state = null;
  }

  /// Forgets a playback that the screen ended or that was lost
  void dismiss() => _end();

  /// "Sign (screen) in to (server)" for a screen signed in to no server (release 53): the fresh hello inside a session,
  /// then [confirm] with its check number and the account (the sheet with the warning of "Sign in with your phone"),
  /// then a new session of this phone's account for the screen alone, sealed under the keys of that hello, which the
  /// screen opens once its user accepted too. The session is listed among the screens this phone signed in before it
  /// leaves, and deleted on anything but a sign in: no orphan token. The custom headers of this phone never go: "Sign
  /// in with your phone" asks for them. Null when the user of the phone cancelled.
  Future<ScreenSignInOutcome?> signInScreen(
    LinkedPeer screen,
    PlayScreenAddress address, {
    required Future<bool> Function(String check, PhonePairingAccount account) confirm,
    void Function()? onSent,
  }) async {
    final account = await ref.read(phonePairingAccountProvider)();
    final server = Uri.tryParse(account.server)?.host ?? account.server;
    final user = account.userName.isNotEmpty ? account.userName : account.userEmail;
    final PlayLinkConnection connection;
    final PhoneHandover handover;
    try {
      connection = await _connect(screen, address);
      handover = await PhoneHandover.start(connection, serverName: server, signInAs: user);
    } on PlayHandoverRefused {
      _log.info('Play on: the screen is signed in already');
      return ScreenSignInOutcome.alreadySignedIn;
    } on PlayLinkException catch (error) {
      _log.info('Play on: no sign in with the screen (${error.failure.name})');
      _connection = null;
      return ScreenSignInOutcome.unreachable;
    }
    if (!await confirm(handover.check, account)) {
      await handover.cancel();
      return null;
    }
    onSent?.call();
    final label = cleanPairingLabel(screen.name) ?? 'TV';
    // The system the screen said, as "Sign in with your phone" names the session; its kind when it said none
    final os = pairingSessionOs(
      PairingScreenDevice(label: label, kind: screen.kind, os: handover.screenOs ?? '', app: ''),
    );
    final sessions = ref.read(pairingSessionsProvider);
    final ({String id, String token}) session;
    try {
      session = await sessions.create(deviceType: pairingSessionName(label), deviceOS: os);
    } on PairingSessionsException catch (error) {
      _log.info('Play on: no session for the screen (${error.failure.name})');
      await handover.cancel();
      return switch (error.failure) {
        PairingSessionsFailure.serverTooOld => ScreenSignInOutcome.serverTooOld,
        PairingSessionsFailure.phoneOffline => ScreenSignInOutcome.phoneOffline,
        PairingSessionsFailure.refused => ScreenSignInOutcome.failed,
      };
    }
    final screens = ref.read(pairedScreensProvider.notifier);
    await screens.add(PairedScreen(sessionId: session.id, label: label, kind: screen.kind, os: os, at: DateTime.now()));
    HandoverResult result;
    try {
      result = await handover.sendSignIn({
        'server': account.server,
        'endpoints': account.endpoints,
        'token': session.token,
        'sessionId': session.id,
        'label': label,
        'user': {'name': account.userName, 'email': account.userEmail},
        'phone': account.phoneName,
        'issuedAt': DateTime.now().toUtc().toIso8601String(),
      });
    } on PlayLinkException {
      result = HandoverResult.failed;
    }
    _log.info('Play on: the sign in of the screen ended (${result.wire})');
    if (result != HandoverResult.added) {
      try {
        await sessions.delete(session.id);
      } catch (error) {
        // Its token went nowhere the phone trusts; the user still sees it in Authorized devices
        _log.warning('Play on: the session made for the screen could not be deleted: ${error.runtimeType}');
      }
      await screens.remove(session.id);
      return switch (result) {
        HandoverResult.declined => ScreenSignInOutcome.declined,
        HandoverResult.alreadySignedIn => ScreenSignInOutcome.alreadySignedIn,
        HandoverResult.unreachable => ScreenSignInOutcome.serverUnreachable,
        HandoverResult.tokenRefused => ScreenSignInOutcome.tokenRejected,
        _ => ScreenSignInOutcome.failed,
      };
    }
    final signedOut = ref.read(screensSignedOutProvider.notifier);
    signedOut.state = {...signedOut.state}..remove(screen.id);
    return ScreenSignInOutcome.signedIn;
  }

  /// "Add (server) to (screen)": the fresh hello inside a session, then [confirm] with its check number (the sheet
  /// with the warning), then the server and its token once the user of the phone accepted, and the answer once the
  /// user of the screen did. Null when the user of the phone cancelled.
  Future<HandoverResult?> addServer(
    LinkedPeer screen,
    PlayScreenAddress address,
    NetworkSource source, {
    required Future<bool> Function(String check) confirm,
    void Function()? onSent,
  }) async {
    final plex = source.plex;
    final machine = source.discoveryId;
    final token = await _environment.readToken(source.id);
    if (plex == null || machine == null || token == null || token.isEmpty) {
      return HandoverResult.failed;
    }
    final PlayLinkConnection connection;
    final PhoneHandover handover;
    try {
      connection = await _connect(screen, address);
      handover = await PhoneHandover.start(connection, serverName: source.name);
    } on PlayLinkException catch (error) {
      _log.info('Play on: no handover with the screen (${error.failure.name})');
      _connection = null;
      return HandoverResult.unreachable;
    }
    if (!await confirm(handover.check)) {
      await handover.cancel();
      return null;
    }
    onSent?.call();
    final public = _environment.learnedPublic(source);
    try {
      final result = await handover.send(
        HandedPlexServer(
          name: source.name,
          machineIdentifier: machine.toLowerCase(),
          hash: plex.hash,
          host: source.host,
          port: source.port,
          publicHost: public?.host,
          publicPort: public?.port,
          rootPath: source.rootPath,
        ),
        token,
      );
      _log.info('Play on: the handover ended (${result.wire})');
      if (result == HandoverResult.added) {
        final without = ref.read(screensWithoutServerProvider.notifier);
        without.state = {
          ...without.state,
          screen.id: {...?without.state[screen.id]}..remove(machine.toLowerCase()),
        };
      }
      return result;
    } on PlayLinkException {
      return HandoverResult.unreachable;
    }
  }
}

final remotePlaybackProvider = NotifierProvider<RemotePlaybackController, RemotePlayback?>(
  RemotePlaybackController.new,
);
