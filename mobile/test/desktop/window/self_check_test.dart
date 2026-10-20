// The self check of a CI runner (self_check.dart): the secret round trip says what failed and where, and the app is
// left as it is when the variable is not set.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/window/self_check.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late _MockFlutterSecureStorage storage;
  late Map<String, String> saved;

  setUp(() {
    storage = _MockFlutterSecureStorage();
    saved = {};
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((call) async {
      saved[call.namedArguments[#key] as String] = call.namedArguments[#value] as String;
    });
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((call) async => saved[call.namedArguments[#key] as String]);
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((call) async {
      saved.remove(call.namedArguments[#key] as String);
    });
  });

  test('a secret written, read back and deleted: ok, and nothing left', () async {
    final result = await secretRoundTrip(SecureStorageRepository(storage));
    expect(result, {'ok': true, 'readBack': true, 'deleted': true});
    expect(saved, isEmpty);
    final key = verify(
      () => storage.write(
        key: captureAny(named: 'key'),
        value: any(named: 'value'),
      ),
    ).captured.single;
    expect(key, startsWith('immuch360_self_check_'));
  });

  test('a keychain that refuses the write: the step and the error of the plugin', () async {
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenThrow(PlatformException(code: 'Unexpected security result code', message: 'Code: -34018'));
    final result = await secretRoundTrip(SecureStorageRepository(storage));
    expect(result['ok'], isFalse);
    expect(result['failedAt'], 'write');
    expect(result['error'], contains('-34018'));
  });

  test('a value read back that is not the one written is not ok', () async {
    when(() => storage.read(key: any(named: 'key'))).thenAnswer((_) async => 'another value');
    final result = await secretRoundTrip(SecureStorageRepository(storage));
    expect(result['ok'], isFalse);
    expect(result['readBack'], isFalse);
  });

  test('without its variable the app is wrapped in nothing', () {
    expect(DesktopSelfCheck.reportPath, isNull, reason: 'IMMUCH360_SELF_CHECK is set where the tests run');
    const app = SizedBox();
    expect(identical(DesktopSelfCheck.wrap(app), app), isTrue);
  });
}
