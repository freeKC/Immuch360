// The app languages intl 0.20 has no date data for (Maori, Kabyle, Northern Khmer, Lombard, Swabian): the timeline's
// own date labels fall back to en_US, as upstream's headers do (e6fdb56bcd), instead of throwing an ArgumentError.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_blocks.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  final previousLocale = Intl.defaultLocale;
  // As main.dart: the date data of every locale intl has
  setUpAll(initializeDateFormatting);
  tearDown(() => Intl.defaultLocale = previousLocale);

  for (final tag in ['mi', 'kab', 'kxm', 'lmo', 'swg']) {
    test('the scrubber label and the overview month title in en_US when the app locale is $tag', () {
      Intl.defaultLocale = tag;
      final date = DateTime(2024, 10, 17);

      expect(scrubberLabelFormat(years: false).format(date), 'Oct 2024');
      expect(scrubberLabelFormat(years: true).format(date), '2024');
      expect(overviewMonthTitle(date), 'October 2024');
    });
  }

  test('a locale intl knows keeps its own names', () {
    Intl.defaultLocale = 'fr';
    expect(overviewMonthTitle(DateTime(2024, 10, 17)), 'Octobre 2024');
  });
}
