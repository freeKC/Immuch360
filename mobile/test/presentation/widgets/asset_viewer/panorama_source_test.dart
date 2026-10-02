// The panorama viewer on a photo that is no asset (PanoramaViewerPage.source): a file of a network share, for example.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

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
    // Longer than a GPano window, with the XMP at its tail: the head, then the tail are read
    final file = Uint8List.fromList([...List.filled(200 * 1024, 0), ...ascii.encode(xmp)]);
    await pumpViewer(tester, name: 'partial.jpg', file: file);

    expect(reads, [(0, 131072), (file.length - 131072, 131072)]);
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
}
