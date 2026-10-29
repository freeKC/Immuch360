import 'package:flutter/material.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_choice_dialog.widget.dart';
import 'package:intl/intl.dart';

/// A remote-control alternative to Flutter's month-by-month date range calendar.
/// Start and end each have focusable Year, Month and Day controls; each opens a
/// bounded TV choice dialog. Jumping to 2010 is one selection, not 190 key presses.
Future<DateTimeRange<DateTime>?> showTvSearchDateRangePicker({
  required BuildContext context,
  required DateTimeRange<DateTime> initialDateRange,
  required DateTime firstDate,
  required DateTime lastDate,
}) => showDialog<DateTimeRange<DateTime>>(
  context: context,
  builder: (_) => _TvSearchDateRangeDialog(initial: initialDateRange, firstDate: firstDate, lastDate: lastDate),
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
    if (value.isBefore(widget.firstDate)) return widget.firstDate;
    if (value.isAfter(widget.lastDate)) return widget.lastDate;
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
      title: '${start ? 'Start' : 'End'} ${part.name}',
      choices: choices,
      current: switch (part) {
        _DatePart.year => current.year,
        _DatePart.month => current.month,
        _DatePart.day => current.day,
      },
    );
    if (selected == null || !mounted) return;
    final newYear = part == _DatePart.year ? selected : current.year;
    final newMonth = part == _DatePart.month ? selected : current.month;
    final newDay = part == _DatePart.day ? selected : current.day.clamp(1, _daysInMonth(newYear, newMonth)).toInt();
    final changed = _clamp(DateTime(newYear, newMonth, newDay));
    setState(() {
      if (start) {
        _start = changed;
      } else {
        _end = changed;
      }
    });
  }

  Widget _dateRow({required bool start}) {
    final date = start ? _start : _end;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(start ? 'Start date' : 'End date', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(DateFormat.yMMMMd().format(date)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: Key(start ? 'tv_date_start_year' : 'tv_date_end_year'),
                onPressed: () => _choose(start: start, part: _DatePart.year),
                child: Text('Year: ${date.year}'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _choose(start: start, part: _DatePart.month),
                child: Text(DateFormat.MMM().format(date)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _choose(start: start, part: _DatePart.day),
                child: Text('Day: ${date.day}'),
              ),
            ),
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Date range', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 20),
              _dateRow(start: true),
              const SizedBox(height: 24),
              _dateRow(start: false),
              if (!valid) ...[const SizedBox(height: 12), const Text('Start date must be on or before end date.')],
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    key: const Key('tv_date_range_apply'),
                    onPressed: valid ? () => Navigator.pop(context, DateTimeRange(start: _start, end: _end)) : null,
                    child: const Text('Select'),
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
