// The invitation to rate the app in Settings and at the end of a viewing: the quiet line of the Quest store build
// (Rate, Something not working?, No thanks; no focus taken), the snack bar that fades by itself, the lasting entries
// (Rate Immuch360 on a store build only, Something not working? on every build), the store page addresses tried in
// turn, and the server version that holds the ask.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/domain/services/rate_app.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';
import 'package:immich_mobile/platform/store_review_api.g.dart';
import 'package:immich_mobile/presentation/widgets/rate_app/rate_app_settings.dart';
import 'package:immich_mobile/providers/rate_app.provider.dart';
import 'package:immich_mobile/utils/store_channel.dart';

const _sentence = 'If Immuch360 is useful to you, a rating on the Meta Horizon Store helps other people find it.';

final _messenger = GlobalKey<ScaffoldMessengerState>();

Future<void> _pumpApp(WidgetTester tester, Widget body, {List<Override> overrides = const []}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: Builder(
          builder: (context) => MaterialApp(
            scaffoldMessengerKey: _messenger,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(body: ListView(children: [body])),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Store implements RateAppStoreApi {
  int reviews = 0;
  int pages = 0;

  @override
  Future<bool> requestReview() async {
    reviews++;
    return true;
  }

  bool opens = true;

  @override
  Future<bool> openStorePage() async {
    pages++;
    return opens;
  }
}

class _Screen implements RateAppScreen {
  @override
  bool get browsing => true;

  @override
  bool get kioskActive => false;

  @override
  bool get remoteControl => false;

  @override
  bool get appOutOfDate => false;

  @override
  Future<bool> showLine() async => true;

  @override
  void hideLine() {}
}

/// Whether anything under [finder] holds the focus
bool _focusIn(Finder finder) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) {
    return false;
  }
  return find.descendant(of: finder, matching: find.byWidget(focused.widget)).evaluate().isNotEmpty;
}

void main() {
  testWidgets('the line: the sentence, Rate, Something not working? and No thanks, and no focus taken', (tester) async {
    final taps = <String>[];
    await _pumpApp(
      tester,
      RateAppLine(
        onRate: () => taps.add('rate'),
        onProblem: () => taps.add('problem'),
        onNoThanks: () => taps.add('no thanks'),
      ),
    );
    expect(find.text(_sentence), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Rate'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Something not working?'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'No thanks'), findsOneWidget, reason: 'written out, not a close icon');
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(_focusIn(find.byKey(RateAppSettingsLine.lineKey)), isFalse);

    await tester.tap(find.byKey(RateAppSettingsLine.rateKey));
    await tester.tap(find.byKey(RateAppSettingsLine.problemKey));
    await tester.tap(find.byKey(RateAppSettingsLine.noThanksKey));
    expect(taps, ['rate', 'problem', 'no thanks']);
  });

  testWidgets('the snack bar at the end of a viewing: the sentence and Rate, gone by itself, no focus', (tester) async {
    await _pumpApp(tester, const SizedBox());
    var rated = 0;
    final context = _messenger.currentContext!;
    _messenger.currentState!.showSnackBar(rateAppSnackBar(context.t, onRate: () => rated++));
    await tester.pumpAndSettle();
    expect(find.byKey(rateAppSnackBarKey), findsOneWidget);
    expect(find.text(_sentence), findsOneWidget);
    expect(_focusIn(find.byKey(rateAppSnackBarKey)), isFalse);
    await tester.pump(kRateAppLineShows);
    await tester.pumpAndSettle();
    expect(find.byKey(rateAppSnackBarKey), findsNothing, reason: 'it fades by itself, even with its action');

    _messenger.currentState!.showSnackBar(rateAppSnackBar(context.t, onRate: () => rated++));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SnackBarAction, 'Rate'));
    await tester.pumpAndSettle();
    expect(rated, 1);
  });

  testWidgets('Settings of a store build: Rate Immuch360 opens the store page, beside Something not working?', (
    tester,
  ) async {
    final store = _Store();
    await _pumpApp(
      tester,
      const RateAppSettingsEntries(),
      overrides: [
        rateAppChannelProvider.overrideWith((ref) async => RateAppChannel.googlePlay),
        rateAppServiceProvider.overrideWith((ref) async => null),
        rateAppStoreApiProvider.overrideWithValue(store),
      ],
    );
    expect(find.text('Rate Immuch360'), findsOneWidget);
    expect(find.text('A rating on Google Play helps other people find the app'), findsOneWidget);
    expect(find.text('Something not working?'), findsOneWidget);
    expect(find.text('Report it on GitHub so that we can fix it'), findsOneWidget);
    await tester.tap(find.byKey(RateAppSettingsEntries.rateKey));
    await tester.pumpAndSettle();
    expect((store.pages, store.reviews), (1, 0), reason: 'the store page, never the review API, from a button');
  });

  testWidgets('Rate Immuch360 whose page did not open shows the address of the page', (tester) async {
    final store = _Store()..opens = false;
    await _pumpApp(
      tester,
      const RateAppSettingsEntries(),
      overrides: [
        rateAppChannelProvider.overrideWith((ref) async => RateAppChannel.googlePlay),
        rateAppServiceProvider.overrideWith((ref) async => null),
        rateAppStoreApiProvider.overrideWithValue(store),
      ],
    );
    await tester.tap(find.byKey(RateAppSettingsEntries.rateKey));
    await tester.pumpAndSettle();
    expect(store.pages, 1);
    expect(find.text('The page did not open on this device. Its address:'), findsOneWidget);
    final https = rateAppStorePages(RateAppChannel.googlePlay).where((url) => url.isScheme('https')).last;
    expect(find.text(https.toString()), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rate_app_address')), findsNothing);
  });

  testWidgets('the line shows at once over a waiting snack bar, and leaves when it is taken away', (tester) async {
    await _pumpApp(tester, const SizedBox());
    final messenger = _messenger.currentState!;
    messenger.showSnackBar(const SnackBar(content: Text('an older snack bar'), duration: Duration(seconds: 30)));
    messenger.showSnackBar(const SnackBar(content: Text('a waiting snack bar')));
    await tester.pumpAndSettle();
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? line;
    showRateAppLine(
      messenger,
      rateAppSnackBar(_messenger.currentContext!.t, onRate: () {}),
      onShown: (value) => line = value,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(rateAppSnackBarKey), findsOneWidget, reason: 'not after the 30 s of the older one');
    expect(find.text('an older snack bar'), findsNothing);
    expect(line, isNotNull);
    hideRateAppLine(messenger);
    await tester.pumpAndSettle();
    expect(find.byKey(rateAppSnackBarKey), findsNothing);
    expect(find.text('a waiting snack bar'), findsNothing, reason: 'the queue went with the line');
    expect(line, isNull, reason: 'closed');
  });

  testWidgets('Settings of a GitHub build or a computer: Something not working? alone', (tester) async {
    for (final channel in [RateAppChannel.github, RateAppChannel.none]) {
      await _pumpApp(
        tester,
        const RateAppSettingsEntries(cards: false),
        overrides: [rateAppChannelProvider.overrideWith((ref) async => channel)],
      );
      expect(find.byKey(RateAppSettingsEntries.rateKey), findsNothing, reason: channel.name);
      expect(find.byKey(RateAppSettingsEntries.problemKey), findsOneWidget, reason: channel.name);
    }
  });

  testWidgets('the line waits in Settings after it showed, and No thanks takes it away for good', (tester) async {
    final store = _Store();
    final now = DateTime.now();
    String? kept = rateAppAsked(
      RateAppState(opens: 4, days: 3, build: 51, buildSince: now.subtract(const Duration(days: 2))),
      RateAppAsk(build: 51, at: now, channel: RateAppChannel.horizonStore),
    ).encode();
    final service = RateAppService(
      channel: RateAppChannel.horizonStore,
      build: 51,
      memory: RateAppMemory(read: () => kept, write: (text) async => kept = text),
      store: store,
      screen: _Screen(),
    );
    await service.start();
    await _pumpApp(
      tester,
      const RateAppSettingsLine(),
      overrides: [rateAppServiceProvider.overrideWith((ref) async => service)],
    );
    expect(find.byKey(RateAppSettingsLine.lineKey), findsOneWidget);
    await tester.tap(find.byKey(RateAppSettingsLine.noThanksKey));
    await tester.pumpAndSettle();
    expect(find.byKey(RateAppSettingsLine.lineKey), findsNothing);
    expect(RateAppState.decode(kept).declined, isTrue);
    expect(store.pages, 0);
    service.dispose();
  });

  testWidgets('the store page: the native one first, then each address in turn', (tester) async {
    final tried = <Uri>[];
    final api = PigeonRateAppStoreApi(
      StoreReviewApi(),
      storePages: [Uri.parse('market://details?id=com.aprogsys.immuch360'), Uri.parse('https://example.org/app')],
      launch: (url) async {
        tried.add(url);
        return url.scheme == 'https';
      },
    );
    // No native side in a test: the pigeon call fails, as the phone flavour and iOS answer false
    expect(await tester.runAsync(api.openStorePage), isTrue);
    expect(tried.map((url) => url.scheme), ['market', 'https']);

    final none = PigeonRateAppStoreApi(StoreReviewApi(), storePages: const [], launch: (url) async => true);
    expect(await tester.runAsync(none.openStorePage), isFalse);
  });

  test('only an app too old for the server holds the ask, not the other warnings of the profile menu', () {
    expect(
      {for (final status in VersionStatus.values) status: rateAppHeldByVersion(status)},
      {
        VersionStatus.upToDate: false,
        VersionStatus.clientOutOfDate: true,
        VersionStatus.serverOutOfDate: false,
        VersionStatus.error: false,
      },
    );
  });

  test('the snack bar is told to fade even with its action', () {
    final bar = rateAppSnackBar(StaticTranslations.instance, onRate: () {});
    expect((bar.persist, bar.duration), (false, kRateAppLineShows));
  });
}
