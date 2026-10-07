// The login form with a remote control: a TV that never reached a server starts on "Use without a server", the
// address, the email and the password are typed in the native text dialog, and OAuth, which opens a web page, is
// replaced by a line that says so.

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
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
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/feature_message.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

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

  Future<void> pumpLoginForm(WidgetTester tester, {required bool tvMode}) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(LoginRoute.name, builder: (_) => Scaffold(body: LoginForm())),
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
}
