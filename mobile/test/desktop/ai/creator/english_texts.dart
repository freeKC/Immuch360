// The English texts of i18n/en.json loaded for a test without a widget, so that StaticTranslations gives the
// sentences the user reads

import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart' as easy;
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// Loads i18n/en.json, next to the mobile folder the tests run in
void loadEnglishTexts() {
  final texts = jsonDecode(File(p.join('..', 'i18n', 'en.json')).readAsStringSync()) as Map<String, dynamic>;
  Localization.load(const Locale('en'), translations: easy.Translations(texts));
}
