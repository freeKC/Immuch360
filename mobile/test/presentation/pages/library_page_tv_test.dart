// The Library with a remote control: it starts on the 360° button, the arrows reach the collection cards, OK opens
// the network shares, and the map of the places is not offered on a TV.

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/library.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:mocktail/mocktail.dart';

import '../../unit/presentation/presentation_context.dart';

class _Session extends LocalSessionNotifier {
  _Session({required this.local});

  final bool local;

  @override
  bool build() => local;
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
    when(context.service.user.tryGetMyUser).thenReturn(null);
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<void> pumpLibrary(WidgetTester tester, {required bool tvMode, bool local = true}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(LibraryRoute.name, builder: (_) => const LibraryPage()),
        ),
        AutoRoute(
          path: '/network-shares',
          page: PageInfo(NetworkSharesRoute.name, builder: (_) => const Text('shares page')),
        ),
        AutoRoute(
          path: '/local-albums',
          page: PageInfo(LocalAlbumsRoute.name, builder: (_) => const Text('device albums')),
        ),
        AutoRoute(
          path: '/panorama-360',
          page: PageInfo(Panorama360Route.name, builder: (_) => const Text('360 timeline')),
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
            tvModeProvider.overrideWithValue(tvMode),
            localSessionProvider.overrideWith(() => _Session(local: local)),
            localAlbumProvider.overrideWith((ref) => Stream.value(const [])),
            localeProvider.overrideWithValue(const Locale('en')),
            allMemoriesProvider.overrideWith((ref, _) async => const <Memory>[]),
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
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

  bool focusedIn(WidgetTester tester, Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    return finder.evaluate().any((element) => element == focused || _isAncestor(element, focused));
  }

  testWidgets('starts on the 360° button', (tester) async {
    await pumpLibrary(tester, tvMode: true);

    expect(focusedIn(tester, find.widgetWithText(FilledButton, '360°')), isTrue);
  });

  testWidgets('the arrows reach the network shares card, and OK opens the shares', (tester) async {
    await pumpLibrary(tester, tvMode: true);
    final sharesCard = find.ancestor(of: find.text('Network shares'), matching: find.byType(RemoteFocusable));

    for (var i = 0; i < 4 && !focusedIn(tester, sharesCard); i++) {
      await tester.sendKeyEvent(
        focusedIn(tester, find.widgetWithText(FilledButton, '360°'))
            ? LogicalKeyboardKey.arrowDown
            : LogicalKeyboardKey.arrowRight,
      );
      await tester.pumpAndSettle();
    }
    expect(focusedIn(tester, sharesCard), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.text('shares page'), findsOneWidget);
  });

  testWidgets('no initial focus out of the remote control layout', (tester) async {
    await pumpLibrary(tester, tvMode: false);

    expect(focusedIn(tester, find.widgetWithText(FilledButton, '360°')), isFalse);
  });

  testWidgets('no places card on a TV, people and memories still there with a server', (tester) async {
    await pumpLibrary(tester, tvMode: true, local: false);
    // The people of the test store load with an error, shown inside the card: not what this test looks at
    tester.takeException();

    expect(find.text('People'), findsOneWidget);
    expect(find.text('Memories'), findsOneWidget);
    expect(find.text('Places'), findsNothing);
  });
}

bool _isAncestor(Element ancestor, BuildContext descendant) {
  var found = false;
  descendant.visitAncestorElements((element) {
    if (element == ancestor) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}
