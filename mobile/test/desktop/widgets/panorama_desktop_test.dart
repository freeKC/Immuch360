// The 360° photo viewer on a computer (design 4.2, 4.3 and 4.7): no gyroscope button but a full screen button, the
// mouse wheel zooms, + and - zoom by the character typed whatever the keyboard layout, a mouse drag turns the view, a
// double click zooms, and a system that asks for fewer animations gets no inertia. The phones keep their gyroscope
// button, their inertia and no full screen button.

import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

/// Yields [image] once, as an image from the network would
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

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await store.dispose();
    await db.close();
  });

  Future<void> pumpViewer(WidgetTester tester, {bool reducedMotion = false}) async {
    final image = (await tester.runAsync(() => createTestImage(width: 64, height: 32)))!;
    addTearDown(image.dispose);
    final PanoramaSource source = (image: _TestImageProvider(image), name: 'trip.jpg', length: null, read: null);
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
            tvModeProvider.overrideWithValue(false),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
                child: child!,
              ),
              home: PanoramaViewerPage.source(source: source),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ({double longitude, double latitude, double fov}) view(WidgetTester tester) =>
      (tester.state(find.byType(PanoramaViewerPage)) as PanoramaViewProbe).view;

  Offset sphereCenter(WidgetTester tester) => tester.getCenter(find.byType(PanoramaViewerPage));

  testWidgets('a computer has a full screen button and no gyroscope button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester);
    expect(find.byIcon(Icons.explore_outlined), findsNothing);
    expect(find.byKey(const Key('desktop_full_screen')), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone keeps its gyroscope button and has no full screen button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpViewer(tester);
    expect(find.byIcon(Icons.explore_outlined), findsOneWidget);
    expect(find.byKey(const Key('desktop_full_screen')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the wheel zooms in and out within the usual limits', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester);
    final start = view(tester).fov;
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(sphereCenter(tester)));

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
    await tester.pumpAndSettle();
    final zoomedIn = view(tester).fov;
    expect(zoomedIn, lessThan(start));

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.pumpAndSettle();
    expect(view(tester).fov, greaterThan(zoomedIn));

    for (var i = 0; i < 40; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    }
    await tester.pumpAndSettle();
    expect(view(tester).fov, 115);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a notch sent as several small wheel moves zooms as much as one notch', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester);
    final start = view(tester).fov;
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(sphereCenter(tester)));

    // A high resolution or free spinning wheel: four moves of a quarter notch, on the scale of the test screen
    final notch = desktopWheelNotch(TargetPlatform.windows, tester.view.devicePixelRatio);
    for (var i = 0; i < 4; i++) {
      await tester.sendEventToBinding(mouse.scroll(Offset(0, -notch / 4)));
    }
    await tester.pumpAndSettle();
    expect(view(tester).fov, closeTo(start * 0.9, 0.01));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the wheel does nothing on a phone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpViewer(tester);
    final start = view(tester).fov;
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(sphereCenter(tester)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
    await tester.pumpAndSettle();
    expect(view(tester).fov, start);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('+ and - of an AZERTY keyboard zoom, by the character they type', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester);
    final start = view(tester).fov;

    // Shift and the "=" key
    await tester.sendKeyDownEvent(LogicalKeyboardKey.equal, character: '+');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.equal);
    await tester.pumpAndSettle();
    final zoomedIn = view(tester).fov;
    expect(zoomedIn, lessThan(start));

    // The "6" key of the main row types "-"
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit6, character: '-');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit6);
    await tester.pumpAndSettle();
    expect(view(tester).fov, greaterThan(zoomedIn));

    // The number pad
    final before = view(tester).fov;
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
    await tester.pumpAndSettle();
    expect(view(tester).fov, lessThan(before));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a mouse drag turns the view and a double click zooms', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester);
    final start = view(tester);

    await tester.dragFrom(sphereCenter(tester), const Offset(-200, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(view(tester).longitude, greaterThan(start.longitude + 5));

    final before = view(tester).fov;
    await tester.tapAt(sphereCenter(tester), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(sphereCenter(tester), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(view(tester).fov, isNot(before));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('fewer animations: the view stops where the arrow is released', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester, reducedMotion: true);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final released = view(tester).longitude;
    expect(released, greaterThan(0));
    await tester.pumpAndSettle();
    expect(view(tester).longitude, released);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone keeps its inertia even with fewer animations', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpViewer(tester, reducedMotion: true);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final released = view(tester).longitude;
    await tester.pumpAndSettle();
    expect(view(tester).longitude, greaterThan(released));
    debugDefaultTargetPlatformOverride = null;
  });
}
