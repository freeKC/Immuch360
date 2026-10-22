// The pairing panel of the big screens: what it shows of a code, on a TV of 960 x 540 dp without scrolling, the code
// first on the Quest, and what it says when there is no code

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_panel.widget.dart';
import 'package:immich_mobile/presentation/widgets/pairing/qr_code.widget.dart';
import 'package:immich_mobile/providers/pairing/screen_pairing.provider.dart';

import '../../../test_utils.dart';

final _now = DateTime.utc(2026, 10, 22, 20);

ScreenPairingView _view({
  PairingScreenKind kind = PairingScreenKind.tv,
  ScreenPairingPhase phase = ScreenPairingPhase.waiting,
  ScreenPairingProblem problem = ScreenPairingProblem.none,
  ScreenPairingNotice notice = ScreenPairingNotice.none,
}) => ScreenPairingView(
  phase: phase,
  kind: kind,
  qrText: 'http://192.168.1.23:8361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA',
  code: 'K7M2Q 9XRTH',
  typedUrl: 'http://192.168.1.23:8361/p',
  startedAt: _now.subtract(const Duration(seconds: 90)),
  expiresAt: _now.add(const Duration(seconds: 30)),
  problem: problem,
  notice: notice,
  noticeDetail: 'photos.example.com',
  port: 8361,
);

void main() {
  setUpAll(TestUtils.init);

  /// A Google TV at 1920 x 1080 and 320 dpi: 960 x 540 logical pixels
  void tvScreen(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPanel(WidgetTester tester, ScreenPairingView view, {VoidCallback? onShowNewCode}) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: Builder(
          builder: (context) => MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            // The left half of the TV's sign-in page, above the version line
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 480,
                  height: 474,
                  child: SingleChildScrollView(
                    child: Center(
                      child: PairingPanelContent(view: view, now: _now, onShowNewCode: onShowNewCode ?? () {}),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('on a TV: the QR code, the code, the countdown and the steps at once', (tester) async {
    tvScreen(tester);
    await pumpPanel(tester, _view());
    expect(find.byType(QrCodeView), findsOneWidget);
    expect(find.text('K7M2Q 9XRTH'), findsOneWidget);
    expect(find.text('New code in 30 s'), findsOneWidget);
    expect(find.text('Waiting for your phone…'), findsOneWidget);
    final last = find.text('Your phone must be on the same Wi-Fi as this TV');
    expect(last, findsOneWidget);
    final typed = find.textContaining('http://192.168.1.23:8361/p');
    expect(typed, findsOneWidget);
    // Nothing below the half screen: no scrolling needed
    expect(tester.getRect(typed).bottom, lessThanOrEqualTo(474));
    // The QR code beside the code, the steps under both
    expect(tester.getRect(find.byType(QrCodeView)).right, lessThan(tester.getRect(find.text('K7M2Q 9XRTH')).left));
    expect(tester.getRect(last).top, greaterThan(tester.getRect(find.byType(QrCodeView)).bottom));
    // The code is never in the QR code's semantics
    expect(find.bySemanticsLabel(RegExp('AQIDBAUGBwgJCgsMDQ4PEA')), findsNothing);
  });

  testWidgets('in the Quest window: the code first, the passthrough line', (tester) async {
    tvScreen(tester);
    await pumpPanel(tester, _view(kind: PairingScreenKind.headset));
    expect(tester.getRect(find.text('K7M2Q 9XRTH')).top, lessThan(tester.getRect(find.byType(QrCodeView)).top));
    expect(find.text('With passthrough on, take your phone and enter this code in Immuch360.'), findsOneWidget);
    expect(find.text('Your phone must be on the same Wi-Fi as this headset'), findsOneWidget);
  });

  testWidgets('on a computer: the network line and the port of the firewall', (tester) async {
    await pumpPanel(tester, _view(kind: PairingScreenKind.computer));
    expect(find.text('Your phone must be on the same network as this computer'), findsOneWidget);
    expect(find.text("If your phone can't reach this computer, allow port 8361 in its firewall."), findsOneWidget);
  });

  testWidgets('what the phone does shows under the code', (tester) async {
    await pumpPanel(tester, _view(phase: ScreenPairingPhase.confirmOnPhone));
    expect(find.text('Confirm on your phone…'), findsOneWidget);
    await pumpPanel(tester, _view(notice: ScreenPairingNotice.tooManyAttempts));
    expect(find.text('Too many attempts: here is a new code.'), findsOneWidget);
    await pumpPanel(tester, _view(notice: ScreenPairingNotice.serverUnreachable));
    expect(find.text("Can't reach photos.example.com from here. Here is a new code."), findsOneWidget);
  });

  testWidgets('paused: no code, and a button for a new one', (tester) async {
    var asked = 0;
    await pumpPanel(tester, _view(phase: ScreenPairingPhase.paused), onShowNewCode: () => asked++);
    expect(find.byType(QrCodeView), findsNothing);
    expect(find.text('K7M2Q 9XRTH'), findsNothing);
    expect(find.text('No phone came for a while: the code is paused.'), findsOneWidget);
    await tester.tap(find.text('Show a new code'));
    expect(asked, 1);
  });

  testWidgets('no local network, a public one: no code, and why', (tester) async {
    await pumpPanel(tester, _view(problem: ScreenPairingProblem.noNetwork));
    expect(find.byType(QrCodeView), findsNothing);
    expect(find.text('Not connected to a local network: type the server address instead.'), findsOneWidget);
    await pumpPanel(tester, _view(problem: ScreenPairingProblem.publicNetwork));
    expect(find.textContaining('Sign in with your phone is off on public networks.'), findsOneWidget);
  });

  testWidgets('the QR code reads in the dark theme too: black modules on a white tile', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Center(
          child: QrCodeView(data: 'http://10.0.2.2:18361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA', size: 200),
        ),
      ),
    );
    final tile = tester.widget<DecoratedBox>(
      find.descendant(of: find.byType(QrCodeView), matching: find.byType(DecoratedBox)),
    );
    expect((tile.decoration as BoxDecoration).color, Colors.white);
    expect(pairingProtocolVersion, 1);
  });
}
