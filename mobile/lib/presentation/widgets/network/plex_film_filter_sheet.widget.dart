// The filters of a library of films of a Plex server (request 7 of 10 November 2026): the order, the decades and
// years, the audience, and the films not watched yet. Within one kind the choices add up, between kinds they narrow
// the list, as in the filter bar of the 360° list. The values come from the server (/library/sections/{id}/filters
// and the values of each filter); the audience bands come from the content ratings of the library as Plex stores
// them, several can be ticked, and a rating the table does not know is offered as Plex gives it. A filter, never a
// parental lock. The choice goes to the server as the parameters of /all (PlexFilmsQuery), so that a large library is
// never read whole to filter it.
//
// A sheet on phones, tablets, the Quest window and computers; a dialog on a TV, whose remote reaches every line, then
// the two buttons at its bottom.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/presentation/pages/network/plex_film.page.dart' show audienceBandLabel;
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';

/// Opens the filters of the library [sectionKey] of [sourceId], from [current]: the query picked, null when the user
/// left without applying
Future<PlexFilmsQuery?> showPlexFilmFilters(
  BuildContext context,
  WidgetRef ref, {
  required String sourceId,
  required String sectionKey,
  required PlexFilmsQuery current,
  List<PlexFilmSort> sorts = PlexFilmSort.values,
}) {
  final sheet = PlexFilmFilterSheet(sourceId: sourceId, sectionKey: sectionKey, initial: current, sorts: sorts);
  if (ref.read(tvModeProvider)) {
    return showDialog<PlexFilmsQuery>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640), child: sheet),
      ),
    );
  }
  return showModalBottomSheet<PlexFilmsQuery>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(heightFactor: 0.85, child: sheet),
  );
}

/// The choices of the filters, the order first, then Apply and Clear at the bottom
class PlexFilmFilterSheet extends ConsumerStatefulWidget {
  const PlexFilmFilterSheet({
    super.key,
    required this.sourceId,
    required this.sectionKey,
    required this.initial,
    this.sorts = PlexFilmSort.values,
  });

  final String sourceId;
  final String sectionKey;
  final PlexFilmsQuery initial;

  /// The orders offered; one alone is no choice, and the sheet shows no Order (the films page of lot A1 orders its
  /// years newest first)
  final List<PlexFilmSort> sorts;

  @override
  ConsumerState<PlexFilmFilterSheet> createState() => _PlexFilmFilterSheetState();
}

class _PlexFilmFilterSheetState extends ConsumerState<PlexFilmFilterSheet> {
  late PlexFilmSort _sort = widget.sorts.contains(widget.initial.sort) ? widget.initial.sort : widget.sorts.first;
  late final Set<int> _years = {...widget.initial.years};
  late final Set<int> _decades = {...widget.initial.decades};
  late bool _unwatched = widget.initial.unwatched;

  /// The bands ticked, and the ratings the table does not know ticked as they are
  late final Set<AudienceBand> _bands = {
    for (final rating in widget.initial.contentRatings)
      if (audienceBandOf(rating) case final AudienceBand band) band,
  };
  late final Set<String> _raw = {
    for (final rating in widget.initial.contentRatings)
      if (audienceBandOf(rating) == null) rating,
  };

  PlexSectionKey get _key => (sourceId: widget.sourceId, sectionKey: widget.sectionKey);

  /// The query of the choices made, the ratings of the library that the bands ticked hold
  PlexFilmsQuery _query(PlexFilmFilterOptions options) => PlexFilmsQuery(
    sort: _sort,
    years: _years,
    decades: _decades,
    unwatched: _unwatched,
    contentRatings: plexContentRatingsOf(options.contentRatings.map((choice) => choice.key), _bands, _raw),
  );

  void _clear() => setState(() {
    _years.clear();
    _decades.clear();
    _bands.clear();
    _raw.clear();
    _unwatched = false;
  });

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final options = ref.watch(plexFilmFilterOptionsProvider(_key));
    return Material(
      color: Colors.transparent,
      child: options.when(
        loading: () => const NetworkLoadingView(),
        error: (error, _) =>
            NetworkErrorView(error: error, onRetry: () => ref.invalidate(plexFilmFilterOptionsProvider(_key))),
        data: (options) => Column(
          children: [
            Expanded(
              child: ListView(
                key: const Key('plex_film_filters'),
                padding: const EdgeInsets.symmetric(vertical: 12),
                children: [
                  if (widget.sorts.length > 1) _Heading(t.plex_films_filter_sort),
                  for (final sort in widget.sorts.length > 1 ? widget.sorts : const <PlexFilmSort>[])
                    RadioListTile<PlexFilmSort>(
                      key: Key('plex_film_sort_${sort.name}'),
                      value: sort,
                      // ignore: deprecated_member_use
                      groupValue: _sort,
                      // ignore: deprecated_member_use
                      onChanged: (value) => setState(() => _sort = value ?? _sort),
                      title: Text(plexFilmSortLabel(t, sort)),
                      dense: true,
                    ),
                  if (options.decades.isNotEmpty || options.years.isNotEmpty) ...[
                    _Heading(t.plex_films_filter_year),
                    ..._decadeTiles(t, options),
                  ],
                  if (options.contentRatings.isNotEmpty) ...[
                    _Heading(t.plex_films_filter_audience),
                    ..._audienceTiles(t, options),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        t.plex_films_audience_note,
                        style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                  SwitchListTile(
                    key: const Key('plex_film_unwatched'),
                    value: _unwatched,
                    onChanged: (value) => setState(() => _unwatched = value),
                    title: Text(t.plex_films_filter_unwatched),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Above the navigation bar of the phone: the safe area of the sheet covers its top only
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: OverflowBar(
                  alignment: MainAxisAlignment.spaceBetween,
                  overflowAlignment: OverflowBarAlignment.end,
                  children: [
                    TextButton(key: const Key('plex_film_filters_clear'), onPressed: _clear, child: Text(t.clear)),
                    FilledButton(
                      key: const Key('plex_film_filters_apply'),
                      onPressed: () => Navigator.of(context).pop(_query(options)),
                      child: Text(t.plex_films_filter_apply),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A line per decade, newest first, ticked as a whole or opened onto its years
  List<Widget> _decadeTiles(Translations t, PlexFilmFilterOptions options) {
    final decades = <int, PlexFilterChoice?>{
      for (final decade in options.decades)
        if (int.tryParse(decade.key) case final int year) year: decade,
    };
    final yearsByDecade = <int, List<PlexFilterChoice>>{};
    for (final year in options.years) {
      final value = int.tryParse(year.key);
      if (value != null) {
        (yearsByDecade[value - value % 10] ??= []).add(year);
        decades.putIfAbsent(value - value % 10, () => null);
      }
    }
    final ordered = decades.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final decade in ordered)
        ExpansionTile(
          key: Key('plex_film_decade_$decade'),
          leading: Checkbox(
            value: _decades.contains(decade),
            onChanged: (on) => setState(() => on == true ? _decades.add(decade) : _decades.remove(decade)),
          ),
          title: Text(_withCount(t.plex_films_filter_decade(decade: '$decade'), decades[decade]?.count)),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final year in yearsByDecade[decade] ?? const <PlexFilterChoice>[])
                    if (int.tryParse(year.key) case final int value)
                      FilterChip(
                        key: Key('plex_film_year_$value'),
                        label: Text(_withCount(year.title, year.count)),
                        selected: _years.contains(value),
                        onSelected: (on) => setState(() => on ? _years.add(value) : _years.remove(value)),
                      ),
                ],
              ),
            ),
          ],
        ),
    ];
  }

  /// A line per audience band the library holds, then a line per rating the table does not know
  List<Widget> _audienceTiles(Translations t, PlexFilmFilterOptions options) {
    final counts = <AudienceBand, List<int?>>{};
    final raw = <PlexFilterChoice>[];
    for (final choice in options.contentRatings) {
      final band = audienceBandOf(choice.key);
      if (band == null) {
        raw.add(choice);
      } else {
        (counts[band] ??= []).add(choice.count);
      }
    }
    // The films of a band, when the server told the count of each of its ratings
    int? total(List<int?> values) => values.contains(null) ? null : values.fold<int>(0, (sum, value) => sum + value!);
    return [
      for (final band in AudienceBand.values)
        if (counts.containsKey(band))
          CheckboxListTile(
            key: Key('plex_film_audience_${band.name}'),
            value: _bands.contains(band),
            onChanged: (on) => setState(() => on == true ? _bands.add(band) : _bands.remove(band)),
            title: Text(_withCount(audienceBandLabel(t, band), total(counts[band]!))),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
          ),
      for (final choice in raw)
        CheckboxListTile(
          key: Key('plex_film_rating_${choice.key}'),
          value: _raw.contains(choice.key),
          onChanged: (on) => setState(() => on == true ? _raw.add(choice.key) : _raw.remove(choice.key)),
          title: Text(_withCount(choice.title, choice.count)),
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
        ),
    ];
  }

  static String _withCount(String label, int? count) => count == null ? label : '$label ($count)';
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(text, style: context.textTheme.titleSmall?.copyWith(color: context.colorScheme.primary)),
  );
}

/// The content ratings of the library ([ratings], as Plex stores them) that the bands ticked hold, with the ratings
/// ticked as they are: what contentRating= of /all takes
Set<String> plexContentRatingsOf(Iterable<String> ratings, Set<AudienceBand> bands, Set<String> raw) => {
  for (final rating in ratings)
    if (bands.contains(audienceBandOf(rating)) || raw.contains(rating)) rating,
};

/// The name of an order of the films
String plexFilmSortLabel(Translations t, PlexFilmSort sort) => switch (sort) {
  PlexFilmSort.yearNewest => t.plex_films_sort_year_newest,
  PlexFilmSort.yearOldest => t.plex_films_sort_year_oldest,
  PlexFilmSort.title => t.plex_films_sort_title,
  PlexFilmSort.recentlyAdded => t.plex_films_sort_added,
};
