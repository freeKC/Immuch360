import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart' as easy;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';

void main() {
  final previousLocale = Intl.defaultLocale;

  setUp(() {
    Localization.load(
      const Locale('en'),
      translations: easy.Translations({
        'phone_share_clients': '{count, plural, one {# device connected} other {# devices connected}}',
        'phone_share_subtitle_on': 'On: {address}',
      }),
    );
  });

  tearDown(() => Intl.defaultLocale = previousLocale);

  // main.dart sets the language tag of the chosen locale, and intl has no number data for some of the selectable ones
  // (Kabyle, Northern Khmer, Lombard, Maori, Swabian, Cantonese): the strings with arguments must still be formatted
  for (final tag in ['kab', 'kxm', 'lmo', 'mi', 'swg', 'yue-Hant']) {
    test('formats a plural and a placeholder when the app locale is $tag', () {
      Intl.defaultLocale = tag;

      expect(StaticTranslations.instance.phone_share_clients(count: 1), '1 device connected');
      expect(StaticTranslations.instance.phone_share_clients(count: 3), '3 devices connected');
      expect(
        StaticTranslations.instance.phone_share_subtitle_on(address: 'http://192.168.1.20:8360'),
        'On: http://192.168.1.20:8360',
      );
    });
  }

  test('keeps the number data of a locale intl knows', () {
    Intl.defaultLocale = 'de';

    expect(StaticTranslations.instance.phone_share_clients(count: 1200), '1.200 devices connected');
  });
}
