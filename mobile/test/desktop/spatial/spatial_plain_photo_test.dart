// "Spatial 2.5D" on a plain photo of the library viewer of a computer (lib/desktop/spatial/spatial_conversion.dart):
// offered while this computer makes its 3D photo with AI (the AI features, the Spatial 2.5D switch, a gate that does
// not refuse, a photo "Make 3D (AI)" takes), with its own tooltip; never on another photo, and a 3D photo keeps its
// button. Pressed: the 3D photo made by AI known for it opens at once; otherwise the conversion dialog on the 3D photo
// alone, Convert, the job in the real queue with the fake engine, its dialog, then the 2.5D page on the file written;
// a failure in the words of the panel, Cancel and Escape that cancel the job, and so does the dialog removed by
// anything else. The choices of the 3D photo and of a version of a share, and what a job ended with.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/spatial/spatial_conversion.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_button.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ai_immersive/share_versions.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:path/path.dart' as p;

import '../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../widget_tester_extensions.dart';
import '../ai/fakes/fake_conversion_engines.dart';
import '../ai/fakes/fake_immersive_engine.dart';
import '../ai/fakes/fake_scene_engine.dart';
import '../ai/ui/settle_still.dart';
import 'spatial_ai_fakes.dart';

const _sbs = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide);
const _convertFirst = 'Spatial 2.5D: makes the 3D photo with AI first, then opens it';

LocalAsset _photo(String name, {int width = 4000, int height = 3000}) => LocalAsset(
  id: 'id-$name',
  name: name,
  type: AssetType.image,
  createdAt: DateTime(2026, 11, 26, 9),
  updatedAt: DateTime(2026, 11, 26, 9),
  width: width,
  height: height,
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

VersionFile _version(String name, {ImmersiveKind? kind, IndexedOrigin? origin, bool available = true}) => VersionFile(
  file: LibraryFile(
    assetId: 'id-$name',
    path: '/photos/$name',
    name: name,
    kind: LibraryMediaKind.image,
    size: 1000,
    modifiedMs: 0,
    createdSeconds: 0,
    mimeType: 'image/jpeg',
    cloudOnly: false,
    available: available,
  ),
  kind: kind,
  origin: origin,
);

ShareVersion _shareVersion(String name, {ImmersiveKind? kind, FlatStereoPhoto? photo}) => ShareVersion(
  entry: NetworkEntry(sourceId: 'nas', path: '/$name', isDirectory: false),
  kind: kind,
  xmp: ourXmp(),
  photo: photo,
);

/// An image that is never asked for its pixels in these tests
class _Marker extends MemoryImage {
  _Marker() : super(Uint8List(0));
}

void main() {
  group('the choices', () {
    test('the 3D photo made by AI among the versions of a library photo: one that can be opened now', () {
      final made = _version(
        'salon_3D_LRF_Full_SBS.jpg',
        kind: ImmersiveKind.stereoPhoto,
        origin: IndexedOrigin.estimated,
      );
      expect(madeStereoVersionOf(PhotoVersions(versions: [made])), same(made));
      expect(
        madeStereoVersionOf(
          PhotoVersions(
            versions: [
              _version('salon_3D_scene.jpg', kind: ImmersiveKind.volumetricScene, origin: IndexedOrigin.reconstructed),
              _version('salon_360.jpg', kind: ImmersiveKind.panorama360, origin: IndexedOrigin.generated),
              _version(
                'old_3D.jpg',
                kind: ImmersiveKind.stereoPhoto,
                origin: IndexedOrigin.estimated,
                available: false,
              ),
            ],
          ),
        ),
        isNull,
      );
      expect(madeStereoVersionOf(PhotoVersions.none), isNull);
    });

    test('the 3D photo made by AI among the versions of a photo of a share: the newest one of a format read here', () {
      final ours = FlatStereoPhoto(eyes: StereoEyes.full, xmp: ourXmp());
      final newer = FlatStereoPhoto(
        eyes: StereoEyes.full,
        xmp: ourXmp(formatVersion: immersiveFormatVersion + 1),
      );
      final made = _shareVersion('salon_3D_LRF_Full_SBS.jpg', kind: ImmersiveKind.stereoPhoto, photo: ours);
      expect(
        madeShareStereoVersionOf([
          _shareVersion('salon_3D_LRF_Full_SBS (1).jpg', kind: ImmersiveKind.stereoPhoto, photo: newer),
          _shareVersion('salon_scene.jpg', kind: ImmersiveKind.volumetricScene),
          made,
        ]),
        same(made),
      );
      expect(
        madeShareStereoVersionOf([
          _shareVersion(
            'other_LR.jpg',
            kind: ImmersiveKind.stereoPhoto,
            photo: const FlatStereoPhoto(eyes: StereoEyes.full),
          ),
        ]),
        isNull,
        reason: 'not made by AI',
      );
    });
  });

  group('the viewer of the library', () {
    late SpatialAiWorld world;
    late List<(String, SpatialPhoto)> opened;
    late List<BaseAsset> looked;
    SpatialMadePhoto? known;
    late bool flat;
    late bool spatial;

    setUp(() {
      world = SpatialAiWorld();
      opened = [];
      looked = [];
      known = null;
      flat = true;
      spatial = true;
    });

    tearDown(() => world.dispose());

    final button = find.byKey(const Key('desktop_spatial_photo'));

    Future<void> settle(WidgetTester tester, {bool Function()? until}) => settleStill(tester, until: until);

    Future<ProviderContainer> pumpViewer(
      WidgetTester tester,
      BaseAsset asset, {
      FlatStereoPhoto? stereo,
      List<Override> extra = const [],
    }) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpConsumerWidget(
        Scaffold(
          appBar: AppBar(actions: [DesktopSpatialPhotoButton(asset: asset)]),
        ),
        overrides: [
          ...world.overrides(),
          appConfigProvider.overrideWithValue(AppConfig(viewer: ViewerConfig(spatial25d: spatial))),
          flatStereoProvider(asset).overrideWith((ref) async => stereo),
          isEquirectangularProvider(asset).overrideWithValue(false),
          aiSourceProvider.overrideWith((ref, source) => flat && source.kind == ConversionKind.sbsFromPhoto),
          spatialMadeVersionOfAssetProvider.overrideWithValue((asset) async {
            looked.add(asset);
            return known;
          }),
          spatialSharePhotoOpenerProvider.overrideWithValue((context, image, name, photo) => opened.add((name, photo))),
          spatialPhotoOpenerProvider.overrideWithValue(
            (context, asset, layout, estimated) =>
                opened.add((asset.name, (layout: layout, estimatedRelief: estimated))),
          ),
          ...extra,
        ],
      );
      await settle(tester);
      return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    }

    /// The job is handed to the queue at once, as Convert does, for the photo [path]: no dialog
    Override queueAtOnce(String path) => spatialConversionLauncherProvider.overrideWith(
      (ref) =>
          (context, {assets = const [], shareFiles = const []}) async =>
              ref.read(conversionQueueProvider.notifier).add([
                ConversionRequest(
                  source: LocalFileSource(path),
                  target: ConversionTarget(folder: world.photos, fileName: 'salon_3D_LRF_Full_SBS.jpg'),
                ),
              ]).first,
    );

    group('offered', () {
      testWidgets('on a plain photo while this computer makes its 3D photo, with its own tooltip', (tester) async {
        await pumpViewer(tester, _photo('salon.jpg'));
        expect(button, findsOneWidget);
        expect(find.byTooltip(_convertFirst), findsOneWidget);
      });

      testWidgets('with the components missing: the dialog installs them', (tester) async {
        world.service = FakeAiComponentsService();
        await pumpViewer(tester, _photo('salon.jpg'));
        expect(find.byTooltip(_convertFirst), findsOneWidget);
      });

      testWidgets('not with the AI features off, the switch off, a photo the AI does not take', (tester) async {
        world.enabled = false;
        await pumpViewer(tester, _photo('salon.jpg'));
        expect(button, findsNothing, reason: 'AI features off');

        world.enabled = true;
        spatial = false;
        await pumpViewer(tester, _photo('salon.jpg'));
        expect(button, findsNothing, reason: 'Spatial 2.5D off');

        spatial = true;
        flat = false;
        await pumpViewer(tester, _photo('PANO_0001.jpg', width: 8000, height: 4000));
        expect(button, findsNothing, reason: 'a 360° photo, a video, a version: not taken by "Make 3D (AI)"');
      });

      testWidgets('not when the gate refuses: the memory, the group held back by this version', (tester) async {
        world.memory = 2 << 30;
        await pumpViewer(tester, _photo('salon.jpg'));
        expect(button, findsNothing, reason: 'not enough memory');

        world.memory = 16 << 30;
        world.held = {AiFeatureGroup.photos};
        await pumpViewer(tester, _photo('salon.jpg'));
        expect(button, findsNothing, reason: 'held back');
      });

      testWidgets('a 3D photo keeps its own button, whatever the AI', (tester) async {
        world.enabled = false;
        await pumpViewer(
          tester,
          _photo('salon_3D_LRF_Full_SBS.jpg', width: 8000, height: 3000),
          stereo: const FlatStereoPhoto(eyes: StereoEyes.full),
        );
        expect(find.byTooltip('Spatial 2.5D'), findsOneWidget);
        await tester.tap(button);
        expect(opened, [('salon_3D_LRF_Full_SBS.jpg', (layout: _sbs, estimatedRelief: false))]);
      });
    });

    group('pressed', () {
      testWidgets('with a 3D photo made by AI already: opened at once, no dialog, no job', (tester) async {
        known = (image: _Marker(), name: 'salon_3D_LRF_Full_SBS.jpg', layout: _sbs);
        final container = await pumpViewer(tester, _photo('salon.jpg'));
        await tester.tap(button);
        await settle(tester, until: () => opened.isNotEmpty);
        expect(opened, [('salon_3D_LRF_Full_SBS.jpg', (layout: _sbs, estimatedRelief: true))]);
        expect(looked.map((asset) => asset.name), ['salon.jpg']);
        expect(find.byKey(const Key('ai_conversion_dialog')), findsNothing);
        expect(container.read(conversionQueueProvider).jobs, isEmpty);
      });

      testWidgets('without one: the dialog of the 3D photo alone, Convert, the job, then the 2.5D page on its file', (
        tester,
      ) async {
        // A build that makes 3D scenes too: the dialog still offers the 3D photo alone
        world.kinds = fakeConversionEngines(scene: FakeSceneEngine());
        world.original('salon.jpg');
        final container = await pumpViewer(tester, _photo('salon.jpg'));
        await tester.tap(button);
        await settle(tester);
        expect(find.byKey(const Key('ai_conversion_dialog')), findsOneWidget);
        expect(find.byKey(const Key('ai_conversion_types')), findsNothing, reason: 'no choice of the type');
        final convert = find.byKey(const Key('ai_conversion_convert'));
        expect(tester.widget<FilledButton>(convert).onPressed, isNotNull);

        await tester.tap(convert);
        await settle(tester, until: () => opened.isNotEmpty);
        final job = container.read(conversionQueueProvider).jobs.single;
        expect(job.kind, ConversionKind.sbsFromPhoto);
        expect(job.state, ConversionState.done);
        expect(opened, [(p.basename(job.writtenPath!), (layout: _sbs, estimatedRelief: true))]);
        expect(p.basename(job.writtenPath!), 'salon_3D_LRF_Full_SBS.jpg');
        expect(find.byKey(const Key('spatial_conversion_dialog')), findsNothing);
        // Read in the zone of the test and pumped: a read waits for the writes queued before it
        DesktopAiSettings? kept;
        unawaited(world.store.read().then((settings) => kept = settings));
        await settle(tester, until: () => kept != null);
        expect(kept?.lastType, isNull, reason: 'a type the user did not choose is not kept');
      });

      testWidgets('a failure: the words of the panel, Close, nothing opened', (tester) async {
        world.engine = FakeImmersiveEngine(failAt: ImmersiveStage.depth);
        final path = world.original('salon.jpg');
        final container = await pumpViewer(tester, _photo('salon.jpg'), extra: [queueAtOnce(path)]);
        await tester.tap(button);
        await settle(tester, until: () => find.byKey(const Key('spatial_conversion_error')).evaluate().isNotEmpty);
        expect(container.read(conversionQueueProvider).jobs.single.state, ConversionState.failed);
        expect(find.text('This photo could not be read'), findsOneWidget);
        expect(find.byKey(const Key('spatial_conversion_bar')), findsNothing, reason: 'no bar left turning');

        await tester.tap(find.byKey(const Key('spatial_conversion_close')));
        await settle(tester);
        expect(find.byKey(const Key('spatial_conversion_dialog')), findsNothing);
        expect(opened, isEmpty);
      });

      testWidgets('Cancel, then Escape: the job running is cancelled and the dialog closes', (tester) async {
        world.engine = FakeImmersiveEngine(holdStage: ImmersiveStage.depth);
        final path = world.original('salon.jpg');
        final container = await pumpViewer(tester, _photo('salon.jpg'), extra: [queueAtOnce(path)]);
        ConversionJob job() => container.read(conversionQueueProvider).jobs.last;

        await tester.tap(button);
        await settle(tester, until: () => job().state == ConversionState.depth);
        expect(find.byKey(const Key('spatial_conversion_dialog')), findsOneWidget);
        expect(find.text('salon.jpg'), findsOneWidget);
        await tester.tap(find.byKey(const Key('spatial_conversion_cancel')));
        world.engine.release();
        await settle(tester, until: () => job().state.isEnded);
        expect(job().state, ConversionState.cancelled);
        expect(find.byKey(const Key('spatial_conversion_dialog')), findsNothing);

        await tester.tap(button);
        await settle(
          tester,
          until: () => container.read(conversionQueueProvider).jobs.length == 2 && job().state == ConversionState.depth,
        );
        expect(find.byKey(const Key('spatial_conversion_dialog')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        world.engine.release();
        await settle(tester, until: () => job().state.isEnded);
        expect(job().state, ConversionState.cancelled);
        expect(find.byKey(const Key('spatial_conversion_dialog')), findsNothing);
        expect(opened, isEmpty);
      });
    });
  });

  testWidgets('a lookup that never answers holds the button 10 s at most, then the conversion is offered', (
    tester,
  ) async {
    var launched = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(
              runSpatialConversion(
                context,
                name: 'salon.jpg',
                known: () => Completer<SpatialMadePhoto?>().future,
                launch: () async {
                  launched++;
                  return null;
                },
                existing: (path) async => null,
                open: (photo) => fail('nothing to open'),
              ),
            ),
            child: const Text('press'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('press'));
    await tester.pump(const Duration(seconds: 9));
    expect(launched, 0, reason: 'still looking');
    await tester.pump(const Duration(seconds: 2));
    expect(launched, 1, reason: 'taken for none past 10 s');
  });

  group('the dialog removed by something else than its buttons', () {
    late SpatialAiWorld world;

    setUp(() => world = SpatialAiWorld());
    tearDown(() => world.dispose());

    for (final waiting in [false, true]) {
      testWidgets('its job is cancelled, without an error (${waiting ? 'a job waiting' : 'the job running'})', (
        tester,
      ) async {
        world.engine = FakeImmersiveEngine(holdStage: ImmersiveStage.depth);
        final path = world.original('salon.jpg');
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpConsumerWidget(
          const Scaffold(body: SizedBox.expand()),
          overrides: [
            ...world.overrides(),
            appConfigProvider.overrideWithValue(const AppConfig(viewer: ViewerConfig(spatial25d: true))),
          ],
        );
        await settleStill(tester);
        final context = tester.element(find.byType(Scaffold));
        final container = ProviderScope.containerOf(context);
        final queue = container.read(conversionQueueProvider.notifier);
        ConversionRequest request(String name) => ConversionRequest(
          source: LocalFileSource(path),
          target: ConversionTarget(folder: world.photos, fileName: name),
        );
        var id = queue.add([request('a_3D_LRF_Full_SBS.jpg')]).first;
        if (waiting) {
          final first = id;
          await settleStill(
            tester,
            until: () => container.read(conversionQueueProvider).byId(first)!.state == ConversionState.depth,
          );
          id = queue.add([request('b_3D_LRF_Full_SBS.jpg')]).first;
        }
        final done = showDialog<SpatialMadePhoto>(
          context: context,
          barrierDismissible: false,
          builder: (context) => SpatialConversionDialog(jobId: id, name: 'salon.jpg', photoOf: (job) async => null),
        );
        await settleStill(tester);
        expect(find.byKey(const Key('spatial_conversion_dialog')), findsOneWidget);

        // As the desktop Back, a logout or a page popping under it would
        Navigator.of(context).pop();
        await tester.pump();
        expect(tester.takeException(), isNull);
        world.engine.release();
        world.engine.release();
        await settleStill(tester, until: () => container.read(conversionQueueProvider).byId(id)!.state.isEnded);
        expect(await done, isNull);
        expect(container.read(conversionQueueProvider).byId(id)!.state, ConversionState.cancelled);
        expect(tester.takeException(), isNull, reason: 'no element left listening to the queue');
      });
    }
  });

  group('what a job ended with', () {
    late Directory folder;

    setUp(() => folder = Directory.systemTemp.createTempSync('spatial_job'));
    tearDown(() => folder.deleteSync(recursive: true));

    ConversionJob job(ConversionState state, {String? written, String? existing, ConversionSkipReason? skip}) =>
        ConversionJob(
          id: 'job-1',
          batchIndex: 0,
          batchSize: 1,
          source: LocalFileSource(p.join(folder.path, 'salon.jpg')),
          kind: ConversionKind.sbsFromPhoto,
          state: state,
          writtenPath: written,
          existingVersionPath: existing,
          skipReason: skip,
        );

    test('the file written, read at once; the version it was skipped for; nothing for a failure', () async {
      final written = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync([1, 2, 3]);
      final done = await spatialJobPhoto(
        job(ConversionState.done, written: written.path),
        existing: (path) async => fail('not asked'),
      );
      expect(done?.name, 'salon_3D_LRF_Full_SBS.jpg');
      expect(done?.layout, _sbs);
      final image = done!.image as ResizeImage;
      expect((image.imageProvider as MemoryImage).bytes, [1, 2, 3]);
      expect(image.width, spatialMadePhotoMaxSide);
      // Read before the share publisher deletes it: the picture holds its bytes
      written.deleteSync();
      expect((image.imageProvider as MemoryImage).bytes, [1, 2, 3]);

      final marker = _Marker();
      final asked = <String>[];
      final skipped = await spatialJobPhoto(
        job(
          ConversionState.skipped,
          existing: '/photos/salon_3D_LRF_Full_SBS.jpg',
          skip: ConversionSkipReason.sameSettingsExists,
        ),
        existing: (path) async {
          asked.add(path);
          return marker;
        },
      );
      expect(asked, ['/photos/salon_3D_LRF_Full_SBS.jpg']);
      expect(skipped?.image, same(marker));

      expect(await spatialJobPhoto(job(ConversionState.failed), existing: (path) async => marker), isNull);
      expect(
        await spatialJobPhoto(
          job(ConversionState.skipped, skip: ConversionSkipReason.nameTaken),
          existing: (path) async => marker,
        ),
        isNull,
      );
    });
  });
}
