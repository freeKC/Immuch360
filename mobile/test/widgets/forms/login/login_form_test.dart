import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:immich_ui/immich_ui.dart';

import '../../../providers/infrastructure/local_session.fake.dart';
import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final back = find.widgetWithText(ImmichTextButton, 'Back');
  final settings = find.widgetWithText(ImmichTextButton, 'Settings');

  /// Pumps the login form under a real router whose other routes render a stub page. [from] is the page the form is
  /// opened from (the welcome page or the settings); without it the form is the only page, as after a deep link.
  Future<StackRouter> pumpLoginForm(WidgetTester tester, {String? from}) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/login',
          initial: from == null,
          page: PageInfo(LoginRoute.name, builder: (_) => Scaffold(body: LoginForm())),
        ),
        AutoRoute(
          path: '/welcome',
          initial: from == 'welcome',
          page: PageInfo(WelcomeRoute.name, builder: (_) => const Text('welcome page')),
        ),
        AutoRoute(
          path: '/settings',
          initial: from == 'settings',
          page: PageInfo(SettingsRoute.name, builder: (_) => const Text('settings page')),
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
          overrides: [...context.overrides, localSessionProvider.overrideWith(FakeLocalSessionNotifier.new)],
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

    if (from != null) {
      // The push completes when the form is popped
      unawaited(router.push(const LoginRoute()));
      await tester.pumpAndSettle();
    }
    return router;
  }

  testWidgets('the server step goes back where it was opened from, and no longer starts without a server', (
    tester,
  ) async {
    await pumpLoginForm(tester, from: 'welcome');

    // The welcome page offers it now
    expect(find.text('Use without a server'), findsNothing);
    expect(back, findsOneWidget);
    expect(tester.getTopLeft(back).dy, greaterThan(tester.getTopLeft(settings).dy));
  });

  testWidgets('Back returns to the welcome page the form was opened from', (tester) async {
    await pumpLoginForm(tester, from: 'welcome');

    await tester.tap(back);
    await tester.pumpAndSettle();

    expect(find.text('welcome page'), findsOneWidget);
    expect(find.byType(LoginForm), findsNothing);
  });

  testWidgets('Back returns to the settings of a session without a server', (tester) async {
    await pumpLoginForm(tester, from: 'settings');

    await tester.tap(back);
    await tester.pumpAndSettle();

    expect(find.text('settings page'), findsOneWidget);
  });

  testWidgets('a form opened on its own goes back to the welcome page', (tester) async {
    await pumpLoginForm(tester);

    await tester.tap(back);
    await tester.pumpAndSettle();

    expect(find.text('welcome page'), findsOneWidget);
    expect(find.byType(LoginForm), findsNothing);
  });
}
