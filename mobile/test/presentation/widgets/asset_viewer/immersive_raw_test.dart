// The raw dual fisheye files of Insta360 cameras in the immersive viewer of the Meta Quest: a photo goes to it stitched
// into a PNG of the cache, a video with the JSON of its calibration; a video of a lens per file is refused.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_stitcher.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';

import '../../../domain/services/spherical_probe_fixtures.dart';
import '../../../fixtures/raw/dual_fisheye_frames.dart';
import '../../../fixtures/raw/insta360.stub.dart';
import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

/// What the viewer was given: by open, or in place by showAdjacent
typedef _Given = ({String url, bool isVideo, String? rawProjection, ImmersiveStereoLayout layout});

class _RecordingImmersiveApi extends ImmersiveApi {
  final opened = <_Given>[];
  final shown = <_Given>[];

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    ImmersiveSphereCoverage coverage,
    int startPositionMs,
    int openingId,
    String? fallbackUrl,
    String? rawProjection,
  ) async => opened.add((url: url, isVideo: isVideo, rawProjection: rawProjection, layout: stereoLayout));

  @override
  Future<bool> showAdjacent(
    int requestId,
    String url,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
    String? fallbackUrl,
    String? rawProjection,
  ) async {
    shown.add((url: url, isVideo: isVideo, rawProjection: rawProjection, layout: stereoLayout));
    return true;
  }
}

/// The calibration of every asset: [calibration], recording the assets and the files on the device it was asked for
class _FixedCalibrations extends DualFisheyeCalibrationService {
  _FixedCalibrations(this.calibration)
    : super(
        store: DualFisheyeCalibrationStore(() async => null),
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  final DualFisheyeCalibration calibration;
  final asked = <(BaseAsset, File?)>[];

  @override
  Future<DualFisheyeCalibration> forAsset(BaseAsset asset, {File? localFile}) async {
    asked.add((asset, localFile));
    return calibration;
  }
}

/// What the file of each video declares: [result] for every video
class _FixedProbes extends SphericalProbeService {
  _FixedProbes(this.result)
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  final SphericalProbe? result;

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async => asset.isVideo ? result : null;
}

/// The calibration of the real X3 photo, levelled
DualFisheyeCalibration _x3() => parseInsta360OffsetV3(
  x3OffsetV3,
)!.copyWith(downBody: downBodyFromAccelerometer(const [-1.003906, -0.124023, 0.082031]), serial: x3Serial);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _RecordingImmersiveApi api;
  late Directory directory;

  setUp(() async {
    await PresentationContext.create();
    container = ProviderContainer(overrides: [storeServiceProvider.overrideWithValue(StoreService.I)]);
    api = _RecordingImmersiveApi();
    directory = Directory.systemTemp.createTempSync('immersive_raw');
  });

  tearDown(() async {
    container.dispose();
    await StoreService.I.delete(StoreKey.sphereCoverageOverrides);
    directory.deleteSync(recursive: true);
  });

  RawImmersiveMedia raw(
    DualFisheyeCalibrationService calibrations, {
    Future<ui.Image> Function(BaseAsset asset, File? localFile)? loadAssetImage,
    Future<File> Function(
      StitchedPhotoFiles files,
      String key,
      DualFisheyeCalibration calibration,
      Future<ui.Image> Function() load,
    )?
    stitchPhoto,
  }) => RawImmersiveMedia(
    calibrations: calibrations,
    layoutOf: (asset) =>
        raw360LayoutOf(name: asset.name, isVideo: asset.isVideo, width: asset.width, height: asset.height),
    files: StitchedPhotoFiles(() async => directory),
    loadAssetImage: loadAssetImage ?? (asset, file) => throw UnimplementedError('no image to load'),
    stitchPhoto: stitchPhoto ?? stitchedPhotoFile,
  );

  ImmersiveAssetResolver resolver({RawImmersiveMedia? rawMedia, SphericalProbe? probe}) => ImmersiveAssetResolver(
    api: api,
    stereoLabels: const {},
    coverageOverrides: container.read(sphereCoverageOverridesProvider.notifier),
    storage: MockStorageRepository(),
    probeService: _FixedProbes(probe),
    gpanoClient: MockClient((_) async => http.Response('', 404)),
    videoSources: VideoSourceService(VideoDecoderApi()),
    raw: rawMedia,
  );

  group('ImmersiveAssetResolver', () {
    testWidgets('stitches a raw photo into a PNG of the cache, and opens it as a file, once', (tester) async {
      await tester.runAsync(() async {
        final calibration = _x3();
        final calibrations = _FixedCalibrations(calibration);
        var loads = 0;
        final media = raw(
          calibrations,
          loadAssetImage: (asset, file) {
            loads++;
            return imageFromRgba(patternDualFisheye(calibration, 256), 512, 256);
          },
        );
        final asset = RemoteAssetFactory.create(name: 'IMG_20240908_133036_00_001.insp', width: 11968, height: 5984);

        final request = await resolver(rawMedia: media).resolve(asset);
        final again = await resolver(rawMedia: media).resolve(asset);

        final file = File.fromUri(Uri.parse(request.url));
        expect(request.url, startsWith('file://'));
        expect(file.parent.path, directory.path);
        expect(file.path, endsWith('.png'));
        expect(request.isVideo, isFalse);
        expect(request.view, raw360SphereView);
        expect(request.rawProjection, isNull);
        expect(again.url, request.url);
        expect(loads, 1, reason: 'the picture of the cache is opened again');
        final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
        final image = (await codec.getNextFrame()).image;
        expect((image.width, image.height), (512, 256));
        image.dispose();
        codec.dispose();
      });
    });

    test('opens a raw video with the calibration for its frame, over the whole sphere', () async {
      final calibrations = _FixedCalibrations(_x3());
      final resolve = resolver(
        rawMedia: raw(calibrations),
        probe: const SphericalProbe(codec: 'hvc1', codedWidth: 5760, codedHeight: 2880),
      );
      final asset = RemoteAssetFactory.create(type: .video, name: 'VID_00_002.insv');

      final request = await resolve.resolve(asset);
      await resolve.open(request, openingId: 1);

      final json = jsonDecode(request.rawProjection!) as Map;
      expect(json['kind'], 'dualFisheye');
      expect((json['frameWidth'], json['frameHeight']), (5760, 2880));
      expect(json['canvasSquare'], 5952);
      expect(request.view, raw360SphereView);
      expect(request.isVideo, isTrue);
      expect(api.opened.single.rawProjection, request.rawProjection);
      expect(api.opened.single.layout, ImmersiveStereoLayout.mono);
      expect(calibrations.asked.single.$1, asset);
    });

    test('refuses a raw video of a lens per file, by its size or by what the file declares', () async {
      final calibrations = _FixedCalibrations(_x3());
      final square = RemoteAssetFactory.create(type: .video, name: 'VID_10_002.insv', width: 2880, height: 2880);
      final unknown = RemoteAssetFactory.create(type: .video, name: 'VID_10_002.insv');

      await expectLater(
        resolver(rawMedia: raw(calibrations)).resolve(square),
        throwsA(isA<RawVideoUnsupportedException>()),
      );
      await expectLater(
        resolver(
          rawMedia: raw(calibrations),
          probe: const SphericalProbe(codedWidth: 2880, codedHeight: 2880),
        ).resolve(unknown),
        throwsA(isA<RawVideoUnsupportedException>()),
      );
      expect(calibrations.asked, isEmpty);
    });

    test('opens a video that is no raw file as before, without calibration', () async {
      final request = await resolver(
        rawMedia: raw(_FixedCalibrations(_x3())),
      ).resolve(RemoteAssetFactory.create(type: .video, name: 'VID_001.mp4', width: 5760, height: 2880));

      expect(request.rawProjection, isNull);
      expect(request.url, endsWith('/original'));
    });
  });

  group('loadRawAssetImage', () {
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
      RemoteImageApi.pigeonChannelCodec,
    );

    tearDown(
      () =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, null),
    );

    test('loads the original of a raw photo only on the server, at most 8191 pixels wide', () async {
      final requests = <List<Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (
        message,
      ) async {
        requests.add(message! as List<Object?>);
        return <Object?>[null];
      });
      final asset = RemoteAssetFactory.create(name: 'IMG_20240908_133036_00_001.insp', width: 11968, height: 5984);

      await expectLater(loadRawAssetImage(asset, null), throwsStateError, reason: 'the loader gave no image');

      // Through the image loader of the app, which sends the headers of the session; the full size image of the
      // server would be the 2880 x 1440 preview of this 72 MP photo
      final [url, _, preferEncoded, width, height] = requests.single;
      expect(url, '${PresentationContext.serverEndpoint}/assets/${asset.id}/original?edited=false');
      expect(preferEncoded, isFalse);
      expect((width, height), (8191, 1));
    });
  });

  group('FolderImmersiveNavigator', () {
    // A raw video of a share, side by side, with the trailer of an X3; a raw photo; the plain photo it opened on
    final video = insta360File([
      insta360Record(1, x3Metadata(), format: 1),
    ], body: mp4File(mp4Moov([mp4VideoTrack([], width: 5760, height: 2880)])));
    final photo = insta360File([insta360Record(1, x3Metadata(), format: 1)], body: [0xff, 0xd8, 0xff, 0xd9]);
    final files = {'/a.jpg': Uint8List(100), '/IMG_001.insp': photo, '/VID_00_002.insv': video};
    final bridge = Uri.parse('http://127.0.0.1:1234/token');

    // The media bridge: range requests on the files above
    MockClient bridgeClient() => MockClient((request) async {
      final bytes = files[request.url.path.substring('/token'.length)];
      if (bytes == null) {
        return http.Response('', 404);
      }
      final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers['range'] ?? '');
      final start = math.min(int.parse(range?.group(1) ?? '0'), bytes.length);
      final end = math.min(int.parse(range?.group(2) ?? '${bytes.length - 1}') + 1, bytes.length);
      return http.Response.bytes(bytes.sublist(start, end), 206);
    });

    List<ImmersiveFolderItem> items() => [
      for (final MapEntry(key: path, value: bytes) in files.entries)
        (
          entry: NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: bytes.length),
          url: bridge.replace(path: '${bridge.path}$path'),
        ),
    ];

    test('shows a raw photo stitched and a raw video with the calibration of its trailer', () async {
      final all = items();
      final calibrations = DualFisheyeCalibrationService(
        store: DualFisheyeCalibrationStore(() async => null),
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('read through the bridge'),
        serverEndpoint: () => null,
        headers: () => const {},
      );
      final stitched = <String>[];
      final navigator = FolderImmersiveNavigator(
        api: api,
        service: NetworkMediaService(),
        client: bridgeClient(),
        items: all,
        index: 0,
        request: ImmersiveRequest(
          url: all.first.url.toString(),
          isVideo: false,
          title: 'a.jpg',
          view: (layout: StereoLayout.mono, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full),
        ),
        raw: raw(
          calibrations,
          stitchPhoto: (files, key, calibration, load) async {
            stitched.add('$key ${calibration.source.name}');
            return files.write(key, Uint8List.fromList([1]));
          },
        ),
      );
      Future<bool> next() => navigator.showAdjacent(
        ImmersiveAdjacentRequest(
          id: 1,
          step: 1,
          stereoLayout: ImmersiveStereoLayout.mono,
          coverage: ImmersiveSphereCoverage.full,
        ),
      );

      expect(await next(), isTrue);
      expect(api.shown.last.url, startsWith('file://${directory.path}/stitched_'));
      expect(api.shown.last.rawProjection, isNull);
      expect(stitched.single, endsWith(' file'), reason: 'the calibration of the trailer of the photo');
      expect(navigator.currentEntry.name, 'IMG_001.insp');

      expect(await next(), isTrue);
      expect(api.shown.last.url, '$bridge/VID_00_002.insv');
      expect(api.shown.last.isVideo, isTrue);
      final json = jsonDecode(api.shown.last.rawProjection!) as Map;
      expect((json['frameWidth'], json['frameHeight']), (5760, 2880));
      expect(((json['lenses'] as List).first as Map)['fx'], closeTo(4627.54, 1e-6));
      expect(api.opened, isEmpty, reason: 'navigation never starts the viewer');
    });
  });
}
