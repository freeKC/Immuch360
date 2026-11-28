// The 360° photo viewer under a pinch of a computer's touchpad (28 November 2026): the pinch zooms (the field of view),
// and the pan Windows sends with it (trackpad_pinch_sequences.dart) no longer turns the view; two fingers that scroll
// still turn it; a pinch sent as a scale signal zooms.

import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

import '../../../desktop/window/trackpad_pinch_sequences.dart';

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

  Future<void> pumpViewer(WidgetTester tester) async {
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

  Future<void> onWindows(WidgetTester tester, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('a pinch that doubles halves the field of view, and the view does not turn', (tester) async {
    await onWindows(tester, () async {
      await pumpViewer(tester);
      final at = tester.getCenter(find.byType(PanoramaViewerPage)) + const Offset(150, 120);
      final before = view(tester);
      await sendPanZoom(tester, at, windowsPinch(2, at));
      await tester.pumpAndSettle();
      final after = view(tester);
      expect(after.fov, closeTo(before.fov / 2, 0.5));
      expect(after.longitude, closeTo(before.longitude, 0.5), reason: 'the pan of the pinch turns nothing');
      expect(after.latitude, closeTo(before.latitude, 0.5));
    });
  });

  testWidgets('two fingers that scroll still turn the view', (tester) async {
    await onWindows(tester, () async {
      await pumpViewer(tester);
      final at = tester.getCenter(find.byType(PanoramaViewerPage));
      final before = view(tester);
      await sendPanZoom(tester, at, scroll(const Offset(-200, 0)));
      await tester.pumpAndSettle();
      expect(view(tester).longitude, isNot(closeTo(before.longitude, 1)));
      expect(view(tester).fov, before.fov);
    });
  });

  testWidgets('a pinch sent as a scale signal zooms', (tester) async {
    await onWindows(tester, () async {
      await pumpViewer(tester);
      final pad = TestPointer(62, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.hover(tester.getCenter(find.byType(PanoramaViewerPage))));
      final before = view(tester).fov;
      await tester.sendEventToBinding(pad.scale(1.5));
      await tester.pumpAndSettle();
      expect(view(tester).fov, closeTo(before / 1.5, 0.5));
    });
  });
}
