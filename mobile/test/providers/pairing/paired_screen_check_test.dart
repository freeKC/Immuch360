// What a big screen does when the session a phone gave it is gone (signed out from the phone or in Immich, or deleted
// by a phone that never heard the screen's answer): back to its sign-in page; and the app's side of a sign in from the
// pairing panel, which puts everything back, the server address too, when an attempt fails

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/pairing/screen_sign_in.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_panel.widget.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/pairing/paired_screen_check.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../../service.mocks.dart';
import '../../test_utils.dart';

class _MockUsersApi extends Mock implements UsersApi {}

class _MockRouter extends Mock implements AppRouter {}

void main() {
  late Drift db;
  late MockApiService api;
  late _MockUsersApi users;
  late _MockRouter router;
  late MockAuthService auth;
  late MockWidgetService widgets;

  setUpAll(() async {
    TestUtils.init();
    registerFallbackValue(<PageRouteInfo>[]);
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await SettingsRepository.ensureInitialized(db);
  });

  tearDownAll(() async {
    await SettingsRepository.reset();
    await db.close();
  });

  setUp(() async {
    api = MockApiService();
    users = _MockUsersApi();
    router = _MockRouter();
    auth = MockAuthService();
    widgets = MockWidgetService();
    when(() => api.usersApi).thenReturn(users);
    when(() => router.replaceAll(any())).thenAnswer((_) async {});
    when(() => auth.clearLocalData()).thenAnswer((_) async {});
    when(() => api.setEndpoint(any())).thenReturn(null);
    when(() => api.setDeviceInfoHeader()).thenAnswer((_) async {});
    when(() => api.updateHeaders()).thenAnswer((_) async {});
    when(() => widgets.clearCredentials()).thenAnswer((_) async {});
    for (final key in [
      StoreKey.accessToken,
      StoreKey.pairingSignedInBy,
      StoreKey.serverUrl,
      StoreKey.serverEndpoint,
      StoreKey.pairingScreenLabel,
    ]) {
      await Store.delete(key);
    }
  });

  group('the check of a paired screen', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          appRouterProvider.overrideWithValue(router),
          authServiceProvider.overrideWithValue(auth),
        ],
      );
    });

    tearDown(() => container.dispose());

    Future<void> paired() async {
      await Store.put(StoreKey.accessToken, 'token-of-the-screen');
      await Store.put(StoreKey.pairingSignedInBy, "Fred's Pixel");
    }

    test('a refused session: back to the sign-in page, local data cleared', () async {
      await paired();
      when(() => users.getMyUser()).thenThrow(ApiException(401, 'gone'));
      await container.read(pairedScreenCheckProvider).check();
      final routes = verify(() => router.replaceAll(captureAny())).captured.single as List<PageRouteInfo>;
      expect(routes.map((route) => route.routeName), [WelcomeRoute.name, LoginRoute.name]);
      verify(() => auth.clearLocalData()).called(1);
    });

    test('a session the server still has, or no answer: nothing changes', () async {
      await paired();
      when(() => users.getMyUser()).thenAnswer((_) async => null);
      await container.read(pairedScreenCheckProvider).check();
      when(() => users.getMyUser()).thenThrow(ApiException(503, 'down'));
      await container.read(pairedScreenCheckProvider).check();
      when(() => users.getMyUser()).thenThrow(Exception('offline'));
      await container.read(pairedScreenCheckProvider).check();
      verifyNever(() => router.replaceAll(any()));
      verifyNever(() => auth.clearLocalData());
    });

    test('a screen no phone signed in is left to the guard of the routes', () async {
      await Store.put(StoreKey.accessToken, 'token-of-a-password');
      await container.read(pairedScreenCheckProvider).check();
      verifyNever(() => users.getMyUser());
    });
  });

  group('the sign in of the panel', () {
    // The Store's cache follows the database through a stream too: its events settle before a value is read, and
    // what was put back is read from the database itself
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));
    Future<T?> stored<T>(StoreKey<T> key) => StoreRepository(db).tryGet(key);

    Future<AppScreenSignInActions> actions(WidgetTester tester) async {
      late WidgetRef captured;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiServiceProvider.overrideWithValue(api), widgetServiceProvider.overrideWithValue(widgets)],
          child: Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return const SizedBox();
            },
          ),
        ),
      );
      return AppScreenSignInActions(captured);
    }

    testWidgets('puts the server back after a failed attempt, and forgets the token everywhere', (tester) async {
      final app = await actions(tester);
      await tester.runAsync(() async {
        await Store.put(StoreKey.serverUrl, 'https://photos.example.com/api');
        await Store.put(StoreKey.serverEndpoint, 'https://photos.example.com/api');
        await settle();
        final snapshot = await app.snapshot();
        expect(snapshot.serverEndpoint, 'https://photos.example.com/api');

        // What a hostile code could name: it becomes the server for the attempt only
        await app.useServer('http://192.168.1.66:2283/api');
        await settle();
        expect(Store.tryGet(StoreKey.serverEndpoint), 'http://192.168.1.66:2283/api');
        verify(() => api.setEndpoint('http://192.168.1.66:2283/api')).called(1);
        await Store.put(StoreKey.accessToken, 'token-of-the-attempt');
        await settle();

        await app.restore(snapshot);
        await settle();
        expect(await stored(StoreKey.serverUrl), 'https://photos.example.com/api');
        expect(await stored(StoreKey.serverEndpoint), 'https://photos.example.com/api');
        expect(await stored(StoreKey.accessToken), isNull);
        verify(() => api.setEndpoint('https://photos.example.com/api')).called(1);
        verify(() => widgets.clearCredentials()).called(1);
      });
    });

    testWidgets('a screen that had no server gets none back', (tester) async {
      final app = await actions(tester);
      await tester.runAsync(() async {
        const snapshot = ScreenSignInSnapshot(headers: {}, label: null);
        await app.useServer('http://192.168.1.66:2283/api');
        await settle();
        await app.restore(snapshot);
        await settle();
        expect(await stored(StoreKey.serverUrl), isNull);
        expect(await stored(StoreKey.serverEndpoint), isNull);
        expect(await stored(StoreKey.pairingScreenLabel), isNull);
      });
    });
  });
}
