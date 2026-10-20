// The filter sheets of the search page with a remote control: the action rail of the People sheet (Right to Apply, Up
// to Clear, Left back to the row the focus came from, radio buttons included), the Media Type, Display options and
// date sheets whole on a 960 x 540 dp TV screen with their buttons in reach (the year of the date sheet in a dialog),
// and the layout of phones unchanged.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/search/quick_date_picker.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/widgets/search/search_filter/display_option_picker.dart';
import 'package:immich_mobile/widgets/search/search_filter/filter_bottom_sheet_scaffold.dart';
import 'package:immich_mobile/widgets/search/search_filter/media_type_picker.dart';
import 'package:immich_mobile/widgets/search/search_filter/search_filter_utils.dart';
import 'package:immich_mobile/widgets/search/search_filter/star_rating_picker.dart';

void main() {
  /// Opens [sheet] as the search page does, on a 1920 x 1080 px TV screen (960 x 540 dp) unless [screen] (in dp) says
  /// otherwise
  Future<void> open(
    WidgetTester tester,
    Widget sheet, {
    bool tvMode = true,
    bool isScrollControlled = true,
    Size screen = const Size(960, 540),
  }) async {
    tester.view.physicalSize = screen * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
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
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            // As main.dart does
            builder: (context, child) => TvShell(enabled: tvMode, child: child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showFilterBottomSheet(context: context, isScrollControlled: isScrollControlled, child: sheet),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The People sheet of the search page, with [content] as the list
  Widget railSheet(Widget content, {bool withApply = true}) => FractionallySizedBox(
    heightFactor: 0.8,
    child: FilterBottomSheetScaffold(
      title: 'People',
      expanded: true,
      tvActionRail: true,
      onSearch: withApply ? () {} : null,
      onClear: () {},
      child: content,
    ),
  );

  Widget people() => ListView.builder(
    itemCount: 30,
    itemBuilder: (context, i) => ListTile(title: Text('person $i'), onTap: () {}),
  );

  FocusNode focusOf(WidgetTester tester, String text) => Focus.of(tester.element(find.text(text)));

  FocusNode? focused() => FocusManager.instance.primaryFocus;

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  group('action rail on TV', () {
    testWidgets('Right from a row goes to Apply, Up to Clear, Left back to the same row', (tester) async {
      await open(tester, railSheet(people()));
      focusOf(tester, 'person 0').requestFocus();
      await tester.pumpAndSettle();
      // Down the list, past the first screen
      for (var i = 0; i < 8; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      final row = focusOf(tester, 'person 8');
      expect(focused(), row);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused()?.debugLabel, 'TV filter apply');

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focused()?.debugLabel, 'TV filter clear');

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focused(), row);
    });

    testWidgets('Right goes to Clear when the sheet has no Apply', (tester) async {
      await open(tester, railSheet(people(), withApply: false));
      focusOf(tester, 'person 2').requestFocus();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused()?.debugLabel, 'TV filter clear');
      expect(find.byKey(const Key('search_filter_apply')), findsNothing);
    });

    testWidgets('Left with no row to go back to goes to the first row on screen', (tester) async {
      await open(tester, railSheet(people()));
      Focus.of(tester.element(find.text('Apply filter'))).requestFocus();
      await tester.pumpAndSettle();
      expect(focused()?.debugLabel, 'TV filter apply');

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focused(), focusOf(tester, 'person 0'));
    });

    testWidgets('radio buttons reach the rail and come back, the choice unchanged', (tester) async {
      final picked = <AssetType>[];
      await open(tester, railSheet(MediaTypePicker(onSelect: picked.add, filter: AssetType.other)));
      final image = focusOf(tester, 'Image');
      image.requestFocus();
      await tester.pumpAndSettle();

      // TvShell moves the focus for a radio button before the sheet sees the key: a focus scope around the content
      // kept it on the choices
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused()?.debugLabel, anyOf('TV filter clear', 'TV filter apply'));

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focused(), image);
      expect(picked, isEmpty);
      expect(tester.widget<RadioGroup<AssetType>>(find.byType(RadioGroup<AssetType>)).groupValue, AssetType.other);
    });
  });

  group('Media Type and Display options sheets on a 960 x 540 dp TV', () {
    // The bottom margin of TvShell, 27 dp of overscan
    const safeBottom = 540 - 27;

    testWidgets('Media Type: whole on screen, Down from the last choice reaches Clear, then Right Apply', (
      tester,
    ) async {
      await open(
        tester,
        FilterBottomSheetScaffold(
          title: 'Select media type',
          onSearch: () {},
          onClear: () {},
          child: MediaTypePicker(onSelect: (_) {}, filter: AssetType.other),
        ),
      );
      // A RenderFlex overflow fails the test before this line otherwise
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(const Key('search_filter_apply'))).bottom, lessThanOrEqualTo(safeBottom));

      focusOf(tester, 'Video').requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), focusOf(tester, 'Clear'));
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(), focusOf(tester, 'Apply filter'));
    });

    testWidgets('Display options: whole on screen, Down from the last option reaches the buttons', (tester) async {
      await open(
        tester,
        FilterBottomSheetScaffold(
          title: 'Display options',
          onSearch: () {},
          onClear: () {},
          child: DisplayOptionPicker(onSelect: (_) {}),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(const Key('search_filter_apply'))).bottom, lessThanOrEqualTo(safeBottom));

      focusOf(tester, 'Archive').requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), anyOf(focusOf(tester, 'Clear'), focusOf(tester, 'Apply filter')));
    });
  });

  group('all filter families in a TV-sized sheet', () {
    testWidgets('Star Rating: six rows and the Apply/Clear actions remain reachable', (tester) async {
      await open(tester, railSheet(StarRatingPicker(onSelect: (_) {})));
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(const Key('search_filter_apply'))).right, lessThan(960));
      expect(tester.getRect(find.byKey(const Key('search_filter_apply'))).bottom, lessThan(513));
      expect(find.byType(RadioListTile<int>), findsNWidgets(6));
      // The last choice starts below the visible area on a 540 dp TV.
      // Scrolling it into view must not move the persistent action buttons.
      final scrollable = find.descendant(
        of: find.byType(StarRatingPicker),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scrollable, findsOneWidget);
      final initialApply = tester.getRect(find.byKey(const Key('search_filter_apply')));
      await tester.drag(scrollable, const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const Key('star_5'))).bottom, lessThanOrEqualTo(513));
      expect(tester.getRect(find.byKey(const Key('search_filter_apply'))), initialApply);
    });

    testWidgets('Location-like dropdown form fits beside the TV action rail', (tester) async {
      await open(
        tester,
        railSheet(
          const Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(decoration: InputDecoration(labelText: 'Country')),
                SizedBox(height: 16),
                TextField(decoration: InputDecoration(labelText: 'State')),
                SizedBox(height: 16),
                TextField(decoration: InputDecoration(labelText: 'City')),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(const Key('search_filter_apply'))).right, lessThan(960));
      expect(tester.getRect(find.byKey(const Key('search_filter_apply'))).bottom, lessThan(513));
    });

    testWidgets('Tag-like long lists scroll independently of their action rail', (tester) async {
      await open(tester, railSheet(people()));
      expect(tester.takeException(), isNull);
      focusOf(tester, 'person 0').requestFocus();
      await tester.pumpAndSettle();
      for (var i = 0; i < 12; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused()?.debugLabel, 'TV filter apply');
    });
  });

  group('date sheet', () {
    late List<DateFilterInputModel> selected;
    late int pickerRequests;

    setUp(() {
      selected = [];
      pickerRequests = 0;
    });

    /// The date sheet of the search page
    Widget dateSheet({DateFilterInputModel? current}) => FilterBottomSheetScaffold(
      title: 'Select a date range',
      onClear: () {},
      child: Flexible(
        child: QuickDatePicker(currentInput: current, onSelect: selected.add, onRequestPicker: () => pickerRequests++),
      ),
    );

    /// The first text of the control that has the focus: the title of a row
    String? focusedLabel() {
      final focusedElement = focused()?.context as Element?;
      String? label;
      void visit(Element element) {
        if (label != null) {
          return;
        }
        final widget = element.widget;
        if (widget is Text) {
          label = widget.data;
          return;
        }
        element.visitChildren(visit);
      }

      focusedElement?.visitChildren(visit);
      return label;
    }

    final thisYear = DateTime.now().year;
    final rows = ['Last month', 'Last 3 months', 'Last 9 months', 'In $thisYear', 'Custom range'];

    testWidgets('TV: the five choices whole on screen, one focus stop each, Down from the last reaches Clear', (
      tester,
    ) async {
      await open(tester, dateSheet());
      expect(tester.takeException(), isNull);
      for (final row in rows) {
        expect(tester.getRect(find.text(row)).bottom, lessThanOrEqualTo(540 - TvShell.overscan.bottom), reason: row);
      }
      expect(
        tester.getRect(find.widgetWithText(OutlinedButton, 'Clear')).bottom,
        lessThanOrEqualTo(540 - TvShell.overscan.bottom),
      );
      expect(find.byWidgetPredicate((widget) => widget is DropdownMenu), findsNothing);

      focusOf(tester, rows.first).requestFocus();
      await tester.pumpAndSettle();
      final visited = [focusedLabel()];
      for (var i = 1; i < rows.length; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        visited.add(focusedLabel());
      }
      expect(visited, rows);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), focusOf(tester, 'Clear'));
      expect(selected, isEmpty, reason: 'a move is no choice');
    });

    testWidgets('TV: OK on the year opens the years, the current one focused, and a year is picked', (tester) async {
      await open(tester, dateSheet(current: YearFilter(thisYear - 1)));
      expect(find.text('In ${thisYear - 1}'), findsOneWidget);
      focusOf(tester, 'Last 9 months').requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'In ${thisYear - 1}');

      await press(tester, LogicalKeyboardKey.select);
      final dialog = find.byType(SimpleDialog);
      expect(dialog, findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('Year')), findsOneWidget);
      // Newest first, down to 2000
      final years = tester
          .widgetList<ListTile>(find.descendant(of: dialog, matching: find.byType(ListTile)))
          .map((tile) => (tile.title as Text?)?.data)
          .toList();
      expect(years.first, '$thisYear');
      expect(years.last, '2000');
      expect(focusedLabel(), '${thisYear - 1}');

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);

      expect(dialog, findsNothing);
      expect(selected, hasLength(1));
      expect((selected.single as YearFilter).year, thisYear - 3);
    });

    testWidgets('TV: Back closes the years and picks nothing; OK on Custom range asks for the range', (tester) async {
      await open(tester, dateSheet());
      focusOf(tester, 'Last 9 months').requestFocus();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(SimpleDialog), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(selected, isEmpty);
      expect(focusedLabel(), 'In $thisYear');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'Custom range');
      await press(tester, LogicalKeyboardKey.select);
      expect(pickerRequests, 1);
    });

    testWidgets('phone, portrait: as high as its choices, the year menu kept', (tester) async {
      await open(tester, dateSheet(), tvMode: false, screen: const Size(390, 844));
      expect(tester.takeException(), isNull);
      for (final row in rows.where((row) => !row.startsWith('In '))) {
        expect(tester.getRect(find.text(row)).bottom, lessThanOrEqualTo(844), reason: row);
      }
      expect(find.byWidgetPredicate((widget) => widget is DropdownMenu), findsOneWidget);
      final sheetTop = tester.getRect(find.text('Select a date range')).top;
      expect(sheetTop, greaterThan(844 / 3), reason: 'not stretched to the whole screen');
    });

    testWidgets('phone, landscape: the choices scroll above the buttons', (tester) async {
      await open(tester, dateSheet(), tvMode: false, screen: const Size(844, 390));
      expect(tester.takeException(), isNull);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: find.byType(QuickDatePicker), matching: find.byType(Scrollable)).first,
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      expect(tester.getRect(find.widgetWithText(OutlinedButton, 'Clear')).bottom, lessThanOrEqualTo(390));
    });
  });

  group('phones', () {
    testWidgets('the rail is TV only: Clear and Apply stay in a row under the list', (tester) async {
      await open(tester, railSheet(people()), tvMode: false);

      final clear = tester.getRect(find.widgetWithText(OutlinedButton, 'Clear'));
      final apply = tester.getRect(find.byKey(const Key('search_filter_apply')));
      final list = tester.getRect(find.byType(ListView));
      expect(clear.top, apply.top);
      expect(clear.right, lessThan(apply.left));
      expect(clear.top, greaterThanOrEqualTo(list.bottom));
      expect(Focus.of(tester.element(find.text('Apply filter'))).debugLabel, isNot('TV filter apply'));
    });
  });
}
