// The zoom of a photo of the asset viewer on a computer (release 53, lib/desktop/window/desktop_photo_zoom.dart): the
// wheel zooms the photo on screen, + and - zoom, 0 fits, 1 shows the pixels of the original one to one; zoomed in, the
// arrows move the photo rather than turn the pages, Escape shows it whole first and only then goes on to the window
// (which closes the viewer, lot feat-desktop-escape-51), and another photo shows whole. A phone has none of it.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/window/desktop_photo_zoom.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._asset);

  final BaseAsset _asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _asset, showingControls: false);
  }
}

void main() {
  late PresentationContext context;
  // 4000 x 2000 pixels in a window of 800 x 600
  final photos = <BaseAsset>[
    LocalAssetStub.image1.copyWith(width: 4000, height: 2000),
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

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {String? character}) async {
    await tester.sendKeyEvent(key, character: character);
    await settle(tester);
  }

  /// The Escapes that went past the viewer, to the window (DesktopShell)
  late List<KeyEvent> windowEscapes;

  /// The viewer pushed over a page, on the first photo, and its zoom, null on a phone. The photos cannot load here:
  /// PhotoView lays out the view of its loading, as large as the window (800 x 600), the fit at a scale of 1, and the
  /// original of 4000 pixels on its long side shows its pixels one to one at a scale of 5.
  Future<(ProviderContainer, PhotoViewZoomTarget?)> pumpViewer(WidgetTester tester) async {
    windowEscapes = [];
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final timeline = TimelineService((
      assetSource: (index, count) async => photos.skip(index).take(count).toList(),
      bucketSource: () => Stream.value([Bucket(assetCount: photos.length)]),
      origin: TimelineOrigin.main,
    ));
    addTearDown(timeline.dispose);
    await tester.pumpWidget(
      Focus(
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            windowEscapes.add(event);
          }
          return KeyEventResult.ignored;
        },
        child: EasyLocalization(
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
              tvModeProvider.overrideWithValue(false),
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
      ),
    );
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    final zooms = find.byType(DesktopPhotoZoom);
    if (zooms.evaluate().isEmpty) {
      return (container, null);
    }
    final zoom = tester.widget<DesktopPhotoZoom>(zooms.first).target as PhotoViewZoomTarget;
    expect(zoom.frame?.fitScale, 1);
    expect(zoom.frame?.oneToOneScale, closeTo(5, 1e-9));
    return (container, zoom);
  }

  Future<void> onWindows(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('a computer: + and - zoom, 1 shows the pixels of the original one to one, 0 fits', (tester) async {
    await onWindows(() async {
      final (_, zoom) = await pumpViewer(tester);
      expect(zoom, isNotNull);
      await press(tester, LogicalKeyboardKey.numpadAdd);
      expect(zoom!.scale, closeTo(desktopZoomKeyStep, 1e-9));
      await press(tester, LogicalKeyboardKey.numpadSubtract);
      expect(zoom.scale, closeTo(1, 1e-9));
      // The original has 4000 pixels on its long side, five times the 800 of its view
      await press(tester, LogicalKeyboardKey.digit1, character: '1');
      expect(zoom.scale, closeTo(5, 1e-9));
      expect(desktopZoomLevel(zoom), closeTo(1, 1e-9));
      await press(tester, LogicalKeyboardKey.digit0, character: '0');
      expect(zoom.scale, closeTo(1, 1e-9));
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a computer: the wheel zooms the photo on screen, out at fit does nothing', (tester) async {
    await onWindows(() async {
      final (container, zoom) = await pumpViewer(tester);
      final mouse = TestPointer(61, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(400, 300)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
      await settle(tester);
      expect(zoom!.scale, closeTo(1, 1e-9));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
      await settle(tester);
      expect(zoom.scale, closeTo(1 / 0.9, 1e-9));
      expect(container.read(assetViewerProvider).showingDetails, isFalse, reason: 'the wheel never opens the details');
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a computer: zoomed in, the arrows move the photo; whole, they turn the pages', (tester) async {
    await onWindows(() async {
      final (container, zoom) = await pumpViewer(tester);
      final jump = container.read(assetViewerJumpProvider);
      await press(tester, LogicalKeyboardKey.digit1, character: '1');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(jump.currentIndex, 0, reason: 'a zoomed photo stays on screen');
      expect(zoom!.position.dx, lessThan(0), reason: 'more of its right side comes into view');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(zoom.position.dy, lessThan(0));
      expect(container.read(assetViewerProvider).showingControls, isFalse, reason: 'Down moves the photo');

      await press(tester, LogicalKeyboardKey.digit0, character: '0');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(jump.currentIndex, 1, reason: 'whole again, the arrows go through the photos');
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a computer: Escape shows a zoomed photo whole first, then goes on to the window', (tester) async {
    await onWindows(() async {
      final (_, zoom) = await pumpViewer(tester);
      await press(tester, LogicalKeyboardKey.digit1, character: '1');
      expect(desktopZoomed(zoom!), isTrue);
      await press(tester, LogicalKeyboardKey.escape);
      expect(desktopZoomed(zoom), isFalse);
      expect(zoom.position, Offset.zero);
      expect(windowEscapes, isEmpty, reason: 'the first Escape stays in the viewer');
      await press(tester, LogicalKeyboardKey.escape);
      expect(windowEscapes, hasLength(1), reason: 'the window closes the viewer, as before');
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a computer: the photo left shows whole when the viewer goes to another one', (tester) async {
    await onWindows(() async {
      final (container, zoom) = await pumpViewer(tester);
      final jump = container.read(assetViewerJumpProvider);
      await press(tester, LogicalKeyboardKey.digit1, character: '1');
      expect(desktopZoomed(zoom!), isTrue);
      unawaited(jump.jumpTo(1));
      await settle(tester);
      expect(jump.currentIndex, 1);
      expect(desktopZoomed(zoom), isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a phone: no desktop zoom, and its keys change nothing', (tester) async {
    final (container, zoom) = await pumpViewer(tester);
    expect(zoom, isNull);
    expect(find.byType(DesktopPhotoZoom), findsNothing);
    final jump = container.read(assetViewerJumpProvider);
    await press(tester, LogicalKeyboardKey.digit1, character: '1');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(jump.currentIndex, 1, reason: 'the arrows go through the photos as before');
  });
}
