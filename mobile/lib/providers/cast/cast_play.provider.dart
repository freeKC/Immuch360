// "Play on..." through Google Cast (experimental): the Cast devices found nearby, what the Plex metadata tells of the
// film before casting, and the session with the device a film plays on.
//
// A cast: the phone binds its relay (cast_relay.dart) to its address on the device's network and makes a one time
// path for the film and its poster; connects to the device (cast_channel.dart), launches the default media receiver
// (CC1AD845), connects to it and sends the LOAD (cast_media.dart) with the relay's addresses; then follows the
// receiver's status for the controls of the sheet and of the dock (play, pause, seek, volume, stop, the position).
// The session and the relay belong to this provider, which lives as long as the app: the pages can come and go.
// Stop, a film that ends badly, another sender taking the device or the connection lost revoke the path and close
// the relay.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_channel.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('CastPlay');

const castServiceType = '_googlecast._tcp';

/// How the phone browses mDNS for Cast devices, replaced in the tests
final castBrowseProvider = Provider<MdnsBrowser>(
  (_) =>
      (type, until) => bonsoirBrowse(type, until, lost: true),
);

/// The Cast devices found while something watches it (the "Play on" sheet), and whether the first look is still on
@immutable
class CastDiscovery {
  const CastDiscovery({this.byService = const {}, this.searching = true});

  /// By mDNS service name, which a "lost" answer gives alone
  final Map<String, CastTarget> byService;
  final bool searching;

  List<CastTarget> get devices => byService.values.toList();

  CastDiscovery copyWith({Map<String, CastTarget>? byService, bool? searching}) =>
      CastDiscovery(byService: byService ?? this.byService, searching: searching ?? this.searching);
}

class CastDevicesNotifier extends AutoDisposeNotifier<CastDiscovery> {
  /// How long the sheet says it is looking before "No Cast device found"
  static const firstLook = Duration(seconds: 6);

  final _stop = Completer<void>();

  @override
  CastDiscovery build() {
    final browse = ref.read(castBrowseProvider);
    final subscription = browse(
      castServiceType,
      _stop.future,
    ).listen((service) => unawaited(_seen(service)), onError: (Object _) {});
    final timer = Timer(firstLook, () => state = state.copyWith(searching: false));
    ref.onDispose(() {
      timer.cancel();
      if (!_stop.isCompleted) {
        _stop.complete();
      }
      unawaited(subscription.cancel());
    });
    return const CastDiscovery();
  }

  Future<void> _seen(MdnsService service) async {
    if (service.lost) {
      if (state.byService.containsKey(service.name)) {
        state = state.copyWith(byService: {...state.byService}..remove(service.name));
      }
      return;
    }
    final host = isPrivatePairingIPv4(service.host) ? service.host : await lookupIPv4(service.host);
    if (host == null) {
      return;
    }
    final target = castTargetOf(
      serviceName: service.name,
      host: host,
      port: service.port,
      attributes: service.attributes,
    );
    if (target != null) {
      state = state.copyWith(byService: {...state.byService, service.name: target});
    }
  }

  /// A device found otherwise (the tests)
  @visibleForTesting
  void put(String serviceName, CastTarget target) =>
      state = state.copyWith(byService: {...state.byService, serviceName: target});
}

final castDevicesProvider = NotifierProvider.autoDispose<CastDevicesNotifier, CastDiscovery>(CastDevicesNotifier.new);

/// What the phone knows of the film before casting it: its texts, the file to send and its format
@immutable
class CastFilmInfo {
  const CastFilmInfo({
    required this.title,
    required this.path,
    required this.format,
    this.year,
    this.durationMs,
    this.thumb,
    this.fileName,
  });

  final String title;
  final int? year;
  final int? durationMs;

  /// The poster's request path on the server, for its photo transcoder
  final String? thumb;

  /// The file's path on this phone's connection, which the media bridge serves
  final String path;
  final String? fileName;
  final CastFilmFormat format;
}

/// The version of [details] the file [path] is (its last segment), else the first one with a file
({PlexFilmMedia? media, PlexFilmPart? part}) castPartOf(PlexFilmDetails details, String? path) {
  final name = path?.split('/').where((segment) => segment.isNotEmpty).lastOrNull;
  PlexFilmPart? part;
  if (name != null) {
    part = details.parts.where((candidate) => candidate.fileName == name).firstOrNull;
  }
  part ??= details.parts.firstOrNull;
  return (media: part == null ? details.medias.firstOrNull : details.mediaOf(part), part: part);
}

/// The format a receiver meets in [part] of [media]: the file's default sound track is the one it plays
CastFilmFormat castFormatOf(PlexFilmMedia? media, PlexFilmPart? part) {
  final audio = part?.streamsOf(PlexStreamType.audio) ?? const <PlexStream>[];
  final played = audio.where((stream) => stream.isDefault).firstOrNull ?? audio.firstOrNull;
  final video = part?.streamsOf(PlexStreamType.video).firstOrNull;
  return CastFilmFormat(
    container: part?.container ?? media?.container,
    videoCodec: video?.codec ?? media?.videoCodec,
    audioCodec: played?.codec ?? media?.audioCodec,
    width: media?.width,
    height: media?.height,
  );
}

/// What the cast of a film needs from the app and the device, replaced in the tests
class CastEnvironment {
  const CastEnvironment({
    required this.connect,
    required this.localAddresses,
    required this.bindRelay,
    required this.filmInfo,
    required this.bridgeUrl,
    required this.poster,
    this.heartbeat = const Duration(seconds: 5),
    this.statusEvery = const Duration(seconds: 5),
    this.answerTimeout = const Duration(seconds: 30),
  });

  final Future<CastChannel> Function(CastTarget target) connect;

  /// This phone's IPv4 addresses
  final Future<List<String>> Function() localAddresses;
  final Future<CastRelayServer> Function(String address) bindRelay;
  final Future<CastFilmInfo?> Function(PlayOnRequest request) filmInfo;

  /// The media bridge's address of a file, asked at each request of the device
  final Future<Uri> Function(String sourceId, String path) bridgeUrl;

  /// The poster's bytes, null when there is none
  final Future<Uint8List?> Function(String sourceId, String thumb) poster;
  final Duration heartbeat;

  /// How often the status is asked while a film plays (the position between two is counted on the phone)
  final Duration statusEvery;

  /// How long the launch and the LOAD may take each
  final Duration answerTimeout;
}

Future<CastFilmInfo?> _readFilmInfo(Ref ref, PlayOnRequest request) async {
  final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(request.sourceId);
  if (fileSystem is! PlexFileSystem) {
    return null;
  }
  final details = await fileSystem.filmDetails(request.ratingKey);
  final (:media, :part) = castPartOf(details, request.path);
  final path = request.path ?? await fileSystem.pathOfItem(request.ratingKey);
  return CastFilmInfo(
    title: details.title.isNotEmpty ? details.title : (request.title ?? ''),
    year: details.year,
    durationMs: part?.durationMs ?? details.durationMs,
    thumb: details.thumb,
    path: path,
    fileName: part?.fileName,
    format: castFormatOf(media, part),
  );
}

final castEnvironmentProvider = Provider<CastEnvironment>((ref) {
  return CastEnvironment(
    connect: (target) => CastSocketChannel.connect(target.host, target.port),
    localAddresses: phoneShareLocalAddresses,
    bindRelay: (address) => CastRelayServer.bind(address),
    filmInfo: (request) => _readFilmInfo(ref, request),
    bridgeUrl: (sourceId, path) async {
      await ref.read(mediaBridgeProvider).start();
      return ref.read(networkConnectionsProvider).mediaUrl(sourceId, path);
    },
    poster: (sourceId, thumb) async {
      final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(sourceId);
      return fileSystem is PlexFileSystem ? fileSystem.picture(thumb, width: 480, height: 720) : null;
    },
  );
});

/// The film's information for the sheet's check, by source, rating key and path
final castFilmInfoProvider = FutureProvider.autoDispose.family<CastFilmInfo?, (String, String, String?)>((ref, key) {
  final (sourceId, ratingKey, path) = key;
  return ref
      .read(castEnvironmentProvider)
      .filmInfo(PlayOnRequest(sourceId: sourceId, server: '', serverName: '', ratingKey: ratingKey, path: path));
});

/// Where a cast is
enum CastPhase { connecting, loading, buffering, playing, paused, ended, failed, takenOver, lost }

/// Why a cast did not start or stopped
enum CastFailure {
  /// This phone has no address on the device's network
  noNetwork,

  /// The film's file or its information could not be read
  film,

  /// The device did not answer
  unreachable,

  /// The device would not start its media receiver
  launch,

  /// The receiver could not play the film
  load,
}

/// What the controls show
@immutable
class CastPlayback {
  const CastPlayback({
    required this.target,
    required this.request,
    required this.title,
    required this.phase,
    required this.at,
    this.positionMs = 0,
    this.durationMs,
    this.rate = 1,
    this.volume,
    this.muted = false,
    this.failure,
  });

  final CastTarget target;
  final PlayOnRequest request;
  final String title;
  final CastPhase phase;

  /// Where the receiver was at [at]
  final int positionMs;
  final DateTime at;
  final int? durationMs;
  final double rate;

  /// The device's volume, 0 to 1, once it told it
  final double? volume;
  final bool muted;
  final CastFailure? failure;

  bool get isPlaying => phase == CastPhase.playing;

  /// Whether the controls still drive something
  bool get live =>
      phase == CastPhase.connecting ||
      phase == CastPhase.loading ||
      phase == CastPhase.buffering ||
      phase == CastPhase.playing ||
      phase == CastPhase.paused;

  /// Whether this is the file at [path] of the source [sourceId]
  bool isOf(String sourceId, String path) => request.sourceId == sourceId && request.path == path;

  /// The position at [now]: the last one told, moved on by the time since while playing
  int positionAt(DateTime now) {
    var position = positionMs;
    if (phase == CastPhase.playing) {
      position += (now.difference(at).inMilliseconds * rate).round();
    }
    final duration = durationMs;
    if (duration != null && duration > 0 && position > duration) {
      position = duration;
    }
    return position < 0 ? 0 : position;
  }

  CastPlayback copyWith({
    CastPhase? phase,
    int? positionMs,
    DateTime? at,
    int? durationMs,
    double? rate,
    double? volume,
    bool? muted,
    CastFailure? failure,
  }) => CastPlayback(
    target: target,
    request: request,
    title: title,
    phase: phase ?? this.phase,
    positionMs: positionMs ?? this.positionMs,
    at: at ?? this.at,
    durationMs: durationMs ?? this.durationMs,
    rate: rate ?? this.rate,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    failure: failure ?? this.failure,
  );
}

/// How a cast went, for the sheet
enum CastOutcome { playing, noNetwork, film, unreachable, launch, load }

/// See the top of this file: the cast under way, null while none
class CastPlaybackController extends Notifier<CastPlayback?> {
  CastChannel? _channel;
  // ignore: cancel_subscriptions, cancelled by _tearDown, which takes every field before its first await
  StreamSubscription<CastChannelMessage>? _messages;
  CastRelayServer? _relay;
  CastRelayLease? _lease;
  Timer? _heartbeat;
  Timer? _statusTimer;
  String? _transportId;
  String? _sessionId;
  int? _mediaSessionId;
  CastFilm? _film;
  Completer<CastOutcome>? _started;
  int _generation = 0;

  DateTime Function() clock = DateTime.now;

  CastEnvironment get _environment => ref.read(castEnvironmentProvider);

  @override
  CastPlayback? build() {
    ref.onDispose(() {
      _generation++;
      unawaited(_tearDown());
    });
    return null;
  }

  /// Casts [request] to [target]; the outcome once the receiver plays it or could not
  Future<CastOutcome> cast(CastTarget target, PlayOnRequest request) async {
    final generation = ++_generation;
    await _tearDown(stopReceiver: state?.target != target);
    state = CastPlayback(
      target: target,
      request: request,
      title: request.title ?? '',
      phase: CastPhase.connecting,
      at: clock(),
      positionMs: request.offsetMs,
    );
    final environment = _environment;

    final address = castRelayAddressFor(await environment.localAddresses(), target.host);
    if (address == null) {
      return _fail(generation, CastOutcome.noNetwork, CastFailure.noNetwork);
    }

    final CastFilmInfo? info;
    final Uint8List? poster;
    try {
      info = await environment.filmInfo(request);
      if (info == null) {
        return _fail(generation, CastOutcome.film, CastFailure.film);
      }
      final thumb = info.thumb;
      poster = thumb == null ? null : await environment.poster(request.sourceId, thumb).catchError((_) => null);
    } catch (error) {
      _log.info('Cast: the film could not be read (${error.runtimeType})');
      return _fail(generation, CastOutcome.film, CastFailure.film);
    }
    if (generation != _generation) {
      return CastOutcome.film;
    }

    final CastRelayServer relay;
    try {
      relay = await environment.bindRelay(address);
    } catch (error) {
      _log.info('Cast: the relay could not listen (${error.runtimeType})');
      return _fail(generation, CastOutcome.noNetwork, CastFailure.noNetwork);
    }
    _relay = relay;
    final lease = _lease = relay.lease(
      CastRelayContent(film: () => environment.bridgeUrl(request.sourceId, info!.path), poster: poster),
    );
    final title = info.title.isNotEmpty ? info.title : (request.title ?? info.fileName ?? '');
    _film = CastFilm(
      contentUrl: lease.filmUrl,
      contentType: castContentTypeOf(container: info.format.container, fileName: info.fileName),
      title: title,
      year: info.year,
      posterUrl: lease.posterUrl,
      durationMs: info.durationMs,
      startMs: request.offsetMs,
    );
    state = CastPlayback(
      target: target,
      request: request,
      title: title,
      phase: CastPhase.connecting,
      at: clock(),
      positionMs: request.offsetMs,
      durationMs: info.durationMs,
    );

    final CastChannel channel;
    try {
      channel = await environment.connect(target);
    } catch (error) {
      _log.info('Cast: the device did not answer (${error.runtimeType})');
      return _fail(generation, CastOutcome.unreachable, CastFailure.unreachable);
    }
    if (generation != _generation) {
      unawaited(channel.close());
      return CastOutcome.unreachable;
    }
    _channel = channel;
    final started = _started = Completer<CastOutcome>();
    _messages = channel.messages.listen(
      (message) => _onMessage(generation, message),
      onError: (Object _) {},
      onDone: () => _onClosed(generation),
    );
    channel.send(castNamespaceConnection, {'type': 'CONNECT'});
    channel.send(castNamespaceReceiver, {'type': 'LAUNCH', 'appId': castDefaultReceiverAppId});
    _heartbeat = Timer.periodic(environment.heartbeat, (_) => channel.send(castNamespaceHeartbeat, {'type': 'PING'}));
    state = state?.copyWith(phase: CastPhase.loading);

    return started.future.timeout(
      environment.answerTimeout * 2,
      onTimeout: () => _fail(
        generation,
        _transportId == null ? CastOutcome.launch : CastOutcome.load,
        _transportId == null ? CastFailure.launch : CastFailure.load,
      ),
    );
  }

  CastOutcome _fail(int generation, CastOutcome outcome, CastFailure failure) {
    if (generation == _generation) {
      final playback = state;
      if (playback != null) {
        state = playback.copyWith(phase: CastPhase.failed, failure: failure, at: clock());
      }
      unawaited(_tearDown(stopReceiver: _transportId != null));
    }
    _complete(outcome);
    return outcome;
  }

  void _complete(CastOutcome outcome) {
    final started = _started;
    if (started != null && !started.isCompleted) {
      started.complete(outcome);
    }
  }

  void _onMessage(int generation, CastChannelMessage message) {
    if (generation != _generation) {
      return;
    }
    final payload = message.payload;
    final type = payload['type'];
    switch (message.namespace) {
      case castNamespaceHeartbeat:
        if (type == 'PING') {
          _channel?.send(castNamespaceHeartbeat, {'type': 'PONG'}, destination: message.source);
        }
      case castNamespaceConnection:
        if (type == 'CLOSE' && message.source == _transportId) {
          _end(generation, CastPhase.takenOver);
        }
      case castNamespaceReceiver:
        if (type == 'RECEIVER_STATUS') {
          _onReceiverStatus(generation, payload);
        } else if (type == 'LAUNCH_ERROR' || (type == 'INVALID_REQUEST' && _transportId == null)) {
          _fail(generation, CastOutcome.launch, CastFailure.launch);
        }
      case castNamespaceMedia:
        if (type == 'MEDIA_STATUS') {
          _onMediaStatus(generation, payload);
        } else if (type == 'LOAD_FAILED' || type == 'LOAD_CANCELLED' || type == 'INVALID_REQUEST') {
          if (_mediaSessionId == null) {
            _fail(generation, CastOutcome.load, CastFailure.load);
          }
        }
    }
  }

  void _onReceiverStatus(int generation, Map<String, Object?> payload) {
    final status = payload['status'];
    if (status is! Map) {
      return;
    }
    final volume = status['volume'];
    if (volume is Map && state != null) {
      final level = volume['level'];
      final muted = volume['muted'];
      state = state!.copyWith(volume: level is num ? level.toDouble() : null, muted: muted is bool ? muted : null);
    }
    final applications = status['applications'];
    final ours = applications is List
        ? applications.whereType<Map>().where((app) => app['appId'] == castDefaultReceiverAppId).firstOrNull
        : null;
    final transport = ours?['transportId'];
    final session = ours?['sessionId'];
    if (_transportId == null) {
      if (transport is String && session is String) {
        _transportId = transport;
        _sessionId = session;
        final channel = _channel;
        final film = _film;
        if (channel != null && film != null) {
          channel.send(castNamespaceConnection, {'type': 'CONNECT'}, destination: transport);
          channel.send(castNamespaceMedia, castLoadMessage(film), destination: transport);
        }
      }
      return;
    }
    // The receiver of this cast is gone from the device: another app or sender took it
    if (ours == null || session != _sessionId) {
      _end(generation, CastPhase.takenOver);
    }
  }

  void _onMediaStatus(int generation, Map<String, Object?> payload) {
    final list = payload['status'];
    final status = list is List ? list.whereType<Map>().firstOrNull : null;
    final playback = state;
    if (status == null || playback == null) {
      return;
    }
    final session = status['mediaSessionId'];
    if (session is int) {
      _mediaSessionId = session;
    }
    final current = status['currentTime'];
    final media = status['media'];
    final duration = media is Map ? media['duration'] : null;
    final rate = status['playbackRate'];
    final phase = switch (status['playerState']) {
      'PLAYING' => CastPhase.playing,
      'PAUSED' => CastPhase.paused,
      'BUFFERING' || 'LOADING' => CastPhase.buffering,
      'IDLE' => switch (status['idleReason']) {
        'FINISHED' => CastPhase.ended,
        'ERROR' => CastPhase.failed,
        'INTERRUPTED' || 'CANCELLED' => CastPhase.takenOver,
        _ => null,
      },
      _ => null,
    };
    state = playback.copyWith(
      phase: phase,
      positionMs: current is num ? (current * 1000).round() : null,
      at: current is num ? clock() : null,
      durationMs: duration is num && duration > 0 ? (duration * 1000).round() : null,
      rate: rate is num ? rate.toDouble() : null,
      failure: phase == CastPhase.failed ? CastFailure.load : null,
    );
    if (phase == CastPhase.playing || phase == CastPhase.paused || phase == CastPhase.buffering) {
      _complete(CastOutcome.playing);
      _statusTimer ??= Timer.periodic(_environment.statusEvery, (_) => _askStatus());
    } else if (phase == CastPhase.failed) {
      _fail(generation, CastOutcome.load, CastFailure.load);
    } else if (phase == CastPhase.ended || phase == CastPhase.takenOver) {
      _end(generation, phase!);
    }
  }

  void _onClosed(int generation) {
    if (generation != _generation) {
      return;
    }
    final playback = state;
    if (_started?.isCompleted == false) {
      _fail(generation, CastOutcome.unreachable, CastFailure.unreachable);
      return;
    }
    if (playback != null && playback.live) {
      state = playback.copyWith(phase: CastPhase.lost, at: clock());
    }
    unawaited(_tearDown(stopReceiver: false));
  }

  /// The cast ended on the device: the controls say so and offer to close; the relay forgets the film
  void _end(int generation, CastPhase phase) {
    if (generation != _generation) {
      return;
    }
    final playback = state;
    if (playback != null) {
      state = playback.copyWith(phase: phase, at: clock());
    }
    _complete(phase == CastPhase.ended ? CastOutcome.playing : CastOutcome.load);
    unawaited(_tearDown(stopReceiver: false));
  }

  void _askStatus() {
    final transport = _transportId;
    if (transport == null) {
      return;
    }
    _channel?.send(castNamespaceMedia, {
      'type': 'GET_STATUS',
      'mediaSessionId': ?_mediaSessionId,
    }, destination: transport);
  }

  void _media(Map<String, Object?> command) {
    final transport = _transportId;
    final session = _mediaSessionId;
    if (transport == null || session == null) {
      return;
    }
    _channel?.send(castNamespaceMedia, {...command, 'mediaSessionId': session}, destination: transport);
  }

  void play() {
    _media({'type': 'PLAY'});
    _optimistic(CastPhase.playing);
  }

  void pause() {
    _media({'type': 'PAUSE'});
    _optimistic(CastPhase.paused);
  }

  /// Shows the asked state until the receiver tells its own
  void _optimistic(CastPhase phase) {
    final playback = state;
    if (playback != null && playback.live) {
      final now = clock();
      state = playback.copyWith(phase: phase, positionMs: playback.positionAt(now), at: now);
    }
  }

  void seekTo(Duration position) {
    final playback = state;
    var target = position.inMilliseconds;
    final duration = playback?.durationMs;
    if (duration != null && duration > 0 && target > duration) {
      target = duration;
    }
    if (target < 0) {
      target = 0;
    }
    _media({'type': 'SEEK', 'currentTime': target / 1000});
    if (playback != null && playback.live) {
      state = playback.copyWith(positionMs: target, at: clock());
    }
  }

  void seekBy(Duration delta) {
    final playback = state;
    if (playback != null) {
      seekTo(Duration(milliseconds: playback.positionAt(clock()) + delta.inMilliseconds));
    }
  }

  /// The device's volume, 0 to 1
  void setVolume(double level) {
    final value = level.clamp(0.0, 1.0);
    _channel?.send(castNamespaceReceiver, {
      'type': 'SET_VOLUME',
      'volume': {'level': value},
    });
    final playback = state;
    if (playback != null) {
      state = playback.copyWith(volume: value);
    }
  }

  /// Stops the film on the device and closes its receiver, the connection and the relay; the controls go
  Future<void> stop() async {
    _generation++;
    await _tearDown(stopReceiver: true);
    state = null;
  }

  /// Forgets a cast that ended, failed or was lost
  Future<void> dismiss() => stop();

  Future<void> _tearDown({bool stopReceiver = true}) async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _statusTimer?.cancel();
    _statusTimer = null;
    _lease?.revoke();
    _lease = null;
    final channel = _channel;
    _channel = null;
    final messages = _messages;
    _messages = null;
    final relay = _relay;
    _relay = null;
    final transport = _transportId;
    final session = _sessionId;
    final media = _mediaSessionId;
    _transportId = null;
    _sessionId = null;
    _mediaSessionId = null;
    _film = null;
    await messages?.cancel();
    if (channel != null) {
      if (stopReceiver && transport != null) {
        if (media != null) {
          channel.send(castNamespaceMedia, {'type': 'STOP', 'mediaSessionId': media}, destination: transport);
        }
        if (session != null) {
          channel.send(castNamespaceReceiver, {'type': 'STOP', 'sessionId': session});
        }
        channel.send(castNamespaceConnection, {'type': 'CLOSE'}, destination: transport);
      }
      try {
        await channel.close();
      } catch (_) {}
    }
    try {
      await relay?.close();
    } on SocketException catch (_) {}
  }
}

final castPlaybackProvider = NotifierProvider<CastPlaybackController, CastPlayback?>(CastPlaybackController.new);
