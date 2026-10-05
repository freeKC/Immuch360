import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/network/phone_share.page.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import 'network_test_app.dart';

const _onState = PhoneShareState(
  status: PhoneShareStatus.on,
  addresses: ['192.168.1.20', '192.168.43.1'],
  port: 8360,
  serviceName: 'Immuch360 on Pixel 9',
  username: 'phone4821',
  password: 'k7m3x9p2',
  clients: 1,
  lastFile: 'VID_20260904_101010.mp4',
);

/// The share without a server: [start] turns it on with [_onState]
class _FakeController extends PhoneShareController {
  _FakeController(this._initial);

  final PhoneShareState _initial;
  int starts = 0;
  int stops = 0;

  @override
  PhoneShareState build() => _initial;

  @override
  Future<void> start() async {
    starts++;
    state = _onState;
  }

  @override
  Future<void> stop({bool idle = false}) async {
    stops++;
    state = PhoneShareState(username: state.username, password: state.password, stoppedIdle: idle);
  }

  @override
  Future<void> newPassword() async => state = state.copyWith(password: 'zz22yy33');
}

void main() {
  late _FakeController controller;
  late bool permitted;

  Future<void> pumpPage(WidgetTester tester, {PhoneShareState initial = const PhoneShareState()}) async {
    controller = _FakeController(initial);
    await pumpNetworkTestApp(
      tester,
      home: const PhoneSharePage(),
      overrides: [
        phoneShareProvider.overrideWith(() => controller),
        phoneSharePermissionsProvider.overrideWithValue(() async => permitted),
      ],
    );
  }

  setUp(() => permitted = true);

  group('PhoneSharePage', () {
    testWidgets('off: the switch, and what would be shared', (tester) async {
      await pumpPage(tester);

      expect(find.text('Share this phone on the network'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(find.byKey(const Key('phone_share_switch')));
      expect(toggle.value, isFalse);
      expect(find.text('Share photos and videos on the Wi-Fi'), findsOneWidget);
      expect(
        find.text(
          'Read only: albums, months and 360° media of this phone. Stops when the app is closed or after an hour '
          'without use.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('phone_share_card')), findsNothing);
      expect(find.textContaining('Keep Immuch360 open'), findsNothing);
    });

    testWidgets('switching on shows the addresses, the name, the user name and the password', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.byKey(const Key('phone_share_switch')));
      await tester.pumpAndSettle();

      expect(controller.starts, 1);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('phone_share_switch'))).value, isTrue);
      expect(find.text('http://192.168.1.20:8360'), findsOneWidget);
      expect(find.text('http://192.168.43.1:8360'), findsOneWidget);
      expect(find.text('Immuch360 on Pixel 9'), findsOneWidget);
      expect(find.text('User name'), findsOneWidget);
      expect(find.text('phone4821'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('k7m3 x9p2'), findsOneWidget);
      expect(
        find.text(
          'On the headset: Library, Network shares, +, then Immuch360 on Pixel 9 under Found on the network, and '
          'type the password.',
        ),
        findsOneWidget,
      );
      expect(find.text('1 device connected'), findsOneWidget);
      expect(find.text('VID_20260904_101010.mp4'), findsOneWidget);
    });

    testWidgets('switching off stops the share', (tester) async {
      await pumpPage(tester, initial: _onState);

      await tester.tap(find.byKey(const Key('phone_share_switch')));
      await tester.pumpAndSettle();

      expect(controller.stops, 1);
      expect(find.byKey(const Key('phone_share_card')), findsNothing);
    });

    testWidgets('"New password" changes the password shown', (tester) async {
      await pumpPage(tester, initial: _onState);

      await tester.ensureVisible(find.byKey(const Key('phone_share_new_password')));
      await tester.tap(find.byKey(const Key('phone_share_new_password')));
      await tester.pumpAndSettle();

      expect(find.text('k7m3 x9p2'), findsNothing);
      expect(find.text('zz22 yy33'), findsOneWidget);
    });

    testWidgets('copies the password as it is typed', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpPage(tester, initial: _onState);

      final copyButton = find.descendant(
        of: find.byKey(const Key('phone_share_password')),
        matching: find.byIcon(Icons.copy_rounded),
      );
      await tester.ensureVisible(copyButton);
      await tester.tap(copyButton);
      await tester.pumpAndSettle();

      expect(copied, 'k7m3x9p2');
      expect(find.text('Copied to clipboard!'), findsOneWidget);
    });

    testWidgets('without the photos and videos permission, nothing starts', (tester) async {
      permitted = false;
      await pumpPage(tester);

      await tester.tap(find.byKey(const Key('phone_share_switch')));
      await tester.pumpAndSettle();

      expect(controller.starts, 0);
      expect(find.text('The app cannot see the photos of this device'), findsOneWidget);
    });

    testWidgets('tells when the phone has no network but keeps the share on', (tester) async {
      await pumpPage(
        tester,
        initial: const PhoneShareState(
          status: PhoneShareStatus.on,
          port: 8360,
          username: 'phone4821',
          password: 'k7m3x9p2',
        ),
      );

      expect(
        find.text('No Wi-Fi: connect this phone to the network of the headset, or turn on its hotspot.'),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('phone_share_switch'))).value, isTrue);
    });

    testWidgets('tells when the share stopped after an hour without use', (tester) async {
      await pumpPage(tester, initial: const PhoneShareState(stoppedIdle: true));

      expect(find.text('Sharing stopped after an hour without use'), findsOneWidget);
    });

    testWidgets('on iOS, tells to keep the app in front', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      // Reset within the test, even when an expectation fails: the binding checks it before the tear downs run
      try {
        await pumpPage(tester, initial: _onState);

        // Below the card: the list builds it once scrolled to
        final notice = find.text(
          'Keep Immuch360 open on this screen: the sharing pauses while the app is in the background.',
        );
        await tester.scrollUntilVisible(
          notice,
          200,
          scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
        );

        expect(notice, findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('PhoneShareTile', () {
    Future<void> pumpTile(
      WidgetTester tester, {
      required bool isHorizonOs,
      PhoneShareState state = const PhoneShareState(),
    }) async {
      controller = _FakeController(state);
      final router = RootStackRouter.build(
        routes: [
          AutoRoute(
            path: '/',
            initial: true,
            page: PageInfo('HomeRoute', builder: (_) => const Scaffold(body: PhoneShareTile())),
          ),
          AutoRoute(
            path: '/phone-share',
            page: PageInfo(PhoneShareRoute.name, builder: (_) => const Text('phone share page')),
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
              phoneShareProvider.overrideWith(() => controller),
              isHorizonOsProvider.overrideWith((_) async => isHorizonOs),
            ],
            child: Builder(
              builder: (context) => MaterialApp.router(
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

    testWidgets('on a phone, says whether the share is on and opens its page', (tester) async {
      await pumpTile(tester, isHorizonOs: false);

      expect(find.text('Share this phone on the network'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.byIcon(Icons.smartphone), findsOneWidget);

      await tester.tap(find.byKey(const Key('phone_share_tile')));
      await tester.pumpAndSettle();

      expect(find.text('phone share page'), findsOneWidget);
    });

    testWidgets('tells the address once on', (tester) async {
      await pumpTile(tester, isHorizonOs: false, state: _onState);

      expect(find.text('On: http://192.168.1.20:8360'), findsOneWidget);
    });

    testWidgets('is hidden on the headset', (tester) async {
      await pumpTile(tester, isHorizonOs: true);

      expect(find.byKey(const Key('phone_share_tile')), findsNothing);
    });
  });
}
