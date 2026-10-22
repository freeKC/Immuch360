// The phone's side of sign in with your phone, without a network: the Settings card (phones with a server only), the
// Connect page and what it says of a scan, and the confirmation sheet

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/pages/common/settings.page.dart';
import 'package:immich_mobile/platform/qr_scan_api.g.dart';
import 'package:immich_mobile/presentation/pages/pairing/connect_screen.page.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_confirm.sheet.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/pairing/phone_pairing.provider.dart';
import 'package:immich_mobile/providers/pairing/screen_pairing.provider.dart';

import '../../../test_utils.dart';

/// The scanner, answering [result]
class _FakeScanner extends QrScanApi {
  _FakeScanner(this.result);

  final QrScanResult result;
  final prompts = <String>[];

  @override
  Future<QrScanResult> scan(String prompt, String cancelLabel) async {
    prompts.add(prompt);
    return result;
  }
}

/// The list of "Connected by this phone", without the Store nor the server
class _Screens extends PairedScreensNotifier {
  _Screens(this.initial);

  final List<PairedScreen> initial;

  @override
  List<PairedScreen> build() => initial;

  @override
  Future<void> refresh() async {}
}

void main() {
  setUpAll(TestUtils.init);

  /// A phone held upright
  void phoneScreen(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1080, 2400)
      ..devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
  }

  Future<void> pump(WidgetTester tester, Widget home, {List<Override> overrides = const []}) async {
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
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: home,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the Settings card', () {
    final card = find.byKey(const Key('settings_pairing'));

    testWidgets('on a phone with a server, first', (tester) async {
      phoneScreen(tester);
      await pump(
        tester,
        const SettingsPage(),
        overrides: [hasServerProvider.overrideWithValue(true), isBigScreenProvider.overrideWithValue(false)],
      );
      expect(card, findsOneWidget);
      expect(find.text('Connect a TV or computer'), findsOneWidget);
      expect(find.text('Sign in your TV, headset or computer by scanning the code it shows'), findsOneWidget);
    });

    testWidgets('not without a server: connecting one comes first', (tester) async {
      phoneScreen(tester);
      await pump(
        tester,
        const SettingsPage(),
        overrides: [hasServerProvider.overrideWithValue(false), isBigScreenProvider.overrideWithValue(false)],
      );
      expect(card, findsNothing);
    });

    testWidgets('not on a big screen, which is signed in rather than signing in', (tester) async {
      phoneScreen(tester);
      await pump(
        tester,
        const SettingsPage(),
        overrides: [hasServerProvider.overrideWithValue(true), isBigScreenProvider.overrideWithValue(true)],
      );
      expect(card, findsNothing);
    });
  });

  group('the Connect page', () {
    testWidgets('lists the screens this phone signed in, with Sign out', (tester) async {
      phoneScreen(tester);
      await pump(
        tester,
        const ConnectScreenPage(),
        overrides: [
          pairedScreensProvider.overrideWith(
            () => _Screens([
              PairedScreen(
                sessionId: 'session-1',
                label: 'Living room TV',
                kind: PairingScreenKind.tv,
                os: 'Android',
                at: DateTime.utc(2026, 10, 22),
              ),
            ]),
          ),
        ],
      );
      expect(find.text('Scan the code'), findsOneWidget);
      expect(find.text('Enter a code instead'), findsOneWidget);
      expect(find.text('Living room TV'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(find.text('You can also sign them out in Immich: Account settings, Authorized devices.'), findsOneWidget);
    });

    testWidgets('says when nothing is connected yet', (tester) async {
      phoneScreen(tester);
      await pump(
        tester,
        const ConnectScreenPage(),
        overrides: [pairedScreensProvider.overrideWith(() => _Screens([]))],
      );
      expect(find.text('No TV or computer yet.'), findsOneWidget);
    });

    testWidgets('a scanned code that is not one of a big screen', (tester) async {
      phoneScreen(tester);
      final scanner = _FakeScanner(QrScanResult(status: QrScanStatus.scanned, text: 'https://example.com'));
      await pump(
        tester,
        const ConnectScreenPage(),
        overrides: [
          pairedScreensProvider.overrideWith(() => _Screens([])),
          qrScanApiProvider.overrideWithValue(scanner),
        ],
      );
      await tester.tap(find.text('Scan the code'));
      await tester.pumpAndSettle();
      expect(scanner.prompts, ['Scan the code on the TV or computer']);
      expect(find.text('This is not an Immuch360 sign-in code.'), findsOneWidget);
    });

    testWidgets('a refused camera offers the code instead', (tester) async {
      phoneScreen(tester);
      await pump(
        tester,
        const ConnectScreenPage(),
        overrides: [
          pairedScreensProvider.overrideWith(() => _Screens([])),
          qrScanApiProvider.overrideWithValue(_FakeScanner(QrScanResult(status: QrScanStatus.permissionDenied))),
        ],
      );
      await tester.tap(find.text('Scan the code'));
      await tester.pumpAndSettle();
      expect(find.text('Allow the camera to scan the code, or enter the code instead.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Enter a code instead'), findsOneWidget);
    });

    testWidgets('a code of the LG webOS app is told apart', (tester) async {
      phoneScreen(tester);
      await pump(
        tester,
        const ConnectScreenPage(),
        overrides: [
          pairedScreensProvider.overrideWith(() => _Screens([])),
          qrScanApiProvider.overrideWithValue(
            _FakeScanner(QrScanResult(status: QrScanStatus.scanned, text: 'http://192.168.1.40:8788/?c=K7M2Q9XR')),
          ),
        ],
      );
      await tester.tap(find.text('Scan the code'));
      await tester.pumpAndSettle();
      expect(find.text('This LG TV signs in through your browser.'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
    });
  });

  group('the confirmation sheet', () {
    const device = PairingScreenDevice(
      label: 'Living room TV',
      kind: PairingScreenKind.tv,
      os: 'Android',
      app: '3.3.0',
    );

    Future<String?> Function() open(WidgetTester tester, {int headers = 0, bool away = false, bool link = false}) {
      String? answer;
      var done = false;
      return () async {
        await pump(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    answer = await showPairingConfirmSheet(
                      context,
                      device: device,
                      server: 'photos.example.com',
                      user: 'Fred',
                      headerCount: headers,
                      notOnPhoneNetwork: away,
                      fromDeepLink: link,
                    );
                    done = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        return done ? answer : null;
      };
    }

    testWidgets('asks before anything is created, with the cascade', (tester) async {
      phoneScreen(tester);
      await open(tester, headers: 2)();
      expect(find.text('Sign in Living room TV?'), findsOneWidget);
      expect(find.text('Living room TV will be signed in to photos.example.com as Fred.'), findsOneWidget);
      expect(find.textContaining('It stays signed in while this phone is.'), findsOneWidget);
      expect(find.text('2 custom headers go along'), findsOneWidget);
      expect(find.text('This screen is not on the network of your phone.'), findsNothing);
      expect(find.text('Only continue if this device shows a code right now.'), findsNothing);
    });

    testWidgets('warns of a screen off the phone network and of a code that came by a link', (tester) async {
      phoneScreen(tester);
      await open(tester, away: true, link: true)();
      expect(find.text('This screen is not on the network of your phone.'), findsOneWidget);
      expect(find.text('Only continue if this device shows a code right now.'), findsOneWidget);
      expect(find.textContaining('custom header'), findsNothing);
    });

    testWidgets('gives the name the user typed, nothing on Cancel', (tester) async {
      phoneScreen(tester);
      String? answer;
      var closed = false;
      await pump(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  answer = await showPairingConfirmSheet(
                    context,
                    device: device,
                    server: 'photos.example.com',
                    user: 'Fred',
                    headerCount: 0,
                    notOnPhoneNetwork: false,
                    fromDeepLink: false,
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('pairing_confirm_name')), '  Lounge   TV ');
      await tester.tap(find.byKey(const Key('pairing_confirm_button')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(answer, 'Lounge TV');

      closed = false;
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(answer, isNull);
    });
  });
}
