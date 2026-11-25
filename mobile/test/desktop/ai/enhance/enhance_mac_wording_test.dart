// The refusal of Sharpen and Rebuild details on a Mac names Natural as offered there, never as run there: Natural was
// not tried on a Mac by the project (release 52, as the README and the site say).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Mac refusal of Enhance says Natural is offered on a Mac, in every language', () {
    final folder = Directory('../i18n');
    final english = jsonDecode(File('${folder.path}/en.json').readAsStringSync()) as Map<String, dynamic>;
    expect(
      english['ai_enhance_refused_mac'],
      'Not on a Mac yet: its engine for the Mac comes in a later version. Natural is offered on a Mac.',
    );
    final locales = folder.listSync().whereType<File>().where((file) => file.path.endsWith('.json')).toList();
    expect(locales, hasLength(89));
    for (final file in locales) {
      final values = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final value = values['ai_enhance_refused_mac'];
      expect(value, isA<String>(), reason: file.path);
      expect((value as String).contains('Mac'), isTrue, reason: file.path);
      expect(value, isNot(contains('runs on a Mac')), reason: file.path);
    }
  });
}
