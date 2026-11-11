// "Play from a phone" on a big screen (a TV, the Quest window, a computer): the listener of the linked phones and its
// announcement, and what the screen does with their commands. It listens while the app is in front, the setting is
// on (it is by default) and at least one phone is linked; on a computer not on a network Windows marks as public.
//
// A play opens the film the way OK on its poster would: the screen finds its own Plex source of the machine
// identifier the phone named, asks that server for the item with its own token (no token ever comes with a play),
// and opens the usual player at the phone's position, with a toast "From (phone)". The remote keeps control: what it
// does shows in the state the phone follows. A film playing is replaced; the Quest asks first, and a TV or a computer
// when "Ask before a phone plays" is on.
//
// Nothing here goes to the logs but kinds and outcomes: never a title, a position, a key or a token.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/windows_dns_sd.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/play_link_server.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/screen_player_prompts.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/providers/pairing/screen_pairing.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('ScreenPlayer');

/// "Play from a phone" is on: unless the user turned it off in its page
final playFromPhoneEnabledProvider = StateProvider<bool>((_) => !(Store.tryGet(StoreKey.playFromPhoneOff) ?? false));

/// "Ask before a phone plays", on a TV or a computer (the Quest always asks)
final playFromPhoneAskProvider = StateProvider<bool>((_) => Store.tryGet(StoreKey.playFromPhoneAsk) ?? false);

/// What the receiver needs from the device, replaced by fakes in the tests
class ScreenPlayerEnvironment {
  const ScreenPlayerEnvironment({
    required this.localAddresses,
    required this.publicNetworkOnly,
    required this.advertise,
    required this.networkChanges,
    required this.lifecycle,
    required this.kind,
    required this.isBigScreen,
    required this.installId,
    required this.deviceName,
    this.preferredPort = playLinkDefaultPort,
  });

  final Future<List<String>> Function() localAddresses;
  final Future<bool> Function() publicNetworkOnly;
  final PairingAdvertise advertise;
  final Stream<void> Function() networkChanges;
  final Stream<AppLifecycleState> Function() lifecycle;
  final Future<PairingScreenKind> Function() kind;
  final Future<bool> Function() isBigScreen;
  final Future<String> Function() installId;
  final Future<String> Function() deviceName;
  final int preferredPort;
}

final screenPlayerEnvironmentProvider = Provider<ScreenPlayerEnvironment>((ref) {
  final pairing = ref.watch(screenPairingEnvironmentProvider);
  return ScreenPlayerEnvironment(
    localAddresses: pairing.localAddresses,
    publicNetworkOnly: pairing.publicNetworkOnly,
    advertise: CurrentPlatform.isWindows
        ? (name, port, attributes) => windowsShareAdvertise(name, port, attributes, type: pairingServiceType)
        : (name, port, attributes) => bonsoirAdvertise(name, port, attributes, type: pairingServiceType),
    networkChanges: () => Connectivity().onConnectivityChanged.map<void>((_) {}),
    lifecycle: appLifecycleStates,
    kind: pairing.kind,
    isBigScreen: () async {
      if (CurrentPlatform.isDesktop || ref.read(tvModeProvider)) {
        return true;
      }
      return ref.read(isHorizonOsProvider.future).catchError((Object _) => false);
    },
    installId: () => phoneShareInstallId(ref.read(storeServiceProvider)),
    deviceName: () async {
      final label = Store.tryGet(StoreKey.pairingScreenLabel);
      return label != null && label.trim().isNotEmpty ? label.trim() : (await pairing.deviceName()).trim();
    },
  );
});

/// Why the receiver does not listen
enum ScreenPlayerProblem { none, noNetwork, publicNetwork, failed }

/// What "Play from a phone" shows of the receiver
@immutable
class ScreenPlayerView {
  const ScreenPlayerView({this.listening = false, this.port, this.problem = ScreenPlayerProblem.none});

  final bool listening;
  final int? port;
  final ScreenPlayerProblem problem;

  @override
  String toString() => 'ScreenPlayerView(listening: $listening, $problem)';
}

/// See the top of this file
class ScreenPlayerController extends Notifier<ScreenPlayerView> {
  late ScreenPlayerEnvironment _environment;
  ScreenPlayerSession? _session;
  PlayLinkServer? _server;
  AppScreenPlayerActions? _actions;
  Future<void> Function()? _stopAdvertising;
  StreamSubscription<AppLifecycleState>? _lifecycle;
  StreamSubscription<void>? _network;
  bool _background = false;
  int _generation = 0;

  /// The phones linked now, read by the session at each open
  List<LinkedPeer> _phones = const [];

  @override
  ScreenPlayerView build() {
    _environment = ref.read(screenPlayerEnvironmentProvider);
    ref.listen(linkedPhonesProvider, (_, next) {
      final before = _phones;
      _phones = next.valueOrNull ?? const [];
      for (final gone in before.where((phone) => _phones.every((other) => other.id != phone.id))) {
        _session?.forgetPhone(gone.id);
      }
      unawaited(_sync());
    }, fireImmediately: true);
    ref.listen(playFromPhoneEnabledProvider, (_, _) => unawaited(_sync()));
    _lifecycle = _environment.lifecycle().listen(_onLifecycle);
    ref.onDispose(() {
      _generation++;
      unawaited(_lifecycle?.cancel());
      unawaited(_bringDown());
    });
    return const ScreenPlayerView();
  }

  /// The state of the screen's playback that the phones follow, for the tests
  @visibleForTesting
  AppScreenPlayerActions? get actions => _actions;

  void _onLifecycle(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        if (!_background) {
          _background = true;
          unawaited(_sync());
        }
      case AppLifecycleState.resumed:
        if (_background) {
          _background = false;
          unawaited(_sync());
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<bool> _wanted() async =>
      !_background &&
      ref.read(playFromPhoneEnabledProvider) &&
      _phones.isNotEmpty &&
      await _environment.isBigScreen().catchError((Object _) => false);

  /// Starts or stops the listener as the conditions say
  Future<void> _sync() async {
    final generation = ++_generation;
    final wanted = await _wanted();
    if (generation != _generation) {
      return;
    }
    if (!wanted) {
      await _bringDown();
      if (generation == _generation) {
        state = const ScreenPlayerView();
      }
      return;
    }
    if (_server != null) {
      return;
    }
    await _start(generation);
  }

  Future<void> _start(int generation) async {
    try {
      final addresses = await _environment.localAddresses();
      if (generation != _generation) {
        return;
      }
      if (addresses.isEmpty) {
        final public = await _environment.publicNetworkOnly();
        state = ScreenPlayerView(problem: public ? ScreenPlayerProblem.publicNetwork : ScreenPlayerProblem.noNetwork);
        _watchNetwork(generation);
        return;
      }
      final screenId = await _environment.installId();
      final kind = await _environment.kind();
      final actions = _actions ??= AppScreenPlayerActions(ref, kind: kind);
      final session = ScreenPlayerSession(screenId: screenId, phones: () => _phones, actions: actions);
      final server = PlayLinkServer(
        session: session,
        servedAddresses: _environment.localAddresses,
        preferredPort: _environment.preferredPort,
      );
      final port = await server.start();
      if (generation != _generation) {
        await server.stop();
        session.close();
        return;
      }
      _session = session;
      _server = server;
      state = ScreenPlayerView(listening: true, port: port);
      _watchNetwork(generation);
      try {
        final name = await _environment.deviceName();
        _stopAdvertising = await _environment.advertise(
          phoneShareServiceName('$name ($playLinkKind)'),
          port,
          playLinkAttributes(screenId: screenId, kind: kind),
        );
        if (generation != _generation) {
          await _stopAdvertising?.call();
          _stopAdvertising = null;
        }
      } catch (error) {
        // The phones then say "Open Immuch360 on it"
        _log.info('Play from a phone: not announced on the network: ${error.runtimeType}');
      }
    } catch (error) {
      _log.warning('Play from a phone: the listener did not start: ${error.runtimeType}');
      if (generation == _generation) {
        state = const ScreenPlayerView(problem: ScreenPlayerProblem.failed);
      }
    }
  }

  void _watchNetwork(int generation) {
    unawaited(_network?.cancel());
    _network = _environment.networkChanges().listen((_) async {
      if (generation != _generation) {
        return;
      }
      if (_server == null) {
        unawaited(_sync());
        return;
      }
      await _server?.refreshServedAddresses();
    });
  }

  Future<void> _bringDown() async {
    final server = _server;
    final session = _session;
    final stopAdvertising = _stopAdvertising;
    _server = null;
    _session = null;
    _stopAdvertising = null;
    unawaited(_network?.cancel());
    _network = null;
    try {
      await stopAdvertising?.call();
    } catch (error) {
      _log.fine('Play from a phone: the announcement did not stop: ${error.runtimeType}');
    }
    session?.close();
    await server?.stop();
  }
}

final screenPlayerProvider = NotifierProvider<ScreenPlayerController, ScreenPlayerView>(ScreenPlayerController.new);

/// What a play of a phone opens: a route of the router, replaced in the tests
typedef ScreenPlayerOpen = Future<void> Function(PageRouteInfo route, {required bool replace});

/// The app's side of the commands: the sources, the connections, the router, the player of the page it opened
class AppScreenPlayerActions implements ScreenPlayerActions {
  AppScreenPlayerActions(this._ref, {required this.kind});

  final Ref _ref;
  final PairingScreenKind kind;

  /// How often the state follows the player
  static const pollInterval = Duration(milliseconds: 500);

  /// How long the page has to show its player after it was opened
  static const openGrace = Duration(seconds: 8);

  ScreenPlayState _state = const ScreenPlayState();
  final _states = StreamController<ScreenPlayState>.broadcast();
  Timer? _poll;
  String? _playerKey;
  DateTime? _openedAt;
  bool _playerSeen = false;
  PlayItem? _pendingTracks;

  @override
  ScreenPlayState get state => _state;

  @override
  Stream<ScreenPlayState> get states => _states.stream;

  ScreenPlayerPrompts get _prompts => _ref.read(screenPlayerPromptsProvider);

  void _set(ScreenPlayState Function(ScreenPlayState state) change) {
    final next = change(_state);
    if (next.sameAs(_state)) {
      return;
    }
    _state = next;
    _states.add(next);
  }

  void _fail(ScreenPlayReason reason) {
    _stopPolling();
    _set((state) => state.next(phase: ScreenPlayPhase.failed, reason: reason));
  }

  @override
  Future<void> play(PlayItem item, LinkedPeer from) async {
    final ask = kind == PairingScreenKind.headset || _ref.read(playFromPhoneAskProvider);
    _set(
      (state) => ScreenPlayState(
        seq: state.seq + 1,
        phase: ask ? ScreenPlayPhase.asking : ScreenPlayPhase.opening,
        server: item.server,
        item: item.item,
        title: item.title,
        from: from.name,
        positionMs: item.offsetMs,
      ),
    );
    if (ask && !await _prompts.askPlay(phone: from.name, title: item.title)) {
      _log.info('Play from a phone: declined on the screen');
      return _fail(ScreenPlayReason.declined);
    }
    _set((state) => state.next(phase: ScreenPlayPhase.opening));
    final source = _ref
        .read(networkSourcesProvider)
        .where((source) => source.type == NetworkSourceType.plex && source.discoveryId?.toLowerCase() == item.server)
        .firstOrNull;
    if (source == null) {
      _log.info('Play from a phone: no such Plex server here');
      return _fail(ScreenPlayReason.noSuchServer);
    }
    final String path;
    try {
      final fileSystem = await _ref.read(networkConnectionsProvider).fileSystem(source.id);
      if (fileSystem is! PlexFileSystem) {
        return _fail(ScreenPlayReason.noSuchServer);
      }
      path = await fileSystem.pathOfItem(item.item);
    } on NetworkFileSystemException catch (error) {
      _log.info('Play from a phone: the server did not give the item (${error.runtimeType})');
      return _fail(
        error.isAuthentication
            ? ScreenPlayReason.tokenRefused
            : error.isNotFound
            ? ScreenPlayReason.notFound
            : ScreenPlayReason.unreachable,
      );
    } catch (error) {
      _log.warning('Play from a phone: the item did not open: ${error.runtimeType}');
      return _fail(ScreenPlayReason.failed);
    }
    final router = _ref.read(appRouterProvider);
    final replace = router.current.name == NetworkVideoRoute.name;
    final route = NetworkVideoRoute(
      sourceId: source.id,
      path: path,
      startAt: item.offsetMs > 0 ? Duration(milliseconds: item.offsetMs) : null,
    );
    _playerKey = 'network:${source.id}:$path';
    _openedAt = DateTime.now();
    _playerSeen = false;
    _pendingTracks = item.audio != null || item.subtitle != null ? item : null;
    try {
      await _ref.read(screenPlayerOpenProvider)(route, replace: replace);
    } catch (error) {
      _log.warning('Play from a phone: the player did not open: ${error.runtimeType}');
      return _fail(ScreenPlayReason.failed);
    }
    _prompts.toast(from: from.name);
    _log.info('Play from a phone: playing');
    _startPolling();
  }

  VideoPlayerNotifier? get _notifier {
    final key = _playerKey;
    if (key == null || !_ref.exists(videoPlayerProvider(key))) {
      return null;
    }
    return _ref.read(videoPlayerProvider(key).notifier);
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) => unawaited(_follow()));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// Follows the player of the page: its status, position and tracks; the page gone (Back on the remote), nothing
  /// plays any more
  Future<void> _follow() async {
    final key = _playerKey;
    if (key == null) {
      return _stopPolling();
    }
    if (!_ref.exists(videoPlayerProvider(key))) {
      if (_playerSeen) {
        _stopPolling();
        _playerKey = null;
        _set((state) => state.next(phase: ScreenPlayPhase.idle, clearReason: true));
      } else if (DateTime.now().difference(_openedAt ?? DateTime.now()) > openGrace) {
        _playerKey = null;
        _fail(ScreenPlayReason.failed);
      }
      return;
    }
    _playerSeen = true;
    final player = _ref.read(videoPlayerProvider(key));
    final notifier = _ref.read(videoPlayerProvider(key).notifier);
    final phase = switch (player.status) {
      VideoPlaybackStatus.playing => ScreenPlayPhase.playing,
      VideoPlaybackStatus.paused => notifier.isReady ? ScreenPlayPhase.paused : ScreenPlayPhase.opening,
      VideoPlaybackStatus.buffering => notifier.isReady ? ScreenPlayPhase.buffering : ScreenPlayPhase.opening,
      VideoPlaybackStatus.completed => ScreenPlayPhase.ended,
      VideoPlaybackStatus.failed => ScreenPlayPhase.failed,
    };
    final tracks = notifier.lastTracks.isEmpty && notifier.isReady ? await notifier.tracks() : notifier.lastTracks;
    final pending = _pendingTracks;
    if (pending != null && tracks.isNotEmpty) {
      _pendingTracks = null;
      await _applyChoice(notifier, tracks, pending);
    }
    _set(
      (state) => state.next(
        phase: phase,
        // Whole seconds while it plays: one state a second at most
        positionMs: phase == ScreenPlayPhase.playing
            ? player.position.inSeconds * 1000
            : player.position.inMilliseconds,
        durationMs: player.duration > Duration.zero ? player.duration.inMilliseconds : null,
        tracks: [for (final track in notifier.lastTracks) ?playTrackOf(track)],
        reason: phase == ScreenPlayPhase.failed ? ScreenPlayReason.failed : null,
        clearReason: phase != ScreenPlayPhase.failed,
      ),
    );
  }

  /// The tracks of [item]'s choice, matched by language: the ids of the two players differ
  static Future<void> _applyChoice(VideoPlayerNotifier notifier, List<NativeVideoTrack> tracks, PlayItem item) async {
    final audio = item.audio?.language;
    if (audio != null) {
      final match = tracks.where((t) => t.type == NativeVideoTrackType.audio && _sameLanguage(t.language, audio));
      if (match.isNotEmpty && !match.first.selected) {
        await notifier.selectTrack(match.first);
      }
    }
    final subtitle = item.subtitle;
    if (subtitle != null) {
      if (subtitle.off) {
        await notifier.disableTracks(NativeVideoTrackType.text);
      } else if (subtitle.language != null) {
        final match = tracks.where(
          (t) => t.type == NativeVideoTrackType.text && _sameLanguage(t.language, subtitle.language!),
        );
        if (match.isNotEmpty) {
          await notifier.selectTrack(match.first);
        }
      }
    }
  }

  static bool _sameLanguage(String? a, String b) =>
      a != null && a.toLowerCase().split(RegExp('[-_]')).first == b.toLowerCase().split(RegExp('[-_]')).first;

  @override
  Future<void> pause() async {
    await _notifier?.pause();
    await _follow();
  }

  @override
  Future<void> resume() async {
    final notifier = _notifier;
    if (notifier == null) {
      return;
    }
    final status = _ref.read(videoPlayerProvider(_playerKey!)).status;
    await (status == VideoPlaybackStatus.completed ? notifier.restart() : notifier.play());
    await _follow();
  }

  @override
  Future<void> seek(int positionMs) async {
    _notifier?.seekTo(Duration(milliseconds: positionMs));
    // The position the phone asked for, at once: the player tells its own at the next poll
    if (_notifier != null) {
      _set((state) => state.next(positionMs: positionMs));
    }
  }

  @override
  Future<void> track(PlayTrackKind kind, String? id) async {
    final notifier = _notifier;
    if (notifier == null) {
      return;
    }
    if (id == null) {
      await notifier.disableTracks(NativeVideoTrackType.text);
    } else {
      final tracks = await notifier.tracks();
      final chosen = tracks.where((track) => playTrackId(track) == id).firstOrNull;
      if (chosen != null) {
        await notifier.selectTrack(chosen);
      }
    }
    await notifier.tracks();
    await _follow();
  }

  @override
  Future<void> stop() async {
    final key = _playerKey;
    _stopPolling();
    _playerKey = null;
    _pendingTracks = null;
    if (key != null && _ref.exists(videoPlayerProvider(key))) {
      await _ref.read(screenPlayerCloseProvider)();
    }
    _set((state) => state.next(phase: ScreenPlayPhase.idle, clearReason: true));
  }

  @override
  Future<bool> askHandover({
    required LinkedPeer from,
    required String server,
    required String check,
    required Future<void> cancel,
  }) => _prompts.askHandover(phone: from.name, server: server, check: check, cancel: cancel);

  @override
  Future<HandoverResult> addServer(HandedPlexServer server, String token) =>
      _ref.read(screenPlexHandoverProvider)(server, token);
}

/// The id of a track of the native player, as the phone sends it back
String playTrackId(NativeVideoTrack track) => '${track.groupIndex}.${track.trackIndex}';

/// A track of the native player as the phone shows it
PlayTrack? playTrackOf(NativeVideoTrack track) => PlayTrack(
  kind: track.type == NativeVideoTrackType.audio ? PlayTrackKind.audio : PlayTrackKind.subtitle,
  id: playTrackId(track),
  label: [
    track.languageName ?? track.language,
    track.label,
    if (track.channels > 2) '${track.channels} ch',
  ].whereType<String>().where((part) => part.isNotEmpty).join(' · '),
  language: track.language,
  selected: track.selected,
);

/// Opens a route for a play of a phone: in place of the player of a film playing, else over the page shown
final screenPlayerOpenProvider = Provider<ScreenPlayerOpen>((ref) {
  return (route, {required replace}) async {
    final router = ref.read(appRouterProvider);
    if (replace) {
      unawaited(router.replace(route));
    } else {
      unawaited(router.push(route));
    }
  };
});

/// Closes the player a play of a phone opened: Stop on the phone
final screenPlayerCloseProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final router = ref.read(appRouterProvider);
    if (router.current.name == NetworkVideoRoute.name) {
      router.pop();
    }
  };
});

/// "Add (server) to (screen)" once both users accepted: the screen checks the server with the token as its own Plex
/// page does (the pinned certificate, the identity, the libraries), then keeps it as a source, or gives the token to
/// the source of that server it already has
final screenPlexHandoverProvider = Provider<Future<HandoverResult> Function(HandedPlexServer server, String token)>((
  ref,
) {
  return (server, token) async {
    final pairing = PlexPairing();
    final candidates = <({String host, int port})>[
      if (server.host.isNotEmpty) (host: server.host, port: server.port ?? plexDefaultPort),
      if (server.publicHost case final publicHost?) (host: publicHost, port: server.publicPort ?? plexDefaultPort),
    ];
    PlexTokenCheck? check;
    var result = HandoverResult.unreachable;
    for (final candidate in candidates) {
      try {
        final found = await pairing.lookUp(
          parsePlexAddress('${candidate.host}:${candidate.port}'),
          knownHash: server.hash,
        );
        if (found.machineIdentifier != server.machineIdentifier) {
          result = HandoverResult.otherServer;
          continue;
        }
        check = await pairing.testToken(found, token);
        break;
      } on PlexFileSystemException catch (error) {
        result = switch (error.failure) {
          PlexFailure.tokenRefused || PlexFailure.tokenForbidden => HandoverResult.tokenRefused,
          PlexFailure.otherServer || PlexFailure.wrongCertificate || PlexFailure.notPlex => HandoverResult.otherServer,
          PlexFailure.unreachable || PlexFailure.unreachableOutsideHome => HandoverResult.unreachable,
          _ => HandoverResult.failed,
        };
        if (result == HandoverResult.tokenRefused) {
          break;
        }
      } catch (error) {
        _log.info('Play from a phone: the handed server did not answer (${error.runtimeType})');
      }
    }
    if (check == null) {
      return result;
    }
    final sources = ref.read(networkSourcesProvider.notifier);
    final existing = ref
        .read(networkSourcesProvider)
        .where(
          (source) =>
              source.type == NetworkSourceType.plex && source.discoveryId?.toLowerCase() == server.machineIdentifier,
        )
        .firstOrNull;
    final plex = PlexServerInfo(
      hash: server.hash,
      publicHost: server.publicHost,
      publicPort: server.publicPort,
      version: check.version,
    );
    if (existing != null) {
      await sources.update(existing.copyWith(plex: plex), password: token);
    } else {
      await sources.add(
        NetworkSource(
          id: NetworkSourcesNotifier.newId(),
          type: NetworkSourceType.plex,
          name: server.name,
          host: server.host,
          port: server.port == plexDefaultPort ? null : server.port,
          rootPath: server.rootPath,
          useTls: true,
          discoveryId: server.machineIdentifier,
          plex: plex,
        ),
        password: token,
      );
    }
    _log.info('Play from a phone: a Plex server was added from a phone');
    return HandoverResult.added;
  };
});
