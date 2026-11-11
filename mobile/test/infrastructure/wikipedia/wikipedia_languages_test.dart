// The Wikipedias the film page tries for each language of the app: the table of the study (info-page-sources.md,
// section 6.3) row by row, then every locale the app ships, then the language of the Plex library.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_languages.dart';

/// The chain as text: "fr", "zh (zh-hans)"
List<String> chainOf(String locale, {String? library}) =>
    wikipediaChainFor(locale, libraryLanguage: library).map((language) => '$language').toList();

void main() {
  group('the table of section 6.3', () {
    const rows = {
      'de_CH': ['de', 'en'],
      'en_GB': ['en'],
      'gsw': ['als', 'de', 'en'],
      'swg': ['als', 'de', 'en'],
      'fil': ['tl', 'en'],
      'tl': ['tl', 'en'],
      'kmr': ['ku', 'en'],
      'kxm': ['km', 'th', 'en'],
      'mfa': ['ms', 'th', 'en'],
      'nb_NO': ['no', 'en'],
      'nn': ['nn', 'no', 'en'],
      'pt_BR': ['pt', 'en'],
      'sr_Cyrl': ['sr (sr-ec)', 'en'],
      'sr_Latn': ['sr (sr-el)', 'en'],
      'yue_Hant': ['zh-yue', 'zh (zh-hant)', 'en'],
      'zh_Hans': ['zh (zh-hans)', 'en'],
      'zh_Hant': ['zh (zh-hant)', 'en'],
      'br': ['br', 'fr', 'en'],
      'kab': ['kab', 'fr', 'en'],
      'lb': ['lb', 'de', 'en'],
      'lmo': ['lmo', 'it', 'en'],
      'ca': ['ca', 'es', 'en'],
      'eu': ['eu', 'es', 'en'],
      'gl': ['gl', 'es', 'en'],
      'be': ['be', 'ru', 'en'],
      'cv': ['cv', 'ru', 'en'],
      'kk': ['kk', 'ru', 'en'],
      'uz': ['uz', 'ru', 'en'],
      // A locale the table does not list reads the wiki of its own code
      'fr': ['fr', 'en'],
      'ja': ['ja', 'en'],
      'en': ['en'],
    };
    for (final MapEntry(key: locale, value: chain) in rows.entries) {
      test(locale, () => expect(chainOf(locale), chain));
    }
  });

  test('the variants and the site ids of the wikis whose subdomain has a dash', () {
    final cantonese = wikipediaChainFor('yue_Hant');
    expect(cantonese.first.wiki, 'zh-yue');
    expect(cantonese.first.variant, isNull);
    expect(cantonese.first.siteId, 'zh_yuewiki');
    expect(cantonese[1], const WikipediaLanguage('zh', variant: 'zh-hant'));
    expect(wikipediaChainFor('gsw').first.siteId, 'alswiki');
    expect(wikipediaChainFor('nb_NO').first.siteId, 'nowiki');
    expect(wikipediaChainFor('sr_Latn').first.apiUri, Uri.parse('https://sr.wikipedia.org/w/api.php'));
  });

  test('a tag with dashes, a region or old codes reads like the app tag', () {
    expect(chainOf('pt-BR'), ['pt', 'en']);
    expect(chainOf('zh-Hans-CN'), ['zh (zh-hans)', 'en']);
    expect(chainOf('zh-TW'), ['zh (zh-hant)', 'en']);
    expect(chainOf('zh-HK'), ['zh (zh-hant)', 'en']);
    expect(chainOf('zh-CN'), ['zh (zh-hans)', 'en']);
    expect(chainOf('zh'), ['zh', 'en']);
    expect(chainOf('sr-Latn-RS'), ['sr (sr-el)', 'en']);
    expect(chainOf('sr'), ['sr', 'en']);
    expect(chainOf('nb'), ['no', 'en']);
    expect(chainOf('iw'), ['he', 'en']);
    expect(chainOf('FR_fr'), ['fr', 'en']);
    expect(chainOf(''), ['en']);
    expect(chainOf('und'), ['en']);
  });

  test('every locale of i18n gives a chain of known form ending in English, each wiki once', () {
    final names = Directory('../i18n')
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('.json'))
        .map((name) => name.substring(0, name.length - '.json'.length))
        .toList();
    expect(names.length, greaterThanOrEqualTo(89));
    final wikiForm = RegExp(r'^[a-z]{2,3}(-[a-z]+)?$');
    for (final locale in names) {
      final chain = wikipediaChainFor(locale);
      expect(chain, isNotEmpty, reason: locale);
      expect(chain.last, WikipediaLanguage.english, reason: locale);
      expect(chain.map((language) => language.wiki).toSet().length, chain.length, reason: locale);
      for (final language in chain) {
        expect(wikiForm.hasMatch(language.wiki), isTrue, reason: '$locale gives ${language.wiki}');
      }
      // Only English starts with English
      if (!locale.startsWith('en')) {
        expect(chain.first, isNot(WikipediaLanguage.english), reason: locale);
      }
    }
  });

  test('the locales of the app read the same in Locale.toString and in a BCP 47 tag', () {
    for (final locale in locales.values) {
      expect(chainOf(locale.toLanguageTag()), chainOf(locale.toString()), reason: '$locale');
    }
    expect(chainOf(locales['Chinese Simplified (zh_CN)']!.toString()), ['zh (zh-hans)', 'en']);
    expect(chainOf(locales['Serbian Latin (sr_Latn)']!.toString()), ['sr (sr-el)', 'en']);
    expect(chainOf(locales['Norwegian Bokmål (nb_NO)']!.toString()), ['no', 'en']);
  });

  group('the language of the library', () {
    test('comes after the app language and before English', () {
      expect(chainOf('fr', library: 'de'), ['fr', 'de', 'en']);
      expect(chainOf('gsw', library: 'it'), ['als', 'de', 'it', 'en']);
      expect(chainOf('nb_NO', library: 'zh-TW'), ['no', 'zh (zh-hant)', 'en']);
    });

    test('comes once', () {
      expect(chainOf('fr', library: 'fr-FR'), ['fr', 'en']);
      expect(chainOf('fr', library: 'en-US'), ['fr', 'en']);
      expect(chainOf('en', library: 'fr'), ['en', 'fr']);
      expect(chainOf('ca', library: 'es-ES'), ['ca', 'es', 'en']);
      // The script of the app wins for a wiki met twice
      expect(chainOf('zh_Hans', library: 'zh-TW'), ['zh (zh-hans)', 'en']);
    });

    test('a library without a language adds nothing', () {
      expect(chainOf('fr', library: 'xn'), ['fr', 'en']);
      expect(chainOf('fr', library: ''), ['fr', 'en']);
      expect(chainOf('fr', library: 'not a language'), ['fr', 'en']);
    });
  });
}
