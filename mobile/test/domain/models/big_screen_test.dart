import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/big_screen.dart';

void main() {
  group('BigScreenRequest', () {
    final contract =
        jsonDecode(File('test/fixtures/ai_immersive/big_screen_contract_v1.json').readAsStringSync())
            as Map<String, dynamic>;

    test('writes the JSON of the contract', () {
      expect(jsonDecode(const BigScreenRequest().toJsonString()), contract['bigScreen']);
    });

    test('reads back what it writes', () {
      expect(BigScreenRequest.fromJson(contract['bigScreen']), const BigScreenRequest());
    });

    test('reads nothing of what a reader of version 1 refuses', () {
      for (final request in contract['unknown'] as List) {
        expect(BigScreenRequest.fromJson(request), isNull, reason: jsonEncode(request));
      }
      expect(BigScreenRequest.fromJson(null), isNull);
      expect(BigScreenRequest.fromJson('bigScreen'), isNull);
    });
  });
}
