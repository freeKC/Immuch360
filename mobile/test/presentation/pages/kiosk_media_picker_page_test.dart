// The picker of the kiosk media (Settings, Advanced, "Kiosk mode"): the 360° list of the Library tab in a selection
// mode of its own, its title instead of a count and no Done; a tap on a tile goes back with that asset as the kiosk
// media, without opening it; the close button goes back with nothing.

import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/kiosk_media_picker.page.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_panoramas.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../unit/presentation/presentation_context.dart';

class _MockList extends Mock implements Panorama360ListService {}

void main() {
  late PresentationContext context;

  // The store and the settings that the thumbnails read
  setUp(() async => context = await PresentationContext.create());
  tearDown(() => context.dispose());

  final assets = List<BaseAsset>.generate(
    6,
    (i) => LocalAssetStub.image1.copyWith(id: 'pano$i', name: 'pano$i.jpg', width: 5760, height: 2880),
  );

  /// The settings page as a button that opens the picker, as KioskSettings does; what the picker gave goes to [picks].
  /// Returns the container of the app, whose selection the picker must leave alone.
  Future<ProviderContainer> openPicker(WidgetTester tester, List<KioskMedia?> picks) async {
    final list = _MockList();
    when(() => list.timelineQuery).thenReturn((
      assetSource: (i, n) async => assets.sublist(i, math.min(i + n, assets.length)),
      bucketSource: () => Stream.value([TimeBucket(date: DateTime(2026, 10, 5), assetCount: assets.length)]),
      origin: TimelineOrigin.panorama360,
    ));
    when(() => list.views).thenAnswer((_) => Stream.value(const Panorama360View()));

    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(
            'SettingsRoute',
            builder: (_) => Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => picks.add(await context.router.pushPath<KioskMedia>('/picker')),
                  child: const Text('Choose'),
                ),
              ),
            ),
          ),
        ),
        AutoRoute(
          path: '/picker',
          page: PageInfo('KioskMediaPickerRoute', builder: (_) => const KioskMediaPickerPage()),
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        panorama360ListProvider.overrideWith((_) => list),
        panorama360ShareFilesProvider.overrideWith((_) => const []),
        localPanoramaScanProvider.overrideWithValue(() async {}),
        hasServerProvider.overrideWithValue(true),
        appConfigProvider.overrideWithValue(const AppConfig()),
        tvModeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: EasyLocalization(
          supportedLocales: locales.values.toList(),
          path: translationsPath,
          startLocale: locales.values.first,
          fallbackLocale: locales.values.first,
          saveLocale: false,
          useFallbackTranslations: true,
          assetLoader: const CodegenLoader(),
          child: Builder(
            builder: (context) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              routerConfig: router.config(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose'));
    // The transition, then the segments and the rows of the grid
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // The thumbnails of the device do not load in a test
    tester.takeException();
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    tester.takeException();
  }

  final pickerTitle = find.text('Choose the 360° photo or video of the kiosk');

  testWidgets('the 360° list opens in a selection of its own: its title, no count, no Done', (tester) async {
    final container = await openPicker(tester, []);

    expect(pickerTitle, findsOneWidget);
    expect(find.text('Done'), findsNothing);
    expect(find.byType(ThumbnailTile), findsNWidgets(assets.length));
    expect(container.read(multiSelectProvider).forceEnable, isFalse, reason: 'the selection of the app stays off');
  });

  testWidgets('a tap on a tile goes back with that asset as the kiosk media, without opening it', (tester) async {
    final picks = <KioskMedia?>[];
    final container = await openPicker(tester, picks);

    await tester.tap(find.byType(ThumbnailTile).at(2));
    await settle(tester);

    expect(picks, [KioskMedia.asset(assets[2])]);
    expect(picks.single, const KioskAssetMedia(localId: 'pano2', name: 'pano2.jpg', isVideo: false));
    expect(pickerTitle, findsNothing, reason: 'back on the settings');
    expect(find.text('Choose'), findsOneWidget);
    expect(container.read(multiSelectProvider).selectedAssets, isEmpty);
  });

  testWidgets('the close button goes back with nothing', (tester) async {
    final picks = <KioskMedia?>[];
    await openPicker(tester, picks);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);

    expect(picks, [null]);
    expect(pickerTitle, findsNothing);
  });
}
