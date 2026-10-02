import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/routing/auth_guard.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../service.mocks.dart';

class MockAuthenticationApi extends Mock implements AuthenticationApi {}

void main() {
  late Drift db;
  late MockApiService apiService;
  late MockAuthService authService;
  late MockAuthenticationApi authenticationApi;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db), listenUpdates: false);
  });

  tearDownAll(() async {
    await StoreService.I.dispose();
    await db.close();
  });

  setUp(() {
    apiService = MockApiService();
    authService = MockAuthService();
    authenticationApi = MockAuthenticationApi();
    when(() => apiService.authenticationApi).thenReturn(authenticationApi);
    when(
      () => authenticationApi.validateAccessToken(),
    ).thenAnswer((_) async => ValidateAccessTokenResponseDto(authStatus: true));
    when(() => authService.clearLocalData()).thenAnswer((_) async {});
  });

  tearDown(() async {
    await StoreService.I.clear();
  });

  /// Pumps a router whose tab shell is behind the guard, then opens the tab shell
  Future<void> openTabShell(WidgetTester tester) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo('HomeRoute', builder: (_) => const Text('home')),
        ),
        AutoRoute(
          path: '/tabs',
          guards: [AuthGuard(apiService, authService)],
          page: PageInfo(TabShellRoute.name, builder: (_) => const Text('tabs')),
        ),
        AutoRoute(
          path: '/login',
          page: PageInfo(LoginRoute.name, builder: (_) => const Text('login')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router.config()));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);

    // The push completes when the route is popped, which never happens here
    unawaited(router.push(const TabShellRoute()));
    await tester.pumpAndSettle();
  }

  testWidgets('sends to the login page without a token', (tester) async {
    await openTabShell(tester);

    expect(find.text('login'), findsOneWidget);
    expect(find.text('tabs'), findsNothing);
    verifyNever(() => authenticationApi.validateAccessToken());
  });

  testWidgets('lets a session without a server through, with no token to check', (tester) async {
    await StoreService.I.put(StoreKey.localSession, true);

    await openTabShell(tester);

    expect(find.text('tabs'), findsOneWidget);
    expect(find.text('login'), findsNothing);
    verifyNever(() => apiService.authenticationApi);
  });

  testWidgets('lets a server session through and checks its token', (tester) async {
    await StoreService.I.put(StoreKey.accessToken, 'token');

    await openTabShell(tester);

    expect(find.text('tabs'), findsOneWidget);
    verify(() => authenticationApi.validateAccessToken()).called(1);
  });

  testWidgets('a session without a server that has ended sends to the login page again', (tester) async {
    await StoreService.I.put(StoreKey.localSession, true);
    await StoreService.I.delete(StoreKey.localSession);

    await openTabShell(tester);

    expect(find.text('login'), findsOneWidget);
  });
}
