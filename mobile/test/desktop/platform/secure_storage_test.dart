import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// The Windows implementation of flutter_secure_storage comes through dependency_overrides (pubspec.yaml)
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reversible and visibly different from the plain bytes, like DPAPI's output; counts its calls
class _FakeCipher implements SecretCipher {
  static final _prefix = utf8.encode('SEALED:');

  int protects = 0;
  bool broken = false;

  @override
  Uint8List protect(Uint8List plain) {
    protects++;
    return Uint8List.fromList([..._prefix, ...plain.reversed.map((byte) => byte ^ 0x5a)]);
  }

  @override
  Uint8List unprotect(Uint8List sealed) {
    if (broken || sealed.length < _prefix.length || utf8.decode(sealed.sublist(0, _prefix.length)) != 'SEALED:') {
      throw StateError('Cannot open');
    }
    return Uint8List.fromList(sealed.sublist(_prefix.length).map((byte) => byte ^ 0x5a).toList().reversed.toList());
  }
}

void main() {
  late Directory folder;
  late _FakeCipher cipher;

  SecretFileStore newStore() => SecretFileStore(directory: () async => folder, cipher: cipher);

  File storeFile() => File('${folder.path}/${SecretFileStore.fileName}');

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('immuch360_secure_storage_test');
    cipher = _FakeCipher();
  });

  tearDown(() async {
    if (folder.existsSync()) {
      await folder.delete(recursive: true);
    }
  });

  group('SecretFileStore', () {
    test('an empty store before the first write, and no file', () async {
      final store = newStore();
      expect(await store.read('server_password'), isNull);
      expect(await store.containsKey('server_password'), isFalse);
      expect(await store.readAll(), isEmpty);
      expect(storeFile().existsSync(), isFalse);
    });

    test('keeps each value under the key the app uses', () async {
      final store = newStore();
      await store.write('network_source_password_1', 'first secret');
      await store.write('plex_token_2', 'TEST-TOKEN-0000000000');
      expect(await store.read('network_source_password_1'), 'first secret');
      expect(await store.read('plex_token_2'), 'TEST-TOKEN-0000000000');
      expect(await store.containsKey('plex_token_2'), isTrue);
      expect(await store.readAll(), {
        'network_source_password_1': 'first secret',
        'plex_token_2': 'TEST-TOKEN-0000000000',
      });
    });

    test('a later write replaces the value of its key only', () async {
      final store = newStore();
      await store.write('a', '1');
      await store.write('b', '2');
      await store.write('a', '3');
      expect(await store.readAll(), {'a': '3', 'b': '2'});
    });

    test('keys and values of any text, the empty value included', () async {
      final store = newStore();
      await store.write('clé été 360°', 'mot de passe: "é" \\ / \u{1F600}');
      await store.write('empty', '');
      final again = newStore();
      expect(await again.read('clé été 360°'), 'mot de passe: "é" \\ / \u{1F600}');
      expect(await again.read('empty'), '');
      expect(await again.containsKey('empty'), isTrue);
    });

    test('what is written is found again by a new store on the same folder', () async {
      await newStore().write('k', 'v');
      expect(await newStore().read('k'), 'v');
    });

    test('the file holds the sealed bytes only, never a key or a value in clear', () async {
      await newStore().write('server_password', 'hunter2-secret');
      final bytes = await storeFile().readAsBytes();
      final text = latin1.decode(bytes);
      expect(text.startsWith('SEALED:'), isTrue);
      expect(text.contains('hunter2-secret'), isFalse);
      expect(text.contains('server_password'), isFalse);
    });

    test('delete removes one key, and a missing key writes nothing', () async {
      final store = newStore();
      await store.write('a', '1');
      await store.write('b', '2');
      final writes = cipher.protects;
      await store.delete('missing');
      expect(cipher.protects, writes);
      await store.delete('a');
      expect(await store.readAll(), {'b': '2'});
      expect(await store.containsKey('a'), isFalse);
    });

    test('writing the same value again writes nothing', () async {
      final store = newStore();
      await store.write('a', '1');
      final writes = cipher.protects;
      await store.write('a', '1');
      expect(cipher.protects, writes);
    });

    test('deleteAll removes the file', () async {
      final store = newStore();
      await store.write('a', '1');
      await store.deleteAll();
      expect(storeFile().existsSync(), isFalse);
      expect(await store.readAll(), isEmpty);
    });

    test('leaves no temporary file behind', () async {
      await newStore().write('a', '1');
      final names = folder.listSync().map((entity) => entity.uri.pathSegments.last).toSet();
      expect(names.where((name) => name.endsWith('.tmp')), isEmpty);
    });

    test('operations asked at once all land', () async {
      final store = newStore();
      await Future.wait([for (var i = 0; i < 25; i++) store.write('key$i', 'value$i')]);
      final other = newStore();
      await Future.wait([for (var i = 25; i < 30; i++) other.write('key$i', 'value$i')]);
      final values = await newStore().readAll();
      expect(values.length, 30);
      expect(values['key7'], 'value7');
      expect(values['key27'], 'value27');
    });

    test('a file that cannot be opened is kept aside and the store starts empty', () async {
      await newStore().write('a', '1');
      cipher.broken = true;
      final store = SecretFileStore(
        directory: () async => folder,
        cipher: cipher,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1234),
      );
      expect(await store.read('a'), isNull);
      expect(File('${storeFile().path}.unreadable-1234').existsSync(), isTrue);
      cipher.broken = false;
      await store.write('b', '2');
      expect(await store.readAll(), {'b': '2'});
    });

    test('a damaged file is not taken for an empty store silently: it is kept aside', () async {
      await folder.create(recursive: true);
      await storeFile().writeAsBytes(utf8.encode('SEALED:not json'));
      final store = SecretFileStore(
        directory: () async => folder,
        cipher: cipher,
        clock: () => DateTime.fromMillisecondsSinceEpoch(99),
      );
      expect(await store.readAll(), isEmpty);
      expect(File('${storeFile().path}.unreadable-99').existsSync(), isTrue);
    });

    test('decode refuses what is not a store of this version', () {
      expect(() => SecretFileStore.decode(utf8.encode('{"version":2,"values":{}}')), throwsFormatException);
      expect(() => SecretFileStore.decode(utf8.encode('[]')), throwsFormatException);
      expect(SecretFileStore.decode(SecretFileStore.encode({'k': 'v'})), {'k': 'v'});
    });
  });

  group('FlutterSecureStorageWindows', () {
    test('serves the platform interface from the store, whatever the Windows options', () async {
      final storage = FlutterSecureStorageWindows(store: newStore());
      const options = {'useBackwardCompatibility': 'true'};
      await storage.write(key: 'k', value: 'v', options: options);
      expect(await storage.read(key: 'k', options: const {}), 'v');
      expect(await storage.containsKey(key: 'k', options: options), isTrue);
      expect(await storage.readAll(options: options), {'k': 'v'});
      await storage.delete(key: 'k', options: options);
      expect(await storage.read(key: 'k', options: options), isNull);
      await storage.write(key: 'x', value: 'y', options: options);
      await storage.deleteAll(options: options);
      expect(await storage.readAll(options: options), isEmpty);
    });
  });

  group('DpapiCipher', () {
    test('seals and opens again on Windows, and a changed byte is refused', () {
      const cipher = DpapiCipher();
      final plain = Uint8List.fromList(utf8.encode('{"version":1,"values":{"k":"v"}}'));
      final sealed = cipher.protect(plain);
      expect(sealed, isNot(plain));
      expect(cipher.unprotect(sealed), plain);
      final damaged = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 0xff;
      expect(() => cipher.unprotect(damaged), throwsStateError);
    }, skip: Platform.isWindows ? false : 'DPAPI runs on Windows only');
  });
}
