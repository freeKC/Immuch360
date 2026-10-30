import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/search/tv_date_range_picker.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';

void main() {
  late DateTimeRange? result;
  late bool closed;

  /// The app in [locale] on a TV screen, the date range dialog open on 15 January to 10 September 2026, or on
  /// [initial] from [firstDate] to [lastDate]
  Future<void> openRange(
    WidgetTester tester, {
    Locale? locale,
    DateTimeRange? initial,
    DateTime? firstDate,
    DateTime? lastDate,
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    result = null;
    closed = false;
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locale ?? locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              builder: (context, child) => TvShell(enabled: true, child: child!),
              home: Scaffold(
                body: Builder(
                  builder: (context) => ElevatedButton(
                    child: const Text('Open range'),
                    onPressed: () async {
                      result = await showTvSearchDateRangePicker(
                        context: context,
                        firstDate: firstDate ?? DateTime(2023),
                        lastDate: lastDate ?? DateTime(2026, 10, 27),
                        initialDateRange:
                            initial ?? DateTimeRange(start: DateTime(2026, 1, 15), end: DateTime(2026, 9, 10)),
                      );
                      closed = true;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open range'));
    await tester.pumpAndSettle();
  }

  Finder value(String part, String text) =>
      find.descendant(of: find.byKey(Key('tv_date_$part')), matching: find.text(text));

  Future<void> choose(WidgetTester tester, String part, String choice) async {
    await tester.tap(find.byKey(Key('tv_date_$part')));
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(ListTile, choice);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets('TV date range can jump to a year directly without month scrolling', (tester) async {
    await openRange(tester);
    expect(find.byKey(const Key('tv_date_start_year')), findsOneWidget);
    expect(value('start_year', '2026'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tv_date_start_year')));
    await tester.pumpAndSettle();
    expect(find.text('Start year'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '2024'));
    await tester.pumpAndSettle();
    expect(value('start_year', '2024'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tv_date_range_apply')));
    await tester.pumpAndSettle();
    expect(result?.start, DateTime(2024, 1, 15));
    expect(result?.end, DateTime(2026, 9, 10));
  });

  testWidgets('each part of each date has its own title, and the day follows the month', (tester) async {
    await openRange(tester);

    for (final (part, title) in [
      ('start_month', 'Start month'),
      ('start_day', 'Start day'),
      ('end_year', 'End year'),
      ('end_month', 'End month'),
      ('end_day', 'End day'),
    ]) {
      await tester.tap(find.byKey(Key('tv_date_$part')));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget, reason: part);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    // 31 March, then February: the day comes down to the last day of February
    await choose(tester, 'start_month', 'March');
    await choose(tester, 'start_day', '31');
    await choose(tester, 'start_month', 'February');
    expect(value('start_day', '28'), findsOneWidget);
    expect(value('start_month', 'Feb'), findsOneWidget);
  });

  testWidgets('a start after the end is said and cannot be selected', (tester) async {
    await openRange(tester);
    expect(find.text('Start date must be on or before end date'), findsNothing);

    await choose(tester, 'end_year', '2023');
    expect(find.text('Start date must be on or before end date'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(find.byKey(const Key('tv_date_range_apply'))).onPressed, isNull);

    await choose(tester, 'start_year', '2023');
    expect(find.text('Start date must be on or before end date'), findsNothing);
    await tester.tap(find.byKey(const Key('tv_date_range_apply')));
    await tester.pumpAndSettle();
    expect(result, DateTimeRange(start: DateTime(2023, 1, 15), end: DateTime(2023, 9, 10)));
  });

  // The Search page gives the time of now and the end of the day of its filter, as Flutter's range picker gets them
  group('dates given with a time of day', () {
    final initial = DateTimeRange(start: DateTime(2026, 3, 10, 15, 30), end: DateTime(2026, 3, 12, 23, 59, 59));
    final firstDate = DateTime(2023, 1, 1, 12);
    final lastDate = DateTime(2026, 10, 27, 18, 45);

    testWidgets('Select gives the days of the range, without their time', (tester) async {
      await openRange(tester, initial: initial, lastDate: lastDate);
      await tester.tap(find.byKey(const Key('tv_date_range_apply')));
      await tester.pumpAndSettle();
      expect(result, DateTimeRange(start: DateTime(2026, 3, 10), end: DateTime(2026, 3, 12)));
    });

    testWidgets('the end on the day of the start is a range of one day', (tester) async {
      await openRange(tester, initial: initial, lastDate: lastDate);
      await choose(tester, 'end_day', '10');
      expect(find.text('Start date must be on or before end date'), findsNothing);
      await tester.tap(find.byKey(const Key('tv_date_range_apply')));
      await tester.pumpAndSettle();
      expect(result, DateTimeRange(start: DateTime(2026, 3, 10), end: DateTime(2026, 3, 10)));
    });

    testWidgets('a day after the last one comes down to the last day, without its time', (tester) async {
      await openRange(tester, initial: initial, lastDate: lastDate);
      await choose(tester, 'end_month', 'October');
      await choose(tester, 'end_day', '31');
      expect(value('end_day', '27'), findsOneWidget);
      await choose(tester, 'start_month', 'October');
      await choose(tester, 'start_day', '27');
      expect(find.text('Start date must be on or before end date'), findsNothing);
      await tester.tap(find.byKey(const Key('tv_date_range_apply')));
      await tester.pumpAndSettle();
      expect(result, DateTimeRange(start: DateTime(2026, 10, 27), end: DateTime(2026, 10, 27)));
    });

    testWidgets('the first day is a whole day, whatever the time of the first date', (tester) async {
      await openRange(tester, initial: initial, firstDate: firstDate, lastDate: lastDate);
      await choose(tester, 'start_year', '2023');
      await choose(tester, 'start_month', 'January');
      await choose(tester, 'start_day', '1');
      await tester.tap(find.byKey(const Key('tv_date_range_apply')));
      await tester.pumpAndSettle();
      expect(result?.start, DateTime(2023));
    });
  });

  testWidgets('Cancel and Back close the dialog without a range', (tester) async {
    await openRange(tester);
    await choose(tester, 'start_year', '2024');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);

    await tester.tap(find.text('Open range'));
    await tester.pumpAndSettle();
    closed = false;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });

  // 960 x 540 dp less the overscan margins of TvShell and the margins of a dialog: 390 dp for the content
  for (final (locale, error) in [
    (null, 'Start date must be on or before end date'),
    (const Locale('fr'), 'La date de début doit être antérieure ou égale à la date de fin'),
  ]) {
    testWidgets('on the screen of a TV the dialog holds without scrolling, its error line shown (${locale ?? 'en'})', (
      tester,
    ) async {
      await openRange(tester, locale: locale);
      await choose(tester, 'end_year', '2023');
      expect(find.text(error), findsOneWidget);

      final body = tester.state<ScrollableState>(
        find.descendant(of: find.byKey(const Key('tv_date_range_body')), matching: find.byType(Scrollable)),
      );
      expect(body.position.maxScrollExtent, 0, reason: 'Cancel and Select in view without a move');
      expect(find.byKey(const Key('tv_date_range_apply')).hitTestable(), findsOneWidget);
    });
  }

  testWidgets('the dialog speaks the language of the app', (tester) async {
    await openRange(tester, locale: const Locale('fr'));

    expect(find.text('Sélectionner une période'), findsOneWidget);
    expect(find.text('Date de début'), findsOneWidget);
    expect(find.text('Date de fin'), findsOneWidget);
    expect(value('start_year', 'Année'), findsOneWidget);
    expect(value('end_month', 'Mois'), findsOneWidget);
    expect(value('end_day', 'Jour'), findsOneWidget);
    expect(find.text('Annuler'), findsOneWidget);
    expect(find.text('Sélectionner'), findsOneWidget);
    for (final english in ['Date range', 'Start date', 'End date', 'Cancel', 'Select']) {
      expect(find.text(english), findsNothing, reason: english);
    }

    await tester.tap(find.byKey(const Key('tv_date_start_year')));
    await tester.pumpAndSettle();
    expect(find.text('Année de début'), findsOneWidget);
    expect(find.text('Start year'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await choose(tester, 'end_year', '2023');
    expect(find.text('La date de début doit être antérieure ou égale à la date de fin'), findsOneWidget);
  });
}
