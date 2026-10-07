import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/routing/router.dart';

/// Pumps [home] under a real router whose network routes render a stub telling where they were opened, or the real
/// page for the routes in [pages]; returns the router so a test can push more
Future<RootStackRouter> pumpNetworkTestApp(
  WidgetTester tester, {
  required Widget home,
  required List<Override> overrides,
  Map<String, Widget Function(RouteData data)> pages = const {},
}) async {
  AutoRoute route(String path, String name, Widget Function(RouteData data) stub) => AutoRoute(
    path: path,
    page: PageInfo(name, builder: pages[name] ?? stub),
  );

  final router = RootStackRouter.build(
    routes: [
      AutoRoute(
        path: '/',
        initial: true,
        page: PageInfo('HomeRoute', builder: (_) => home),
      ),
      route('/network-shares', NetworkSharesRoute.name, (_) => const Text('shares page')),
      route('/network-share-edit', NetworkShareEditRoute.name, (data) {
        final args = data.argsAs<NetworkShareEditRouteArgs>(orElse: () => const NetworkShareEditRouteArgs());
        return Text('edit ${args.source?.name ?? 'new'}');
      }),
      route('/network-browser', NetworkBrowserRoute.name, (data) {
        final args = data.argsAs<NetworkBrowserRouteArgs>();
        return Text('browse ${args.sourceId} ${args.path}');
      }),
      route('/plex-server-edit', PlexServerEditRoute.name, (data) {
        final args = data.argsAs<PlexServerEditRouteArgs>(orElse: () => const PlexServerEditRouteArgs());
        final name = args.source?.name ?? args.server?.displayName ?? 'new';
        return Text('plex edit $name${args.focusToken ? ' token' : ''}');
      }),
      route('/camera', CameraRoute.name, (data) => Text('camera ${data.argsAs<CameraRouteArgs>().sourceId}')),
      route('/camera-edit', CameraEditRoute.name, (data) {
        final args = data.argsAs<CameraEditRouteArgs>(orElse: () => const CameraEditRouteArgs());
        return Text('camera edit ${args.source?.name ?? args.server?.host ?? 'new'}');
      }),
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
        overrides: overrides,
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
  return router;
}
