// The table of ONNX Runtime the app calls (lot A4a, design-final 2026-10-26 section 2.1). The session asks for API 23
// so that ONNX Runtime 1.23.2, the last release for Intel Macs, loads the same model as 1.31.0. An entry is found by
// its place in the table, and the table of API 23 is shorter than the one the bindings describe (API 31): every entry
// the code calls must sit below the size of the table of API 23. .github/desktop/ai/ort_bindings/ort_functions.json
// lists them with their place, written by generate.sh, which reads the size of the table of API 23 in the header of
// 1.23.2; this test keeps that list, the generated bindings and the code together without any library.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:path/path.dart' as p;

const _bindings = 'lib/desktop/ai/ort/ort_api_bindings.dart';
const _list = '../.github/desktop/ai/ort_bindings/ort_functions.json';

/// The entries of struct OrtApi in the bindings, in their order
List<String> _table(String bindings) {
  final struct = RegExp(
    r'^final class OrtApi extends ffi\.Struct \{\n(.*?)^\}',
    multiLine: true,
    dotAll: true,
  ).firstMatch(bindings);
  if (struct == null) {
    throw StateError('No struct OrtApi in $_bindings');
  }
  return [
    for (final field in struct.group(1)!.split(';'))
      if (field.contains('external')) RegExp(r'(\w+)\s*$').firstMatch(field.trim())!.group(1)!,
  ];
}

void main() {
  // A Windows checkout may turn the line ends into CRLF
  final table = _table(File(_bindings).readAsStringSync().replaceAll('\r\n', '\n'));
  final list = jsonDecode(File(_list).readAsStringSync()) as Map<String, dynamic>;
  final listed = {
    for (final entry in (list['functions'] as List).cast<Map<String, dynamic>>())
      entry['name'] as String: entry['rank'] as int,
  };
  final sizes = (list['tableSize'] as Map<String, dynamic>).cast<String, int>();

  test('the session asks for the API of the list, and the bindings describe the table of API 31', () {
    expect(list['apiVersion'], ortApiVersion);
    expect(sizes['api31'], table.length);
    expect(sizes['api23'], lessThan(sizes['api31']!));
  });

  test('every entry listed is at its place in the bindings, below the size of the table of API 23', () {
    expect(listed, isNotEmpty);
    for (final MapEntry(key: name, value: rank) in listed.entries) {
      expect(table.indexOf(name), rank, reason: name);
      expect(rank, lessThan(sizes['api23']!), reason: '$name is not in the table of API $ortApiVersion');
    }
  });

  test('the code calls exactly the entries listed', () {
    final entries = table.toSet();
    final called = <String>{};
    for (final file in Directory('lib/desktop/ai/ort').listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart') || p.basename(file.path) == p.basename(_bindings)) {
        continue;
      }
      for (final match in RegExp(r'\.ref\.(\w+)').allMatches(file.readAsStringSync())) {
        if (entries.contains(match.group(1))) {
          called.add(match.group(1)!);
        }
      }
    }
    expect(called, unorderedEquals(listed.keys), reason: 'run .github/desktop/ai/ort_bindings/generate.sh');
  });
}
