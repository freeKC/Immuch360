// The 360° page with a remote control on a 1080p TV: on arrival the first tile of the list has the focus, not nothing,
// and Up from the first row of the grid goes to the chips above it, not to the Back button of the bar, however far
// the grid has scrolled.

import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/panorama_360.page.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_panoramas.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../unit/presentation/presentation_context.dart';

class _MockList extends Mock implements Panorama360ListService {}

/// The app with the real navigation observer and the TV shell, on a page with a button that opens the 360° page
class _App extends ConsumerStatefulWidget {
  const _App({required this.router});

  final RootStackRouter router;

  @override
  ConsumerState<_App> createState() => _AppState();
}

class _AppState extends ConsumerState<_App> {
  late final _observer = AppNavigationObserver(ref: ref);

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    debugShowCheckedModeBanner: false,
    localizationsDelegates: context.localizationDelegates,
    supportedLocales: context.supportedLocales,
    locale: context.locale,
    routerConfig: widget.router.config(navigatorObservers: () => [_observer]),
    builder: (context, child) => TvShell(child: child!),
  );
}

void main() {
  late PresentationContext context;

  // The store and the settings that the thumbnails read
  setUp(() async => context = await PresentationContext.create());
  tearDown(() => context.dispose());

  /// Opens the 360° page from a page whose button has the focus, as the Library does, with 48 photos of the device
  Future<void> openPage(WidgetTester tester) async {
    // A Google TV at 1920 x 1080 and 320 dpi: 960 x 540 logical pixels
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final assets = List<BaseAsset>.generate(
      48,
      (i) => LocalAssetStub.image1.copyWith(id: 'pano$i', width: 5760, height: 2880),
    );
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
            'LibraryRoute',
            builder: (_) => Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  autofocus: true,
                  onPressed: () => context.router.pushPath('/panorama'),
                  child: const Text('360°'),
                ),
              ),
            ),
          ),
        ),
        AutoRoute(
          path: '/panorama',
          page: PageInfo('Panorama360Route', builder: (_) => const Panorama360Page()),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          panorama360ListProvider.overrideWith((_) => list),
          panorama360ShareFilesProvider.overrideWith((_) => const []),
          localPanoramaScanProvider.overrideWithValue(() async {}),
          hasServerProvider.overrideWithValue(true),
          appConfigProvider.overrideWithValue(const AppConfig()),
          tvModeProvider.overrideWithValue(true),
        ],
        child: EasyLocalization(
          supportedLocales: locales.values.toList(),
          path: translationsPath,
          startLocale: locales.values.first,
          fallbackLocale: locales.values.first,
          saveLocale: false,
          useFallbackTranslations: true,
          assetLoader: const CodegenLoader(),
          child: _App(router: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    // The transition, then the segments and the rows of the grid
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // The thumbnails of the device do not load in a test
    tester.takeException();
  }

  Finder tiles() => find.byType(ThumbnailTile);

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    final targets = finder.evaluate().toSet();
    var found = targets.contains(focused);
    focused.visitAncestorElements((element) {
      found = found || targets.contains(element);
      return !found;
    });
    return found || finder.evaluate().any((element) => Focus.maybeOf(element) == FocusManager.instance.primaryFocus);
  }

  final back = find.byType(BackButton);
  // Found off screen too: the chips scroll under the bar
  final dateChip = find.ancestor(
    of: find.text('Date', skipOffstage: false),
    matching: find.byType(InputChip, skipOffstage: false),
  );

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('on arrival the first tile of the grid has the focus', (tester) async {
    await openPage(tester);

    expect(Focus.of(tester.element(tiles().first)).hasPrimaryFocus, isTrue, reason: 'not nothing, nor Back');
  });

  testWidgets('Up from the first row of the grid goes to the chips, not to Back, once they scrolled away', (
    tester,
  ) async {
    await openPage(tester);
    Focus.of(tester.element(tiles().first)).requestFocus();
    await tester.pump();

    for (var i = 0; i < 3; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    for (var row = 2; row >= 0; row--) {
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(back), isFalse, reason: 'Up to row $row of the grid');
    }
    expect(Focus.of(tester.element(tiles().first)).hasPrimaryFocus, isTrue);
    final bar = tester.getRect(find.byType(AppBar));
    expect(tester.getRect(dateChip).bottom, lessThanOrEqualTo(bar.bottom), reason: 'the chips hide under the bar');

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedIn(dateChip), isTrue, reason: 'the chip above the first column, back in view');
    expect(tester.getRect(dateChip).top, greaterThanOrEqualTo(bar.bottom));

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedIn(back), isTrue, reason: 'the bar comes after the chips');
  });
}
