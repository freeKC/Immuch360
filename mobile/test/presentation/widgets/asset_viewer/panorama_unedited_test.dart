// The 360° views never show an edited picture: a photo turned with the one-key rotation (or edited in the editor)
// while it was viewed flat, then viewed as 360°, comes to the sphere and to the immersive viewer of the Meta Quest as
// the camera made it. Those views turn their camera, and follow the head or the phone by themselves. Their guesses of
// the layout and the coverage read the size of the file too, never the one the server gave the asset after the edit:
// a turn swaps it, which would read a VR180 photo as top and bottom and a 3D one side by side as mono.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../../widget_tester_extensions.dart';

class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  const _TestImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) => Future.value(this);

  @override
  ImageStreamCompleter loadImage(_TestImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image.clone())));
}

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
  late PresentationContext context;
  const server = PresentationContext.serverEndpoint;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  // Turned on the server while viewed flat, then chosen to be viewed as 360°
  final edited = RemoteAssetFactory.create(width: 4096, height: 2048, name: 'trip.jpg').copyWith(isEdited: true);

  test('the sphere loads the unedited thumbnail, preview and original', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = container.read(panoramaImageProvider)(edited, const Size(1080, 1920));
    expect(provider, isA<RemoteFullImageProvider>());
    expect((provider as RemoteFullImageProvider).edited, isFalse);
  });

  test('the immersive viewer of a Meta Quest opens the unedited original of a photo', () {
    expect(immersiveMediaUrl(edited), '$server/assets/${edited.id}/original?edited=false');
  });

  testWidgets('the sphere reads its GPano tags from the unedited preview', (tester) async {
    final image = (await tester.runAsync(() => createTestImage(width: 64, height: 32)))!;
    addTearDown(image.dispose);
    final requests = <Uri>[];
    await tester.pumpConsumerWidget(
      PanoramaViewerPage(asset: edited),
      overrides: [
        panoramaImageProvider.overrideWithValue((_, _) => _TestImageProvider(image)),
        panoramaGPanoClientProvider.overrideWithValue(
          MockClient((request) async {
            requests.add(request.url);
            return http.Response.bytes(const [], 206);
          }),
        ),
        isHorizonOsProvider.overrideWith((ref) => false),
      ],
    );
    await tester.pumpAndSettle();

    expect(requests, [Uri.parse('$server/assets/${edited.id}/thumbnail?size=preview&edited=false')]);
  });

  // Turned once on the server while viewed flat: the server swapped the size of the asset, its file keeps its own
  final turnedVr180 = RemoteAssetFactory.create(
    width: 2048,
    height: 4096,
    name: 'trip_vr180.jpg',
  ).copyWith(isEdited: true);
  const vr180File = ExifInfo(width: 4096, height: 2048);
  final turnedStereo = RemoteAssetFactory.create(
    width: 2048,
    height: 8192,
    name: 'stereo.jpg',
  ).copyWith(isEdited: true);
  const stereoFile = ExifInfo(width: 8192, height: 2048);

  Future<void> pumpSphere(WidgetTester tester, RemoteAsset asset, ExifInfo exif) async {
    final image = (await tester.runAsync(() => createTestImage(width: 64, height: 32)))!;
    addTearDown(image.dispose);
    await tester.pumpConsumerWidget(
      PanoramaViewerPage(asset: asset),
      overrides: [
        panoramaImageProvider.overrideWithValue((_, _) => _TestImageProvider(image)),
        panoramaGPanoClientProvider.overrideWithValue(MockClient((_) async => http.Response.bytes(const [], 206))),
        isHorizonOsProvider.overrideWith((ref) => false),
        assetExifProvider(asset).overrideWith((ref) => Stream.value(exif)),
      ],
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the sphere guesses a turned VR180 photo from the size of its file: two eyes side by side', (
    tester,
  ) async {
    await pumpSphere(tester, turnedVr180, vr180File);
    expect(find.text('180°'), findsOneWidget);
    expect(find.byTooltip('3D, side by side'), findsOneWidget, reason: 'top and bottom from the turned size');
  });

  testWidgets('the sphere guesses a turned 3D photo from the size of its file: side by side, whole sphere', (
    tester,
  ) async {
    await pumpSphere(tester, turnedStereo, stereoFile);
    expect(find.text('360°'), findsOneWidget);
    expect(find.byTooltip('3D, side by side'), findsOneWidget, reason: 'mono from the turned size');
  });

  group('the immersive viewer of a Meta Quest', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(overrides: [storeServiceProvider.overrideWithValue(StoreService.I)]);
    });

    tearDown(() => container.dispose());

    ImmersiveAssetResolver resolver(Map<String, ExifInfo> exif) => ImmersiveAssetResolver(
      api: ImmersiveApi(),
      stereoLabels: const {},
      coverageOverrides: container.read(sphereCoverageOverridesProvider.notifier),
      storage: MockStorageRepository(),
      probeService: _NoProbes(),
      gpanoClient: MockClient((_) async => http.Response('', 404)),
      videoSources: VideoSourceService(VideoDecoderApi()),
      exifOf: (asset) async => exif[asset.remoteId],
    );

    test('guesses a turned photo from the size of its file', () async {
      final exif = {turnedVr180.id: vr180File, turnedStereo.id: stereoFile};
      final vr180 = await resolver(exif).resolve(turnedVr180);
      expect(vr180.url, '$server/assets/${turnedVr180.id}/original?edited=false');
      expect((vr180.view.layout, vr180.view.coverage), (StereoLayout.leftRight, SphereCoverage.half));
      final stereo = await resolver(exif).resolve(turnedStereo);
      expect((stereo.view.layout, stereo.view.coverage), (StereoLayout.leftRight, SphereCoverage.full));
    });

    test('guesses from the name alone when the size of the file is not known, never from the turned one', () async {
      final vr180 = await resolver(const {}).resolve(turnedVr180);
      expect((vr180.view.layout, vr180.view.coverage), (StereoLayout.mono, SphereCoverage.half));
    });
  });

  test('the 3D and VR180 marks of the 360° page read the size of the file', () {
    Panorama360Entry entry(RemoteAsset asset, ExifInfo file) =>
        Panorama360Entry(asset: asset, day: DateTime(2026), frame: (width: file.width, height: file.height));
    expect(panorama360TraitsOf(entry(turnedVr180, vr180File)), {Panorama360Trait.stereo3d, Panorama360Trait.vr180});
    expect(panorama360TraitsOf(entry(turnedStereo, stereoFile)), {Panorama360Trait.stereo3d});
    expect(
      panorama360TraitsOf(Panorama360Entry(asset: turnedStereo, day: DateTime(2026))),
      isEmpty,
      reason: 'the turned size reads mono',
    );
  });

  test('a video of the server opens as it is: the server edits no video', () {
    final video = RemoteAssetFactory.create(type: AssetType.video);
    expect(immersiveMediaUrl(video), '$server/assets/${video.id}/original');
  });
}
