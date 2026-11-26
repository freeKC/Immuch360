// "Spatial 2.5D" on the page of a photo of a share or a folder, on a computer: offered for two eyes side by side (ours,
// another tool's by its name and frame, half width and crossed included) and two eyes one above the other by the name,
// never for a 360° photo, an ordinary photo, an Apple spatial pair, a 3D scene or a file of a newer format, nor while
// the Spatial 2.5D switch is off, nor on a phone. The page against the test media bridge, with real HTTP requests.
// An ordinary photo gets it too while this computer makes its 3D photo with AI (spatial_conversion.dart): the 3D photo
// made by AI found in its folder opens at once, else the job of the queue makes it first.

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/spatial/spatial_conversion.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_button.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/domain/models/ai_immersive/generated_panorama.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/play_on_screen/relay_file_system.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import '../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../presentation/pages/network/network_viewer_fakes.dart';
import '../ai/fakes/fake_conversion_engines.dart';
import '../ai/fakes/fake_scene_engine.dart' show fakeJpegWithXmp;
import '../ai/fakes/fake_stereo_panorama_engine.dart';
import '../ai/ui/settle_still.dart';
import 'spatial_ai_fakes.dart';

const _sbs = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide);
const _tb = SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom);
const _tbSphere = SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom, sphere: fullSphereCrop);
const _sbsSphere = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, sphere: fullSphereCrop);

/// GPano tags of an equirectangular photo, in the packet of a real JPEG
const _gpanoPacket =
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    '<rdf:Description xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" GPano:ProjectionType="equirectangular"/>'
    '</rdf:RDF></x:xmpmeta>';

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

/// An image that never comes: the thumbnails of the versions button stay blank
class _PendingImage extends ImageProvider<_PendingImage> {
  const _PendingImage(this.url);

  final Uri url;

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_PendingImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

/// Lets the real I/O of the page (the photo read and decoded) run for a while, for what must not come
Future<void> _idleRealIo(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

void main() {
  group('what a photo of a share is offered in 2.5D with', () {
    test('two eyes side by side as the probe told them: ours with the AI label, crossed half width eyes', () {
      final ours = NetworkMediaInfo(
        stereoPhoto: FlatStereoPhoto(eyes: StereoEyes.full, xmp: ourXmp()),
      );
      expect(spatialPhotoOfShareFile('salon_3D_LRF_Full_SBS.jpg', ours), (layout: _sbs, estimatedRelief: true));

      const crossed = NetworkMediaInfo(
        stereoPhoto: FlatStereoPhoto(eyes: StereoEyes.half, eyeOrder: EyeOrder.rightLeft),
      );
      expect(spatialPhotoOfShareFile('scene_RL.jpg', crossed), (
        layout: const SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, swapped: true, squeezed: true),
        estimatedRelief: false,
      ));
    });

    test('two eyes one above the other by the name, never a 360° one', () {
      expect(spatialPhotoOfShareFile('chateau_3D_TB.jpg', const NetworkMediaInfo()), (
        layout: _tb,
        estimatedRelief: false,
      ));
      expect(
        spatialPhotoOfShareFile('chateau_3D_HTB.jpg', const NetworkMediaInfo())?.layout,
        const SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom, squeezed: true),
      );
      expect(spatialPhotoOfShareFile('chateau_3D_TB.jpg', const NetworkMediaInfo(cameraEquirect: true)), isNull);
      expect(spatialPhotoOfShareFile('chateau_360_TB.jpg', const NetworkMediaInfo()), isNull, reason: '360° name');
    });

    test('nothing for an ordinary photo, a file not read yet, an Apple pair, a 3D scene, a newer format', () {
      expect(spatialPhotoOfShareFile('IMG_1234.jpg', const NetworkMediaInfo()), isNull);
      expect(spatialPhotoOfShareFile('chateau_3D_TB.jpg', null), isNull, reason: 'not read yet');
      const pair = HeicStereoPair(
        primaryItemId: 1,
        leftItemId: 2,
        rightItemId: 3,
        pitmIdOffset: 0,
        pitmIdBytes: 2,
        width: 4032,
        height: 3024,
      );
      expect(spatialPhotoOfShareFile('IMG_0001_TB.heic', const NetworkMediaInfo(stereoPair: pair)), isNull);
      const scene = NetworkMediaInfo(scene: SceneXmp(origin: ImmersiveOrigin.reconstructedFromPhoto));
      expect(spatialPhotoOfShareFile('salon_TB.jpg', scene), isNull);
      final newer = NetworkMediaInfo(
        stereoPhoto: FlatStereoPhoto(
          eyes: StereoEyes.full,
          xmp: ourXmp(formatVersion: immersiveFormatVersion + 1),
        ),
      );
      expect(spatialPhotoOfShareFile('salon_3D_LRF_Full_SBS.jpg', newer), isNull);
    });

    test('a 360° photo of two eyes as its 360° button lays them out; nothing for one eye, a raw photo, no frame', () {
      const sphere = NetworkMediaInfo(cameraEquirect: true);
      expect(spatialPhotoOfShareFile('pano_3D_TB.jpg', sphere, decoded: const Size(2048, 2048)), (
        layout: _tbSphere,
        estimatedRelief: false,
      ));
      expect(
        spatialPhotoOfShareFile('pano.jpg', sphere, decoded: const Size(4096, 1024))?.layout,
        _sbsSphere,
        reason: 'two eyes side by side, by the frame alone',
      );
      expect(
        spatialPhotoOfShareFile(
          'pano.jpg',
          const NetworkMediaInfo(cameraEquirect: true, frameWidth: 5760, frameHeight: 5760),
        )?.layout,
        _tbSphere,
        reason: 'its EXIF frame before it is decoded',
      );
      expect(
        spatialPhotoOfShareFile('lac_VR180.jpg', sphere, decoded: const Size(4096, 2048))?.layout,
        const SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, sphere: halfSphereCrop),
      );
      expect(spatialPhotoOfShareFile('pano.jpg', sphere, decoded: const Size(4096, 2048)), isNull, reason: 'one eye');
      expect(spatialPhotoOfShareFile('pano_3D_TB.jpg', sphere), isNull, reason: 'no frame yet');
      expect(
        spatialPhotoOfShareFile(
          'IMG_0001.insp',
          const NetworkMediaInfo(rawKind: RawMediaKind.insta360Photo),
          decoded: const Size(2048, 2048),
        ),
        isNull,
        reason: 'a raw photo of a 360° camera',
      );
      const ours = NetworkMediaInfo(
        cameraEquirect: true,
        panorama: GeneratedPanoramaInfo(kind: ImmersiveKind.stereoPanorama360, origin: ImmersiveOrigin.estimatedDepth),
      );
      expect(spatialPhotoOfShareFile('pano_360_3D.jpg', ours, decoded: const Size(4096, 4096)), (
        layout: _tbSphere,
        estimatedRelief: true,
      ));
    });

    test('a frame the probe could not read: told by the name and the size the page decoded it at', () {
      const read = NetworkMediaInfo();
      expect(spatialPhotoOfShareFile('salon_LR.heic', read), isNull, reason: 'no frame yet');
      expect(spatialPhotoOfShareFile('salon_LR.heic', read, decoded: const Size(4096, 1152)), (
        layout: _sbs,
        estimatedRelief: false,
      ));
      expect(spatialPhotoOfShareFile('salon.heic', read, decoded: const Size(4096, 1152)), isNull, reason: 'no name');
      expect(
        spatialPhotoOfShareFile(
          'salon_LR.heic',
          const NetworkMediaInfo(cameraEquirect: true),
          decoded: const Size(4096, 1152),
        ),
        isNull,
        reason: '360°',
      );
    });
  });

  group('the page of a photo of a share', () {
    late Drift db;
    late StoreService store;
    late MemoryShare share;
    late TestMediaServer server;
    late List<(String, SpatialPhoto)> opened;
    late List<ImageProvider> images;
    HttpOverrides? previousOverrides;

    setUpAll(() async {
      // Real HTTP to the test server: the widget tests answer every request with an error otherwise
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      share = MemoryShare(_source);
      server = await TestMediaServer.start(share);
    });

    tearDownAll(() async {
      await server.close();
      HttpOverrides.global = previousOverrides;
    });

    setUp(() async {
      db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
      share = MemoryShare(
        _source,
        files: {
          '/salon_LR.jpg': jpegFile(width: 3840, height: 1080),
          '/salon_3D_LRF_Full_SBS.jpg': jpegFile(width: 8000, height: 3000, xmp: ourXmp()),
          '/chateau_3D_TB.jpg': fakePhoto(),
          '/pano_3D_TB.jpg': fakePhoto(equirectangularXmp),
          '/pano_360_TB.jpg': fakeJpegWithXmp(_gpanoPacket, width: 64, height: 64),
          '/PANO_0001.jpg': fakeJpegWithXmp(_gpanoPacket, width: 128, height: 64),
          '/IMG_1234.jpg': jpegFile(width: 4000, height: 3000),
        },
      );
      server.share = share;
      opened = [];
      images = [];
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });

    tearDown(() async {
      await store.dispose();
      await db.close();
    });

    /// Runs [body] as on a Windows computer
    Future<void> onComputer(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    /// [ai]: the AI of a computer (SpatialAiWorld.overrides), else the AI features off
    Future<void> pumpPhoto(
      WidgetTester tester,
      String path, {
      bool spatial = true,
      List<Override> ai = const [],
      String sourceId = 'nas',
    }) async {
      await pumpNetworkRouter(
        tester,
        home: NetworkPhotoPage(sourceId: sourceId, path: path),
        settle: false,
        overrides: [
          storeServiceProvider.overrideWithValue(store),
          overrideConnections((ref) => FakeConnections(ref, share, baseUrl: server.baseUrl)),
          isHorizonOsProvider.overrideWith((ref) async => false),
          appConfigProvider.overrideWithValue(AppConfig(viewer: ViewerConfig(spatial25d: spatial))),
          // A fresh cache per test
          networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
          networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
          if (ai.isEmpty) aiFeaturesEnabledProvider.overrideWith((ref) => false),
          ...ai,
          spatialSharePhotoOpenerProvider.overrideWithValue((context, image, name, photo) {
            images.add(image);
            opened.add((name, photo));
          }),
        ],
      );
    }

    final button = find.byKey(const Key('desktop_spatial_photo'));
    final rotate = find.byKey(const Key('network_photo_rotate'));
    bool shows(Finder finder) => finder.evaluate().isNotEmpty;

    testWidgets('two eyes side by side by the name and the frame: offered, and opens the photo with its layout', (
      tester,
    ) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/salon_LR.jpg');
        await pumpRealIo(tester, () => shows(button));
        expect(find.byTooltip('Spatial 2.5D'), findsOneWidget);

        await tester.tap(button);
        await tester.pump();
        expect(opened, [('salon_LR.jpg', (layout: _sbs, estimatedRelief: false))]);
        // The picture the page shows, from the image cache: no second download nor decode, the same 4096 px cap
        expect(
          find.byWidgetPredicate((widget) => widget is Image && widget.image == images.single),
          findsWidgets,
          reason: 'the 2.5D page gets the provider of the photo shown',
        );
        await endRealIo(tester);
      });
    });

    testWidgets('a 3D photo of ours: offered, with the relief estimated by AI', (tester) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/salon_3D_LRF_Full_SBS.jpg');
        await pumpRealIo(tester, () => shows(button));

        await tester.tap(button);
        await tester.pump();
        expect(opened, [('salon_3D_LRF_Full_SBS.jpg', (layout: _sbs, estimatedRelief: true))]);
        await endRealIo(tester);
      });
    });

    testWidgets('two eyes one above the other by the name: offered top bottom', (tester) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/chateau_3D_TB.jpg');
        await pumpRealIo(tester, () => shows(button));

        await tester.tap(button);
        await tester.pump();
        expect(opened, [('chateau_3D_TB.jpg', (layout: _tb, estimatedRelief: false))]);
        await endRealIo(tester);
      });
    });

    testWidgets('nothing for a 360° photo, even named top bottom, nor for an ordinary photo', (tester) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/pano_3D_TB.jpg');
        await pumpRealIo(tester, () => shows(find.byTooltip('360°')));
        expect(find.byTooltip('360°'), findsOneWidget, reason: 'its file was read');
        expect(button, findsNothing);
        await endRealIo(tester);

        await pumpPhoto(tester, '/IMG_1234.jpg');
        await pumpRealIo(tester, () => shows(rotate));
        expect(rotate, findsOneWidget, reason: 'its file was read');
        expect(button, findsNothing);
        await endRealIo(tester);
      });
    });

    testWidgets('a 360° photo of two eyes, by its decoded frame: offered, and opens as a sphere', (tester) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/pano_360_TB.jpg');
        await pumpRealIo(tester, () => shows(button));
        expect(find.byTooltip('360°'), findsOneWidget);
        expect(find.byTooltip('Spatial 2.5D'), findsOneWidget);
        await tester.tap(button);
        await tester.pump();
        expect(opened, [('pano_360_TB.jpg', (layout: _tbSphere, estimatedRelief: false))]);
        await endRealIo(tester);

        // One eye: nothing with the AI off
        await pumpPhoto(tester, '/PANO_0001.jpg');
        await pumpRealIo(tester, () => shows(find.byTooltip('360°')));
        await _idleRealIo(tester);
        expect(button, findsNothing);
        await endRealIo(tester);
      });
    });

    testWidgets('nothing while the Spatial 2.5D switch is off', (tester) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/chateau_3D_TB.jpg', spatial: false);
        await pumpRealIo(tester, () => shows(rotate));
        expect(rotate, findsOneWidget, reason: 'its file was read');
        expect(button, findsNothing);
        await endRealIo(tester);
      });
    });

    testWidgets('nothing on a phone', (tester) async {
      await pumpPhoto(tester, '/chateau_3D_TB.jpg');
      await pumpRealIo(tester, () => shows(rotate));
      expect(rotate, findsOneWidget, reason: 'its file was read');
      expect(button, findsNothing);
      await endRealIo(tester);
    });

    group('a plain photo, while this computer makes its 3D photo with AI', () {
      late SpatialAiWorld world;
      const convertFirst = 'Spatial 2.5D: makes the 3D photo with AI first, then opens it';

      setUp(() => world = SpatialAiWorld());
      tearDown(() => world.dispose());

      /// The job of the photo handed to the queue at once, as Convert does, for a copy of it on this computer
      Override queueAtOnce() => spatialConversionLauncherProvider.overrideWith(
        (ref) =>
            (context, {assets = const [], shareFiles = const []}) async =>
                ref.read(conversionQueueProvider.notifier).add([
                  ConversionRequest(
                    source: LocalFileSource(world.original(shareFiles.single.name)),
                    target: ConversionTarget(folder: world.photos, fileName: 'IMG_1234_3D_LRF_Full_SBS.jpg'),
                  ),
                ]).first,
      );

      testWidgets('offered with its own tooltip; not for a 360° photo, nor with the switch off, nor on a phone', (
        tester,
      ) async {
        await onComputer(() async {
          await pumpPhoto(tester, '/IMG_1234.jpg', ai: world.overrides());
          await pumpRealIo(tester, () => shows(button));
          expect(find.byTooltip(convertFirst), findsOneWidget);
          await endRealIo(tester);

          await pumpPhoto(tester, '/pano_3D_TB.jpg', ai: world.overrides());
          await pumpRealIo(tester, () => shows(find.byTooltip('360°')));
          expect(find.byTooltip('360°'), findsOneWidget, reason: 'its file was read');
          expect(button, findsNothing);
          await endRealIo(tester);

          await pumpPhoto(tester, '/IMG_1234.jpg', spatial: false, ai: world.overrides());
          await pumpRealIo(tester, () => shows(rotate));
          expect(rotate, findsOneWidget, reason: 'its file was read');
          expect(button, findsNothing);
          await endRealIo(tester);

          // A 3D photo keeps its own button
          await pumpPhoto(tester, '/salon_LR.jpg', ai: world.overrides());
          await pumpRealIo(tester, () => shows(button));
          expect(find.byTooltip('Spatial 2.5D'), findsOneWidget);
          await endRealIo(tester);
        });
        await pumpPhoto(tester, '/IMG_1234.jpg', ai: world.overrides());
        await pumpRealIo(tester, () => shows(rotate));
        expect(rotate, findsOneWidget, reason: 'its file was read');
        expect(button, findsNothing, reason: 'a phone');
        await endRealIo(tester);
      });

      testWidgets('not when the gate refuses this computer', (tester) async {
        world.memory = 2 << 30;
        await onComputer(() async {
          await pumpPhoto(tester, '/IMG_1234.jpg', ai: world.overrides());
          await pumpRealIo(tester, () => shows(rotate));
          expect(rotate, findsOneWidget, reason: 'its file was read');
          expect(button, findsNothing);
          await endRealIo(tester);
        });
      });

      testWidgets('not for a photo a phone sends from its relay: nothing is written next to it (release 53)', (
        tester,
      ) async {
        const relay = NetworkSource(
          id: 'tree:relay-00112233445566778899aabbccddeeff',
          type: NetworkSourceType.phoneRelay,
          name: 'Pixel',
          host: '192.168.1.20',
        );
        expect(isPlayRelaySource(relay.id), isTrue);
        final t = StaticTranslations.instance;
        await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source, relay]));
        share = MemoryShare(relay, files: {'/IMG_1234.jpg': jpegFile(width: 4000, height: 3000)});
        server.share = share;
        await onComputer(() async {
          await pumpPhoto(tester, '/IMG_1234.jpg', sourceId: relay.id, ai: world.overrides());
          // The relayed photo does not turn, so its menu tells the file was read; then give the button its chance
          await pumpRealIo(tester, () => shows(find.byTooltip(t.more)));
          expect(find.byTooltip(t.more), findsOneWidget, reason: 'its file was read');
          await pumpRealIo(tester, () => shows(button));
          expect(button, findsNothing);
          expect(find.byTooltip(convertFirst), findsNothing);
          await endRealIo(tester);
        });
      });

      testWidgets('pressed with a 3D photo made by AI in its folder: that one opens at once, no job', (tester) async {
        final original = jpegFile(width: 4000, height: 3000);
        share = MemoryShare(
          _source,
          folders: {},
          files: {
            '/salon.jpg': original,
            '/salon_3D_LRF_Full_SBS.jpg': jpegFile(
              width: 8000,
              height: 3000,
              xmp: ourXmp(sourceName: 'salon.jpg', sourceSize: original.length),
            ),
          },
        );
        share.folders['/'] = [share.file('/salon.jpg'), share.file('/salon_3D_LRF_Full_SBS.jpg')];
        server.share = share;
        await onComputer(() async {
          await pumpPhoto(tester, '/salon.jpg', ai: [...world.overrides(), queueAtOnce()]);
          await pumpRealIo(tester, () => shows(button));
          expect(find.byTooltip(convertFirst), findsOneWidget);
          await tester.tap(button);
          await pumpRealIo(tester, () => opened.isNotEmpty);
          expect(opened, [('salon_3D_LRF_Full_SBS.jpg', (layout: _sbs, estimatedRelief: true))]);
          final container = ProviderScope.containerOf(tester.element(find.byType(NetworkPhotoPage)));
          expect(container.read(conversionQueueProvider).jobs, isEmpty);
          await endRealIo(tester);
        });
      });

      testWidgets('pressed without one: the job of the queue, its dialog, then the 2.5D page on the file made', (
        tester,
      ) async {
        await onComputer(() async {
          await pumpPhoto(tester, '/IMG_1234.jpg', ai: [...world.overrides(), queueAtOnce()]);
          await pumpRealIo(tester, () => shows(button));
          await tester.tap(button);
          await settleStill(tester, until: () => opened.isNotEmpty);
          final container = ProviderScope.containerOf(tester.element(find.byType(NetworkPhotoPage)));
          final job = container.read(conversionQueueProvider).jobs.single;
          expect(job.state, ConversionState.done);
          expect(opened, [('IMG_1234_3D_LRF_Full_SBS.jpg', (layout: _sbs, estimatedRelief: true))]);
          expect(find.byKey(const Key('spatial_conversion_dialog')), findsNothing);
          await endRealIo(tester);
        });
      });

      group('a 360° photo of one eye, while this computer makes its 3D version', () {
        const convertFirst360 = 'Spatial 2.5D: makes the 360° 3D photo with AI first, then opens it';

        /// The job of the 3D version handed to the queue at once, as Convert does, for a copy of it on this computer
        Override sphereAtOnce() => spatialSphereConversionLauncherProvider.overrideWith(
          (ref) =>
              (context, {assets = const [], shareFiles = const []}) async =>
                  ref.read(conversionQueueProvider.notifier).add([
                    ConversionRequest(
                      source: LocalFileSource(world.original(shareFiles.single.name)),
                      target: ConversionTarget(folder: world.photos, fileName: 'PANO_0001_3D.jpg'),
                    ),
                  ], kind: ConversionKind.stereoPanoramaFromPanorama).first,
        );

        testWidgets('offered with its own tooltip, not without the engine; pressed: the job, then the sphere', (
          tester,
        ) async {
          await onComputer(() async {
            await pumpPhoto(tester, '/PANO_0001.jpg', ai: [...world.overrides(), sphereAtOnce()]);
            await pumpRealIo(tester, () => shows(find.byTooltip('360°')));
            await _idleRealIo(tester);
            expect(button, findsNothing, reason: 'this build does not make the type');
            await endRealIo(tester);

            world.kinds = fakeConversionEngines(stereoPanorama: FakeStereoPanoramaEngine());
            await pumpPhoto(tester, '/PANO_0001.jpg', ai: [...world.overrides(), sphereAtOnce()]);
            await pumpRealIo(tester, () => shows(button));
            expect(find.byTooltip(convertFirst360), findsOneWidget);
            await tester.tap(button);
            await settleStill(tester, until: () => opened.isNotEmpty);
            final container = ProviderScope.containerOf(tester.element(find.byType(NetworkPhotoPage)));
            final job = container.read(conversionQueueProvider).jobs.single;
            expect(job.kind, ConversionKind.stereoPanoramaFromPanorama);
            expect(job.state, ConversionState.done);
            expect(opened, [('PANO_0001_3D.jpg', (layout: _tbSphere, estimatedRelief: true))]);
            await endRealIo(tester);
          });
        });
      });
    });
  });
}
