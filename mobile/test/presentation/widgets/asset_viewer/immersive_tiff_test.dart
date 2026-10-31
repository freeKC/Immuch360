// The immersive viewer of a Meta Quest on a TIFF (fix-tiff-android): its decoders refuse TIFF, so a TIFF of the
// headset opens from a JPEG of the cache made once, a TIFF of the server from the JPEG the server made of it.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_tiff.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/presentation/presentation_context.dart';

class _NoProbes extends SphericalProbeService {
  _NoProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PresentationContext context;
  late Directory cache;
  late Directory files;
  late ProviderContainer container;
  late MockStorageRepository storage;

  setUp(() async {
    context = await PresentationContext.create();
    cache = Directory.systemTemp.createTempSync('tiff_jpeg_');
    files = Directory.systemTemp.createTempSync('tiff_files_');
    container = ProviderContainer(overrides: [storeServiceProvider.overrideWithValue(StoreService.I)]);
    storage = MockStorageRepository();
    UndecodablePhotos.instance.clear();
  });

  tearDown(() async {
    container.dispose();
    cache.deleteSync(recursive: true);
    files.deleteSync(recursive: true);
    await context.dispose();
  });

  ImmersiveAssetResolver resolver() => ImmersiveAssetResolver(
    api: ImmersiveApi(),
    stereoLabels: const {},
    coverageOverrides: container.read(sphereCoverageOverridesProvider.notifier),
    storage: storage,
    probeService: _NoProbes(),
    gpanoClient: MockClient((_) async => http.Response('', 404)),
    videoSources: VideoSourceService(VideoDecoderApi()),
    tiffJpegs: TiffJpegCache(() async => cache),
  );

  LocalAsset headsetPhoto(String name) => LocalAsset(
    id: '61',
    name: name,
    checksum: 'checksum-61',
    type: AssetType.image,
    createdAt: DateTime(2026, 10, 31),
    updatedAt: DateTime(2026, 10, 31),
    width: 64,
    height: 32,
    playbackStyle: AssetPlaybackStyle.image,
    isEdited: false,
  );

  File fileOf(String name, List<int> bytes) => File('${files.path}/$name')..writeAsBytesSync(bytes);

  test('a TIFF of the headset opens on the big screen and the sphere from a JPEG of the cache, made once', () async {
    final tiff = headsetPhoto('scan.tif');
    final file = fileOf('scan.tif', img.encodeTiff(img.Image(width: 64, height: 32)));
    when(() => storage.getFileForAsset('61')).thenAnswer((_) async => file);

    final quad = await resolver().resolveStereoPhoto(tiff, const BigScreenStereoPhotoRequest());
    expect(quad.url, startsWith('file://'));
    expect(quad.url, endsWith('.jpg'));
    final jpeg = File.fromUri(Uri.parse(quad.url)).readAsBytesSync();
    expect(jpeg.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    expect((img.decodeJpg(jpeg)!.width, img.decodeJpg(jpeg)!.height), (64, 32));

    // The sphere reads the same JPEG, not made again even with the TIFF gone
    file.deleteSync();
    final sphere = await resolver().resolve(tiff, localPath: file.path);
    expect(sphere.url, quad.url);
    expect(cache.listSync().whereType<File>().where((entry) => entry.path.endsWith('.jpg')), hasLength(1));
  });

  test('a JPEG of the headset opens from its own file', () async {
    final file = fileOf('beach.jpg', img.encodeJpg(img.Image(width: 64, height: 32)));
    when(() => storage.getFileForAsset('61')).thenAnswer((_) async => file);

    final quad = await resolver().resolveStereoPhoto(headsetPhoto('beach.jpg'), const BigScreenStereoPhotoRequest());
    expect(quad.url, file.uri.toString());
    expect(cache.listSync(), isEmpty);
  });

  test('a TIFF of the headset that does not decode fails with the words of the TIFF decoder', () async {
    final file = fileOf('broken.tif', [0x49, 0x49, 0x2A, 0x00, ...List.filled(64, 0x41)]);
    when(() => storage.getFileForAsset('61')).thenAnswer((_) async => file);

    await expectLater(
      resolver().resolveStereoPhoto(headsetPhoto('broken.tif'), const BigScreenStereoPhotoRequest()),
      throwsA(isA<TiffDecodeException>()),
    );
  });

  test('the JPEG of a TIFF keeps its orientation and is at most the width of a 360 texture', () async {
    final source = img.Image(width: 64, height: 32)..exif.imageIfd.orientation = 6;
    final jpeg = await tiffAsJpeg(img.encodeTiff(source));
    final decoded = img.decodeJpg(jpeg)!;
    expect((decoded.width, decoded.height), (32, 64));
    final small = img.decodeJpg(await tiffAsJpeg(img.encodeTiff(img.Image(width: 400, height: 100)), maxSide: 100))!;
    expect((small.width, small.height), (100, 25));
    expect(tiffJpegMaxSide, 8192);
    expect(defaultTargetPlatform, TargetPlatform.android, reason: 'the tests run as Android');
  });
}
