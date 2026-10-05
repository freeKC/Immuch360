// The panorama viewer on a photo that is no asset (PanoramaViewerPage.source): a file of a network share, for example.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

import '../../../fixtures/raw/insta360.stub.dart';
import '../../../widget_tester_extensions.dart';

/// Yields [image] once, a little later, as an image from the network would
class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  const _TestImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) => Future.value(this);

  @override
  ImageStreamCompleter loadImage(_TestImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image.clone())));
}

void main() {
  late Drift db;
  late StoreService store;
  late List<(int, int)> reads;

  final coverageButton = find.byTooltip('Field of view');

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    reads = [];
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  /// A reader of [bytes] that records what it reads, or fails with [failure]
  ByteRangeReader reader(Uint8List bytes, {Exception? failure}) => (offset, length) async {
    reads.add((offset, length));
    if (failure != null) {
      throw failure;
    }
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(start + length, bytes.length));
  };

  Future<void> pumpViewer(
    WidgetTester tester, {
    required String name,
    int width = 64,
    int height = 32,
    Uint8List? file,
    Exception? failure,
  }) async {
    final image = (await tester.runAsync(() => createTestImage(width: width, height: height)))!;
    addTearDown(image.dispose);
    final PanoramaSource source = (
      image: _TestImageProvider(image),
      name: name,
      length: file?.length,
      read: file == null ? null : reader(file, failure: failure),
    );
    await tester.pumpConsumerWidget(
      PanoramaViewerPage.source(source: source),
      overrides: [storeServiceProvider.overrideWithValue(store), isHorizonOsProvider.overrideWith((ref) => false)],
    );
  }

  testWidgets('shows a photo that is no asset over the whole sphere, guessing from the image and its name', (
    tester,
  ) async {
    await pumpViewer(tester, name: 'trip.jpg');

    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.text('360°'), findsOneWidget);
    expect(find.byTooltip('Mono (not 3D)'), findsOneWidget);
  });

  testWidgets('a name that says VR180 shows two eyes side by side over the front half', (tester) async {
    await pumpViewer(tester, name: 'trip_vr180.jpg');

    expect(find.text('180°'), findsOneWidget);
    expect(find.byTooltip('3D, side by side'), findsOneWidget);
  });

  testWidgets('reads the GPano tags of the file: a partial panorama covers its crop, with no coverage control', (
    tester,
  ) async {
    const xmp =
        '<rdf:Description GPano:ProjectionType="equirectangular" GPano:FullPanoWidthPixels="9202" '
        'GPano:FullPanoHeightPixels="4601" GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="2035" '
        'GPano:CroppedAreaImageWidthPixels="4460" GPano:CroppedAreaImageHeightPixels="1667"/>';
    // Longer than a GPano window, with the XMP at its tail: the head, then the tail are read, after the last 72 bytes,
    // which tell a raw Insta360 photo
    final file = Uint8List.fromList([...List.filled(200 * 1024, 0), ...ascii.encode(xmp)]);
    await pumpViewer(tester, name: 'partial.jpg', file: file);

    expect(reads, [(file.length - 72, 72), (0, 131072), (file.length - 131072, 131072)]);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(coverageButton, findsNothing);
    expect(find.byTooltip('Mono (not 3D)'), findsOneWidget);
  });

  testWidgets('a file that cannot be read keeps the full sphere', (tester) async {
    await pumpViewer(tester, name: 'trip.jpg', file: Uint8List(10), failure: Exception('share gone'));

    expect(reads, [(0, 131072)]);
    expect(coverageButton, findsOneWidget);
    expect(find.text('360°'), findsOneWidget);
  });

  testWidgets('the coverage picked holds while the viewer is open, and is not remembered', (tester) async {
    await pumpViewer(tester, name: 'trip.jpg');

    await tester.tap(coverageButton);
    await tester.pumpAndSettle();

    expect(find.text('180°'), findsOneWidget);
    expect(find.text('180°, half sphere (VR180)'), findsOneWidget, reason: 'the choice is told');
    expect(store.tryGet(StoreKey.sphereCoverageOverrides), isNull);

    await tester.tap(coverageButton);
    await tester.pumpAndSettle();
    expect(find.text('360°'), findsOneWidget);
  });

  group('raw dual fisheye photos', () {
    final stereoButton = find.byTooltip('Mono (not 3D)');

    // An X3 photo: the JPEG, then the trailer of the camera with its calibration
    final x3Photo = insta360File([insta360Record(1, x3Metadata(), format: 1)], body: insta360PhotoHead());

    /// Pumps the viewer on the photo [name], whose file is [file], and lets the shader stitch it until [label] shows.
    /// The shader runs outside the fake time of the test: the spinner meanwhile would never let the frames settle.
    Future<void> pumpRawViewer(
      WidgetTester tester, {
      required String name,
      required Uint8List file,
      required Finder label,
    }) async {
      final image = (await tester.runAsync(() => createTestImage(width: 128, height: 64)))!;
      addTearDown(image.dispose);
      final PanoramaSource source = (
        image: _TestImageProvider(image),
        name: name,
        length: file.length,
        read: reader(file),
      );
      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: locales.values.toList(),
          path: translationsPath,
          startLocale: locales.values.first,
          fallbackLocale: locales.values.first,
          saveLocale: false,
          useFallbackTranslations: true,
          assetLoader: const CodegenLoader(),
          child: ProviderScope(
            overrides: [
              storeServiceProvider.overrideWithValue(store),
              isHorizonOsProvider.overrideWith((ref) => false),
            ],
            child: Builder(
              builder: (context) => MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                home: Material(child: PanoramaViewerPage.source(source: source)),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 100 && label.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    testWidgets('stitches a .insp photo with the calibration of its file, over the whole sphere, and says so', (
      tester,
    ) async {
      final label = find.text('Raw 360° file, stitched by the app (lens calibration read from the file)');
      await pumpRawViewer(tester, name: 'IMG_20240908_133036_00_001.insp', file: x3Photo, label: label);

      expect(label, findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(coverageButton, findsNothing, reason: 'a stitch covers the whole sphere');
      expect(stereoButton, findsNothing, reason: 'two lenses side by side are no 3D layout');
      expect(reads, isNot(contains((0, 131072))), reason: 'a raw photo has no GPano tags to read');
    });

    testWidgets('finds a photo renamed from .insp by the end of its file', (tester) async {
      final label = find.text('Raw 360° file, stitched by the app (lens calibration read from the file)');
      await pumpRawViewer(tester, name: 'IMG_001.jpg', file: x3Photo, label: label);

      expect(label, findsOneWidget);
      expect(coverageButton, findsNothing);
    });

    testWidgets('shows as it is a photo whose trailer says the camera stitched it (field 129, 6)', (tester) async {
      final stitched = insta360File([
        insta360Record(1, x5Metadata(imageCategory: 6), format: 1),
      ], body: insta360PhotoHead());
      final raw = find.textContaining('stitched by the app');
      await pumpRawViewer(tester, name: 'IMG_001.jpg', file: stitched, label: raw);
      // The reads of the trailer and of the GPano tags, past the time the stitch would have taken
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }

      expect(raw, findsNothing);
      expect(coverageButton, findsOneWidget, reason: 'an equirect photo, which may be a VR180 one');
      expect(find.text('360°'), findsOneWidget);
      expect(reads, contains((0, 131072)), reason: 'its GPano tags are read as for any equirect photo');
    });

    testWidgets('stitches a .insp photo whose trailer was cut with the nominal values of an X3', (tester) async {
      final label = find.text('Raw 360° file, stitched by the app (nominal lens values, seams possible)');
      final cut = Uint8List.fromList([...insta360PhotoHead(), 0xff, 0xd9]);
      await pumpRawViewer(tester, name: 'IMG_001.insp', file: cut, label: label);

      expect(label, findsOneWidget);
    });
  });
}
