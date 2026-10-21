import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_choice_dialog.widget.dart';
import 'package:intl/intl.dart';

sealed class DateFilterInputModel {
  DateTimeRange<DateTime> asDateTimeRange();

  String asHumanReadable(BuildContext context) {
    // General implementation for arbitrary date and time ranges
    // If date range is less than 24 hours, set the end date to the end of the day
    final date = asDateTimeRange();
    if (date.end.difference(date.start).inHours < 24) {
      return DateFormat.yMMMd().format(date.start.toLocal());
    } else {
      return context.t.search_filter_date_interval(
        start: DateFormat.yMMMd().format(date.start.toLocal()),
        end: DateFormat.yMMMd().format(date.end.toLocal()),
      );
    }
  }
}

class RecentMonthRangeFilter extends DateFilterInputModel {
  final int monthDelta;
  RecentMonthRangeFilter(this.monthDelta);

  @override
  DateTimeRange<DateTime> asDateTimeRange() {
    final now = DateTime.now();
    // Note that DateTime's constructor properly handles month overflow.
    final from = DateTime(now.year, now.month - monthDelta, 1);
    return DateTimeRange<DateTime>(start: from, end: now);
  }

  @override
  String asHumanReadable(BuildContext context) {
    return context.t.last_months(count: monthDelta);
  }
}

class YearFilter extends DateFilterInputModel {
  final int year;
  YearFilter(this.year);

  @override
  DateTimeRange<DateTime> asDateTimeRange() {
    final now = DateTime.now();
    final from = DateTime(year, 1, 1);

    if (now.year == year) {
      // To not go beyond today if the user picks the current year
      return DateTimeRange<DateTime>(start: from, end: now);
    }

    final to = DateTime(year, 12, 31, 23, 59, 59);
    return DateTimeRange<DateTime>(start: from, end: to);
  }

  @override
  String asHumanReadable(BuildContext context) {
    return context.t.in_year(year: year.toString());
  }
}

class CustomDateFilter extends DateFilterInputModel {
  final DateTime start;
  final DateTime end;

  CustomDateFilter(this.start, this.end);

  factory CustomDateFilter.fromRange(DateTimeRange<DateTime> range) {
    return CustomDateFilter(range.start, range.end);
  }

  @override
  DateTimeRange<DateTime> asDateTimeRange() {
    return DateTimeRange<DateTime>(start: start, end: end);
  }
}

enum _QuickPickerType { last1Month, last3Months, last9Months, year, custom }

class QuickDatePicker extends HookWidget {
  QuickDatePicker({super.key, required this.currentInput, required this.onSelect, required this.onRequestPicker})
    : _selection = _selectionFromModel(currentInput),
      _initialYear = _initialYearFromModel(currentInput);

  final Function() onRequestPicker;
  final Function(DateFilterInputModel range) onSelect;

  final DateFilterInputModel? currentInput;
  final _QuickPickerType? _selection;
  final int _initialYear;

  // Generate a list of recent years from 2000 to the current year (including the current one)
  final List<int> _recentYears = List.generate(1 + DateTime.now().year - 2000, (index) {
    return index + 2000;
  });

  static int _initialYearFromModel(DateFilterInputModel? model) {
    return model?.asDateTimeRange().start.year ?? DateTime.now().year;
  }

  static _QuickPickerType? _selectionFromModel(DateFilterInputModel? model) {
    if (model is RecentMonthRangeFilter) {
      return switch (model.monthDelta) {
        1 => _QuickPickerType.last1Month,
        3 => _QuickPickerType.last3Months,
        9 => _QuickPickerType.last9Months,
        _ => _QuickPickerType.custom,
      };
    } else if (model is YearFilter) {
      return _QuickPickerType.year;
    } else if (model is CustomDateFilter) {
      return _QuickPickerType.custom;
    }
    return null;
  }

  Text _monthLabel(BuildContext context, int monthsFromNow) => Text(context.t.last_months(count: monthsFromNow));

  /// With a remote control: the row shows the year, and OK opens the years in a dialog. The menu of the phones keeps
  /// the focus there (it takes Up and Down, and OK does not pick an entry), so only the year shown could be picked.
  Widget _remoteYearPicker(BuildContext context) {
    Future<void> chooseYear() async {
      final year = await showTvChoiceDialog<int?>(
        context: context,
        title: context.t.year,
        choices: [for (final year in _recentYears.reversed) TvChoice(value: year, label: year.toString())],
        current: _initialYear,
      );
      if (year != null) {
        onSelect(YearFilter(year));
      }
    }

    return _singleFocusRow(
      context,
      onTap: chooseYear,
      child: RadioListTile(
        title: Text(context.t.in_year(year: _initialYear.toString())),
        secondary: const Icon(Icons.arrow_drop_down_rounded),
        value: _QuickPickerType.year,
        toggleable: true,
      ),
    );
  }

  /// A row that [onTap] handles whatever the choice: [child] neither takes the taps nor, with a remote control, the
  /// focus, so that the row is one focus stop and OK always reaches [onTap]
  Widget _singleFocusRow(BuildContext context, {required VoidCallback onTap, required Widget child}) {
    return InkWell(
      onTap: onTap,
      child: IgnorePointer(
        ignoring: true,
        child: ExcludeFocus(
          excluding: MediaQuery.navigationModeOf(context) == NavigationMode.directional,
          child: child,
        ),
      ),
    );
  }

  Widget _yearPicker(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Row(
      children: [
        Text(context.t.in_year_selector),
        const SizedBox(width: 15),
        Expanded(
          child: DropdownMenu(
            initialSelection: _initialYear,
            menuStyle: MenuStyle(maximumSize: WidgetStateProperty.all(Size(size.width, size.height * 0.5))),
            dropdownMenuEntries: _recentYears.map((e) => DropdownMenuEntry(value: e, label: e.toString())).toList(),
            onSelected: (year) {
              if (year == null) {
                return;
              }
              onSelect(YearFilter(year));
            },
          ),
        ),
      ],
    );
  }

  // We want the exact date picker to always be selectable.
  // Even if it's already toggled it should always open the full date picker, RadioListTiles don't do that by default
  // so we wrap it in a InkWell
  Widget _exactPicker(BuildContext context) {
    final hasPreviousInput = currentInput != null && currentInput is CustomDateFilter;

    return _singleFocusRow(
      context,
      onTap: onRequestPicker,
      child: RadioListTile(
        title: Text(context.t.pick_custom_range),
        subtitle: hasPreviousInput ? Text(currentInput!.asHumanReadable(context)) : null,
        secondary: hasPreviousInput ? const Icon(Icons.edit) : null,
        value: _QuickPickerType.custom,
        toggleable: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remote = MediaQuery.navigationModeOf(context) == NavigationMode.directional;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Scrollbar(
        // Depending on the screen size the last option might get cut off
        // Add a clear visual cue that there are more options when scrolling
        // When the screen size is large enough the scrollbar is hidden automatically
        trackVisibility: true,
        thumbVisibility: true,
        child: SingleChildScrollView(
          child: RadioGroup(
            onChanged: (value) {
              if (value == null) {
                return;
              }
              final _ = switch (value) {
                _QuickPickerType.custom => onRequestPicker(),
                _QuickPickerType.last1Month => onSelect(RecentMonthRangeFilter(1)),
                _QuickPickerType.last3Months => onSelect(RecentMonthRangeFilter(3)),
                _QuickPickerType.last9Months => onSelect(RecentMonthRangeFilter(9)),
                // When a year is selected the combobox triggers onSelect() on its own.
                // Here we handle the radio button being selected which can only ever be the initial year
                _QuickPickerType.year => onSelect(YearFilter(_initialYear)),
              };
            },
            groupValue: _selection,
            child: Column(
              children: [
                RadioListTile(title: _monthLabel(context, 1), value: _QuickPickerType.last1Month, toggleable: true),
                RadioListTile(title: _monthLabel(context, 3), value: _QuickPickerType.last3Months, toggleable: true),
                RadioListTile(title: _monthLabel(context, 9), value: _QuickPickerType.last9Months, toggleable: true),
                if (remote)
                  _remoteYearPicker(context)
                else
                  RadioListTile(title: _yearPicker(context), value: _QuickPickerType.year, toggleable: true),
                _exactPicker(context),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
