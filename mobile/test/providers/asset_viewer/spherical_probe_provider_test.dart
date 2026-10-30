import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../domain/services/spherical_probe_fixtures.dart';
import '../../infrastructure/repository.mock.dart';
import '../../unit/factories/remote_asset_factory.dart';

const _endpoint = 'https://immich.example/api';

/// Answers [request] for [file] as the server does, with range requests
http.Response _respond(Uint8List file, http.Request request, {bool ignoresRange = false}) {
  final range = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(request.headers['range'] ?? '');
  if (ignoresRange || range == null) {
    return http.Response.bytes(file, 200);
  }
  final start = int.parse(range.group(1)!);
  if (start >= file.length) {
    return http.Response('', 416);
  }
  final end = math.min(int.parse(range.group(2)!) + 1, file.length);
  return http.Response.bytes(Uint8List.sublistView(file, start, end), 206);
}

/// Serves [file], and records the requests
MockClient _server(Uint8List file, List<http.Request> requests, {bool ignoresRange = false}) =>
    MockClient((request) async {
      requests.add(request);
      return _respond(file, request, ignoresRange: ignoresRange);
    });

void main() {
  // A VR180 video, as a camera records it: the moov box after the media data
  final vr180 = mp4File(
    mp4Moov([
      mp4VideoTrack([mp4St3d(2), mp4Sv3dProjection(mp4Mshp())]),
    ]),
    moovAtEnd: true,
    mdat: mp4Box('mdat', mp4Zeros(300000)),
  );
  const vr180Probe = SphericalProbe(
    stereo: StereoLayout.leftRight,
    halfSphere: true,
    hasSphericalMetadata: true,
    codec: 'hvc1',
    tracks: [ProbedTrack(index: 0, codec: 'hvc1')],
  );

  late MockStorageRepository storage;
  late List<http.Request> requests;

  setUp(() {
    storage = MockStorageRepository();
    requests = [];
  });

  SphericalProbeService service(http.Client client, {Duration timeout = const Duration(seconds: 5)}) =>
      SphericalProbeService(
        storage: storage,
        client: () => client,
        serverEndpoint: () => _endpoint,
        headers: () => {'x-custom': 'yes'},
        timeout: timeout,
      );

  LocalAsset localVideo({String? remoteId}) => LocalAsset(
    id: 'local-1',
    remoteId: remoteId,
    name: 'VID_180.mp4',
    type: AssetType.video,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    playbackStyle: AssetPlaybackStyle.video,
    isEdited: false,
  );

  Future<File> writeFile(Uint8List bytes) async {
    final directory = await Directory.systemTemp.createTemp('spherical_probe_test');
    addTearDown(() => directory.delete(recursive: true));
    return File('${directory.path}/VID_180.mp4')..writeAsBytesSync(bytes);
  }

  group('SphericalProbeService', () {
    test('reads the original of a video on the server with range requests and the app headers', () async {
      final asset = RemoteAssetFactory.create(type: .video);

      final probe = await service(_server(vr180, requests)).probe(asset);

      expect(probe, vr180Probe);
      expect(requests, isNotEmpty);
      for (final request in requests) {
        expect(request.url.toString(), '$_endpoint/assets/${asset.id}/original');
        expect(request.headers['range'], startsWith('bytes='));
        expect(request.headers['x-custom'], 'yes');
      }
      final bytesAsked = requests.fold(0, (total, request) {
        final range = RegExp(r'(\d+)-(\d+)').firstMatch(request.headers['range']!)!;
        return total + int.parse(range.group(2)!) - int.parse(range.group(1)!) + 1;
      });
      expect(bytesAsked, lessThan(vr180.length), reason: 'not the whole video');
    });

    test('keeps the result per asset in memory', () async {
      final asset = RemoteAssetFactory.create(type: .video);
      final probes = service(_server(vr180, requests));

      expect(await probes.probe(asset), vr180Probe);
      final count = requests.length;
      expect(await probes.probe(asset), vr180Probe);

      expect(requests, hasLength(count));
    });

    test('cached gives a probe already read, and nothing before', () async {
      final asset = RemoteAssetFactory.create(type: .video);
      final other = RemoteAssetFactory.create(type: .video);
      final probes = service(_server(vr180, requests));

      expect(probes.cached(asset), isNull);
      expect(requests, isEmpty, reason: 'cached reads nothing');

      expect(await probes.probe(asset), vr180Probe);
      final count = requests.length;

      expect(probes.cached(asset), vr180Probe);
      expect(probes.cached(other), isNull);
      expect(requests, hasLength(count));
    });

    test('reads the copy on the device, without the server', () async {
      final file = await writeFile(vr180);
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => file);

      final probe = await service(_server(vr180, requests)).probe(localVideo());

      expect(probe, vr180Probe);
      expect(requests, isEmpty);
    });

    test('reads the file it is given', () async {
      final file = await writeFile(vr180);

      final probe = await service(_server(vr180, requests)).probe(localVideo(remoteId: 'remote-1'), localFile: file);

      expect(probe, vr180Probe);
      verifyNever(() => storage.getFileForAsset(any()));
      expect(requests, isEmpty);
    });

    test('reads the server copy when the copy on the device is unreadable', () async {
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => File('/nowhere/VID_180.mp4'));

      final probe = await service(_server(vr180, requests)).probe(localVideo(remoteId: 'remote-1'));

      expect(probe, vr180Probe);
      expect(requests.first.url.toString(), '$_endpoint/assets/remote-1/original');
    });

    test('gives null for a photo, without reading anything', () async {
      expect(await service(_server(vr180, requests)).probe(RemoteAssetFactory.create()), isNull);
      expect(requests, isEmpty);
    });

    test('gives null for a video only on the device whose file is gone', () async {
      when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => null);

      expect(await service(_server(vr180, requests)).probe(localVideo()), isNull);
      expect(requests, isEmpty);
    });

    test('gives null on a server error, and tries again next time', () async {
      final asset = RemoteAssetFactory.create(type: .video);
      var fails = true;
      final client = MockClient((request) async {
        requests.add(request);
        return fails ? http.Response('nope', 500) : _respond(vr180, request);
      });
      final probes = service(client);

      expect(await probes.probe(asset), isNull);
      fails = false;
      expect(await probes.probe(asset), vr180Probe);
    });

    test('gives null past its time limit', () async {
      final slow = MockClient((_) => Future.delayed(const Duration(seconds: 2), () => http.Response.bytes(vr180, 200)));

      final probe = await service(
        slow,
        timeout: const Duration(milliseconds: 50),
      ).probe(RemoteAssetFactory.create(type: .video));

      expect(probe, isNull);
    });

    test('copes with a server that ignores the range, from the head of the file only', () async {
      final atHead = mp4File(
        mp4Moov([
          mp4VideoTrack([mp4Sv3dProjection(mp4Mshp())]),
        ]),
      );
      expect(
        (await service(
          _server(atHead, requests, ignoresRange: true),
        ).probe(RemoteAssetFactory.create(type: .video)))?.halfSphere,
        isTrue,
      );

      // Past the head, it would send the whole video again for each read: the probe gives up
      expect(
        await service(_server(vr180, requests, ignoresRange: true)).probe(RemoteAssetFactory.create(type: .video)),
        isNull,
      );
    });
  });

  group('SphericalProbeService.probeTranscoded', () {
    // The server's transcoded stream, as Immich writes it: its moov box first (faststart), larger than the first read
    // of the probe for a long video, then the media data
    final copy = mp4File(
      mp4Moov([
        mp4VideoTrack(
          const [],
          codec: 'avc1',
          config: mp4AvcC(profile: 0x42, level: 0x3c),
          width: 5760,
          height: 2880,
          stsz: mp4Stsz(sizes: List.filled(30000, 12000)),
        ),
      ]),
      mdat: mp4Box('mdat', mp4Zeros(2 << 20)),
    );

    test('reads the head of the stream once, on a server that ignores the range', () async {
      final probe = await service(_server(copy, requests, ignoresRange: true)).probeTranscoded('video-1');

      expect(probe?.codec, 'avc1');
      expect(probe?.codedWidth, 5760);
      expect(probe?.codedHeight, 2880);
      expect(requests, hasLength(1), reason: 'the moov box lies in the head read once');
      expect(requests.single.url.toString(), '$_endpoint/assets/video-1/video/playback');
      expect(requests.single.headers['x-custom'], 'yes');
    });

    test('reads it with range requests too, and keeps it apart from the original of the same video', () async {
      final probes = service(_server(copy, requests));

      expect((await probes.probeTranscoded('video-1'))?.codedWidth, 5760);
      final count = requests.length;
      expect((await probes.probeTranscoded('video-1'))?.codedWidth, 5760);
      expect(requests, hasLength(count), reason: 'kept in memory');
      expect(probes.cached(RemoteAssetFactory.create(type: .video).copyWith(id: 'video-1')), isNull);
    });

    test('gives null without a server, and on a server error', () async {
      final none = SphericalProbeService(
        storage: storage,
        client: () => _server(copy, requests),
        serverEndpoint: () => null,
        headers: () => const {},
      );
      expect(await none.probeTranscoded('video-1'), isNull);
      expect(await service(MockClient((_) async => http.Response('', 500))).probeTranscoded('video-1'), isNull);
    });
  });

  test('headPrefetchReader serves the reads within the head from one read', () async {
    final asked = <(int, int)>[];
    final file = Uint8List.fromList(List.generate(100, (i) => i));
    final read = headPrefetchReader((offset, length) async {
      asked.add((offset, length));
      return Uint8List.sublistView(file, offset, math.min(offset + length, file.length));
    }, headLength: 40);

    expect(await read(0, 8), [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(await read(30, 10), List.generate(10, (i) => 30 + i));
    expect(asked, [(0, 40)]);
    expect(await read(35, 10), List.generate(10, (i) => 35 + i), reason: 'past the head: a read of its own');
    expect(asked, [(0, 40), (35, 10)]);
  });

  test('httpRangeReader reads nothing past the end of the file', () async {
    final read = httpRangeReader(_server(Uint8List.fromList([1, 2, 3]), requests), Uri.parse('$_endpoint/file'));

    expect(await read(1, 10), [2, 3]);
    expect(await read(3, 10), isEmpty);
    expect(requests.map((request) => request.headers['range']), ['bytes=1-10', 'bytes=3-12']);
  });
}
