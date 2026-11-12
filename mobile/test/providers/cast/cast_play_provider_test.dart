// The cast of a Plex film: the launch of the default media receiver, the LOAD with the relay's one time address (and
// no token), the receiver's status, the controls, Stop, and the ways a cast fails or ends; a device simulated on a
// fake channel, the relay real on the loopback in front of a fake media bridge

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_channel.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

const _token = 'plex-token-secret-42';
const _transport = 'web-5';
const _session = 'session-1';

typedef _Sent = ({String namespace, String destination, Map<String, Object?> payload});

/// A Cast device on the other end: answers the launch and the LOAD as [onLaunch] and [onLoad] say
class _Device implements CastChannel {
  final _controller = StreamController<CastChannelMessage>.broadcast();
  final List<_Sent> sent = [];
  bool closed = false;

  /// The receiver status after LAUNCH, null for none
  Map<String, Object?>? Function() onLaunch = () => _receiverStatus(castDefaultReceiverAppId);

  /// The answer to LOAD, null for none
  Map<String, Object?>? Function(Map<String, Object?> load) onLoad = (load) =>
      _mediaStatus('PLAYING', currentTime: (load['currentTime']! as num).toDouble());

  @override
  Stream<CastChannelMessage> get messages => _controller.stream;

  void tell(String namespace, Map<String, Object?> payload, {String source = castReceiverId}) => scheduleMicrotask(
    () => _controller.add(CastChannelMessage(namespace: namespace, source: source, payload: payload)),
  );

  @override
  void send(String namespace, Map<String, Object?> payload, {String destination = castReceiverId}) {
    sent.add((namespace: namespace, destination: destination, payload: payload));
    if (namespace == castNamespaceReceiver && payload['type'] == 'LAUNCH') {
      final status = onLaunch();
      if (status != null) {
        tell(castNamespaceReceiver, status);
      }
    }
    if (namespace == castNamespaceMedia && payload['type'] == 'LOAD') {
      final answer = onLoad(payload);
      if (answer != null) {
        tell(castNamespaceMedia, answer, source: _transport);
      }
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  /// The connection drops
  Future<void> drop() => _controller.close();

  List<_Sent> of(String type) => [
    for (final message in sent)
      if (message.payload['type'] == type) message,
  ];
}

Map<String, Object?> _receiverStatus(String? appId, {String session = _session, double level = 0.4}) => {
  'type': 'RECEIVER_STATUS',
  'status': {
    'applications': [
      if (appId != null) {'appId': appId, 'sessionId': session, 'transportId': _transport, 'displayName': 'Default'},
    ],
    'volume': {'level': level, 'muted': false},
  },
};

Map<String, Object?> _mediaStatus(String state, {double currentTime = 0, String? idleReason}) => {
  'type': 'MEDIA_STATUS',
  'status': [
    {
      'mediaSessionId': 3,
      'playerState': state,
      'currentTime': currentTime,
      'playbackRate': 1,
      'idleReason': ?idleReason,
      'media': {'duration': 7320.0},
    },
  ],
};

const _target = CastTarget(id: 'cc1', name: 'Living room', host: '192.168.1.42', port: 8009, model: 'Chromecast');

const _request = PlayOnRequest(
  sourceId: 'source-1',
  server: 'abcdef',
  serverName: 'Home Plex',
  ratingKey: '77',
  title: 'Amélie',
  offsetMs: 61000,
  path: '/.item/77/amelie.mkv',
);

const _info = CastFilmInfo(
  title: 'Le Fabuleux Destin d\'Amélie Poulain',
  year: 2001,
  durationMs: 7320000,
  thumb: '/library/metadata/77/thumb/1',
  path: '/.item/77/amelie.mkv',
  fileName: 'amelie.mkv',
  format: CastFilmFormat(container: 'mkv', videoCodec: 'h264', audioCodec: 'aac'),
);

void main() {
  final film = Uint8List.fromList(List<int>.generate(2048, (index) => index % 256));
  late HttpServer bridge;
  late _Device device;
  late ProviderContainer container;
  late List<String> addresses;
  late List<CastRelayServer> relays;
  late int connects;

  setUp(() async {
    bridge = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    bridge.listen((request) async {
      request.response.headers.contentType = ContentType('video', 'x-matroska');
      request.response.add(film);
      await request.response.close();
    });
    device = _Device();
    addresses = ['10.8.0.3', '192.168.1.20'];
    relays = [];
    connects = 0;
    container = ProviderContainer(
      overrides: [
        castEnvironmentProvider.overrideWithValue(
          CastEnvironment(
            connect: (target) async {
              connects++;
              return device;
            },
            localAddresses: () async => addresses,
            bindRelay: (address) async {
              expect(address, '192.168.1.20');
              final relay = await CastRelayServer.bind('127.0.0.1', port: 0);
              relays.add(relay);
              return relay;
            },
            filmInfo: (request) async => _info,
            bridgeUrl: (sourceId, path) async =>
                Uri.parse('http://127.0.0.1:${bridge.port}/bridge/$sourceId$path?X-Plex-Token=never-here'),
            poster: (sourceId, thumb) async => Uint8List.fromList([0xff, 0xd8, 1]),
            heartbeat: const Duration(hours: 1),
            statusEvery: const Duration(hours: 1),
            answerTimeout: const Duration(seconds: 2),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    await container.read(castPlaybackProvider.notifier).stop();
    container.dispose();
    for (final relay in relays) {
      await relay.close();
    }
    await bridge.close(force: true);
  });

  CastPlaybackController controller() => container.read(castPlaybackProvider.notifier);
  CastPlayback? playback() => container.read(castPlaybackProvider);

  Future<List<int>> fetch(Uri url) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(url)).close();
      final body = <int>[];
      await response.forEach(body.addAll);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('status ${response.statusCode}');
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  test('launches the default receiver, then LOADs the film from the relay: playing', () async {
    final outcome = await controller().cast(_target, _request);
    expect(outcome, CastOutcome.playing);

    expect(device.sent.first.namespace, castNamespaceConnection);
    expect(device.sent.first.destination, castReceiverId);
    final launch = device.of('LAUNCH').single;
    expect(launch.payload['appId'], 'CC1AD845');
    final connects = device.of('CONNECT');
    expect(connects.map((message) => message.destination), [castReceiverId, _transport]);

    final load = device.of('LOAD').single;
    expect(load.namespace, castNamespaceMedia);
    expect(load.destination, _transport);
    expect(load.payload['currentTime'], 61);
    final media = load.payload['media']! as Map<String, Object?>;
    final url = Uri.parse(media['contentUrl']! as String);
    expect(url.path, matches(RegExp(r'^/cast/[0-9a-f]{32}/film$')));
    expect(media['contentType'], 'video/mp4');
    final metadata = media['metadata']! as Map<String, Object?>;
    expect(metadata['title'], 'Le Fabuleux Destin d\'Amélie Poulain');
    expect(metadata['subtitle'], '2001');

    // No token, no bridge token, no server address in anything the device was sent
    final everything = jsonEncode([for (final message in device.sent) message.payload]);
    expect(everything, isNot(contains(_token)));
    expect(everything, isNot(contains('never-here')));
    expect(everything.toLowerCase(), isNot(contains('x-plex')));
    expect(everything, isNot(contains('/bridge/')));

    // The relay serves the film and the poster under those addresses
    expect(await fetch(url), film);
    final images = metadata['images']! as List;
    expect(await fetch(Uri.parse((images.single as Map)['url']! as String)), [0xff, 0xd8, 1]);

    final state = playback()!;
    expect(state.phase, CastPhase.playing);
    expect(state.title, 'Le Fabuleux Destin d\'Amélie Poulain');
    expect(state.durationMs, 7320000);
    expect(state.positionMs, 61000);
    expect(state.volume, 0.4);
    expect(state.live, isTrue);
  });

  test('the controls: pause, play, seek, volume, each to the right end with the media session', () async {
    await controller().cast(_target, _request);
    controller().pause();
    expect(playback()!.phase, CastPhase.paused);
    controller().play();
    controller().seekTo(const Duration(seconds: 90));
    controller().setVolume(0.7);

    final pause = device.of('PAUSE').single;
    expect(pause.destination, _transport);
    expect(pause.payload['mediaSessionId'], 3);
    expect(device.of('PLAY').single.payload['mediaSessionId'], 3);
    final seek = device.of('SEEK').single;
    expect(seek.payload['currentTime'], 90);
    expect(seek.payload['mediaSessionId'], 3);
    final volume = device.of('SET_VOLUME').single;
    expect(volume.namespace, castNamespaceReceiver);
    expect(volume.destination, castReceiverId);
    expect(volume.payload['volume'], {'level': 0.7});
    expect(playback()!.positionMs, 90000);
    expect(playback()!.volume, 0.7);
  });

  test('the position moves on between two statuses while playing, and stops at the duration', () async {
    var now = DateTime.utc(2026, 11, 11, 23);
    controller().clock = () => now;
    await controller().cast(_target, _request);
    now = now.add(const Duration(seconds: 5));
    expect(playback()!.positionAt(now), 66000);
    expect(playback()!.positionAt(now.add(const Duration(hours: 3))), 7320000);
  });

  test('Stop: the media and the receiver stopped, the connection closed, the path gone, no controls', () async {
    await controller().cast(_target, _request);
    final load = device.of('LOAD').single.payload['media']! as Map<String, Object?>;
    final url = Uri.parse(load['contentUrl']! as String);
    await controller().stop();

    expect(device.of('STOP').map((message) => message.namespace), [castNamespaceMedia, castNamespaceReceiver]);
    expect(device.of('STOP').last.payload['sessionId'], _session);
    expect(device.of('CLOSE').single.destination, _transport);
    expect(device.closed, isTrue);
    expect(playback(), isNull);
    expect(relays.single.isClosed, isTrue);
    await expectLater(fetch(url), throwsA(anything));
  });

  test('a phone without an address on the device network does not cast', () async {
    addresses = ['100.64.0.2'];
    expect(await controller().cast(_target, _request), CastOutcome.noNetwork);
    expect(connects, 0);
    expect(relays, isEmpty);
    expect(playback()!.phase, CastPhase.failed);
    expect(playback()!.failure, CastFailure.noNetwork);
    expect(playback()!.live, isFalse);
  });

  test('a LOAD the receiver refuses: load failed, the receiver stopped and the relay closed', () async {
    device.onLoad = (_) => {'type': 'LOAD_FAILED'};
    expect(await controller().cast(_target, _request), CastOutcome.load);
    await pumpEventQueue();
    expect(playback()!.failure, CastFailure.load);
    expect(device.of('STOP').where((message) => message.namespace == castNamespaceReceiver), hasLength(1));
    expect(relays.single.isClosed, isTrue);
  });

  test('a device that never launches the receiver: launch failed after the wait', () async {
    device.onLaunch = () => null;
    expect(await controller().cast(_target, _request), CastOutcome.launch);
    expect(playback()!.failure, CastFailure.launch);
  });

  test('another sender takes the device: the cast says so and the path is revoked', () async {
    await controller().cast(_target, _request);
    device.tell(castNamespaceReceiver, _receiverStatus('233637DE', session: 'another'));
    await pumpEventQueue();
    expect(playback()!.phase, CastPhase.takenOver);
    expect(playback()!.live, isFalse);
    expect(relays.single.leaseCount, 0);
  });

  test('the film ends on the device: ended, Close remains', () async {
    await controller().cast(_target, _request);
    device.tell(
      castNamespaceMedia,
      _mediaStatus('IDLE', currentTime: 7320, idleReason: 'FINISHED'),
      source: _transport,
    );
    await pumpEventQueue();
    expect(playback()!.phase, CastPhase.ended);
    await controller().dismiss();
    expect(playback(), isNull);
  });

  test('the connection drops while playing: lost', () async {
    await controller().cast(_target, _request);
    await device.drop();
    await pumpEventQueue();
    expect(playback()!.phase, CastPhase.lost);
    expect(relays.single.isClosed, isTrue);
  });

  group('the Plex metadata of the film', () {
    const aac = PlexStream(id: 1, type: PlexStreamType.audio, codec: 'aac');
    const dts = PlexStream(id: 2, type: PlexStreamType.audio, codec: 'dca', isDefault: true);
    const video = PlexStream(id: 3, type: PlexStreamType.video, codec: 'hevc');
    const first = PlexFilmPart(
      id: 10,
      key: '/library/parts/10/1/file.mkv',
      file: '/data/a/one.mkv',
      container: 'mkv',
      streams: [video, aac, dts],
    );
    const second = PlexFilmPart(id: 11, key: '/library/parts/11/1/file.mp4', file: '/data/a/two.mp4', container: 'mp4');
    const details = PlexFilmDetails(
      ratingKey: '77',
      title: 'Amélie',
      medias: [
        PlexFilmMedia(
          id: 1,
          videoCodec: 'hevc',
          audioCodec: 'aac',
          container: 'mkv',
          width: 3840,
          height: 2160,
          parts: [first],
        ),
        PlexFilmMedia(
          id: 2,
          videoCodec: 'h264',
          audioCodec: 'aac',
          container: 'mp4',
          width: 1920,
          height: 1080,
          parts: [second],
        ),
      ],
    );

    test('the version of the file the phone opened, else the first', () {
      expect(castPartOf(details, '/.films/1/77/11/two.mp4').part, second);
      expect(castPartOf(details, '/.films/1/77/11/two.mp4').media?.id, 2);
      expect(castPartOf(details, null).part, first);
      expect(castPartOf(details, '/somewhere/else.avi').part, first);
    });

    test('the sound the receiver plays is the default track of the file', () {
      final (:media, :part) = castPartOf(details, null);
      final format = castFormatOf(media, part);
      expect(format.container, 'mkv');
      expect(format.videoCodec, 'hevc');
      expect(format.audioCodec, 'dca');
      expect(format.width, 3840);
      final other = castFormatOf(details.medias.last, second);
      expect(other.audioCodec, 'aac');
      expect(other.videoCodec, 'h264');
    });
  });
}
