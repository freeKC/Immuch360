// The login form with a remote control: a TV that never reached a server starts on "Use without a server", the
// address, the email and the password are typed in the native text dialog, and OAuth, which opens a web page, is
// replaced by a line that says so. A computer has the same line until OAuth is checked there.

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/feature_message.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/server_info/server_config.model.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/pages/login/login.page.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/feature_message.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../providers/infrastructure/local_session.fake.dart';
import '../../service.mocks.dart';
import '../../unit/presentation/presentation_context.dart';

class _MockTvApi extends Mock implements TvApi {}

class _MockFeatureMessageService extends Mock implements FeatureMessageService {}

/// Takes any address as a server
class _Auth extends AuthNotifier {
  _Auth(Ref ref)
    : super(
        MockAuthService(),
        MockApiService(),
        MockUserService(),
        MockSecureStorageService(),
        MockWidgetService(),
        ref,
      );

  @override
  Future<String> validateServerUrl(String url) async => url;
}

void main() {
  late PresentationContext context;
  late _MockTvApi tvApi;

  setUpAll(() {
    registerFallbackValue(TvTextRequest(title: '', text: '', kind: TvTextKind.text, okLabel: '', cancelLabel: ''));
  });

  setUp(() async {
    context = await PresentationContext.create();
    tvApi = _MockTvApi();
    // A server with both the password and OAuth
    when(() => context.service.serverInfo.getServerVersion()).thenAnswer((_) async => null);
    when(
      () => context.service.serverInfo.getServerFeatures(),
    ).thenAnswer((_) async => const ServerFeatures(map: true, trash: true, oauthEnabled: true, passwordLogin: true));
    when(() => context.service.serverInfo.getServerConfig()).thenAnswer(
      (_) async => const ServerConfig(
        trashDays: 30,
        oauthButtonText: 'Sign in with SSO',
        externalDomain: '',
        mapDarkStyleUrl: '',
        mapLightStyleUrl: '',
      ),
    );
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The login form alone, or the whole login page with [page] (the version and the Logs link under the form); in
  /// the TV shell of the app with [tvShell]
  Future<void> pumpLoginForm(
    WidgetTester tester, {
    required bool tvMode,
    bool page = false,
    bool tvShell = false,
    TextScaler? textScaler,
  }) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(LoginRoute.name, builder: (_) => page ? const LoginPage() : Scaffold(body: LoginForm())),
        ),
      ],
    );
    final featureMessages = _MockFeatureMessageService();
    when(featureMessages.markSeen).thenAnswer((_) async {});

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
            localSessionProvider.overrideWith(FakeLocalSessionNotifier.new),
            featureMessageServiceProvider.overrideWithValue(featureMessages),
            authProvider.overrideWith(_Auth.new),
            tvModeProvider.overrideWithValue(tvMode),
            tvApiProvider.overrideWithValue(tvApi),
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              routerConfig: router.config(),
              builder: (context, child) {
                final scaled = textScaler == null
                    ? child!
                    : MediaQuery(
                        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                        child: child!,
                      );
                return tvShell ? TvShell(child: scaled) : scaled;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
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

  /// The entry of the native text dialog around the field of type [field]
  Finder entryOf(Type field) => find.ancestor(of: find.byType(field), matching: find.byType(TvTextEntry));

  /// Puts the focus on the entry around the field of type [field], as the arrows would
  Future<void> focusEntry(WidgetTester tester, Type field) async {
    final scale = find.descendant(
      of: find.descendant(of: entryOf(field), matching: find.byType(RemoteFocusable)),
      matching: find.byType(AnimatedScale),
    );
    Focus.of(tester.element(scale)).requestFocus();
    await tester.pumpAndSettle();
  }

  testWidgets('a TV that never reached a server starts on "Use without a server"', (tester) async {
    // The store of the context is shared by the tests of this file
    await StoreService.I.delete(StoreKey.serverEndpoint);
    addTearDown(() => StoreService.I.put(StoreKey.serverEndpoint, PresentationContext.serverEndpoint));
    await pumpLoginForm(tester, tvMode: true);

    expect(focusedIn(find.widgetWithText(ImmichTextButton, 'Use without a server')), isTrue);
  });

  testWidgets('a TV that reached a server before starts on its address', (tester) async {
    await pumpLoginForm(tester, tvMode: true);

    expect(focusedIn(entryOf(ImmichURLInput)), isTrue);
    expect(find.text('http://localhost:3000'), findsOneWidget);
  });

  testWidgets('the address, then the email and the password through the text dialog; no OAuth button', (tester) async {
    when(() => tvApi.editText(any())).thenAnswer((invocation) async {
      final request = invocation.positionalArguments.single as TvTextRequest;
      return switch (request.kind) {
        TvTextKind.url => 'https://photos.example.org',
        TvTextKind.email => 'user@example.org',
        _ => null,
      };
    });
    await pumpLoginForm(tester, tvMode: true);
    expect(find.text('Press OK to type'), findsOneWidget);

    await focusEntry(tester, ImmichURLInput);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    final address = verify(() => tvApi.editText(captureAny())).captured.single as TvTextRequest;
    expect(address.kind, TvTextKind.url);
    // Typed, the address is submitted like Next: the server asks for the credentials
    expect(find.text('https://photos.example.org'), findsWidgets);
    expect(entryOf(ImmichEmailInput), findsOneWidget);
    expect(find.widgetWithText(ImmichTextButton, 'Sign in with SSO'), findsNothing);
    expect(find.text('Sign in with SSO'), findsNothing);
    expect(
      find.text(
        'Signing in with Sign in with SSO opens a web page, which this TV cannot do. Sign in with an email and a '
        'password instead.',
      ),
      findsOneWidget,
    );
    expect(focusedIn(entryOf(ImmichEmailInput)), isTrue, reason: 'the email first');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    final email = verify(() => tvApi.editText(captureAny())).captured.single as TvTextRequest;
    expect(email.kind, TvTextKind.email);
    expect(find.text('user@example.org'), findsOneWidget);
    expect(focusedIn(entryOf(ImmichPasswordInput)), isTrue, reason: 'then the password');
  });

  testWidgets('a computer says that OAuth is not there yet, instead of its button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpLoginForm(tester, tvMode: false);
      await tester.enterText(find.byType(TextFormField).first, 'https://photos.example.org');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ImmichTextButton, 'Sign in with SSO'), findsNothing);
      expect(
        find.text(
          'Signing in with Sign in with SSO is not available in Immuch360 Desktop yet. Sign in with an email and a '
          'password instead.',
        ),
        findsOneWidget,
      );
      expect(find.byType(ImmichEmailInput), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('out of the remote control layout the fields are typed in and OAuth is a button', (tester) async {
    await pumpLoginForm(tester, tvMode: false);
    expect(find.text('Press OK to type'), findsNothing);
    expect(focusedIn(find.widgetWithText(ImmichTextButton, 'Use without a server')), isFalse);

    await tester.enterText(find.byType(TextFormField).first, 'https://photos.example.org');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in with SSO'), findsOneWidget);
    verifyNever(() => tvApi.editText(any()));
  });

  group('the login page on a 1080p TV', () {
    setUp(() async {
      PackageInfo.setMockInitialValues(
        appName: 'Immuch360',
        packageName: 'app.alextran.immich',
        version: '3.3.0',
        buildNumber: '3030022',
        buildSignature: '',
      );
      // A TV that never reached a server: the page starts on "Use without a server", the last action of the form
      await StoreService.I.delete(StoreKey.serverEndpoint);
    });

    tearDown(() => StoreService.I.put(StoreKey.serverEndpoint, PresentationContext.serverEndpoint));

    /// A Google TV at 1920 x 1080 and 320 dpi: 960 x 540 logical pixels
    void tvScreen(WidgetTester tester) {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
    }

    /// Where the form shows: the body of the page above the version line, inside the top margin of the TV shell
    Rect visibleArea(WidgetTester tester, {double margin = 0}) {
      final screen = tester.getRect(find.byType(LoginPage));
      final bar = tester.getRect(find.ancestor(of: find.text('Logs'), matching: find.byType(SafeArea)).first);
      return Rect.fromLTRB(screen.left, screen.top + margin, screen.right, bar.top);
    }

    bool shows(WidgetTester tester, Finder finder, Rect area) {
      final rect = tester.getRect(finder);
      return rect.top >= area.top - 0.5 && rect.bottom <= area.bottom + 0.5;
    }

    testWidgets('every action of the server step shows at once, "Use without a server" with the focus', (tester) async {
      tvScreen(tester);
      await pumpLoginForm(tester, tvMode: true, page: true, tvShell: true);
      final useWithoutServer = find.widgetWithText(ImmichTextButton, 'Use without a server');
      expect(focusedIn(useWithoutServer), isTrue);

      final area = visibleArea(tester, margin: TvShell.overscan.top);
      for (final (name, finder) in [
        ('the logo', find.byType(ImmichLogo)),
        ('the address', entryOf(ImmichURLInput)),
        ('Next', find.text('Next')),
        ('Settings', find.widgetWithText(ImmichTextButton, 'Settings')),
        ('Use without a server', useWithoutServer),
      ]) {
        expect(shows(tester, finder, area), isTrue, reason: '$name between ${area.top} and ${area.bottom}');
      }
      expect(tester.getRect(find.text('Logs')).bottom, lessThanOrEqualTo(540 - TvShell.overscan.bottom));
    });

    testWidgets('with large text the page scrolls to the action that has the focus', (tester) async {
      tvScreen(tester);
      await pumpLoginForm(tester, tvMode: true, page: true, tvShell: true, textScaler: const TextScaler.linear(2.5));
      final useWithoutServer = find.widgetWithText(ImmichTextButton, 'Use without a server');

      expect(focusedIn(useWithoutServer), isTrue);
      expect(shows(tester, useWithoutServer, visibleArea(tester, margin: TvShell.overscan.top)), isTrue);
    });

    testWidgets('the credentials step starts on the email, even once Logs had the focus', (tester) async {
      tvScreen(tester);
      when(() => tvApi.editText(any())).thenAnswer((_) async => 'https://photos.example.org');
      // A server two major versions behind: the warning shows once the credentials are asked, a rebuild of the form
      when(
        () => context.service.serverInfo.getServerVersion(),
      ).thenAnswer((_) async => const ServerVersion(major: 1, minor: 0, patch: 0));
      await pumpLoginForm(tester, tvMode: true, page: true, tvShell: true);
      final logs = find.ancestor(of: find.text('Logs'), matching: find.byType(RemoteFocusable));

      // Down from "Use without a server" to Logs under the form, then up to the address
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusedIn(logs), isTrue);
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      expect(focusedIn(entryOf(ImmichURLInput)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(find.textContaining('Your server version is not compatible'), findsOneWidget);
      expect(focusedIn(entryOf(ImmichEmailInput)), isTrue, reason: 'not Logs, the item focused before the address');
      expect(focusedIn(logs), isFalse);
    });

    testWidgets('a phone keeps its layout: the logo a fifth of the height down', (tester) async {
      await pumpLoginForm(tester, tvMode: false, page: true);

      final body = visibleArea(tester);
      expect(tester.getRect(find.byType(ImmichLogo)).top, closeTo(body.top + body.height / 5, 1));
      expect(tester.getSize(find.byType(ImmichLogo)), const Size.square(100));
    });
  });
}
