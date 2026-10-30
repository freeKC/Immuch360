// The left navigation pattern of the TV guidelines in the tab shell: Back from the content of a tab goes to its
// destination in the rail, from there to Photos, from Photos out of the app. Never a loop, never a confirmation. A
// phone keeps its bottom bar as before, hidden during a selection even when it turns.

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/kiosk_config.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/common/tab_shell.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/kiosk/kiosk_start.provider.dart';
import 'package:immich_mobile/providers/search/tv_search_navigation.provider.dart';
import 'package:immich_mobile/routing/router.dart';

class _NotReadOnly extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _WithoutServer extends LocalSessionNotifier {
  @override
  bool build() => true;
}

/// Search and Albums need a server: without one their destinations are disabled and a tap on them does nothing
class _WithServer extends LocalSessionNotifier {
  @override
  bool build() => false;
}

class _NoHaptics extends HapticNotifier {
  _NoHaptics(super.ref);

  @override
  void selectionClick() {}
}

/// Counts the kiosk starts the shell asks for, and what each did. The opener of the app is replaced by a count of the
/// openings (it reads the services of the viewer, not part of this test); the notice is the one of the app.
class _CountingKioskStart extends KioskStart {
  final List<KioskStartOutcome> outcomes = [];
  final List<KioskMedia> opened = [];

  @override
  Future<KioskStartOutcome> run({
    required KioskConfig config,
    required Future<bool> Function() isHorizonOs,
    required KioskOpener Function(KioskMedia media) prepare,
    required KioskCountdown countdown,
  }) async {
    final outcome = await super.run(
      config: config,
      isHorizonOs: isHorizonOs,
      prepare: (media) =>
          () async => opened.add(media),
      countdown: countdown,
    );
    outcomes.add(outcome);
    return outcome;
  }
}

const _film = KioskAssetMedia(remoteId: 'remote-1', name: 'expo_360.mp4', isVideo: true);

void main() {
  late int systemPops;

  setUp(() {
    systemPops = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') {
          systemPops++;
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    required bool tvMode,
    Size size = const Size(1920, 1080),
    bool hasServer = false,
    KioskStart? kioskStart,
    KioskConfig kiosk = const KioskConfig(),
  }) async {
    // A TV screen: landscape, so the tabs are a navigation rail
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    Widget content(String name) => Center(
      child: ElevatedButton(onPressed: () {}, child: Text('$name content')),
    );
    AutoRoute tab(String name, String path, {bool initial = false}) => AutoRoute(
      path: path,
      initial: initial,
      page: PageInfo(name, builder: (_) => content(path)),
    );
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(TabShellRoute.name, builder: (_) => const TabShellPage()),
          children: [
            tab(MainTimelineRoute.name, 'photos', initial: true),
            tab(SearchRoute.name, 'search'),
            tab(LibraryRoute.name, 'library'),
            tab(AlbumsRoute.name, 'albums'),
          ],
        ),
      ],
    );

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
            tvModeProvider.overrideWithValue(tvMode),
            readonlyModeProvider.overrideWith(_NotReadOnly.new),
            localSessionProvider.overrideWith(hasServer ? _WithServer.new : _WithoutServer.new),
            hapticFeedbackProvider.overrideWith(_NoHaptics.new),
            // By default no kiosk media chosen: the shell starts as usual (see startKiosk)
            appConfigProvider.overrideWithValue(AppConfig(kiosk: kiosk)),
            // A Meta Quest, asked only when a kiosk media is chosen
            isHorizonOsProvider.overrideWith((_) async => true),
            if (kioskStart != null) kioskStartProvider.overrideWithValue(kioskStart),
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              // As main.dart does
              builder: (context, child) => tvMode ? TvShell(child: child!) : child!,
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
  }

  bool hasFocus(WidgetTester tester, String text) => Focus.of(tester.element(find.text(text))).hasPrimaryFocus;

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Future<void> openLibraryAndFocusItsContent(WidgetTester tester) async {
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.text('library content'), findsOneWidget);
    Focus.of(tester.element(find.text('library content'))).requestFocus();
    await tester.pumpAndSettle();
  }

  testWidgets('the shell asks for the kiosk start once per run of the app, which opens nothing with no media chosen', (
    tester,
  ) async {
    final kiosk = _CountingKioskStart();
    await pumpShell(tester, tvMode: true, kioskStart: kiosk);
    expect(kiosk.outcomes, [KioskStartOutcome.off]);

    // Another tab, in the same shell
    await openLibraryAndFocusItsContent(tester);
    expect(kiosk.outcomes, [KioskStartOutcome.off]);

    // A new shell in the same run of the app (a login, a return from the welcome page): no second start
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(tester, tvMode: true, kioskStart: kiosk);
    expect(kiosk.outcomes, [KioskStartOutcome.off, KioskStartOutcome.ranBefore]);
    expect(find.byType(SnackBar), findsNothing);
  });

  group('a kiosk media chosen on a Meta Quest', () {
    final notice = find.text('Kiosk mode: expo_360.mp4 opens in a few seconds');

    testWidgets('the shell says it opens soon, and Cancel leaves the app as it is', (tester) async {
      final kiosk = _CountingKioskStart();
      await pumpShell(
        tester,
        tvMode: false,
        kioskStart: kiosk,
        kiosk: KioskConfig(media: _film.encode()),
      );

      expect(notice, findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(kiosk.outcomes, [KioskStartOutcome.cancelled]);
      expect(kiosk.opened, isEmpty);
      expect(notice, findsNothing);
      expect(find.text('photos content'), findsOneWidget);
    });

    testWidgets('without Cancel, the media opens once the notice is over', (tester) async {
      final kiosk = _CountingKioskStart();
      await pumpShell(
        tester,
        tvMode: false,
        kioskStart: kiosk,
        kiosk: KioskConfig(media: _film.encode()),
      );
      expect(notice, findsOneWidget);
      expect(kiosk.opened, isEmpty);

      await tester.pump(kioskCountdownDelay);
      await tester.pumpAndSettle();

      expect(kiosk.outcomes, [KioskStartOutcome.opened]);
      expect(kiosk.opened, [_film]);
      expect(notice, findsNothing);
    });
  });

  testWidgets('Back: the rail, then Photos, then out of the app, in three presses', (tester) async {
    await pumpShell(tester, tvMode: true);
    await openLibraryAndFocusItsContent(tester);

    await back(tester);
    expect(hasFocus(tester, 'Library'), isTrue, reason: 'the destination of the tab in the rail');
    expect(find.text('library content'), findsOneWidget);
    expect(systemPops, 0);

    await back(tester);
    expect(find.text('photos content'), findsOneWidget);
    expect(hasFocus(tester, 'Photos'), isTrue);
    expect(systemPops, 0);

    await back(tester);
    expect(systemPops, 1, reason: 'out to the TV home, without a confirmation');
  });

  testWidgets('Back from active Search results resets Search before leaving the tab', (tester) async {
    await pumpShell(tester, tvMode: true, hasServer: true);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('search content'))).requestFocus();
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.text('search content')));
    container.read(tvSearchHasActiveQueryProvider.notifier).state = true;
    final before = container.read(tvSearchReturnToStartProvider);

    await back(tester);
    expect(container.read(tvSearchReturnToStartProvider), before + 1);
    expect(find.text('search content'), findsOneWidget);
    expect(hasFocus(tester, 'Search'), isFalse, reason: 'Back first resets results in the Search content');

    // After SearchPage clears its query, the next Back goes to the rail.
    container.read(tvSearchHasActiveQueryProvider.notifier).state = false;
    await back(tester);
    expect(hasFocus(tester, 'Search'), isTrue);
    expect(systemPops, 0);
  });

  testWidgets('Back on the rail goes to Photos, even with Search results', (tester) async {
    await pumpShell(tester, tvMode: true, hasServer: true);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.text('search content')));
    container.read(tvSearchHasActiveQueryProvider.notifier).state = true;
    final before = container.read(tvSearchReturnToStartProvider);
    Focus.of(tester.element(find.text('Search'))).requestFocus();
    await tester.pumpAndSettle();

    await back(tester);
    expect(find.text('photos content'), findsOneWidget, reason: 'the rail step of the left navigation');
    expect(hasFocus(tester, 'Photos'), isTrue);
    expect(container.read(tvSearchReturnToStartProvider), before, reason: 'Search is not reset from the rail');
    expect(systemPops, 0);
  });

  testWidgets('Back in Photos goes to the rail, Search left with its results', (tester) async {
    await pumpShell(tester, tvMode: true, hasServer: true);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.text('search content')));
    // Search keeps its results out of view: the flag stays set while another tab shows
    container.read(tvSearchHasActiveQueryProvider.notifier).state = true;
    final before = container.read(tvSearchReturnToStartProvider);
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('photos content'))).requestFocus();
    await tester.pumpAndSettle();

    await back(tester);
    expect(hasFocus(tester, 'Photos'), isTrue, reason: 'the destination of the tab in the rail');
    expect(container.read(tvSearchReturnToStartProvider), before, reason: 'the Search out of view is not reset');
    expect(systemPops, 0);
  });

  testWidgets('Back from the content of Photos goes to the rail first', (tester) async {
    await pumpShell(tester, tvMode: true);
    Focus.of(tester.element(find.text('photos content'))).requestFocus();
    await tester.pumpAndSettle();

    await back(tester);
    expect(hasFocus(tester, 'Photos'), isTrue);
    expect(systemPops, 0);

    await back(tester);
    expect(systemPops, 1);
  });

  testWidgets('the arrows go from the rail to the content and back', (tester) async {
    await pumpShell(tester, tvMode: true);
    Focus.of(tester.element(find.text('Photos'))).requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(hasFocus(tester, 'photos content'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(focused.findAncestorWidgetOfExactType<NavigationRail>(), isNotNull, reason: 'a destination of the rail');
  });

  testWidgets('out of the remote control layout Back works as before: Photos, then out', (tester) async {
    await pumpShell(tester, tvMode: false);
    await openLibraryAndFocusItsContent(tester);

    await back(tester);
    expect(find.text('photos content'), findsOneWidget, reason: 'straight to Photos, not to the rail');
    expect(systemPops, 0);

    await back(tester);
    expect(systemPops, 1);
  });

  testWidgets('out of the remote control layout Back from Search results goes to Photos as before', (tester) async {
    await pumpShell(tester, tvMode: false, hasServer: true);
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.text('search content'), findsOneWidget);
    Focus.of(tester.element(find.text('search content'))).requestFocus();
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.text('search content')));
    container.read(tvSearchHasActiveQueryProvider.notifier).state = true;
    final before = container.read(tvSearchReturnToStartProvider);

    await back(tester);
    expect(find.text('photos content'), findsOneWidget, reason: 'straight to Photos, the results left as they are');
    expect(container.read(tvSearchReturnToStartProvider), before, reason: 'Search is not reset');
    expect(systemPops, 0);
  });

  testWidgets('a phone that turns during a selection keeps its bottom bar hidden', (tester) async {
    const portrait = Size(1080, 1920);
    await pumpShell(tester, tvMode: false, size: portrait);
    expect(find.byType(NavigationBar), findsOneWidget);

    EventStream.shared.emit(const MultiSelectToggleEvent(true));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);

    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pumpAndSettle();
    tester.view.physicalSize = portrait;
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing, reason: 'still selecting');

    EventStream.shared.emit(const MultiSelectToggleEvent(false));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
