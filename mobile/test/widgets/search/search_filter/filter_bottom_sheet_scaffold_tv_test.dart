// The filter sheets of the search page with a remote control: the action rail of the People sheet (Right to Apply, Up
// to Clear, Left back to the row the focus came from, radio buttons included), and the layout of phones unchanged.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/widgets/search/search_filter/filter_bottom_sheet_scaffold.dart';
import 'package:immich_mobile/widgets/search/search_filter/media_type_picker.dart';
import 'package:immich_mobile/widgets/search/search_filter/search_filter_utils.dart';

void main() {
  /// Opens [sheet] as the search page does, on a 1920 x 1080 px TV screen (960 x 540 dp)
  Future<void> open(WidgetTester tester, Widget sheet, {bool tvMode = true, bool isScrollControlled = true}) async {
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
