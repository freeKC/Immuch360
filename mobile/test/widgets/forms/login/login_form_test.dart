import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/domain/services/feature_message.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/view_intent_api.g.dart';
import 'package:immich_mobile/providers/feature_message.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_handler.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:mocktail/mocktail.dart';

import '../../../providers/infrastructure/local_session.fake.dart';
import '../../../repository.mocks.dart';
import '../../../unit/presentation/presentation_context.dart';

class MockFeatureMessageService extends Mock implements FeatureMessageService {}

/// Grants the gallery at once and records the requests
class _GalleryPermission extends GalleryPermissionNotifier {
  _GalleryPermission(this.calls) : super(DevicePermissionService(MockPermissionRepository()));

  final List<String> calls;

  @override
  Future<DevicePermissionStatus> getGalleryPermissionStatus() async => state;

  @override
  Future<DevicePermissionStatus> requestGalleryPermission() async {
    calls.add('permission');
    return state = DevicePermissionStatus.granted;
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
  late PresentationContext context;
  late MockFeatureMessageService featureMessageService;
  late List<String> calls;

  setUp(() async {
    context = await PresentationContext.create();
    featureMessageService = MockFeatureMessageService();
    when(() => featureMessageService.markSeen()).thenAnswer((_) async {});
    calls = [];
  });

  tearDown(() async {
    await context.dispose();
  });

  final useWithoutServer = find.text('Use without a server');

  /// Pumps the login form under a real router whose tab shell renders a stub page, in a session without a server when
  /// [localSession] is true
  Future<ProviderContainer> pumpLoginForm(WidgetTester tester, {bool localSession = false}) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(LoginRoute.name, builder: (_) => Scaffold(body: LoginForm())),
        ),
        AutoRoute(
          path: '/tabs',
          page: PageInfo(TabShellRoute.name, builder: (_) => const Text('tabs')),
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
            ...context.overrides,
            localSessionProvider.overrideWith(FakeLocalSessionNotifier.new),
            galleryPermissionNotifier.overrideWith((_) => _GalleryPermission(calls)),
            localSessionRefreshProvider.overrideWithValue(
              ({bool full = false}) async => calls.add('refresh full:$full'),
            ),
            viewIntentHandlerProvider.overrideWithValue(_ViewIntentHandler(calls)),
            featureMessageServiceProvider.overrideWithValue(featureMessageService),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return MaterialApp.router(
                debugShowCheckedModeBanner: false,
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                routerConfig: router.config(),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (localSession) {
      await container.read(localSessionProvider.notifier).enter();
      await tester.pumpAndSettle();
    }
    return container;
  }

  testWidgets('offers to use the app without a server, under the settings button', (tester) async {
    await pumpLoginForm(tester);

    expect(useWithoutServer, findsOneWidget);
    final settings = find.text('Settings');
    expect(settings, findsOneWidget);
    expect(tester.getTopLeft(useWithoutServer).dy, greaterThan(tester.getTopLeft(settings).dy));
  });

  testWidgets('opens the device photos without a server', (tester) async {
    final container = await pumpLoginForm(tester);

    await tester.tap(useWithoutServer);
    await tester.pumpAndSettle();

    expect(container.read(localSessionProvider), isTrue);
    expect(container.read(hasServerProvider), isFalse);
    expect(calls, ['permission', 'refresh full:true', 'flush']);
    verify(() => featureMessageService.markSeen()).called(1);
    expect(find.text('tabs'), findsOneWidget);
  });

  testWidgets('is not offered again when already in a session without a server', (tester) async {
    await pumpLoginForm(tester, localSession: true);

    expect(useWithoutServer, findsNothing);
    expect(find.text('Settings'), findsOneWidget);
  });
}
