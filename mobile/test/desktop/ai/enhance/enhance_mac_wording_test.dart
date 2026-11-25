// The refusal of Sharpen and Rebuild details on an Intel Mac (release 53: they run on Apple chips through the Metal
// build of stable-diffusion.cpp). Its old text ("Not on a Mac yet... Natural is offered on a Mac") was dropped from the
// 88 translations, which say it again at the next release; until then they show the English. No language may say a
// level "runs on a Mac": nothing was tried on a Mac yet.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Mac texts of Enhance never say a level was tried on a Mac, in every language', () {
    final folder = Directory('../i18n');
    final english = jsonDecode(File('${folder.path}/en.json').readAsStringSync()) as Map<String, dynamic>;
    expect(english['ai_enhance_refused_mac'], 'Needs a Mac with an Apple chip (M1 or later).');
    expect(english['ai_enhance_mac_untried'], startsWith('Not tried on a Mac yet'));
    final locales = folder.listSync().whereType<File>().where((file) => file.path.endsWith('.json')).toList();
    expect(locales, hasLength(89));
    for (final file in locales) {
      final values = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final key in ['ai_enhance_refused_mac', 'ai_enhance_refused_mac_graphics', 'ai_enhance_mac_untried']) {
        final value = values[key];
        if (value == null) {
          continue;
        }
        expect(value, isA<String>(), reason: '${file.path} $key');
        expect(value, isNot(contains('runs on a Mac')), reason: '${file.path} $key');
        if (!file.path.endsWith('en.json')) {
          // Translated after this text: the old one never comes back
          expect(value, isNot(contains('later version')), reason: '${file.path} $key');
        }
      }
    }
  });
}
