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
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/presentation/pages/pairing/enter_code.page.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('PhonePlay');

/// Where a linked screen listens, as it announces itself
typedef PlayScreenAddress = ({String host, int port});

/// The linked screens announced nearby, by id, while something watches it (the "Play on" sheet)
class NearbyPlayScreensNotifier extends AutoDisposeNotifier<Map<String, PlayScreenAddress>> {
  StreamSubscription<MdnsService>? _browse;
  final _stop = Completer<void>();

  @override
  Map<String, PlayScreenAddress> build() {
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

/// What a film to play on a screen is, as the page that offers "Play on..." knows it
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
  });

  /// The Plex source on this phone
  final String sourceId;

  /// Its machine identifier
  final String server;
  final String serverName;
  final String ratingKey;
  final String? title;
  final int offsetMs;
  final PlayTrackChoice? audio;
  final PlayTrackChoice? subtitle;

  /// The path of the file on this phone's connection, for "Continue on this phone" on the same page
  final String? path;

  PlayItem get item => PlayItem(
    server: server,
    item: ratingKey,
    serverName: serverName,
    title: title,
    offsetMs: offsetMs,
    audio: audio,
    subtitle: subtitle,
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

  /// Plays [request] on [screen] at [address]
  Future<PlayOnOutcome> play(LinkedPeer screen, PlayScreenAddress address, PlayOnRequest request) async {
    final generation = ++_generation;
    final ({String status, ScreenPlayState state}) answer;
    try {
      final connection = await _connect(screen, address);
      // Once the Quest asked its user: a minute and a half
      answer = await connection.command({
        'type': 'play',
        ...request.item.toJson(),
      }, timeout: const Duration(seconds: 90));
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
        ? PlayOnOutcome.failed
        : switch (state.reason) {
            ScreenPlayReason.noSuchServer => PlayOnOutcome.noSuchServer,
            ScreenPlayReason.declined => PlayOnOutcome.declined,
            ScreenPlayReason.tokenRefused || ScreenPlayReason.unreachable => PlayOnOutcome.screenCannotOpen,
            ScreenPlayReason.notFound => PlayOnOutcome.notFound,
            ScreenPlayReason.busy || ScreenPlayReason.failed => PlayOnOutcome.failed,
            null => state.phase == ScreenPlayPhase.failed ? PlayOnOutcome.failed : PlayOnOutcome.playing,
          };
    final without = ref.read(screensWithoutServerProvider.notifier);
    final missing = {...?without.state[screen.id]};
    if (outcome == PlayOnOutcome.noSuchServer ? missing.add(request.server) : missing.remove(request.server)) {
      without.state = {...without.state, screen.id: missing};
    }
    if (outcome != PlayOnOutcome.playing || generation != _generation) {
      return outcome;
    }
    this.state = RemotePlayback(screen: screen, request: request, state: state);
    unawaited(_follow(generation));
    return outcome;
  }

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
        if (next.phase == ScreenPlayPhase.idle && next.item == null) {
          return;
        }
        // Another phone played something else there: this phone's controller ends
        if (next.item != playback.request.ratingKey || next.server != playback.request.server) {
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
