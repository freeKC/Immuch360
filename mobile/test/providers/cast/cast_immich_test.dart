// Cast of Immich photos and videos (release 52): what the phone reads before casting (the server's JPEG for a photo,
// the probe and the converted version of a video), never a session in an address the device sees; the photo LOAD;
// the next photo of the viewer on the same receiver, whose INTERRUPTED of the photo before is this phone's own doing.
// A device simulated on a fake channel, the relay real on the loopback in front of a fake Immich server.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_channel.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';
import 'package:immich_mobile/providers/cast/cast_immich.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

const _transport = 'web-5';
const _session = 'session-1';
const _user = 'a1b2c3d4-0000-4000-8000-00000000abcd';
const _sessionHeader = 'x-immich-session-of-the-phone';

typedef _Sent = ({String namespace, String destination, Map<String, Object?> payload});

class _Device implements CastChannel {
  final _controller = StreamController<CastChannelMessage>.broadcast();
  final List<_Sent> sent = [];
  var _mediaSession = 0;

  /// What the receiver tells after a LOAD, given the new media session and the one before
  List<Map<String, Object?>> Function(int session, int? before) onLoad = (session, before) => [
    if (before != null) _media(before, 'IDLE', idleReason: 'INTERRUPTED'),
    _media(session, 'PLAYING'),
  ];

  @override
  Stream<CastChannelMessage> get messages => _controller.stream;

  void tell(String namespace, Map<String, Object?> payload, {String source = castReceiverId}) => scheduleMicrotask(
    () => _controller.add(CastChannelMessage(namespace: namespace, source: source, payload: payload)),
  );

  @override
  void send(String namespace, Map<String, Object?> payload, {String destination = castReceiverId}) {
    sent.add((namespace: namespace, destination: destination, payload: payload));
    if (namespace == castNamespaceReceiver && payload['type'] == 'LAUNCH') {
      tell(castNamespaceReceiver, {
        'type': 'RECEIVER_STATUS',
        'status': {
          'applications': [
            {'appId': castDefaultReceiverAppId, 'sessionId': _session, 'transportId': _transport},
          ],
          'volume': {'level': 0.5, 'muted': false},
        },
      });
    }
    if (namespace == castNamespaceMedia && payload['type'] == 'LOAD') {
      final before = _mediaSession == 0 ? null : _mediaSession;
      _mediaSession++;
      for (final status in onLoad(_mediaSession, before)) {
        tell(castNamespaceMedia, status, source: _transport);
      }
    }
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  List<Map<String, Object?>> loads() => [
    for (final message in sent)
      if (message.payload['type'] == 'LOAD') message.payload,
  ];
}

Map<String, Object?> _media(int session, String state, {String? idleReason}) => {
  'type': 'MEDIA_STATUS',
  'status': [
    {'mediaSessionId': session, 'playerState': state, 'currentTime': 0, 'playbackRate': 1, 'idleReason': ?idleReason},
  ],
};

const _target = CastTarget(id: 'cc1', name: 'Living room', host: '192.168.1.42', port: 8009, model: 'Chromecast');

RemoteAsset _asset(int n, {AssetType type = AssetType.image}) => RemoteAsset(
  id: '00000000-0000-4000-8000-00000000000$n',
  name: type == AssetType.image ? 'IMG_$n.HEIC' : 'IMG_$n.MOV',
  ownerId: _user,
  checksum: 'c$n',
  type: type,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  durationMs: type == AssetType.video ? 12000 : null,
  isEdited: false,
);

PlayOnRequest _request(RemoteAsset asset) =>
    PlayOnRequest.ofAsset(asset, userId: _user, endpoints: const [], serverName: 'photos')!;

void main() {
  late HttpServer server;
  late List<HttpRequest> served;
  late Map<String, int> lengths;
  late CastImmichEnvironment immich;

  setUp(() async {
    served = [];
    lengths = {'original': 5000, 'playback': 1200};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      served.add(request);
      final playback = request.uri.path.endsWith('/video/playback');
      final length = request.uri.path.endsWith('/original')
          ? lengths['original']!
          : playback
          ? lengths['playback']!
          : 3;
      request.response.headers.contentType = request.uri.path.contains('thumbnail')
          ? ContentType('image', 'jpeg')
          : ContentType('video', 'mp4');
      request.response.contentLength = length;
      if (request.method == 'GET') {
        request.response.add(List.filled(length, 7));
      }
      await request.response.close();
    });
    final client = http.Client();
    addTearDown(client.close);
    immich = CastImmichEnvironment(
      serverEndpoint: () => 'http://127.0.0.1:${server.port}/api',
      // The app's client adds the session in a header; the relay's addresses never carry it
      send: (request) {
        request.headers[_sessionHeader] = 'secret';
        return client.send(request);
      },
      probe: (asset) async => const SphericalProbe(
        codec: 'hvc1',
        tracks: [ProbedTrack(index: 1, handlerType: 'soun', codec: 'mp4a')],
        codedWidth: 1920,
        codedHeight: 1080,
      ),
    );
  });

  tearDown(() => server.close(force: true));

  group('what the phone reads beforehand', () {
    test('a photo: the server\'s full size JPEG, and a 360 photo goes flat with its note', () async {
      final info = (await readImmichCastInfo(immich, _request(_asset(1))))!;
      expect(info.photo, isTrue);
      expect(info.contentType, 'image/jpeg');
      expect(info.flat360, isFalse);
      final answer = await info.upstream!('GET', const {});
      expect(answer.statusCode, 200);
      await answer.stream.drain<void>();
      expect(served.single.uri.path, '/api/assets/${_asset(1).id}/thumbnail');
      expect(served.single.uri.queryParameters['size'], 'fullsize');
      expect(served.single.headers.value(_sessionHeader), 'secret');

      final sphere = PlayOnRequest.ofAsset(
        _asset(2),
        userId: _user,
        endpoints: const [],
        serverName: 'photos',
        projection: PlayProjection.equirect,
      )!;
      expect((await readImmichCastInfo(immich, sphere))!.flat360, isTrue);
    });

    test('an HEVC video the server converted: the converted version goes to a device without HEVC', () async {
      final info = (await readImmichCastInfo(immich, _request(_asset(3, type: AssetType.video))))!;
      expect(info.format.videoCodec, 'hevc');
      expect(info.format.audioCodec, 'aac');
      expect(info.format.container, 'mov');
      expect(info.convertedUpstream, isNotNull);
      // Chromecast (first generations): HEVC is unsure, the converted H.264 should play
      final chromecast = castVersionFor(info, castProfileOf('Chromecast'));
      expect(chromecast.converted, isTrue);
      expect(chromecast.check.support, CastSupport.yes);
      // A Google TV Streamer decodes HEVC: the original goes
      expect(castVersionFor(info, castProfileOf('Google TV Streamer')).converted, isFalse);
    });

    test('a video the server did not convert: the original, with its verdict', () async {
      lengths = {'original': 5000, 'playback': 5000};
      final info = (await readImmichCastInfo(immich, _request(_asset(3, type: AssetType.video))))!;
      expect(info.convertedUpstream, isNull);
      final version = castVersionFor(info, castProfileOf('Google Nest Hub'));
      expect(version.converted, isFalse);
      expect(version.check.support, CastSupport.no);
    });

    test('codes of the sample entries', () {
      expect(castCodecOfFourCc('avc1'), 'h264');
      expect(castCodecOfFourCc('hev1'), 'hevc');
      expect(castCodecOfFourCc('dvh1'), 'hevc');
      expect(castCodecOfFourCc('av01'), 'av1');
      expect(castCodecOfFourCc('ec-3'), 'eac3');
      expect(castCodecOfFourCc(null), isNull);
    });
  });

  test('a photo LOAD is PhotoMediaMetadata, with no position', () {
    final load = castLoadMessage(
      CastFilm(
        contentUrl: Uri.parse('http://192.168.1.20:8364/cast/x/film'),
        contentType: 'image/jpeg',
        title: 'a',
        photo: true,
      ),
    );
    final media = load['media']! as Map<String, Object?>;
    expect((media['metadata']! as Map)['metadataType'], 4);
    expect(media['contentType'], 'image/jpeg');
    expect(load.containsKey('currentTime'), isFalse);
  });

  group('on the device', () {
    late _Device device;
    late ProviderContainer container;
    late List<CastRelayServer> relays;

    setUp(() {
      device = _Device();
      relays = [];
      container = ProviderContainer(
        overrides: [
          castImmichEnvironmentProvider.overrideWithValue(immich),
          castEnvironmentProvider.overrideWith(
            (ref) => CastEnvironment(
              connect: (_) async => device,
              localAddresses: () async => ['192.168.1.20'],
              bindRelay: (_) async {
                final relay = await CastRelayServer.bind('127.0.0.1', port: 0);
                relays.add(relay);
                return relay;
              },
              filmInfo: (request) => readImmichCastInfo(immich, request),
              bridgeUrl: (_, _) async => throw StateError('no bridge for Immich'),
              poster: (_, _) async => null,
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
    });

    CastPlaybackController controller() => container.read(castPlaybackProvider.notifier);

    test(
      'a photo shows; the next one goes on the same receiver, the INTERRUPTED of the one before is ignored',
      () async {
        expect(await controller().cast(_target, _request(_asset(1))), CastOutcome.playing);
        expect(container.read(castPlaybackProvider)?.phase, CastPhase.showing);
        final first = device.loads().single;
        final firstUrl = Uri.parse((first['media']! as Map)['contentUrl']! as String);
        expect(firstUrl.toString(), isNot(contains('secret')));
        expect(firstUrl.toString(), isNot(contains(_asset(1).id)), reason: 'only the relay\'s random path');

        expect(await controller().castNext(_request(_asset(2))), CastOutcome.playing);
        final playback = container.read(castPlaybackProvider)!;
        expect(playback.phase, CastPhase.showing);
        expect(playback.request.ratingKey, _asset(2).id);
        expect(device.loads(), hasLength(2));
        expect(device.sent.where((message) => message.payload['type'] == 'LAUNCH'), hasLength(1));
        // The path of the photo before is gone, the new one serves
        final relay = relays.single;
        expect(relay.leaseCount, 1);
      },
    );

    test('another sender interrupting the photo shown is taken over', () async {
      expect(await controller().cast(_target, _request(_asset(1))), CastOutcome.playing);
      device.tell(castNamespaceMedia, _media(1, 'IDLE', idleReason: 'INTERRUPTED'), source: _transport);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(castPlaybackProvider)?.phase, CastPhase.takenOver);
    });

    test('the relay serves the server\'s answer to the device, the session stays on the phone', () async {
      expect(await controller().cast(_target, _request(_asset(1))), CastOutcome.playing);
      final url = Uri.parse((device.loads().single['media']! as Map)['contentUrl']! as String);
      final relayed = url.replace(host: '127.0.0.1', port: relays.single.port);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final answer = await (await client.getUrl(relayed)).close();
      expect(answer.statusCode, 200);
      expect(answer.headers.contentType?.mimeType, 'image/jpeg');
      await answer.drain<void>();
      expect(answer.headers.value(_sessionHeader), isNull);
    });
  });
}
