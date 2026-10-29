import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/search/tv_date_range_picker.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';

void main() {
  testWidgets('TV date range can jump to a year directly without month scrolling', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    DateTimeRange? result;
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
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              builder: (context, child) => TvShell(enabled: true, child: child!),
              home: Scaffold(
                body: Builder(
                  builder: (context) => ElevatedButton(
                    child: const Text('Open range'),
                    onPressed: () async {
                      result = await showTvSearchDateRangePicker(
                        context: context,
                        firstDate: DateTime(2023),
                        lastDate: DateTime(2026, 10, 27),
                        initialDateRange: DateTimeRange(start: DateTime(2026, 1, 15), end: DateTime(2026, 9, 10)),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open range'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_date_start_year')), findsOneWidget);

    await tester.tap(find.byKey(const Key('tv_date_start_year')));
    await tester.pumpAndSettle();
    expect(find.text('Start year'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '2024'));
    await tester.pumpAndSettle();
    expect(find.text('Year: 2024'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tv_date_range_apply')));
    await tester.pumpAndSettle();
    expect(result?.start.year, 2024);
    expect(result?.end.year, 2026);
  });
}
