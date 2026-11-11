// The Wikipedias the film page reads, in the order it tries them: the one of the app's language, then the one of the
// language of the Plex library, then English. Several languages of the app have no Wikipedia of their own, or a small
// one, and borrow the nearest (Swabian reads the Alemannic wiki, then the German one); Chinese and Serbian have one
// wiki in two scripts, which the server converts when the request names a variant. The table is the one of the study
// of the film page (info-page-sources.md, section 6.3); a language it does not list reads the wiki of its own code.

/// One Wikipedia: [wiki] is its subdomain ("fr" for fr.wikipedia.org, "zh-yue" for the Cantonese one), [variant] the
/// script the server converts its text to ("zh-hans", "zh-hant", "sr-el", "sr-ec"), null for a wiki in one script
class WikipediaLanguage {
  const WikipediaLanguage(this.wiki, {this.variant});

  final String wiki;
  final String? variant;

  static const english = WikipediaLanguage('en');

  /// The id Wikidata gives this wiki in the sitelinks of an item: "frwiki", "zh_yuewiki"
  String get siteId => '${wiki.replaceAll('-', '_')}wiki';

  /// The Action API of this wiki
  Uri get apiUri => Uri.https('$wiki.wikipedia.org', '/w/api.php');

  @override
  bool operator ==(Object other) => other is WikipediaLanguage && other.wiki == wiki && other.variant == variant;

  @override
  int get hashCode => Object.hash(wiki, variant);

  @override
  String toString() => variant == null ? wiki : '$wiki ($variant)';
}

/// The Wikipedias to try for a film, in order: the one of [appLocale] (a tag of the app such as "fr", "pt_BR",
/// "zh_Hans", "sr_Latn", "nb_NO", with "_" or "-" between its parts) and those it borrows, then the one of
/// [libraryLanguage] (the language of a Plex section, "fr", "en-US", "zh-TW"), then English. A wiki comes once, at the
/// first place it is met.
List<WikipediaLanguage> wikipediaChainFor(String appLocale, {String? libraryLanguage}) {
  final chain = <WikipediaLanguage>[];
  final seen = <String>{};
  for (final language in [
    ..._wikipediasOf(appLocale),
    if (libraryLanguage != null) ..._wikipediasOf(libraryLanguage),
    WikipediaLanguage.english,
  ]) {
    // By wiki only: one wiki read in two scripts would cost a request for the same article
    if (seen.add(language.wiki)) {
      chain.add(language);
    }
  }
  return chain;
}

/// Codes that name no language, or none with a Wikipedia: Plex gives "xn" to a library without a language
const _noLanguage = {'und', 'zxx', 'mul', 'mis', 'xn', 'xx'};

/// Old codes that Java, and so some Android versions, still give
const _formerCodes = {'iw': 'he', 'in': 'id', 'ji': 'yi', 'jw': 'jv', 'mo': 'ro'};

/// The languages that read another wiki first, or one more after their own (section 6.3 of the study)
const _borrowed = <String, List<String>>{
  'fil': ['tl'],
  'gsw': ['als', 'de'],
  'swg': ['als', 'de'],
  'kmr': ['ku'],
  'kxm': ['km', 'th'],
  'mfa': ['ms', 'th'],
  'nb': ['no'],
  'nn': ['nn', 'no'],
  'br': ['br', 'fr'],
  'kab': ['kab', 'fr'],
  'lb': ['lb', 'de'],
  'lmo': ['lmo', 'it'],
  'ca': ['ca', 'es'],
  'eu': ['eu', 'es'],
  'gl': ['gl', 'es'],
  'be': ['be', 'ru'],
  'cv': ['cv', 'ru'],
  'kk': ['kk', 'ru'],
  'uz': ['uz', 'ru'],
};

/// Regions that write Chinese in simplified characters; the others that a tag may name write it in traditional ones
const _simplifiedChineseRegions = {'CN', 'SG', 'MY'};
const _traditionalChineseRegions = {'TW', 'HK', 'MO'};

final _languageCode = RegExp(r'^[a-z]{2,3}$');

/// The wikis of one tag, in order; none when the tag names no language
List<WikipediaLanguage> _wikipediasOf(String tag) {
  final parts = tag.trim().split(RegExp('[-_]')).where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) {
    return const [];
  }
  var language = parts.first.toLowerCase();
  language = _formerCodes[language] ?? language;
  if (!_languageCode.hasMatch(language) || _noLanguage.contains(language)) {
    return const [];
  }
  String? script;
  String? region;
  for (final part in parts.skip(1)) {
    if (part.length == 4) {
      script ??= part.toLowerCase();
    } else if (part.length == 2 || (part.length == 3 && int.tryParse(part) != null)) {
      region ??= part.toUpperCase();
    }
  }

  switch (language) {
    case 'zh':
      return [WikipediaLanguage('zh', variant: _chineseVariant(script, region))];
    case 'yue':
      // The Cantonese wiki is written in traditional characters; the Chinese one after it follows the script of the tag
      return [
        const WikipediaLanguage('zh-yue'),
        WikipediaLanguage('zh', variant: script == 'hans' ? 'zh-hans' : 'zh-hant'),
      ];
    case 'sr':
      final variant = switch (script) {
        'latn' => 'sr-el',
        'cyrl' => 'sr-ec',
        _ => null,
      };
      return [WikipediaLanguage('sr', variant: variant)];
  }
  final wikis = _borrowed[language] ?? [language];
  return [for (final wiki in wikis) WikipediaLanguage(wiki)];
}

/// The script the Chinese wiki converts to for [script] or, without one, for [region]; null leaves the text as written
String? _chineseVariant(String? script, String? region) {
  if (script == 'hans' || (script == null && _simplifiedChineseRegions.contains(region))) {
    return 'zh-hans';
  }
  if (script == 'hant' || (script == null && _traditionalChineseRegions.contains(region))) {
    return 'zh-hant';
  }
  return null;
}
