// The focus of the remote on the watch page of the DJI live video on a TV, while the safety notice, Options or another
// page covers it (the notice on FreeKC's TV, 26 October, build 30). The page keeps running under them: a phone that
// knows this TV connects by itself, and its first picture opened the full screen view, whose key catcher took the
// focus from under the notice. The arrows then neither scrolled the notice nor reached "I understand", and Back left
// the page. These tests send the remote's keys and check where they go. Nothing here ran on a TV: these are widget
// tests.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/dji_watch.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_notice.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/routing/route_opening_key_gate.dart';

import '../../../unit/presentation/presentation_context.dart';
import 'dji_link_fakes.dart';

/// A 1080p TV: 960 by 540 dp
const _tv = Size(960, 540);

class _FakeTvApi extends Fake implements TvApi {
  @override
  Future<String?> editText(TvTextRequest request) async => null;
}

/// The test app with the app's navigation observer, which holds the keys while a route opens
class _ObservedApp extends ConsumerStatefulWidget {
  const _ObservedApp({required this.home});

  final Widget home;

  @override
  ConsumerState<_ObservedApp> createState() => _ObservedAppState();
}

class _ObservedAppState extends ConsumerState<_ObservedApp> {
  late final _observer = AppNavigationObserver(ref: ref);

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    localizationsDelegates: context.localizationDelegates,
    supportedLocales: context.supportedLocales,
    locale: context.locale,
    navigatorObservers: [_observer],
    home: Scaffold(body: widget.home),
  );
}

void main() {
  late PresentationContext context;
  late Map<StoreKey<bool>, bool> memory;

  setUp(() async {
    context = await PresentationContext.create();
    memory = {};
  });

  tearDown(() async {
    RouteOpeningKeyGate.instance.reset();
    await context.dispose();
  });

  FakeDjiLinkApi television() => FakeDjiLinkApi(
    environment: fakeEnvironment(accessoryFeature: false, flavour: 'phone'),
    snapshot: fakeSnapshot(state: DjiLinkState.unsupportedTransport),
  );

  List<Override> overrides(
    FakeDjiLinkApi api,
    FakeRelayEnvironment relay,
    void Function(DjiLinkEvents?) onEvents, {
    bool noticeRead = false,
  }) => [
    tvModeProvider.overrideWithValue(true),
    tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: true, isLowRamDevice: false)),
    tvApiProvider.overrideWithValue(_FakeTvApi()),
    djiLinkApiProvider.overrideWithValue(api),
    djiLinkEventsSetUpProvider.overrideWithValue(onEvents),
    djiRelayEnvironmentProvider.overrideWithValue(relay.build()),
    djiLiveNoticeReadProvider.overrideWith((ref) => noticeRead),
    djiLiveMemoryProvider.overrideWithValue(
      DjiLiveMemory(read: (key) => memory[key] ?? false, write: (key, value) async => memory[key] = value),
    ),
    isHorizonOsProvider.overrideWith((ref) async => false),
    djiLinkVideoViewBuilderProvider.overrideWithValue(
      () => const ColoredBox(key: Key('dji_watch_placeholder'), color: Colors.black),
    ),
  ];

  Finder notice() => find.byKey(const Key('dji_live_notice'));
  Finder text() => find.byKey(const Key('dji_live_notice_text'));
  Finder understand() => find.byKey(const Key('dji_live_notice_ok'));
  Finder watchPage() => find.byKey(const Key('dji_watch'), skipOffstage: false);
  Finder optionsPanel() => find.byKey(const Key('dji_watch_tv_options_panel'));

  /// Whether the focus is on the widget [finder] finds or inside it
  bool focusIn(WidgetTester tester, Finder finder) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null || finder.evaluate().isEmpty) {
      return false;
    }
    final target = tester.element(finder);
    if (identical(focus, target)) {
      return true;
    }
    var found = false;
    focus.visitAncestorElements((ancestor) {
      found = identical(ancestor, target);
      return !found;
    });
    return found;
  }

  /// The full screen view's key catcher has the focus
  bool fullScreenFocused() => FocusManager.instance.primaryFocus?.debugLabel == 'dji_watch_tv_full';

  double noticeOffset(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(of: text(), matching: find.byType(Scrollable)).first)
      .position
      .pixels;

  /// A first page with a button that opens the watch page, then the watch page
  Future<(FakeDjiLinkApi, FakeRelayEnvironment, DjiLinkEvents?)> open(
    WidgetTester tester, {
    bool noticeRead = false,
  }) async {
    DjiLinkEvents? listener;
    final api = television();
    final relay = FakeRelayEnvironment();
    await tester.binding.setSurfaceSize(_tv);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open_watch'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DjiWatchPage())),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(api, relay, (events) => listener = events, noticeRead: noticeRead),
    );
    await tester.tap(find.byKey(const Key('open_watch')));
    await tester.pump();
    await tester.pumpAndSettle();
    return (api, relay, listener);
  }

  /// The first picture of a phone that knows this TV
  DjiLinkSnapshot picture() => fakeSnapshot(
    decode: fakeDecode(),
    relayReceiving: fakeReceiving(),
    telemetryValues: fakeTelemetry(percent: 34, motorTimeS: 41.6),
    liveFrame: fakeFrame(),
  );

  /// A phone that knows this TV is listed, connects by itself, and its first picture comes
  Future<void> firstPicture(WidgetTester tester, FakeRelayEnvironment relay, DjiLinkEvents listener) async {
    relay.browsed.add(fakeAnnounced('192.168.1.21', fakeDroneTxt));
    await tester.pumpAndSettle();
    listener.snapshotChanged(picture());
    await tester.pumpAndSettle();
  }

  /// Down [presses] times, as FreeKC did: how far the notice scrolled, and whether "I understand" got the focus
  Future<(double, bool)> downs(WidgetTester tester, int presses) async {
    final before = noticeOffset(tester);
    var reached = false;
    for (var i = 0; i < presses; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      reached = reached || focusIn(tester, understand());
    }
    return (noticeOffset(tester) - before, reached);
  }

  /// Read to the end with the arrows, then OK on "I understand"
  Future<void> readAndAccept(WidgetTester tester) async {
    final (scrolled, reached) = await downs(tester, 8);
    expect(scrolled, greaterThan(0), reason: 'the arrows scroll the notice');
    expect(reached, isTrue, reason: 'the arrows reach I understand');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(notice(), findsNothing, reason: 'OK on I understand closes the notice');
  }

  testWidgets('no phone yet: the notice has the focus, the arrows read it to its end, OK on I understand closes it', (
    tester,
  ) async {
    await open(tester);
    expect(focusIn(tester, text()), isTrue);

    await readAndAccept(tester);

    expect(focusIn(tester, find.byKey(const Key('dji_watch_address'))), isTrue, reason: 'Phone not listed?');
  });

  testWidgets('a phone that knows this TV is listed behind the notice: the notice keeps the focus', (tester) async {
    final (api, relay, _) = await open(tester);
    relay.browsed.add(fakeAnnounced('192.168.1.21', fakeDroneTxt));
    await tester.pumpAndSettle();

    expect(api.connects, isNotEmpty, reason: 'this TV connects by itself behind the notice');
    expect(focusIn(tester, text()), isTrue);

    await readAndAccept(tester);
    expect(focusIn(tester, find.byKey(const ValueKey('dji_watch_phone_192.168.1.21:8362'))), isTrue);
  });

  testWidgets(
    'its first picture comes behind the notice: the notice keeps the focus, then the full screen view has it',
    (tester) async {
      final (_, relay, listener) = await open(tester);
      await firstPicture(tester, relay, listener!);

      expect(find.byKey(const Key('dji_watch_tv_full'), skipOffstage: false), findsOneWidget);
      expect(focusIn(tester, text()), isTrue, reason: 'build 30 gave it to the full screen view behind the notice');

      await readAndAccept(tester);

      expect(fullScreenFocused(), isTrue, reason: 'the picture had come: the remote is in the full screen view');
      expect(watchPage(), findsOneWidget);
    },
  );

  testWidgets('Back on the notice with a picture behind closes it and leaves the watch page', (tester) async {
    final (_, relay, listener) = await open(tester);
    await firstPicture(tester, relay, listener!);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(notice(), findsNothing);
    expect(watchPage(), findsNothing);
    expect(find.byKey(const Key('open_watch')), findsOneWidget, reason: 'back on the page that opened it');
  });

  testWidgets('Back on the notice with another page over the watch page leaves the watch page, not that page', (
    tester,
  ) async {
    final api = television();
    final relay = FakeRelayEnvironment();
    await tester.binding.setSurfaceSize(_tv);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late NavigatorState navigator;
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) {
          navigator = Navigator.of(context);
          return const Text('first page');
        },
      ),
      overrides: overrides(api, relay, (_) {}),
    );
    // The watch page, and in the same instant another page over it, as a second OK on the page left behind did on the
    // emulator; the notice comes over both
    navigator.push(MaterialPageRoute<void>(builder: (_) => const DjiWatchPage())).ignore();
    navigator
        .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('page over the watch page'))))
        .ignore();
    await tester.pumpAndSettle();
    expect(notice(), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(notice(), findsNothing);
    expect(watchPage(), findsNothing, reason: 'the notice not read leaves the watch page');
    expect(find.text('page over the watch page'), findsOneWidget, reason: 'build 30 closed this one instead');
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('first page'), findsOneWidget);
  });

  testWidgets('Options open on the phones view when the first picture comes: Options keeps the focus', (tester) async {
    final (_, relay, listener) = await open(tester, noticeRead: true);
    relay.browsed.add(fakeAnnounced('192.168.1.21', fakeDroneTxt));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(focusIn(tester, optionsPanel()), isTrue);

    listener!.snapshotChanged(picture());
    await tester.pumpAndSettle();

    expect(optionsPanel(), findsOneWidget);
    expect(focusIn(tester, optionsPanel()), isTrue, reason: 'build 30 gave it to the full screen view under Options');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusIn(tester, optionsPanel()), isTrue, reason: 'the arrows move in Options');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(optionsPanel(), findsNothing);
    expect(fullScreenFocused(), isTrue, reason: 'Options closed: the remote is in the full screen view');
  });

  testWidgets('the notice read again from Options: a refusal and a new first picture behind it leave it the focus', (
    tester,
  ) async {
    final (_, relay, listener) = await open(tester, noticeRead: true);
    await firstPicture(tester, relay, listener!);
    expect(fullScreenFocused(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('dji_watch_tv_safety')),
      100,
      scrollable: find.descendant(of: optionsPanel(), matching: find.byType(Scrollable)).first,
    );
    await tester.tap(find.byKey(const Key('dji_watch_tv_safety')));
    await tester.pumpAndSettle();
    expect(focusIn(tester, text()), isTrue);

    // The phone removed this TV: the phones view comes back behind the notice
    listener.snapshotChanged(fakeSnapshot(relayReceiving: fakeReceiving(state: DjiRelayReceiveState.wrongCode)));
    await tester.pumpAndSettle();
    expect(focusIn(tester, text()), isTrue, reason: 'build 30 gave it to the phone row behind the notice');

    // Added again: a new first picture opens the full screen view behind the notice
    await tester.pump(djiWatchTryEvery);
    await tester.pump();
    listener.snapshotChanged(picture());
    await tester.pumpAndSettle();
    expect(focusIn(tester, text()), isTrue, reason: 'build 30 gave it to the full screen view behind the notice');

    await readAndAccept(tester);
    expect(fullScreenFocused(), isTrue);
  });

  testWidgets('a page over the watch page when the first picture comes keeps the focus; back, the full screen has it', (
    tester,
  ) async {
    final (_, relay, listener) = await open(tester, noticeRead: true);
    relay.browsed.add(fakeAnnounced('192.168.1.21', fakeDroneTxt));
    await tester.pumpAndSettle();
    // Diagnostics, opened from Options, comes the same way: a page over the watch page
    Navigator.of(tester.element(watchPage()))
        .push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: TextButton(key: const Key('over'), autofocus: true, onPressed: () {}, child: const Text('over')),
            ),
          ),
        )
        .ignore();
    await tester.pumpAndSettle();
    expect(focusIn(tester, find.byKey(const Key('over'))), isTrue);

    listener!.snapshotChanged(picture());
    await tester.pumpAndSettle();

    expect(focusIn(tester, find.byKey(const Key('over'))), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(fullScreenFocused(), isTrue);
  });

  group('the keys while the watch page and its notice open', () {
    /// The app with its navigation observer, a first page whose "open" button has the focus and "below" under it
    Future<void> pumpObserved(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(_tv);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = television();
      final relay = FakeRelayEnvironment();
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
            overrides: [...context.overrides, ...overrides(api, relay, (_) {})],
            child: _ObservedApp(
              home: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Builder(
                    builder: (context) => TextButton(
                      key: const Key('open_watch'),
                      autofocus: true,
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DjiWatchPage())),
                      child: const Text('open'),
                    ),
                  ),
                  TextButton(key: const Key('below'), onPressed: () {}, child: const Text('below')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(focusIn(tester, find.byKey(const Key('open_watch'))), isTrue);
    }

    testWidgets('Down at once after OK goes nowhere; the notice then has the focus and Back returns to open', (
      tester,
    ) async {
      await pumpObserved(tester);

      // OK opens the page; Down and OK come before its first frame, as a slow TV or a quick hand sends them
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      // The watch page's first frame: the notice is pushed after it, and a Down in that gap
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(notice(), findsOneWidget);
      expect(focusIn(tester, text()), isTrue);
      expect(noticeOffset(tester), 0, reason: 'the early Downs did not scroll it either');
      expect(find.byType(DjiWatchPage, skipOffstage: false), findsOneWidget, reason: 'the second OK opened nothing');

      // Later, the keys read the notice
      await readAndAccept(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(focusIn(tester, find.byKey(const Key('open_watch'))), isTrue, reason: 'build 30 left it on below');
    });

    testWidgets('slow keys: each Down after the notice showed scrolls it, then OK validates', (tester) async {
      await pumpObserved(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));

      await readAndAccept(tester);
      expect(focusIn(tester, find.byKey(const Key('dji_watch_address'))), isTrue);
    });
  });
}
