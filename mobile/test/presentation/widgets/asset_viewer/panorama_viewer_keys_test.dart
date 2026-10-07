// The 360° photo viewer with a remote control: the arrows turn the view while they are held and ease out when
// released, the zoom keys zoom within the usual limits, OK goes to Zoom in (never Close), Left from there reaches
// Close, which closes, Back and Down leave the app bar before Back closes the viewer, and a TV has neither the
// gyroscope button nor a missing hint.

import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/data/db/main/database.dart';
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
    await store.dispose();
    await db.close();
  });

  /// The viewer over a page, so that closing it shows that page again
  Future<void> pumpViewer(WidgetTester tester, {bool tvMode = true}) async {
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
            tvModeProvider.overrideWithValue(tvMode),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: (_) => PanoramaViewerPage.source(source: source))),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  ({double longitude, double latitude, double fov}) view(WidgetTester tester) =>
      (tester.state(find.byType(PanoramaViewerPage)) as PanoramaViewProbe).view;

  /// Holds [key] down for [duration], frame by frame
  Future<void> hold(WidgetTester tester, LogicalKeyboardKey key, Duration duration) async {
    await tester.sendKeyDownEvent(key);
    for (var elapsed = Duration.zero; elapsed < duration; elapsed += const Duration(milliseconds: 16)) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendKeyUpEvent(key);
  }

  testWidgets('a held right arrow turns the view right, faster and faster, then eases to a stop', (tester) async {
    await pumpViewer(tester);
    expect(view(tester).longitude, 0);

    await hold(tester, LogicalKeyboardKey.arrowRight, const Duration(milliseconds: 600));
    final released = view(tester).longitude;
    // 40 degrees per second at first, 120 after half a second: about 40 degrees over 0.6 s
    expect(released, inInclusiveRange(25, 60));

    await tester.pumpAndSettle();
    expect(view(tester).longitude, greaterThan(released + 10), reason: 'it eases on like after a flick');
    expect(view(tester).latitude, 0);
  });

  testWidgets('left turns the other way, and a short press nudges by a few degrees', (tester) async {
    await pumpViewer(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(view(tester).longitude, inInclusiveRange(-20, -5));
  });

  testWidgets('up looks up, never past the zenith', (tester) async {
    await pumpViewer(tester);

    await hold(tester, LogicalKeyboardKey.arrowUp, const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(view(tester).latitude, greaterThan(5));

    await hold(tester, LogicalKeyboardKey.arrowUp, const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(view(tester).latitude, 90);

    await hold(tester, LogicalKeyboardKey.arrowDown, const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(view(tester).latitude, lessThan(90));
  });

  testWidgets('channel up and down zoom, within 15 to 115 degrees', (tester) async {
    await pumpViewer(tester);
    expect(view(tester).fov, 90);

    await tester.sendKeyEvent(LogicalKeyboardKey.channelUp);
    await tester.pumpAndSettle();
    expect(view(tester).fov, closeTo(72, 0.01));

    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.channelUp);
      await tester.pumpAndSettle();
    }
    expect(view(tester).fov, 15);

    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.channelDown);
      await tester.pumpAndSettle();
    }
    expect(view(tester).fov, 115);
  });

  testWidgets('OK goes to Zoom in, not Close; Back returns to the sphere, then closes', (tester) async {
    await pumpViewer(tester);
    final zoomIn = tester.widget<IconButton>(find.byKey(const Key('panorama_zoom_in'))).focusNode!;

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(zoomIn.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(view(tester).fov, closeTo(72, 0.01), reason: 'OK on Zoom in zooms in');
    expect(find.byType(PanoramaViewerPage), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PanoramaViewerPage), findsOneWidget, reason: 'back to the sphere first');
    expect(zoomIn.hasFocus, isFalse);

    // The arrows turn the view again
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(view(tester).longitude, greaterThan(0));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PanoramaViewerPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('Left from the zoom buttons reaches Close, and OK there closes the viewer', (tester) async {
    await pumpViewer(tester);
    final close = Focus.of(tester.element(find.descendant(of: find.byType(CloseButton), matching: find.byType(Icon))));

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    final zoomOut = find.descendant(of: find.byTooltip('Zoom out'), matching: find.byType(Icon));
    expect(Focus.of(tester.element(zoomOut)).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(close.hasPrimaryFocus, isTrue, reason: 'never the sphere under the app bar');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(PanoramaViewerPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('Down from the app bar goes back to the sphere, whose arrows turn the view again', (tester) async {
    await pumpViewer(tester);
    final zoomIn = tester.widget<IconButton>(find.byKey(const Key('panorama_zoom_in'))).focusNode!;

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(zoomIn.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(zoomIn.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(view(tester).longitude, greaterThan(0));
  });

  testWidgets('a TV has zoom buttons, no gyroscope, and a hint for the arrows for a few seconds', (tester) async {
    await pumpViewer(tester);

    expect(find.byIcon(Icons.explore_outlined), findsNothing);
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    expect(find.byTooltip('Zoom out'), findsOneWidget);
    expect(find.text('Arrows to look around, OK for the controls, Back to close'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Arrows to look around, OK for the controls, Back to close'), findsNothing);
  });

  testWidgets('a phone keeps the gyroscope, without zoom buttons nor hint, and Back closes at once', (tester) async {
    await pumpViewer(tester, tvMode: false);

    expect(find.byIcon(Icons.explore_outlined), findsOneWidget);
    expect(find.byTooltip('Zoom in'), findsNothing);
    expect(find.text('Arrows to look around, OK for the controls, Back to close'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PanoramaViewerPage), findsNothing);
  });
}
