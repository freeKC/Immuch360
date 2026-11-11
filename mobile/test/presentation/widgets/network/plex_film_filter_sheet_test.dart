import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/presentation/widgets/network/plex_film_filter_sheet.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../system_navigation_bar.dart';

const _options = PlexFilmFilterOptions(
  years: [
    PlexFilterChoice(key: '2001', title: '2001'),
    PlexFilterChoice(key: '1999', title: '1999'),
    PlexFilterChoice(key: '1994', title: '1994'),
  ],
  decades: [
    PlexFilterChoice(key: '2000', title: '2000s'),
    PlexFilterChoice(key: '1990', title: '1990s'),
  ],
  contentRatings: [
    PlexFilterChoice(key: 'fr/12', title: 'fr/12', count: 3),
    PlexFilterChoice(key: 'PG-13', title: 'PG-13', count: 2),
    PlexFilterChoice(key: 'G', title: 'G'),
    PlexFilterChoice(key: 'NR', title: 'NR', count: 1),
    PlexFilterChoice(key: 'xx/Q', title: 'xx/Q', count: 1),
  ],
);

void main() {
  late PresentationContext context;

  setUp(() async => context = await PresentationContext.create());
  tearDown(() => context.dispose());

  /// Opens the filters from a button, the query they give back in [result]
  Future<List<PlexFilmsQuery?>> open(
    WidgetTester tester, {
    bool tvMode = false,
    bool navigationBar = false,
    PlexFilmsQuery? current,
  }) async {
    final results = <PlexFilmsQuery?>[];
    // A phone, with its navigation bar at the bottom or not, or a 1080p TV
    if (navigationBar) {
      screenWithNavigationBar(tester, ratio: 2.5);
    } else {
      tester.view.physicalSize = tvMode ? const Size(1920, 1080) : const Size(1080, 2400);
      tester.view.devicePixelRatio = tvMode ? 2 : 2.5;
      addTearDown(tester.view.reset);
    }
    await tester.pumpTestWidget(
      context,
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () async => results.add(
            await showPlexFilmFilters(
              context,
              ref,
              sourceId: 'source',
              sectionKey: '1',
              current: current ?? const PlexFilmsQuery(),
            ),
          ),
          child: const Text('open'),
        ),
      ),
      overrides: [
        plexFilmFilterOptionsProvider.overrideWith((ref, key) async => _options),
        tvModeProvider.overrideWithValue(tvMode),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final found = find.text(text);
    await tester.ensureVisible(found);
    await tester.pumpAndSettle();
    await tester.tap(found);
    await tester.pumpAndSettle();
  }

  testWidgets('offers the decades, the audience bands the library holds and the ratings the table does not know', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('2000s'), findsOneWidget);
    expect(find.text('1990s'), findsOneWidget);
    expect(find.text('All audiences'), findsOneWidget);
    expect(find.text('12 and over (5)'), findsOneWidget, reason: 'fr/12 and PG-13 together');
    expect(find.text('Not rated (1)'), findsOneWidget);
    expect(find.text('xx/Q (1)'), findsOneWidget);
    expect(find.text('16 and over'), findsNothing, reason: 'no film of that band');
  });

  testWidgets('applies the choices as the query of the server, the bands as the ratings they hold', (tester) async {
    final results = await open(tester);
    await tapText(tester, '12 and over (5)');
    await tapText(tester, 'xx/Q (1)');
    // The 1990s as a whole, and 2001 opened from its decade
    await tester.tap(
      find.descendant(of: find.byKey(const Key('plex_film_decade_1990')), matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();
    await tapText(tester, '2000s');
    await tapText(tester, '2001');
    await tapText(tester, 'Year, oldest first');
    await tapText(tester, 'Not watched');
    await tapText(tester, 'Show the films');
    final query = results.single!;
    expect(query.contentRatings, {'fr/12', 'PG-13', 'xx/Q'});
    expect(query.decades, {1990});
    expect(query.years, {2001});
    expect(query.sort, PlexFilmSort.yearOldest);
    expect(query.unwatched, isTrue);
  });

  testWidgets('starts from the current query, and Clear takes every filter off', (tester) async {
    final results = await open(
      tester,
      current: const PlexFilmsQuery(contentRatings: {'NR'}, unwatched: true, sort: PlexFilmSort.title),
    );
    final notRated = tester.widget<CheckboxListTile>(find.byKey(const Key('plex_film_audience_unrated')));
    expect(notRated.value, isTrue);
    await tapText(tester, 'Clear');
    await tapText(tester, 'Show the films');
    final query = results.single!;
    expect(query.isFiltered, isFalse);
    expect(query.sort, PlexFilmSort.title, reason: 'Clear leaves the order');
  });

  testWidgets('keeps Clear and Show the films above the navigation bar of a phone, the list scrolling above them', (
    tester,
  ) async {
    await open(tester, navigationBar: true);
    expectAboveNavigationBar(tester, find.byKey(const Key('plex_film_filters_clear')));
    expectAboveNavigationBar(tester, find.byKey(const Key('plex_film_filters_apply')));
    final list = tester.getRect(find.byKey(const Key('plex_film_filters')));
    expect(list.bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const Key('plex_film_filters_apply'))).top));
  });

  testWidgets('opens in a dialog on a TV', (tester) async {
    await open(tester, tvMode: true);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byKey(const Key('plex_film_filters_apply')), findsOneWidget);
  });
}
