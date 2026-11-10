// The invitation to rate the app of the Quest store build: one sentence, Not now and Rate, Not now focused first for
// the remote; Back is Not now. With the stores of Play and Apple no dialog is built.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/domain/services/rate_app.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/rate_app/rate_app_dialog.dart';

const _sentence = 'If Immuch360 is useful to you, a rating on the Meta Horizon Store helps other people find it.';

final _navigator = GlobalKey<NavigatorState>();

Future<void> _pumpApp(WidgetTester tester) async {
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
          navigatorKey: _navigator,
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: const Scaffold(body: Text('browse')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the dialog and gives the future of its answer, once it shows
Future<({Future<RateAppAnswer> answer})> _open(WidgetTester tester) async {
  final answer = showRateAppDialog(_navigator.currentContext!);
  await tester.pumpAndSettle();
  return (answer: answer);
}

class _Store implements RateAppStoreApi {
  int reviews = 0;
  int pages = 0;

  @override
  Future<bool> requestReview() async {
    reviews++;
    return true;
  }

  @override
  Future<bool> openStorePage() async {
    pages++;
    return true;
  }
}

/// The screen of the app in the test: the dialog in the test's navigator
class _Screen implements RateAppScreen {
  int invites = 0;

  @override
  bool get browsing => true;

  @override
  bool get kioskActive => false;

  @override
  bool get versionWarning => false;

  @override
  Future<RateAppAnswer?> showInvite() {
    invites++;
    return showRateAppDialog(_navigator.currentContext!);
  }
}

void main() {
  testWidgets('the sentence and both buttons; Not now answers not now and closes', (tester) async {
    await _pumpApp(tester);
    final answer = (await _open(tester)).answer;

    expect(find.byKey(RateAppDialog.dialogKey), findsOneWidget);
    expect(find.text(_sentence), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Not now'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Rate'), findsOneWidget);

    await tester.tap(find.byKey(RateAppDialog.notNowKey));
    await tester.pumpAndSettle();
    expect(await answer, RateAppAnswer.notNow);
    expect(find.byKey(RateAppDialog.dialogKey), findsNothing);
  });

  testWidgets('Rate answers rate', (tester) async {
    await _pumpApp(tester);
    final answer = (await _open(tester)).answer;
    await tester.tap(find.byKey(RateAppDialog.rateKey));
    await tester.pumpAndSettle();
    expect(await answer, RateAppAnswer.rate);
  });

  testWidgets('Back and a tap outside are Not now', (tester) async {
    await _pumpApp(tester);
    var answer = (await _open(tester)).answer;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await answer, RateAppAnswer.notNow);
    expect(find.byKey(RateAppDialog.dialogKey), findsNothing);

    answer = (await _open(tester)).answer;
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(await answer, RateAppAnswer.notNow);
  });

  testWidgets('with a remote: Not now has the focus first, Right reaches Rate', (tester) async {
    await _pumpApp(tester);
    final answer = (await _open(tester)).answer;
    bool focused(Key key) =>
        Focus.of(tester.element(find.descendant(of: find.byKey(key), matching: find.byType(Text)))).hasPrimaryFocus;
    expect(focused(RateAppDialog.notNowKey), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focused(RateAppDialog.rateKey), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await answer, RateAppAnswer.rate);
  });

  testWidgets('the Quest store build: Rate opens the store page once and is kept', (tester) async {
    await _pumpApp(tester);
    final store = _Store();
    final screen = _Screen();
    String? kept;
    final rate = RateAppService(
      channel: RateAppChannel.horizonStore,
      build: 45,
      memory: RateAppMemory(read: () => kept, write: (text) async => kept = text),
      store: store,
      screen: screen,
      settle: Duration.zero,
    );
    kept = RateAppState(
      opens: 4,
      days: 3,
      lastDay: rateAppDayOf(DateTime.now()),
      successes: 1,
      build: 45,
      buildSince: DateTime.now().subtract(const Duration(days: 2)),
    ).encode();
    await rate.start();
    rate.succeeded(RateAppViewing.immersive);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text(_sentence), findsOneWidget);

    await tester.tap(find.byKey(RateAppDialog.rateKey));
    await tester.pumpAndSettle();
    expect((screen.invites, store.pages, store.reviews), (1, 1, 0));
    expect(RateAppState.decode(kept).rated, isTrue);
    rate.dispose();
  });

  testWidgets('Google Play and the App Store build no dialog and ask their prompt once', (tester) async {
    for (final channel in [RateAppChannel.googlePlay, RateAppChannel.appStore]) {
      await _pumpApp(tester);
      final store = _Store();
      final screen = _Screen();
      String? kept = RateAppState(
        opens: 4,
        days: 3,
        lastDay: rateAppDayOf(DateTime.now()),
        successes: 1,
        build: 45,
        buildSince: DateTime.now().subtract(const Duration(days: 2)),
      ).encode();
      final rate = RateAppService(
        channel: channel,
        build: 45,
        memory: RateAppMemory(read: () => kept, write: (text) async => kept = text),
        store: store,
        screen: screen,
        settle: Duration.zero,
      );
      await rate.start();
      rate.succeeded(RateAppViewing.panorama);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(RateAppDialog), findsNothing, reason: channel.name);
      expect((screen.invites, store.reviews), (0, 1), reason: channel.name);
      rate.dispose();
    }
  });
}
