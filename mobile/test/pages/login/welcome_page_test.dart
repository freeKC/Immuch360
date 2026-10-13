// The welcome page, the first screen while no session exists: the icon, the name and the promise of the app, then
// three choices in this order: without a server (the photos and videos of this device; on a computer the folders to
// choose first), a network share or a media server (the shares page, without a server), an Immich server (the login
// form). Touch, the remote of a TV (the focus starts on the first choice), the keyboard of a computer, and both themes.

import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/domain/services/feature_message.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/login/welcome.page.dart';
import 'package:immich_mobile/platform/view_intent_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/feature_message.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_handler.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/theme/color_scheme.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:immich_mobile/widgets/common/immich_title_text.dart';
import 'package:mocktail/mocktail.dart';

import '../../providers/infrastructure/local_session.fake.dart';
import '../../repository.mocks.dart';
import '../../test_utils.dart';

class _MockFeatureMessageService extends Mock implements FeatureMessageService {}

/// Answers the gallery request with [answer] and records it
class _GalleryPermission extends GalleryPermissionNotifier {
  _GalleryPermission(this.calls, this.answer) : super(DevicePermissionService(MockPermissionRepository()));

  final List<String> calls;
  final DevicePermissionStatus answer;

  @override
  Future<DevicePermissionStatus> getGalleryPermissionStatus() async => state;

  @override
  Future<DevicePermissionStatus> requestGalleryPermission() async {
    calls.add('permission');
    return state = answer;
  }
}

/// Records the deferred intents being flushed
class _ViewIntentHandler implements ViewIntentHandler {
  _ViewIntentHandler(this.calls);

  final List<String> calls;

  @override
  void init() {}

  @override
  Future<void> onAppResumed() async {}

  @override
  Future<void> flushDeferredViewIntent() async => calls.add('flush');

  @override
  Future<void> handle(ViewIntentPayload attachment) async {}
}

void main() {
  late _MockFeatureMessageService featureMessages;
  late List<String> calls;

  setUpAll(TestUtils.init);

  setUp(() {
    featureMessages = _MockFeatureMessageService();
    when(featureMessages.markSeen).thenAnswer((_) async {});
    calls = [];
  });

  final withoutServer = find.byKey(const Key('welcome_without_server'));
  final shares = find.byKey(const Key('welcome_shares'));
  final server = find.byKey(const Key('welcome_server'));

  /// A Google TV at 1920 x 1080 and 320 dpi: 960 x 540 logical pixels
  void tvScreen(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  /// A phone held upright: 400 x 800 logical pixels
  void phoneScreen(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1200, 2400)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// The welcome page under a real router whose other routes render a stub page. [tvMode] puts it in the TV shell of
  /// the app, [gallery] is the answer of the gallery request (on a computer: granted once a folder is chosen), [theme]
  /// the colours of the app.
  Future<ProviderContainer> pumpWelcome(
    WidgetTester tester, {
    bool tvMode = false,
    DevicePermissionStatus gallery = DevicePermissionStatus.granted,
    ThemeData? theme,
    TextScaler? textScaler,
  }) async {
    Widget stub(String text) => Scaffold(body: Center(child: Text(text)));
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(WelcomeRoute.name, builder: (_) => const WelcomePage()),
        ),
        AutoRoute(
          path: '/tabs',
          page: PageInfo(TabShellRoute.name, builder: (_) => stub('tabs')),
        ),
        AutoRoute(
          path: '/shares',
          page: PageInfo(NetworkSharesRoute.name, builder: (_) => stub('shares')),
        ),
        AutoRoute(
          path: '/folders',
          page: PageInfo(FoldersRoute.name, builder: (_) => stub('folders')),
        ),
        AutoRoute(
          path: '/login',
          page: PageInfo(LoginRoute.name, builder: (_) => stub('login')),
        ),
      ],
    );

    late ProviderContainer container;
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
            localSessionProvider.overrideWith(FakeLocalSessionNotifier.new),
            galleryPermissionNotifier.overrideWith((_) => _GalleryPermission(calls, gallery)),
            localSessionRefreshProvider.overrideWithValue(
              ({bool full = false}) async => calls.add('refresh full:$full'),
            ),
            viewIntentHandlerProvider.overrideWithValue(_ViewIntentHandler(calls)),
            featureMessageServiceProvider.overrideWithValue(featureMessages),
            tvModeProvider.overrideWithValue(tvMode),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return MaterialApp.router(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: theme,
                routerConfig: router.config(),
                // The text scale around the TV shell, which adds its overscan margins to what it reads
                builder: (context, child) {
                  final shell = TvShell(enabled: tvMode, child: child!);
                  return textScaler == null
                      ? shell
                      : MediaQuery(
                          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                          child: shell,
                        );
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

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
    return found;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  /// The back button of the system
  Future<void> goBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('shows the icon, the name and the promise, then the three choices in their order', (tester) async {
    phoneScreen(tester);
    await pumpWelcome(tester);

    expect(find.byType(ImmichLogo), findsOneWidget);
    expect(find.byType(ImmichTitleText), findsOneWidget);
    expect(find.text('Your media. Any screen. Every perspective.'), findsOneWidget);
    for (final (choice, title, description) in [
      (
        withoutServer,
        'Use without a server',
        'The photos and videos of this device. Add shares and media servers later.',
      ),
      (shares, 'Add a network share or a media server', 'SMB, WebDAV, DLNA, Plex or a Tapo camera'),
      (server, 'Connect to an Immich server', 'Sync with an Immich server to back up, search and share'),
    ]) {
      expect(
        find.descendant(of: choice, matching: find.text(title)),
        findsOneWidget,
        reason: title,
      );
      expect(
        find.descendant(of: choice, matching: find.text(description)),
        findsOneWidget,
        reason: title,
      );
    }

    // One above the other on a phone, under the promise
    final promise = tester.getRect(find.text('Your media. Any screen. Every perspective.'));
    final first = tester.getRect(withoutServer);
    final second = tester.getRect(shares);
    final third = tester.getRect(server);
    expect(first.top, greaterThan(promise.bottom));
    expect(second.top, greaterThan(first.bottom));
    expect(third.top, greaterThan(second.bottom));
    expect(first.width, second.width);
    expect(second.width, third.width);
    // Nothing has the focus on a touch screen
    expect(focusedIn(withoutServer), isFalse);
  });

  testWidgets('"Use without a server" opens the photos and videos of this device', (tester) async {
    final container = await pumpWelcome(tester);

    await tester.tap(withoutServer);
    await tester.pumpAndSettle();

    expect(container.read(localSessionProvider), isTrue);
    expect(container.read(hasServerProvider), isFalse);
    expect(calls, ['permission', 'refresh full:true', 'flush']);
    verify(featureMessages.markSeen).called(1);
    expect(find.text('tabs'), findsOneWidget);
    expect(find.byType(WelcomePage), findsNothing);
  });

  testWidgets('a refused gallery still opens the tabs, where the Photos tab asks again', (tester) async {
    final container = await pumpWelcome(tester, gallery: DevicePermissionStatus.denied);

    await tester.tap(withoutServer);
    await tester.pumpAndSettle();

    expect(container.read(localSessionProvider), isTrue);
    expect(find.text('tabs'), findsOneWidget);
    expect(find.text('folders'), findsNothing);
  });

  testWidgets('a share or a media server opens the shares page without a server, the tabs under it', (tester) async {
    final container = await pumpWelcome(tester);

    await tester.tap(shares);
    await tester.pumpAndSettle();

    expect(container.read(localSessionProvider), isTrue);
    // The gallery is not asked for: a share needs no access to the photos of the device
    expect(calls, ['refresh full:true', 'flush']);
    verify(featureMessages.markSeen).called(1);
    expect(find.text('shares'), findsOneWidget);

    await goBack(tester);

    expect(find.text('tabs'), findsOneWidget);
  });

  testWidgets('"Connect to an Immich server" opens the login form, whose Back comes back here', (tester) async {
    final container = await pumpWelcome(tester);

    await tester.tap(server);
    await tester.pumpAndSettle();

    expect(find.text('login'), findsOneWidget);
    expect(container.read(localSessionProvider), isFalse);
    expect(calls, isEmpty);

    await goBack(tester);

    expect(find.byType(WelcomePage), findsOneWidget);
  });

  testWidgets('a second tap while the session starts is ignored', (tester) async {
    await pumpWelcome(tester);

    await tester.tap(withoutServer);
    await tester.tap(withoutServer, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(calls, ['permission', 'refresh full:true', 'flush']);
    verify(featureMessages.markSeen).called(1);
  });

  group('with the remote of a TV', () {
    testWidgets('the focus starts on "Use without a server", and the arrows go down the choices', (tester) async {
      tvScreen(tester);
      await pumpWelcome(tester, tvMode: true);

      expect(focusedIn(withoutServer), isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(shares), isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(server), isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(shares), isTrue);

      // OK opens the choice with the focus
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('shares'), findsOneWidget);
    });

    testWidgets('OK on the first choice opens the device without a server', (tester) async {
      tvScreen(tester);
      final container = await pumpWelcome(tester, tvMode: true);

      await press(tester, LogicalKeyboardKey.select);

      expect(container.read(localSessionProvider), isTrue);
      expect(find.text('tabs'), findsOneWidget);
    });

    testWidgets('on a 1080p TV the whole page shows at once, inside the overscan margins', (tester) async {
      tvScreen(tester);
      await pumpWelcome(tester, tvMode: true);

      final area = Rect.fromLTRB(
        TvShell.overscan.left,
        TvShell.overscan.top,
        960 - TvShell.overscan.right,
        540 - TvShell.overscan.bottom,
      );
      for (final (name, finder) in [
        ('the icon', find.byType(ImmichLogo)),
        ('the promise', find.text('Your media. Any screen. Every perspective.')),
        ('Use without a server', withoutServer),
        ('a share', shares),
        ('a server', server),
      ]) {
        final rect = tester.getRect(finder);
        expect(
          area.contains(rect.topLeft) && area.contains(rect.bottomRight - const Offset(0.5, 0.5)),
          isTrue,
          reason: '$name at $rect, outside $area',
        );
      }
      // Side by side: the icon and the promise on the left, the choices on the right
      expect(tester.getRect(find.byType(ImmichLogo)).right, lessThan(tester.getRect(withoutServer).left));
    });

    testWidgets('with large text the page scrolls to the choice that has the focus', (tester) async {
      tvScreen(tester);
      await pumpWelcome(tester, tvMode: true, textScaler: const TextScaler.linear(1.6));
      final visible = Rect.fromLTRB(0, TvShell.overscan.top, 960, 540 - TvShell.overscan.bottom);
      // The choices no longer fit at once
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.maxScrollExtent, greaterThan(0));

      expect(focusedIn(withoutServer), isTrue);
      for (final choice in [shares, server]) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focusedIn(choice), isTrue);
        final rect = tester.getRect(choice);
        expect(rect.top >= visible.top - 0.5 && rect.bottom <= visible.bottom + 0.5, isTrue, reason: '$rect');
      }
    });
  });

  group('on a computer', () {
    /// Runs [body] as on Windows; the override is checked at the end of each test, before its tear down
    Future<void> onWindows(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('"Use without a server" leads to the folders while none is chosen, above the tabs', (tester) async {
      await onWindows(() async {
        // A computer without a folder reads as a gallery that is not given
        final container = await pumpWelcome(tester, gallery: DevicePermissionStatus.denied);

        await tester.tap(withoutServer);
        await tester.pumpAndSettle();

        expect(container.read(localSessionProvider), isTrue);
        expect(find.text('folders'), findsOneWidget);

        await goBack(tester);

        expect(find.text('tabs'), findsOneWidget);
      });
    });

    testWidgets('with folders already chosen it opens the tabs', (tester) async {
      await onWindows(() async {
        await pumpWelcome(tester);

        await tester.tap(withoutServer);
        await tester.pumpAndSettle();

        expect(find.text('tabs'), findsOneWidget);
        expect(find.text('folders'), findsNothing);
      });
    });

    testWidgets('a share does not lead to the folders', (tester) async {
      await onWindows(() async {
        await pumpWelcome(tester, gallery: DevicePermissionStatus.denied);

        await tester.tap(shares);
        await tester.pumpAndSettle();

        expect(find.text('shares'), findsOneWidget);
        expect(find.text('folders'), findsNothing);
      });
    });

    testWidgets('Tab goes through the choices in their order, and Enter opens the one with the focus', (tester) async {
      await onWindows(() async {
        await pumpWelcome(tester);
        // No focus before the keyboard is used: a click does not leave a ring behind
        expect(focusedIn(withoutServer), isFalse);

        await press(tester, LogicalKeyboardKey.tab);
        expect(focusedIn(withoutServer), isTrue);
        await press(tester, LogicalKeyboardKey.tab);
        expect(focusedIn(shares), isTrue);
        await press(tester, LogicalKeyboardKey.tab);
        expect(focusedIn(server), isTrue);

        await press(tester, LogicalKeyboardKey.enter);
        expect(find.text('login'), findsOneWidget);
      });
    });
  });

  group('in the light and the dark theme', () {
    /// The contrast ratio of WCAG 2 between two opaque colours
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
    }

    /// [color] drawn over [background]
    Color over(Color color, Color background) => Color.alphaBlend(color, background);

    for (final brightness in Brightness.values) {
      for (final preset in ImmichColorPreset.values) {
        testWidgets('the text of each choice reads on its card: ${preset.name}, ${brightness.name}', (tester) async {
          final theme = brightness == Brightness.light ? preset.themeOfPreset.light : preset.themeOfPreset.dark;
          await pumpWelcome(
            tester,
            theme: getThemeData(colorScheme: theme, locale: const Locale('en')),
          );
          final page = theme.surface;

          for (final (choice, title, description) in [
            (withoutServer, 'Use without a server', 'The photos and videos of this device.'),
            (shares, 'Add a network share or a media server', 'SMB, WebDAV, DLNA, Plex or a Tapo camera'),
            (server, 'Connect to an Immich server', 'Sync with an Immich server'),
          ]) {
            final material = tester.widget<Material>(
              find.descendant(of: choice, matching: find.byType(Material)).first,
            );
            final card = over(material.color!, page);
            final titleColor = tester
                .widget<Text>(find.descendant(of: choice, matching: find.text(title)))
                .style!
                .color!;
            final descriptionColor = tester
                .widget<Text>(find.descendant(of: choice, matching: find.textContaining(description)))
                .style!
                .color!;
            expect(contrast(over(titleColor, card), card), greaterThanOrEqualTo(4.5), reason: title);
            expect(contrast(over(descriptionColor, card), card), greaterThanOrEqualTo(4.5), reason: description);
          }
        });
      }
    }
  });
}
