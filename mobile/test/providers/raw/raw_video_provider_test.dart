// Where the other file of a split Insta360 pair is found (docs/18-design-projections-and-parsers.md, section 7.3): on
// the device next to the opened file (an album shared, or recorded within a minute), on the server among the videos of
// the same owner, with the same choice of original or transcoded stream, and on a share in the folder of the file.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../domain/services/spherical_probe_fixtures.dart';
import '../../infrastructure/repository.mock.dart';
import '../../medium/repository_context.dart';

class _MockConnections extends Mock implements NetworkConnections {}

class _MockFileSystem extends Mock implements NetworkFileSystem {}

/// What the file of every video declares: one square video track
class _SquareProbes extends SphericalProbeService {
  _SquareProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  final probed = <String>[];

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async {
    probed.add(asset.name);
    return const SphericalProbe(
      tracks: [ProbedTrack(index: 0, handlerType: 'vide', codec: 'hvc1', codedWidth: 2880, codedHeight: 2880)],
    );
  }
}

const _opened = 'VID_20240908_193126_10_004.insv';
const _sibling = 'VID_20240908_193126_00_004.insv';

void main() {
  late MediumRepositoryContext context;
  late MockStorageRepository storage;
  late _SquareProbes probes;
  late RawAssetInputs inputs;
  final recorded = DateTime(2024, 9, 8, 19, 31, 26);

  setUp(() {
    context = MediumRepositoryContext();
    storage = MockStorageRepository();
    when(() => storage.getFileForAsset(any())).thenAnswer((call) async => File('/dcim/${call.positionalArguments[0]}'));
    probes = _SquareProbes();
    inputs = RawAssetInputs(
      local: () => LocalAssetRepository(context.db),
      remote: () => RemoteAssetRepository(context.db),
      storage: storage,
      probes: probes,
      calibrations: DualFisheyeCalibrationService(
        store: DualFisheyeCalibrationStore(() async => null),
        storage: storage,
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      ),
      originalUrl: (id) => 'https://server/assets/$id/original',
      transcodedUrl: (id) => 'https://server/assets/$id/video/playback',
    );
  });

  tearDown(() => context.dispose());

  group('RawAssetInputs', () {
    Future<LocalAsset> localVideo(String id, String name, DateTime createdAt) async {
      await context.newLocalAsset(id: id, name: name, type: AssetType.video, createdAt: createdAt);
      return (await LocalAssetRepository(context.db).getById(id))!;
    }

    test('finds the other file on the device in an album of the opened one, whatever its date', () async {
      final opened = await localVideo('opened', _opened, recorded);
      await localVideo('sibling', _sibling.toUpperCase(), recorded.add(const Duration(minutes: 10)));
      await localVideo('elsewhere', _sibling, recorded.add(const Duration(seconds: 1)));
      final album = await context.newLocalAlbum(id: 'camera');
      await context.newLocalAlbumAsset(albumId: album.id, assetId: 'opened');
      await context.newLocalAlbumAsset(albumId: album.id, assetId: 'sibling');
      final file = File('/dcim/opened');

      final sibling = await inputs.siblings(
        opened,
        localFile: file,
        source: ChosenVideoSource(url: file.uri.toString()),
      )(_sibling);

      expect(sibling?.name, _sibling.toUpperCase(), reason: 'case aside, the album first');
      expect(sibling?.url, File('/dcim/sibling').uri.toString());
      expect(sibling?.probe?.videoTracks, hasLength(1));
      expect(sibling?.key, startsWith('asset:'));
    });

    test('takes a file of the device of no shared album within a minute only', () async {
      final opened = await localVideo('opened', _opened, recorded);
      await localVideo('later', _sibling, recorded.add(const Duration(minutes: 2)));
      final file = File('/dcim/opened');
      Future<String?> find() async => (await inputs.siblings(
        opened,
        localFile: file,
        source: ChosenVideoSource(url: file.uri.toString()),
      )(_sibling))?.url;

      expect(await find(), isNull, reason: 'two minutes apart, no album: another recording');

      await localVideo('near', _sibling, recorded.add(const Duration(seconds: 30)));
      expect(await find(), File('/dcim/near').uri.toString());
    });

    test('finds the other file on the server, the original or the transcoded stream as the opened one', () async {
      final user = await context.newUser();
      final other = await context.newUser();
      await context.newRemoteAsset(
        id: 'a',
        name: _opened,
        ownerId: user.id,
        type: AssetType.video,
        createdAt: recorded,
      );
      await context.newRemoteAsset(
        id: 'b',
        name: _sibling,
        ownerId: user.id,
        type: AssetType.video,
        createdAt: recorded.add(const Duration(seconds: 1)),
      );
      // Not the one: another owner, in the trash, or a day later
      await context.newRemoteAsset(
        id: 'c',
        name: _sibling,
        ownerId: other.id,
        type: AssetType.video,
        createdAt: recorded,
      );
      await context.newRemoteAsset(
        id: 'd',
        name: _sibling,
        ownerId: user.id,
        type: AssetType.video,
        createdAt: recorded,
        deletedAt: recorded,
      );
      await context.newRemoteAsset(
        id: 'e',
        name: _sibling,
        ownerId: user.id,
        type: AssetType.video,
        createdAt: recorded.add(const Duration(days: 1)),
      );
      final opened = (await RemoteAssetRepository(context.db).get('a'))!;

      final original = await inputs.siblings(
        opened,
        source: const ChosenVideoSource(
          url: 'https://server/assets/a/original',
          fallbackUrl: 'https://server/assets/a/video/playback',
        ),
      )(_sibling);
      final transcoded = await inputs.siblings(
        opened,
        source: const ChosenVideoSource(url: 'https://server/assets/a/video/playback'),
      )(_sibling);

      expect(
        (original?.url, original?.fallbackUrl, original?.originalUrl),
        ('https://server/assets/b/original', 'https://server/assets/b/video/playback', null),
      );
      expect(
        (transcoded?.url, transcoded?.fallbackUrl, transcoded?.originalUrl),
        ('https://server/assets/b/video/playback', null, 'https://server/assets/b/original'),
      );
      expect(probes.probed, [_sibling, _sibling]);
    });

    test('gives the input of an asset played from the server, with its original beside its transcoded stream', () {
      final asset = RemoteAsset(
        id: 'a',
        name: _opened,
        ownerId: 'user',
        checksum: 'x',
        type: AssetType.video,
        createdAt: recorded,
        updatedAt: recorded,
        width: 2880,
        height: 2880,
        isEdited: false,
      );

      final transcoded = inputs.input(
        asset,
        source: const ChosenVideoSource(url: 'https://server/assets/a/video/playback'),
      );
      final original = inputs.input(asset, source: const ChosenVideoSource(url: 'https://server/assets/a/original'));

      expect(transcoded.originalUrl, 'https://server/assets/a/original');
      expect(original.originalUrl, isNull);
      expect((transcoded.width, transcoded.height, transcoded.name), (2880, 2880, _opened));
    });
  });

  group('shareSiblingFinder', () {
    final bridge = Uri.parse('http://127.0.0.1:1234/token');
    final video = Uint8List.fromList(mp4File(mp4Moov([mp4VideoTrack([], width: 2880, height: 2880)])));
    NetworkEntry entry(String path) =>
        NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: video.length);
    MockClient client() => MockClient((request) async {
      final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers['range'] ?? '');
      final start = math.min(int.parse(range?.group(1) ?? '0'), video.length);
      final end = math.min(int.parse(range?.group(2) ?? '${video.length - 1}') + 1, video.length);
      return http.Response.bytes(video.sublist(start, end), 206);
    });

    test('finds the other file in the folder the page has, by its name, else case aside', () async {
      final folder = [
        (entry: entry('/DCIM/$_opened'), url: bridge.replace(path: '/token/DCIM/$_opened')),
        (entry: entry('/DCIM/${_sibling.toLowerCase()}'), url: bridge.replace(path: '/token/DCIM/lower')),
      ];

      final sibling = await shareSiblingFinder(
        entry: entry('/DCIM/$_opened'),
        folder: folder,
        connections: null,
        bridgeClient: client(),
        media: NetworkMediaService(),
      )(_sibling);

      expect(sibling?.url, '$bridge/DCIM/lower');
      expect(sibling?.key, startsWith('share:nas:/DCIM/'));
      expect(sibling?.probe?.videoTracks.single.codedWidth, 2880);
      final file = await sibling!.open();
      expect(file?.size, video.length);
    });

    test('lists the folder of the file when the page has no listing, and gives up when it is not there', () async {
      final connections = _MockConnections();
      final fileSystem = _MockFileSystem();
      when(() => connections.fileSystem('nas')).thenAnswer((_) async => fileSystem);
      when(() => fileSystem.list('/DCIM')).thenAnswer(
        (_) async => [
          const NetworkEntry(sourceId: 'nas', path: '/DCIM/sub', isDirectory: true),
          entry('/DCIM/$_opened'),
          entry('/DCIM/$_sibling'),
        ],
      );
      when(
        () => connections.mediaUrl('nas', '/DCIM/$_sibling'),
      ).thenAnswer((_) async => bridge.replace(path: '/token/DCIM/$_sibling'));
      RawSiblingFinder find() => shareSiblingFinder(
        entry: entry('/DCIM/$_opened'),
        connections: connections,
        bridgeClient: client(),
        media: NetworkMediaService(),
      );

      expect((await find()(_sibling))?.url, '$bridge/DCIM/$_sibling');
      expect(await find()('VID_20240908_193126_00_005.insv'), isNull);

      when(() => fileSystem.list('/DCIM')).thenThrow(const NetworkFileSystemException('gone'));
      expect(await find()(_sibling), isNull);
    });
  });
}
