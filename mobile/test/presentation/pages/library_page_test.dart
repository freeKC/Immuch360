import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:immich_mobile/presentation/pages/library.page.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import '../../unit/presentation/presentation_context.dart';

/// Server info with the trash feature switched off
class _NoTrashServerInfo extends ServerInfoNotifier {
  _NoTrashServerInfo(super.service) {
    state = state.copyWith(
      serverFeatures: const ServerFeatures(map: true, trash: false, oauthEnabled: false, passwordLogin: true),
    );
  }
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final panoramaEntry = find.widgetWithText(FilledButton, '360°');
  final favoritesEntry = find.widgetWithText(FilledButton, 'Favorites');

  /// Pumps the Library shortcut buttons under a real router whose timeline routes render a stub page, so a push can
  /// be observed.
  Future<void> pumpLibraryButtons(WidgetTester tester, {bool trash = true}) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(
            LibraryRoute.name,
            builder: (_) => const Scaffold(body: CustomScrollView(slivers: [LibraryActionButtonGrid()])),
          ),
        ),
        AutoRoute(
          path: '/panorama-360',
          page: PageInfo(Panorama360Route.name, builder: (_) => const Text('360 timeline')),
        ),
        AutoRoute(
          path: '/favorites',
          page: PageInfo(FavoriteRoute.name, builder: (_) => const Text('favorites timeline')),
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
            ...context.overrides,
            if (!trash) serverInfoProvider.overrideWith((ref) => _NoTrashServerInfo(context.service.serverInfo)),
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

  group('Library 360° entry', () {
    testWidgets('sits next to Favorites, in the same style, with the 360 icon', (tester) async {
      await pumpLibraryButtons(tester);

      expect(panoramaEntry, findsOneWidget);
      expect(find.descendant(of: panoramaEntry, matching: find.byIcon(Icons.threesixty_rounded)), findsOneWidget);
      expect(favoritesEntry, findsOneWidget);

      final firstRow = find.ancestor(of: favoritesEntry, matching: find.byType(Row)).first;
      expect(find.descendant(of: firstRow, matching: panoramaEntry), findsOneWidget);
      expect(tester.getTopLeft(panoramaEntry).dy, tester.getTopLeft(favoritesEntry).dy);
      expect(tester.getTopLeft(panoramaEntry).dx, greaterThan(tester.getTopLeft(favoritesEntry).dx));
      expect(tester.getSize(panoramaEntry), tester.getSize(favoritesEntry));
    });

    testWidgets('opens the 360° timeline when tapped', (tester) async {
      await pumpLibraryButtons(tester);

      await tester.tap(panoramaEntry);
      await tester.pumpAndSettle();

      expect(find.text('360 timeline'), findsOneWidget);
    });

    testWidgets('keeps the other entries, trash included when the server has it', (tester) async {
      await pumpLibraryButtons(tester);

      for (final label in ['Favorites', '360°', 'Archived', 'Shared links', 'Trash']) {
        expect(find.widgetWithText(FilledButton, label), findsOneWidget, reason: label);
      }

      await tester.tap(favoritesEntry);
      await tester.pumpAndSettle();

      expect(find.text('favorites timeline'), findsOneWidget);
    });

    testWidgets('is still shown when the server has no trash', (tester) async {
      await pumpLibraryButtons(tester, trash: false);

      expect(panoramaEntry, findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Trash'), findsNothing);
    });
  });
}
