// The Search page with the TV Search navigation of Michael Cloutier (mlc70, branch
// feature/tv-search-navigation-upstream-20261027), on a TV and on a phone: the custom date range of a TV is the year
// first dialog and its Cancel keeps the date filter there was, a phone keeps Immich's calendar and its Cancel that
// clears the filter. Back from the results of a TV puts Search back to its start, the focus on the search entry.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/search_result.model.dart';
import 'package:immich_mobile/domain/services/search.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/pages/search/paginated_search.provider.dart';
import 'package:immich_mobile/presentation/pages/search/search.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/search/tv_search_navigation.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/presentation/presentation_context.dart';

/// A server that finds nothing: the results show "No results found". [asked] keeps the filters it was asked
class _NoResults extends Fake implements SearchService {
  _NoResults(this.asked);

  final List<SearchFilter> asked;

  @override
  Future<SearchResult?> search(SearchFilter filter, int page) async {
    asked.add(filter);
    return null;
  }
}

class _MockTvApi extends Mock implements TvApi {}

/// A server with [features]
class _ServerInfo extends ServerInfoNotifier {
  _ServerInfo(super.service, ServerFeatures features) {
    state = state.copyWith(serverFeatures: features);
  }
}

void main() {
  late PresentationContext context;
  late _MockTvApi tvApi;
  late List<SearchFilter> asked;

  setUpAll(() {
    registerFallbackValue(TvTextRequest(title: '', text: '', kind: TvTextKind.text, okLabel: '', cancelLabel: ''));
  });

  setUp(() async {
    context = await PresentationContext.create();
    tvApi = _MockTvApi();
    asked = [];
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The Search page on a TV (1920 x 1080 at 2, under TvShell) or on a phone in portrait (1080 x 2340 at 3)
  Future<void> pumpSearch(WidgetTester tester, {required bool tvMode}) async {
    tester.view.physicalSize = tvMode ? const Size(1920, 1080) : const Size(1080, 2340);
    tester.view.devicePixelRatio = tvMode ? 2 : 3;
    addTearDown(tester.view.reset);
    const features = ServerFeatures(map: true, trash: true, oauthEnabled: false, passwordLogin: true);
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
            tvModeProvider.overrideWithValue(tvMode),
            tvApiProvider.overrideWithValue(tvApi),
            serverInfoProvider.overrideWith((ref) => _ServerInfo(context.service.serverInfo, features)),
            paginatedSearchProvider.overrideWith((ref) => PaginatedSearchNotifier(_NoResults(asked))),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              // As main.dart does
              builder: (context, child) => TvShell(enabled: tvMode, child: child!),
              home: const SearchPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The date chip, its sheet, and a choice of the sheet
  Future<void> pickDate(WidgetTester tester, {required String chip, required String choice}) async {
    // The chips scroll sideways: on a phone the date chip starts beyond the right edge of the screen
    final chips = find.descendant(
      of: find.byKey(const Key('search_filter_chip_list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text(chip), 100, scrollable: chips.first);
    // The last move of scrollUntilVisible is laid out at the next frame, where the tap reads the place of the chip
    await tester.pumpAndSettle();
    await tester.tap(find.text(chip));
    await tester.pumpAndSettle();
    // Custom range is one row that takes the tap and OK as a whole, its text under an IgnorePointer: the tap on the
    // text reaches the row, as a finger does
    await tester.tap(find.text(choice).last, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    return finder.evaluate().any((element) {
      var found = element == focused;
      if (!found) {
        focused.visitAncestorElements((ancestor) {
          found = ancestor == element;
          return !found;
        });
      }
      return found;
    });
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(SearchPage)));

  /// What the tab shell of a TV does on Back when the focus is in the Search content and Search shows results
  Future<void> backFromResults(WidgetTester tester) async {
    containerOf(tester).read(tvSearchReturnToStartProvider.notifier).state++;
    await tester.pumpAndSettle();
  }

  /// A part of a date in the year first dialog of a TV, and its value in the choice dialog that opens
  Future<void> choose(WidgetTester tester, String part, String choice) async {
    await tester.tap(find.byKey(Key('tv_date_$part')));
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(ListTile, choice);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Future<void> selectRange(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tv_date_range_apply')));
    await tester.pumpAndSettle();
  }

  const noResults = 'No results found, try a different search term or combination';
  const suggestions = 'Search for your photos and videos';
  const endOfDay = Duration(hours: 23, minutes: 59, seconds: 59);

  group('Back from the results on a TV', () {
    testWidgets('puts Search back to its start, the focus on the search entry', (tester) async {
      await pumpSearch(tester, tvMode: true);
      expect(containerOf(tester).read(tvSearchHasActiveQueryProvider), isFalse);

      await pickDate(tester, chip: 'Date', choice: 'Last month');
      expect(find.text(noResults), findsOneWidget);
      expect(containerOf(tester).read(tvSearchHasActiveQueryProvider), isTrue);
      // The focus in the content, away from the search entry, as when the remote went down to the results
      Focus.of(tester.element(find.text('Last month'))).requestFocus();
      await tester.pumpAndSettle();
      expect(focusedIn(find.byKey(const Key('search_text_field'))), isFalse);

      await backFromResults(tester);
      expect(find.text(suggestions), findsOneWidget);
      expect(find.text(noResults), findsNothing);
      expect(find.text('Last month'), findsNothing);
      expect(find.text('Date'), findsOneWidget, reason: 'the date chip without its filter');
      expect(
        containerOf(tester).read(tvSearchHasActiveQueryProvider),
        isFalse,
        reason: 'the next Back goes to the rail',
      );
      expect(focusedIn(find.byKey(const Key('search_text_field'))), isTrue, reason: 'ready for another query');
    });

    testWidgets('clears a text query typed with the keyboard of the TV', (tester) async {
      when(() => tvApi.editText(any())).thenAnswer((_) async => 'beach');
      await pumpSearch(tester, tvMode: true);

      await tester.tap(find.byKey(const Key('search_text_field')));
      await tester.pumpAndSettle();
      expect(find.text('beach'), findsOneWidget);
      expect(find.text(noResults), findsOneWidget);
      expect(containerOf(tester).read(tvSearchHasActiveQueryProvider), isTrue);

      await backFromResults(tester);
      expect(find.text('beach'), findsNothing);
      expect(find.text(suggestions), findsOneWidget);
      expect(containerOf(tester).read(tvSearchHasActiveQueryProvider), isFalse);
    });

    testWidgets('leaves no date choice marked in the date sheet', (tester) async {
      await pumpSearch(tester, tvMode: true);
      await pickDate(tester, chip: 'Date', choice: 'Last month');
      expect(find.text(noResults), findsOneWidget);

      await backFromResults(tester);
      await tester.tap(find.text('Date'));
      await tester.pumpAndSettle();
      final choices = tester.widget<RadioGroup<Object?>>(find.byWidgetPredicate((widget) => widget is RadioGroup));
      expect(choices.groupValue, isNull, reason: 'Last month is not marked any more');
    });

    testWidgets('clears the filter of similar photos, which can then search again', (tester) async {
      await pumpSearch(tester, tvMode: true);
      const similar = SearchFilter(
        assetId: 'asset-1',
        people: {},
        location: SearchLocationFilter(),
        camera: SearchCameraFilter(),
        date: SearchDateFilter(),
        display: SearchDisplayFilters(isNotInAlbum: false, isArchive: false, isFavorite: false),
        rating: SearchRatingFilter(),
        mediaType: AssetType.other,
      );
      containerOf(tester).read(searchPreFilterProvider.notifier).setFilter(similar);
      await tester.pumpAndSettle();
      expect(asked.last.assetId, 'asset-1');
      expect(find.text(noResults), findsOneWidget);

      await backFromResults(tester);
      expect(containerOf(tester).read(searchPreFilterProvider), isNull);
      expect(find.text(suggestions), findsOneWidget);

      // Similar photos of the same photo again: the page searches again
      asked.clear();
      containerOf(tester).read(searchPreFilterProvider.notifier).setFilter(similar);
      await tester.pumpAndSettle();
      expect(asked.map((filter) => filter.assetId), ['asset-1']);
      expect(find.text(noResults), findsOneWidget);
    });
  });

  group('custom date range', () {
    testWidgets('on a TV it opens the year first dialog, and Cancel keeps the date filter there was', (tester) async {
      await pumpSearch(tester, tvMode: true);
      await pickDate(tester, chip: 'Date', choice: 'Last month');
      expect(find.text('Last month'), findsOneWidget, reason: 'the chip shows the filter');

      await pickDate(tester, chip: 'Last month', choice: 'Custom range');
      expect(find.byKey(const Key('tv_date_start_year')), findsOneWidget);
      expect(find.byType(DateRangePickerDialog), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Last month'), findsOneWidget, reason: 'the filter is kept');
      expect(find.text('Date'), findsNothing);

      // Back is the Cancel of a remote
      await pickDate(tester, chip: 'Last month', choice: 'Custom range');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv_date_start_year')), findsNothing);
      expect(find.text('Last month'), findsOneWidget, reason: 'the filter is kept');
    });

    testWidgets('on a TV a range opened again and selected keeps the end of its chip', (tester) async {
      await pumpSearch(tester, tvMode: true);
      await pickDate(tester, chip: 'Date', choice: 'Custom range');
      await choose(tester, 'start_year', '2024');
      await choose(tester, 'start_month', 'October');
      await choose(tester, 'start_day', '1');
      await choose(tester, 'end_year', '2025');
      await choose(tester, 'end_month', 'March');
      await choose(tester, 'end_day', '10');
      await selectRange(tester);
      expect(asked.last.date.takenAfter, DateTime(2024, 10, 1));
      expect(asked.last.date.takenBefore, DateTime(2025, 3, 10).add(endOfDay));
      expect(find.text('Oct 1, 2024 to Mar 10, 2025'), findsOneWidget);

      // Opened again twice, only the start year changed each time
      for (final year in [2023, 2022]) {
        await pickDate(tester, chip: 'Oct 1, ${year + 1} to Mar 10, 2025', choice: 'Custom range');
        expect(find.text('March 10, 2025'), findsOneWidget, reason: 'the end of the chip, not a day later');
        await choose(tester, 'start_year', '$year');
        await selectRange(tester);
        expect(asked.last.date.takenAfter, DateTime(year, 10, 1));
        expect(asked.last.date.takenBefore, DateTime(2025, 3, 10).add(endOfDay), reason: 'the end did not move');
        expect(find.text('Oct 1, $year to Mar 10, 2025'), findsOneWidget);
      }
    });

    testWidgets('on a TV Select at once searches the whole of today, as on a phone', (tester) async {
      await pumpSearch(tester, tvMode: true);
      await pickDate(tester, chip: 'Date', choice: 'Custom range');
      await selectRange(tester);

      final today = DateUtils.dateOnly(DateTime.now());
      expect(asked.last.date.takenAfter, today, reason: 'the photos of earlier today are in');
      expect(asked.last.date.takenBefore, today.add(endOfDay));
    });

    testWidgets('on a phone it opens the calendar, and Cancel clears the date filter as in Immich', (tester) async {
      await pumpSearch(tester, tvMode: false);
      await pickDate(tester, chip: 'Date', choice: 'Last month');
      expect(find.text('Last month'), findsOneWidget, reason: 'the chip shows the filter');

      await pickDate(tester, chip: 'Last month', choice: 'Custom range');
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      expect(find.byKey(const Key('tv_date_start_year')), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsNothing);
      expect(find.text('Last month'), findsNothing, reason: 'the filter is cleared');
      expect(find.text('Date'), findsOneWidget);
    });
  });

  group('search entry', () {
    testWidgets('on a TV the keyboard is titled Search, not with the example of the hint', (tester) async {
      when(() => tvApi.editText(any())).thenAnswer((_) async => null);
      await pumpSearch(tester, tvMode: true);
      expect(find.text('File name or extension'), findsOneWidget, reason: 'the hint stays in the field');

      await tester.tap(find.byKey(const Key('search_text_field')));
      await tester.pumpAndSettle();
      final request = verify(() => tvApi.editText(captureAny())).captured.single as TvTextRequest;
      expect(request.title, 'Search');
    });

    testWidgets('on a TV the app bar is high enough for the line under the entry', (tester) async {
      await pumpSearch(tester, tvMode: true);
      final bar = tester.getRect(find.byType(AppBar));
      final line = tester.getRect(find.text('Press OK to type'));
      expect(line.bottom, lessThanOrEqualTo(bar.bottom), reason: 'not clipped by the toolbar');
      expect(tester.getRect(find.byKey(const Key('search_text_field'))).top, greaterThanOrEqualTo(bar.top));
    });

    testWidgets('a phone keeps the toolbar of Immich and its text field', (tester) async {
      await pumpSearch(tester, tvMode: false);
      expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight);
      expect(find.text('Press OK to type'), findsNothing);

      await tester.enterText(find.byType(TextField), 'beach');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text(noResults), findsOneWidget);
      verifyNever(() => tvApi.editText(any()));
    });
  });
}
