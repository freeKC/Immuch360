import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/library.page.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../providers/network/fakes.dart';
import '../../../unit/presentation/presentation_context.dart';

/// A session without a server, whatever the Store says
class _LocalSession extends LocalSessionNotifier {
  @override
  bool build() => true;
}

/// These shares, whatever the Store says
class _Sources extends NetworkSourcesNotifier {
  _Sources(this.sources);

  final List<NetworkSource> sources;

  @override
  List<NetworkSource> build() => sources;
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

  final card = find.text('Network shares');

  /// The Library of a session without a server (with a server, the map of the places card needs a platform view)
  Future<void> pumpLibrary(WidgetTester tester, {List<NetworkSource> sources = const []}) async {
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
            localSessionProvider.overrideWith(_LocalSession.new),
            localAlbumProvider.overrideWith((ref) => Stream.value(const [])),
            localeProvider.overrideWithValue(const Locale('en')),
            networkSourcesProvider.overrideWith(() => _Sources(sources)),
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

  group('Library network shares card', () {
    testWidgets('sits next to the albums of the device without a server, and opens the shares', (tester) async {
      await pumpLibrary(tester);

      expect(card, findsOneWidget);
      expect(find.byIcon(Icons.lan_outlined), findsOneWidget, reason: 'no share yet');
      final deviceAlbums = find.text('On this device');
      expect(tester.getTopLeft(card).dy, tester.getTopLeft(deviceAlbums).dy);
      expect(tester.getTopLeft(card).dx, greaterThan(tester.getTopLeft(deviceAlbums).dx));

      await tester.tap(card);
      await tester.pumpAndSettle();

      expect(find.text('shares page'), findsOneWidget);
    });

    testWidgets('shows the names of the first shares', (tester) async {
      final more = List.generate(
        3,
        (index) => NetworkSource(
          id: 'more-$index',
          type: NetworkSourceType.smb,
          name: 'Share $index',
          host: 'nas.local',
          share: 'media',
        ),
      );
      await pumpLibrary(tester, sources: [smbSource, webDavSource, ...more]);

      expect(find.text('NAS'), findsOneWidget);
      expect(find.text('Cloud'), findsOneWidget);
      expect(find.text('Share 0'), findsOneWidget);
      expect(find.text('Share 1'), findsOneWidget);
      expect(find.text('Share 2'), findsNothing, reason: 'four at most');
      expect(find.byIcon(Icons.lan_outlined), findsNothing);
    });
  });
}
