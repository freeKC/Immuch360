// The Location and Camera filter sheets with a remote control: each field is one focus stop that the arrows go
// through, OK opens its choices in a dialog that holds the focus, a choice fills the field as the menu does, Back
// changes nothing; phones keep the menu. Location has the action rail of the other sheets; Camera keeps its buttons
// under Make and Model, which sit side by side on a TV.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/search/search_filter.provider.dart';
import 'package:immich_mobile/widgets/search/search_filter/camera_picker.dart';
import 'package:immich_mobile/widgets/search/search_filter/filter_bottom_sheet_scaffold.dart';
import 'package:immich_mobile/widgets/search/search_filter/location_picker.dart';
import 'package:immich_mobile/widgets/search/search_filter/search_filter_utils.dart';
import 'package:openapi/api.dart';

void main() {
  late List<Map<String, String?>> picked;
  late List<String> countries;

  setUp(() {
    picked = [];
    countries = ['France', 'Japan'];
  });

  /// The suggestions of the server: the places and cameras of a small library
  List<String> suggestions(SearchSuggestionArgs args) => switch (args.type) {
    SearchSuggestionType.country => countries,
    SearchSuggestionType.state => switch (args.locationCountry) {
      'France' => ['Bretagne', 'Provence'],
      'Japan' => ['Tokyo'],
      _ => ['Bretagne', 'Provence', 'Tokyo'],
    },
    SearchSuggestionType.city => switch (args.locationState) {
      'Bretagne' => ['Brest', 'Rennes'],
      'Tokyo' => ['Shibuya'],
      _ => ['Brest', 'Rennes', 'Shibuya'],
    },
    SearchSuggestionType.cameraMake => ['Canon', 'Nikon'],
    SearchSuggestionType.cameraModel => args.make == 'Nikon' ? ['Z 6', 'Z 8'] : ['EOS R5'],
    _ => [],
  };

  /// Opens [sheet] as the search page does, on a 1920 x 1080 px TV screen (960 x 540 dp)
  Future<void> open(WidgetTester tester, Widget sheet, {bool tvMode = true}) async {
    tester.view.physicalSize = const Size(1920, 1080);
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
        child: ProviderScope(
          overrides: [getSearchSuggestionsProvider.overrideWith((ref, args) async => suggestions(args))],
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
                    onPressed: () => showFilterBottomSheet(context: context, isScrollControlled: true, child: sheet),
                    child: const Text('open'),
                  ),
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

  /// The Location sheet of the search page
  Widget locationSheet({SearchLocationFilter? filter}) => FilterBottomSheetScaffold(
    title: 'Location',
    tvActionRail: true,
    onSearch: () {},
    onClear: () {},
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: LocationPicker(onSelected: picked.add, filter: filter),
    ),
  );

  /// The Camera sheet of the search page, without the action rail, which would take Right and Down from Make and leave
  /// Model out of reach
  Widget cameraSheet() => FilterBottomSheetScaffold(
    title: 'Camera',
    onSearch: () {},
    onClear: () {},
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: CameraPicker(onSelect: picked.add),
    ),
  );

  final dropdownMenus = find.byWidgetPredicate((widget) => widget is DropdownMenu);

  Finder field(String label) => find.ancestor(of: find.text(label), matching: find.byType(InputDecorator)).first;

  /// The focus node of the field labelled [label]
  FocusNode fieldFocus(WidgetTester tester, String label) => Focus.of(tester.element(field(label)));

  /// The text shown in the field labelled [label]
  String? fieldText(WidgetTester tester, String label) {
    final decorator = tester.widget<InputDecorator>(field(label));
    return (decorator.child as Text?)?.data;
  }

  FocusNode? focused() => FocusManager.instance.primaryFocus;

  bool focusedIn(Finder finder) {
    final context = focused()?.context;
    if (context == null) {
      return false;
    }
    return finder.evaluate().any((element) {
      var found = element == context;
      if (!found) {
        context.visitAncestorElements((ancestor) {
          found = ancestor == element;
          return !found;
        });
      }
      return found;
    });
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> focusField(WidgetTester tester, String label) async {
    fieldFocus(tester, label).requestFocus();
    await tester.pumpAndSettle();
  }

  group('Location sheet on TV', () {
    testWidgets('Down goes from Country to State to City; Right reaches the rail, Left comes back; Up too', (
      tester,
    ) async {
      await open(tester, locationSheet());
      expect(dropdownMenus, findsNothing);
      await focusField(tester, 'Country');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), fieldFocus(tester, 'State'));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), fieldFocus(tester, 'City'));

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused()?.debugLabel, 'TV filter apply');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focused()?.debugLabel, 'TV filter clear');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focused(), fieldFocus(tester, 'City'));
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(), fieldFocus(tester, 'Country'));
    });

    testWidgets('OK opens the countries with the current one focused; a choice fills the field', (tester) async {
      await open(
        tester,
        locationSheet(
          filter: const SearchLocationFilter(country: 'Japan', state: 'Tokyo', city: 'Shibuya'),
        ),
      );
      expect(fieldText(tester, 'Country'), 'Japan');
      await focusField(tester, 'Country');

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.descendant(of: find.byType(SimpleDialog), matching: find.text('Country')), findsOneWidget);
      expect(focusedIn(find.widgetWithText(ListTile, 'Japan')), isTrue);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Japan')).selected, isTrue);

      // The arrows stay in the dialog
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(find.widgetWithText(ListTile, 'France')), isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(find.byType(SimpleDialog)), isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(find.widgetWithText(ListTile, 'France')), isTrue);

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(SimpleDialog), findsNothing);
      expect(fieldText(tester, 'Country'), 'France');
      expect(fieldText(tester, 'State'), '');
      expect(fieldText(tester, 'City'), '');
      expect(picked, [
        {'country': 'France', 'state': null, 'city': null},
      ]);
      expect(focused(), fieldFocus(tester, 'Country'), reason: 'the focus comes back to the field');

      // The states of the new country
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.widgetWithText(ListTile, 'Bretagne'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Tokyo'), findsNothing);
      expect(focusedIn(find.widgetWithText(ListTile, 'Bretagne')), isTrue, reason: 'no current state: the first');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(fieldText(tester, 'State'), 'Provence');
      expect(picked.last, {'country': 'France', 'state': 'Provence', 'city': null});
    });

    testWidgets('Back closes the dialog only and changes nothing', (tester) async {
      await open(tester, locationSheet(filter: const SearchLocationFilter(country: 'Japan')));
      await focusField(tester, 'Country');
      await press(tester, LogicalKeyboardKey.select);
      await press(tester, LogicalKeyboardKey.arrowUp);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.text('Location'), findsOneWidget, reason: 'the sheet is still open');
      expect(fieldText(tester, 'Country'), 'Japan');
      expect(picked, isEmpty);
      expect(focused(), fieldFocus(tester, 'Country'));
    });

    testWidgets('with no choices the field says so, OK opens nothing and Down goes on', (tester) async {
      countries = [];
      await open(tester, locationSheet());
      expect(find.descendant(of: field('Country'), matching: find.text('No results')), findsOneWidget);
      await focusField(tester, 'Country');
      expect(focused(), fieldFocus(tester, 'Country'));

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(Dialog), findsNothing);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), fieldFocus(tester, 'State'));
    });

    testWidgets('fits the 960 x 540 dp screen with its buttons above the overscan margin', (tester) async {
      await open(tester, locationSheet());
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const Key('search_filter_apply'))).bottom,
        lessThanOrEqualTo(540 - TvShell.overscan.bottom),
      );
    });
  });

  group('Camera sheet on TV', () {
    testWidgets('Right goes from Make to Model; the models follow the make', (tester) async {
      await open(tester, cameraSheet());
      await focusField(tester, 'Make');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(), fieldFocus(tester, 'Model'));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focused(), fieldFocus(tester, 'Make'));

      await press(tester, LogicalKeyboardKey.select);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(fieldText(tester, 'Make'), 'Nikon');
      expect(picked, [
        {'make': 'Nikon', 'model': null},
      ]);

      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.widgetWithText(ListTile, 'Z 8'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'EOS R5'), findsNothing);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(fieldText(tester, 'Model'), 'Z 8');
      expect(picked.last, {'make': 'Nikon', 'model': 'Z 8'});
    });
  });

  group('Camera sheet on TV, no rail', () {
    testWidgets('Down from Make reaches the buttons under the fields, Right goes on to Apply', (tester) async {
      await open(tester, cameraSheet());
      await focusField(tester, 'Make');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(find.byType(OutlinedButton)) || focusedIn(find.byType(ElevatedButton)), isTrue);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedIn(find.byKey(const Key('search_filter_apply'))), isTrue);
    });
  });

  group('phones', () {
    testWidgets('keep the menus', (tester) async {
      await open(tester, locationSheet(), tvMode: false);
      expect(dropdownMenus, findsNWidgets(3));
    });
  });
}
