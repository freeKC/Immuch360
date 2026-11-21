// The zoom of a photo with the remote of a TV, which has no pinch: the zoom keys of the remote (channel up and down on
// most) and Zoom in, on the right of Rotate in the bottom bar, zoom the photo on screen; then the arrows move it rather
// than go to another asset, Back shows it whole before it closes the viewer, and the first zoom of the viewer says so
// once. Another asset shows whole. Phones keep their pinch: no button, the keys change nothing.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_page.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/rotate_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/tv_zoom_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_photo_zoom.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:immich_mobile/widgets/photo_view/src/utils/photo_view_utils.dart';
import 'package:mocktail/mocktail.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._asset);

  final BaseAsset _asset;

  @override
  AssetViewerState build() {
    super.build();
    // The bars hidden, as once a photo of a TV opened and its controls went
    return AssetViewerState(currentAsset: _asset, showingControls: false);
  }
}

void main() {
  late PresentationContext context;
  final photos = <BaseAsset>[
    LocalAssetStub.image1,
    LocalAssetStub.image2,
    LocalAssetStub.image1.copyWith(id: 'local-third'),
  ];

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      null,
    );
    await context.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    tester.takeException();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  /// The viewer pushed over a page, on the first photo, whose controller is [photo]: the photos cannot load here, so
  /// the page of the first photo is handed one laid out as a 1920 x 1080 photo on a 960 x 540 screen
  Future<ProviderContainer> pumpViewer(WidgetTester tester, PhotoViewController photo, {bool tvMode = true}) async {
    final timeline = TimelineService((
      assetSource: (index, count) async => photos.skip(index).take(count).toList(),
      bucketSource: () => Stream.value([Bucket(assetCount: photos.length)]),
      origin: TimelineOrigin.main,
    ));
    addTearDown(timeline.dispose);
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
            ...context.overrides,
            tvModeProvider.overrideWithValue(tvMode),
            assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(photos[0])),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Material(child: AssetViewerPage(initialIndex: 0, timelineService: timeline)),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    photo.scaleBoundaries = const ScaleBoundaries(
      PhotoViewComputedScale.contained,
      12.0,
      PhotoViewComputedScale.contained,
      Size(960, 540),
      Size(1920, 1080),
    );
    final page = tester.widget<AssetPage>(find.byWidgetPredicate((widget) => widget is AssetPage && widget.index == 0));
    page.onPhotoController!(photo, attached: true);
    return ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
  }

  PhotoViewController newPhoto() {
    final photo = PhotoViewController(initialScale: 0.5);
    addTearDown(photo.dispose);
    return photo;
  }

  testWidgets('on a TV the zoom keys zoom the photo, the arrows move it, Back shows it whole then closes', (
    tester,
  ) async {
    final photo = newPhoto();
    final container = await pumpViewer(tester, photo);
    final jump = container.read(assetViewerJumpProvider);

    await press(tester, LogicalKeyboardKey.channelUp);
    await press(tester, LogicalKeyboardKey.channelUp);
    expect(tvPhotoZoomOf(photo), closeTo(1.5625, 1e-9));
    expect(find.text('Zoomed in: the arrows move the photo, Back shows it whole'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(jump.currentIndex, 0, reason: 'a zoomed photo stays on screen');
    expect(photo.position.dx, lessThan(0), reason: 'more of its right side comes into view');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(photo.position.dy, lessThan(0));
    expect(container.read(assetViewerProvider).showingControls, isFalse, reason: 'Down moves the photo');

    await press(tester, LogicalKeyboardKey.channelDown);
    expect(tvPhotoZoomOf(photo), closeTo(1.25, 1e-9));

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(AssetViewer), findsOneWidget, reason: 'Back shows the photo whole first');
    expect(tvPhotoZoomed(photo), isFalse);
    expect(photo.position, Offset.zero);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(jump.currentIndex, 1, reason: 'whole again, the arrows go through the photos');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    tester.takeException();
    expect(find.byType(AssetViewer), findsNothing);
  });

  testWidgets('on a TV Zoom in, one Right from Rotate, zooms by one step at each press; OK never lands on it', (
    tester,
  ) async {
    final photo = newPhoto();
    final container = await pumpViewer(tester, photo);
    bool zoomHasFocus() =>
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvZoomInButton>() != null;
    bool rotateHasFocus() =>
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvRotateButton>() != null;

    // A double OK on the photo shows and hides the controls, as before: OK lands neither on Rotate nor on Zoom in
    await press(tester, LogicalKeyboardKey.select);
    expect(container.read(assetViewerProvider).showingControls, isTrue);
    expect(find.bySemanticsLabel('Zoom in'), findsOneWidget);
    expect(zoomHasFocus(), isFalse);
    await press(tester, LogicalKeyboardKey.select);
    expect(container.read(assetViewerProvider).showingControls, isFalse);
    expect(tvPhotoZoomed(photo), isFalse);

    // Down reaches Rotate, Zoom in is one Right away
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(rotateHasFocus(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(zoomHasFocus(), isTrue);

    await press(tester, LogicalKeyboardKey.select);
    expect(tvPhotoZoomOf(photo), closeTo(1.25, 1e-9));
    await press(tester, LogicalKeyboardKey.select);
    expect(tvPhotoZoomOf(photo), closeTo(1.5625, 1e-9));
  });

  testWidgets('on a TV another photo shows whole, and the one left is whole when the viewer comes back', (
    tester,
  ) async {
    final photo = newPhoto();
    final container = await pumpViewer(tester, photo);
    final jump = container.read(assetViewerJumpProvider);
    await press(tester, LogicalKeyboardKey.channelUp);
    expect(tvPhotoZoomed(photo), isTrue);

    await press(tester, LogicalKeyboardKey.mediaTrackNext);

    expect(jump.currentIndex, 1);
    expect(tvPhotoZoomed(photo), isFalse);
    expect(photo.position, Offset.zero);
  });

  testWidgets('a phone keeps its pinch: no Zoom in button, and the zoom keys change nothing', (tester) async {
    final photo = newPhoto();
    final container = await pumpViewer(tester, photo, tvMode: false);
    container.read(assetViewerProvider.notifier).setControls(true);
    await settle(tester);

    expect(find.byKey(const Key('tv_zoom_in_button')), findsNothing);
    await press(tester, LogicalKeyboardKey.channelUp);
    expect(tvPhotoZoomed(photo), isFalse);
  });
}
