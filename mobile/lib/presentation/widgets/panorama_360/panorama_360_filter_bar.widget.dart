import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';

/// The filters above the grid of the 360° page: the period, where the media are (with a server), photos or videos,
/// 3D and VR180, then the cameras when there are two or more. Within a row the chips add up, between rows they narrow
/// down (see [Panorama360Filter]).
class Panorama360FilterBar extends ConsumerWidget {
  const Panorama360FilterBar({super.key});

  /// Height of the bar with its two rows of chips, for the scrubber
  static const estimatedHeight = 112.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(panorama360FilterProvider);
    final notifier = ref.read(panorama360FilterProvider.notifier);
    final hasServer = ref.watch(hasServerProvider);
    final view = ref.watch(panorama360ViewProvider).valueOrNull;
    final facets = view?.facets ?? const Panorama360Facets();
    final t = context.t;
    final period = filter.period;

    Widget sourceChip(Panorama360Source source, String label) => FilterChip(
      label: Text(label),
      selected: filter.sources.contains(source),
      onSelected: (_) => notifier.toggleSource(source),
    );

    final showCameras = facets.cameras.length >= 2 || filter.cameras.isNotEmpty;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _ChipRow(
              children: [
                InputChip(
                  avatar: const Icon(Icons.calendar_month_outlined),
                  label: Text(period == null ? t.search_filter_date : _periodLabel(context, period)),
                  selected: period != null,
                  showCheckmark: false,
                  onPressed: () => unawaited(_showPeriodSheet(context, ref, facets, period)),
                  onDeleted: period == null ? null : () => notifier.setPeriod(null),
                ),
                if (hasServer) ...[
                  sourceChip(Panorama360Source.server, t.library_360_on_server),
                  sourceChip(Panorama360Source.device, t.on_this_device),
                  if (facets.availableSources.contains(Panorama360Source.shared) ||
                      filter.sources.contains(Panorama360Source.shared))
                    sourceChip(Panorama360Source.shared, t.shared_with_me),
                ],
                FilterChip(
                  label: Text(t.photos),
                  selected: filter.kinds.contains(Panorama360Kind.photo),
                  onSelected: (_) => notifier.toggleKind(Panorama360Kind.photo),
                ),
                FilterChip(
                  label: Text(t.videos),
                  selected: filter.kinds.contains(Panorama360Kind.video),
                  onSelected: (_) => notifier.toggleKind(Panorama360Kind.video),
                ),
                FilterChip(
                  label: Text(t.library_360_filter_3d),
                  selected: filter.traits.contains(Panorama360Trait.stereo3d),
                  onSelected: (_) => notifier.toggleTrait(Panorama360Trait.stereo3d),
                ),
                FilterChip(
                  label: Text(t.library_360_filter_vr180),
                  selected: filter.traits.contains(Panorama360Trait.vr180),
                  onSelected: (_) => notifier.toggleTrait(Panorama360Trait.vr180),
                ),
                if (!filter.isDefault) ActionChip(label: Text(t.clear), onPressed: notifier.clear),
              ],
            ),
            if (showCameras)
              _ChipRow(
                children: [
                  for (final camera in facets.cameras)
                    FilterChip(
                      label: Text(
                        '${camera.key.isEmpty ? t.library_360_unknown_camera : camera.label} (${camera.count})',
                      ),
                      selected: filter.cameras.contains(camera.key),
                      onSelected: (_) => notifier.toggleCamera(camera.key),
                    ),
                ],
              ),
            if (view != null && view.entries.isEmpty && facets.total > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Text(
                  t.library_360_no_match,
                  style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A row of chips that scrolls sideways when they do not fit
class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(spacing: 8, children: children),
      ),
    );
  }
}

String _locale(BuildContext context) => context.locale.toLanguageTag();

String _monthLabel(BuildContext context, int year, int month) =>
    DateFormat.yMMMM(_locale(context)).format(DateTime(year, month));

String _periodLabel(BuildContext context, Panorama360Period period) => switch (period) {
  Panorama360Year(:final year) => '$year',
  Panorama360Month(:final year, :final month) => _monthLabel(context, year, month),
  Panorama360Range(:final first, :final last) => context.t.search_filter_date_interval(
    start: DateFormat.yMMMd(_locale(context)).format(first),
    end: DateFormat.yMMMd(_locale(context)).format(last),
  ),
};

/// The period sheet: all, a year or one of its months with their counts (newest first), or a range of days
Future<void> _showPeriodSheet(
  BuildContext context,
  WidgetRef ref,
  Panorama360Facets facets,
  Panorama360Period? current,
) async {
  final notifier = ref.read(panorama360FilterProvider.notifier);
  final t = context.t;
  final firstDay = facets.firstDay;
  final lastDay = facets.lastDay;
  // Set once the user asked for a range: the picker opens once the sheet is gone
  var pickRange = false;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      void choose(Panorama360Period? period) {
        notifier.setPeriod(period);
        Navigator.of(sheetContext).pop();
      }

      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(t.all), selected: current == null, onTap: () => choose(null)),
            for (final MapEntry(key: year, value: months) in facets.months.entries)
              ExpansionTile(
                title: Text('$year'),
                trailing: Text('${months.values.fold(0, (total, count) => total + count)}'),
                initiallyExpanded: switch (current) {
                  Panorama360Year(year: final selected) || Panorama360Month(year: final selected) => selected == year,
                  _ => false,
                },
                children: [
                  ListTile(
                    title: Text(t.library_360_whole_year),
                    trailing: Text('${months.values.fold(0, (total, count) => total + count)}'),
                    selected: current == Panorama360Year(year),
                    onTap: () => choose(Panorama360Year(year)),
                  ),
                  for (final MapEntry(key: month, value: count) in months.entries)
                    ListTile(
                      title: Text(_monthLabel(sheetContext, year, month)),
                      trailing: Text('$count'),
                      selected: current == Panorama360Month(year, month),
                      onTap: () => choose(Panorama360Month(year, month)),
                    ),
                ],
              ),
            if (firstDay != null && lastDay != null)
              ListTile(
                title: Text(t.search_filter_date_custom),
                selected: current is Panorama360Range,
                onTap: () {
                  pickRange = true;
                  Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      );
    },
  );

  if (!pickRange || firstDay == null || lastDay == null || !context.mounted) {
    return;
  }
  // The picker refuses an initial range outside its bounds: a range picked before the list changed is dropped there
  final initialRange =
      current is Panorama360Range && !current.first.isBefore(firstDay) && !current.last.isAfter(lastDay)
      ? DateTimeRange(start: current.first, end: current.last)
      : null;
  final range = await showDateRangePicker(
    context: context,
    firstDate: firstDay,
    lastDate: lastDay,
    initialDateRange: initialRange,
  );
  if (range != null) {
    notifier.setPeriod(Panorama360Range(range.start, range.end));
  }
}
