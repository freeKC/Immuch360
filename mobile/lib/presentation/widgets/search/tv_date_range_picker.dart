import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_choice_dialog.widget.dart';
import 'package:intl/intl.dart';

/// A remote-control alternative to Flutter's month-by-month date range calendar.
/// Start and end each have focusable Year, Month and Day controls; each opens a
/// bounded TV choice dialog. Jumping to 2010 is one selection, not 190 key presses.
///
/// As Flutter's [showDateRangePicker], it works on days: the time of day of the dates it is given is dropped, and the
/// range it gives back is made of days.
Future<DateTimeRange<DateTime>?> showTvSearchDateRangePicker({
  required BuildContext context,
  required DateTimeRange<DateTime> initialDateRange,
  required DateTime firstDate,
  required DateTime lastDate,
}) => showDialog<DateTimeRange<DateTime>>(
  context: context,
  builder: (_) => _TvSearchDateRangeDialog(
    initial: DateUtils.datesOnly(initialDateRange),
    firstDate: DateUtils.dateOnly(firstDate),
    lastDate: DateUtils.dateOnly(lastDate),
  ),
);

enum _DatePart { year, month, day }

class _TvSearchDateRangeDialog extends StatefulWidget {
  const _TvSearchDateRangeDialog({required this.initial, required this.firstDate, required this.lastDate});

  final DateTimeRange<DateTime> initial;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_TvSearchDateRangeDialog> createState() => _TvSearchDateRangeDialogState();
}

class _TvSearchDateRangeDialogState extends State<_TvSearchDateRangeDialog> {
  late DateTime _start;
  late DateTime _end;

  @override
  void initState() {
    super.initState();
    _start = _clamp(widget.initial.start);
    _end = _clamp(widget.initial.end);
  }

  DateTime _clamp(DateTime value) {
    if (value.isBefore(widget.firstDate)) {
      return widget.firstDate;
    }
    if (value.isAfter(widget.lastDate)) {
      return widget.lastDate;
    }
    return value;
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  Future<void> _choose({required bool start, required _DatePart part}) async {
    final current = start ? _start : _end;
    final choices = switch (part) {
      _DatePart.year => [
        for (var year = widget.lastDate.year; year >= widget.firstDate.year; year--)
          TvChoice<int>(value: year, label: year.toString()),
      ],
      _DatePart.month => [
        for (var month = 1; month <= 12; month++)
          TvChoice<int>(value: month, label: DateFormat.MMMM().format(DateTime(2020, month))),
      ],
      _DatePart.day => [
        for (var day = 1; day <= _daysInMonth(current.year, current.month); day++)
          TvChoice<int>(value: day, label: day.toString()),
      ],
    };
    final selected = await showTvChoiceDialog<int>(
      context: context,
      title: _choiceTitle(start: start, part: part),
      choices: choices,
      current: switch (part) {
        _DatePart.year => current.year,
        _DatePart.month => current.month,
        _DatePart.day => current.day,
      },
    );
    if (selected == null || !mounted) {
      return;
    }
    final newYear = part == _DatePart.year ? selected : current.year;
    final newMonth = part == _DatePart.month ? selected : current.month;
    final newDay = part == _DatePart.day ? selected : current.day.clamp(1, _daysInMonth(newYear, newMonth));
    final changed = _clamp(DateTime(newYear, newMonth, newDay));
    setState(() {
      if (start) {
        _start = changed;
      } else {
        _end = changed;
      }
    });
  }

  /// The title of the choice dialog of one part of one date, a whole text per case for the translations
  String _choiceTitle({required bool start, required _DatePart part}) => switch ((start, part)) {
    (true, _DatePart.year) => context.t.tv_date_range_start_year,
    (true, _DatePart.month) => context.t.tv_date_range_start_month,
    (true, _DatePart.day) => context.t.tv_date_range_start_day,
    (false, _DatePart.year) => context.t.tv_date_range_end_year,
    (false, _DatePart.month) => context.t.tv_date_range_end_month,
    (false, _DatePart.day) => context.t.tv_date_range_end_day,
  };

  /// A button of one part of a date: the name of the part above its value, so no sentence is built from pieces
  Widget _partButton({required bool start, required _DatePart part, required String caption, required String value}) {
    final theme = Theme.of(context).textTheme;
    return Expanded(
      child: OutlinedButton(
        key: Key('tv_date_${start ? 'start' : 'end'}_${part.name}'),
        onPressed: () => _choose(start: start, part: part),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(caption, style: theme.labelSmall),
              Text(value, style: theme.titleMedium),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateRow({required bool start}) {
    final date = start ? _start : _end;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The name of the date and the date in words on one line, so that the dialog holds on the screen of a TV
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                start ? context.t.start_date : context.t.end_date,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(width: 16),
            Text(DateFormat.yMMMMd().format(date)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _partButton(start: start, part: _DatePart.year, caption: context.t.year, value: date.year.toString()),
            const SizedBox(width: 8),
            _partButton(
              start: start,
              part: _DatePart.month,
              caption: context.t.month,
              value: DateFormat.MMM().format(date),
            ),
            const SizedBox(width: 8),
            _partButton(start: start, part: _DatePart.day, caption: context.t.day, value: date.day.toString()),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final valid = !_start.isAfter(_end);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 450, maxWidth: 680),
        // It holds on a TV screen of 540 dp, the error line shown; with a larger text it scrolls, the focus bringing
        // each button into view
        child: SingleChildScrollView(
          key: const Key('tv_date_range_body'),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.t.search_filter_date_title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 20),
              _dateRow(start: true),
              const SizedBox(height: 24),
              _dateRow(start: false),
              if (!valid) ...[
                const SizedBox(height: 12),
                Text(
                  context.t.tv_date_range_start_after_end,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(context.t.cancel)),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    key: const Key('tv_date_range_apply'),
                    onPressed: valid ? () => Navigator.pop(context, DateTimeRange(start: _start, end: _end)) : null,
                    child: Text(context.t.select),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
