import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/common/settings.page.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';

/// A session with or without a server, whatever the Store says
class _Session extends LocalSessionNotifier {
  _Session({required this.local});

  final bool local;

  @override
  bool build() => local;
}

void main() {
  const serverSections = ['Backup', 'Free Up Space', 'Networking', 'Notifications', 'Sync Status'];
  const deviceSections = ['Advanced', 'Asset Viewer', 'Language', 'Preferences', 'Photo Grid', "What's new"];
  final connectCard = find.widgetWithText(SettingsCard, 'Connect to a server');

  /// Pumps the settings page on a phone sized screen, under a router whose login route renders a stub page
  Future<void> pumpSettings(WidgetTester tester, {required bool local}) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(400 * 3, 1800 * 3);
    addTearDown(tester.view.reset);

    final router = RootStackRouter.build(
      routes: [
        AutoRoute(path: '/', initial: true, page: SettingsRoute.page),
        AutoRoute(
          path: '/login',
          page: PageInfo(LoginRoute.name, builder: (_) => const Text('login page')),
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
          overrides: [localSessionProvider.overrideWith(() => _Session(local: local))],
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

  testWidgets('lists every section with a server, and no way to connect one', (tester) async {
    await pumpSettings(tester, local: false);

    for (final title in [...serverSections, ...deviceSections]) {
      expect(find.widgetWithText(SettingsCard, title), findsOneWidget, reason: title);
    }
    expect(connectCard, findsNothing);
  });

  testWidgets('leaves out the server sections without a server and offers to connect one first', (tester) async {
    await pumpSettings(tester, local: true);

    for (final title in serverSections) {
      expect(find.widgetWithText(SettingsCard, title), findsNothing, reason: title);
    }
    for (final title in deviceSections) {
      expect(find.widgetWithText(SettingsCard, title), findsOneWidget, reason: title);
    }
    expect(connectCard, findsOneWidget);
    expect(find.text('Sync with an Immich server to back up, search and share'), findsOneWidget);
    final cards = tester.widgetList<SettingsCard>(find.byType(SettingsCard)).toList();
    expect(cards.first.title, 'Connect to a server');

    await tester.tap(connectCard);
    await tester.pumpAndSettle();

    expect(find.text('login page'), findsOneWidget);
  });

  test('marks only the backup, connection and sync sections as needing a server', () {
    expect(
      SettingSection.values.where((section) => section.needsServer),
      unorderedEquals([
        SettingSection.backup,
        SettingSection.freeUpSpace,
        SettingSection.networking,
        SettingSection.notifications,
        SettingSection.beta,
      ]),
    );
  });
}
