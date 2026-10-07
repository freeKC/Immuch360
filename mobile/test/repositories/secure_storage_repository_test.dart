// The secrets of a Plex server and of a camera stay on this device: on iOS they are written with an accessibility that
// keeps them out of iCloud and of the device to device backups, and deleted with the same one, since the plugin looks
// for an item by its accessibility. The other secrets are written and deleted as before.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late _MockFlutterSecureStorage storage;
  late SecureStorageRepository repository;

  setUpAll(() {
    registerFallbackValue(IOSOptions.defaultOptions);
  });

  setUp(() {
    storage = _MockFlutterSecureStorage();
    repository = SecureStorageRepository(storage);
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
        iOptions: any(named: 'iOptions'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => storage.delete(
        key: any(named: 'key'),
        iOptions: any(named: 'iOptions'),
      ),
    ).thenAnswer((_) async {});
  });

  IOSOptions? iOptionsOfWrite() =>
      verify(
            () => storage.write(
              key: any(named: 'key'),
              value: any(named: 'value'),
              iOptions: captureAny(named: 'iOptions'),
            ),
          ).captured.single
          as IOSOptions?;

  IOSOptions? iOptionsOfDelete() =>
      verify(
            () => storage.delete(
              key: any(named: 'key'),
              iOptions: captureAny(named: 'iOptions'),
            ),
          ).captured.single
          as IOSOptions?;

  test('a device only secret is written and deleted after first unlock, this device only', () async {
    await repository.write('network_source_password_0123456789abcdef', 'TEST-TOKEN-0000000000', deviceOnly: true);
    final written = iOptionsOfWrite();
    expect(written?.toMap()['accessibility'], 'first_unlock_this_device');

    await repository.delete('network_source_password_0123456789abcdef', deviceOnly: true);
    final deleted = iOptionsOfDelete();
    expect(deleted?.toMap()['accessibility'], 'first_unlock_this_device');
    expect(deleted?.toMap(), written?.toMap(), reason: 'the delete finds the item by the same accessibility');
  });

  test('the other secrets are written and deleted with the options of the storage, as before', () async {
    await repository.write('network_source_password_smb', 's3cret');
    expect(iOptionsOfWrite(), isNull);

    await repository.delete('network_source_password_smb');
    expect(iOptionsOfDelete(), isNull);
  });
}
