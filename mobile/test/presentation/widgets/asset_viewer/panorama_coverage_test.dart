import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../../widget_tester_extensions.dart';

/// Yields [image] once, a little later, as the image providers of the app do
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
  late PresentationContext context;
  late ui.Image image;
  // The XMP of the preview, for the GPano tags: none by default
  String? previewXmp;

  final coverageButton = find.byTooltip('Field of view');

  setUp(() async {
    context = await PresentationContext.create();
    previewXmp = null;
  });

  tearDown(() async {
    await StoreService.I.delete(StoreKey.sphereCoverageOverrides);
    await context.dispose();
  });

  Future<void> pumpViewer(WidgetTester tester, BaseAsset asset) async {
    image = (await tester.runAsync(() => createTestImage(width: 64, height: 32)))!;
    addTearDown(image.dispose);
    await tester.pumpConsumerWidget(
      PanoramaViewerPage(asset: asset),
      overrides: [
        panoramaImageProvider.overrideWithValue((_, _) => _TestImageProvider(image)),
        panoramaGPanoClientProvider.overrideWithValue(
          MockClient((_) async => http.Response.bytes((previewXmp ?? '').codeUnits, 206)),
        ),
        isHorizonOsProvider.overrideWith((ref) => false),
      ],
    );
  }

  String? stored() => StoreService.I.tryGet(StoreKey.sphereCoverageOverrides);

  testWidgets('shows a regular 360° photo over the whole sphere, and remembers the half sphere picked', (tester) async {
    final asset = RemoteAssetFactory.create(width: 4096, height: 2048, name: 'trip.jpg');
    await pumpViewer(tester, asset);

    expect(coverageButton, findsOneWidget);
    expect(find.text('360°'), findsOneWidget);
    expect(find.byTooltip('Mono (not 3D)'), findsOneWidget);

    await tester.tap(coverageButton);
    await tester.pumpAndSettle();

    expect(find.text('180°'), findsOneWidget);
    expect(find.text('180°, half sphere (VR180)'), findsOneWidget, reason: 'the choice is told');
    expect(stored(), '{"${asset.id}":"half"}');
    // Two square eyes side by side make a 2:1 frame
    expect(find.byTooltip('3D, side by side'), findsOneWidget);

    // Back to the guess: the choice is forgotten
    await tester.tap(coverageButton);
    await tester.pumpAndSettle();

    expect(find.text('360°'), findsOneWidget);
    expect(stored(), '{}');
    expect(find.byTooltip('Mono (not 3D)'), findsOneWidget);
  });

  testWidgets('shows a VR180 photo over the front half, as its name says, and remembers the full sphere picked', (
    tester,
  ) async {
    final asset = RemoteAssetFactory.create(width: 5760, height: 2880, name: 'IMG_VR180.jpg');
    await pumpViewer(tester, asset);

    expect(find.text('180°'), findsOneWidget);
    expect(find.byTooltip('3D, side by side'), findsOneWidget);

    await tester.tap(coverageButton);
    await tester.pumpAndSettle();

    expect(find.text('360°'), findsOneWidget);
    expect(stored(), '{"${asset.id}":"full"}');
  });

  testWidgets('opens with the coverage picked before for the asset', (tester) async {
    final asset = RemoteAssetFactory.create(width: 4096, height: 2048, name: 'trip.jpg');
    await StoreService.I.put(StoreKey.sphereCoverageOverrides, '{"${asset.id}":"half"}');

    await pumpViewer(tester, asset);

    expect(find.text('180°'), findsOneWidget);
  });

  testWidgets('takes two square eyes picked side by side for a half sphere, and keeps that layout', (tester) async {
    final asset = RemoteAssetFactory.create(width: 4096, height: 2048, name: 'trip.jpg');
    await pumpViewer(tester, asset);

    await tester.tap(find.byTooltip('Mono (not 3D)'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('3D, top and bottom'), findsOneWidget);
    expect(find.text('360°'), findsOneWidget, reason: 'two 4:1 eyes');

    await tester.tap(find.byTooltip('3D, top and bottom'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('3D, side by side'), findsOneWidget);
    expect(find.text('180°'), findsOneWidget, reason: 'two square eyes');
    expect(stored(), isNull, reason: 'a guess, not a choice');

    await tester.tap(coverageButton);
    await tester.pumpAndSettle();
    expect(find.text('360°'), findsOneWidget);
    expect(find.byTooltip('3D, side by side'), findsOneWidget);
    expect(stored(), '{"${asset.id}":"full"}');
  });

  testWidgets('has no coverage control for a partial panorama, which covers what its GPano crop says', (tester) async {
    previewXmp =
        '<rdf:Description GPano:FullPanoWidthPixels="8704" GPano:FullPanoHeightPixels="4352" '
        'GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="1088" '
        'GPano:CroppedAreaImageWidthPixels="8704" GPano:CroppedAreaImageHeightPixels="2176"/>';
    await pumpViewer(tester, RemoteAssetFactory.create(width: 8704, height: 2176, name: 'band.jpg'));

    expect(find.byTooltip('Mono (not 3D)'), findsOneWidget, reason: 'the sphere shows');
    expect(coverageButton, findsNothing);
  });
}
