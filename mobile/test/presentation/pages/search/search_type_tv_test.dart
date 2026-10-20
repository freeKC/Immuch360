// The search type button of the search page with a remote control: a dialog that keeps the focus (Left and Back left
// the open menu for the navigation rail, the menu still open), the types of the server only, the current one marked
// and focused first, a choice changes the hint of the search field; phones keep the menu.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/services/search.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:immich_mobile/presentation/pages/search/paginated_search.provider.dart';
import 'package:immich_mobile/presentation/pages/search/search.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/presentation/presentation_context.dart';

class _SearchService extends Mock implements SearchService {}

/// A server with [features]
class _ServerInfo extends ServerInfoNotifier {
  _ServerInfo(super.service, ServerFeatures features) {
    state = state.copyWith(serverFeatures: features);
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

  Future<void> pumpSearch(WidgetTester tester, {required bool tvMode, bool smartSearch = false}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final features = ServerFeatures(
      map: true,
      trash: true,
      oauthEnabled: false,
      passwordLogin: true,
      smartSearch: smartSearch,
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
            tvModeProvider.overrideWithValue(tvMode),
            serverInfoProvider.overrideWith((ref) => _ServerInfo(context.service.serverInfo, features)),
            paginatedSearchProvider.overrideWith((ref) => PaginatedSearchNotifier(_SearchService())),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              // As main.dart does
              builder: (context, child) => TvShell(enabled: tvMode, child: child!),
              home: const SearchPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder typeButton() => find.widgetWithIcon(IconButton, Icons.more_vert_rounded);

  Finder choice(String label) => find.widgetWithText(ListTile, label);

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    return finder.evaluate().any((element) {
      var found = element == focused;
      if (!found) {
        focused.visitAncestorElements((ancestor) {
          found = ancestor == element;
          return !found;
        });
      }
      return found;
    });
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> openWithOk(WidgetTester tester) async {
    Focus.of(tester.element(find.byIcon(Icons.more_vert_rounded))).requestFocus();
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.select);
  }

  group('on TV', () {
    testWidgets('OK opens a dialog of the types of the server that keeps the focus, the current one focused', (
      tester,
    ) async {
      await pumpSearch(tester, tvMode: true);
      await openWithOk(tester);

      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.text('Search type'), findsOneWidget);
      expect(find.byType(MenuItemButton), findsNothing);
      // No smart search nor OCR on this server
      expect(find.descendant(of: find.byType(SimpleDialog), matching: find.byType(ListTile)), findsNWidgets(2));
      expect(choice('Search by context'), findsNothing);
      expect(tester.widget<ListTile>(choice('Search by file name')).selected, isTrue);
      expect(focusedIn(choice('Search by file name')), isTrue);

      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
      ]) {
        for (var i = 0; i < 3; i++) {
          await press(tester, key);
          expect(focusedIn(find.byType(SimpleDialog)), isTrue, reason: '$key ${i + 1}');
        }
      }
    });

    testWidgets('a type chosen changes the hint of the search field; Back changes nothing', (tester) async {
      await pumpSearch(tester, tvMode: true);
      expect(find.text('File name or extension'), findsOneWidget);

      await openWithOk(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(choice('Search by description')), isTrue);
      await press(tester, LogicalKeyboardKey.select);

      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.text('File name or extension'), findsNothing);
      expect(find.byIcon(Icons.text_snippet_outlined), findsOneWidget);
      expect(focusedIn(typeButton()), isTrue);

      await press(tester, LogicalKeyboardKey.select);
      expect(focusedIn(choice('Search by description')), isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.byIcon(Icons.text_snippet_outlined), findsOneWidget);
    });

    testWidgets('smart search is offered when the server has it, and is the type at first', (tester) async {
      await pumpSearch(tester, tvMode: true, smartSearch: true);
      await openWithOk(tester);

      expect(find.descendant(of: find.byType(SimpleDialog), matching: find.byType(ListTile)), findsNWidgets(3));
      expect(focusedIn(choice('Search by context')), isTrue);
    });
  });

  testWidgets('phones keep the menu', (tester) async {
    await pumpSearch(tester, tvMode: false);
    await tester.tap(typeButton());
    await tester.pumpAndSettle();

    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.byType(MenuItemButton), findsNWidgets(2));

    await tester.tap(find.widgetWithText(MenuItemButton, 'Search by description'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.text_snippet_outlined), findsOneWidget);
  });
}
