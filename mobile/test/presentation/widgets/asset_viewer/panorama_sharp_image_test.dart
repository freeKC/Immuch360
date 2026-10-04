// The sharp image the panorama viewer loads once zoomed in on a photo of the server: the full size image of the
// server for most photos, the original for a raw dual fisheye one, whose full size image is its preview on a default
// server.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_calibration_store.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';

import '../../../fixtures/raw/insta360.stub.dart';
import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

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

/// The calibration of the real X3 photo for every asset, without reading any file
class _FixedCalibrations extends DualFisheyeCalibrationService {
  _FixedCalibrations()
    : super(
        store: DualFisheyeCalibrationStore(() async => null),
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  @override
  Future<DualFisheyeCalibration> forAsset(BaseAsset asset, {File? localFile}) async =>
      parseInsta360OffsetV3(x3OffsetV3)!;
}

void main() {
  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  late PresentationContext context;
  // The URL and the decode size of each image asked of the image loader of the app
  late List<(Object?, Object?, Object?)> requests;

  final gyroscopeButton = find.byTooltip('Gyroscope');

  setUp(() async {
    context = await PresentationContext.create();
    requests = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (
      message,
    ) async {
      final args = message! as List<Object?>;
      requests.add((args[0], args[3], args[4]));
      // No image: the viewer keeps the one it shows
      return <Object?>[null];
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, null);
    await context.dispose();
  });

  /// Pumps the viewer on [asset] until it shows the sphere. The shader of a raw photo stitches outside the fake time
  /// of the test: the spinner meanwhile would never let the frames settle.
  Future<void> pumpViewer(WidgetTester tester, BaseAsset asset) async {
    final image = (await tester.runAsync(() => createTestImage(width: 128, height: 64)))!;
    addTearDown(image.dispose);
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
            panoramaImageProvider.overrideWithValue((_, _) => _TestImageProvider(image)),
            panoramaGPanoClientProvider.overrideWithValue(MockClient((_) async => http.Response('', 404))),
            isHorizonOsProvider.overrideWith((ref) => false),
            dualFisheyeCalibrationServiceProvider.overrideWithValue(_FixedCalibrations()),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Material(child: PanoramaViewerPage(asset: asset)),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && gyroscopeButton.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(gyroscopeButton, findsOneWidget, reason: 'the sphere shows');
  }

  Future<void> doubleTapToZoomIn(WidgetTester tester) async {
    final centre = tester.getCenter(find.byType(PanoramaViewerPage));
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
  }

  testWidgets('loads the original of a raw photo once zoomed in, at most 8191 pixels wide', (tester) async {
    final asset = RemoteAssetFactory.create(name: 'IMG_20240908_133036_00_001.insp', width: 11968, height: 5984);
    await pumpViewer(tester, asset);
    expect(requests, isEmpty, reason: 'the preview is sharp enough before zooming in');

    await doubleTapToZoomIn(tester);

    expect(requests, [('${PresentationContext.serverEndpoint}/assets/${asset.id}/original?edited=false', 8191, 1)]);
  });

  testWidgets('loads the full size image of the server for another photo', (tester) async {
    final asset = RemoteAssetFactory.create(name: 'trip.jpg', width: 4096, height: 2048);
    await pumpViewer(tester, asset);

    await doubleTapToZoomIn(tester);

    expect(requests, [
      ('${PresentationContext.serverEndpoint}/assets/${asset.id}/thumbnail?size=fullsize&edited=false', 8191, 1),
    ]);
  });
}
