import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/domain/services/settings_file/settings_file_crypto.dart';

const _origin = SettingsFileOrigin(appVersion: '3.4.1', build: '3030044', platform: 'android');

final _created = DateTime.utc(2026, 11, 11, 23, 30);

/// A small derivation for the tests that do not check the parameters: the round trips stay fast
final _fastKdf = SettingsFileKdf(salt: List.filled(16, 7), memoryKiB: 64, iterations: 1);

const _content = SettingsFileContent(
  server: SettingsFileServer(
    url: 'https://alice:pw@photos.example.org',
    endpoint: 'https://photos.example.org/api',
    accessToken: 'session-token',
  ),
  settings: {
    'themeMode': 'dark',
    'viewerVideoSource': null,
    'networkCustomHeaders': '{"X-Proxy-Token":"secret"}',
    'networkLocalEndpoint': 'http://bob:pw@192.168.1.5:2283',
    'networkExternalEndpointList': '["https://carol:pw@photos.example.org","https://other.example.org"]',
  },
  store: {'djiObstacleFarCm': 250, 'playFromPhoneAsk': true},
  sources: [
    {'id': '0011223344556677', 'type': 'smb', 'name': 'NAS', 'host': '192.168.1.10', 'share': 'photo'},
  ],
  sourceSecrets: {'0011223344556677': SettingsFileSourceSecrets(password: 'smb-pass')},
  backupAlbums: [SettingsFileBackupAlbum(id: '-1739773001', name: 'Camera', choice: SettingsFileAlbumChoice.selected)],
  pairing: {'pairedScreens': '[]'},
);

void main() {
  group('settings level', () {
    test('round trip keeps every section', () {
      final file = SettingsFile(
        origin: _origin,
        createdAt: _created,
        level: SettingsFileLevel.settings,
        content: _content,
      );
      final read = SettingsFile.parse(file.encode());
      expect(read.level, SettingsFileLevel.settings);
      expect(read.isEncrypted, isFalse);
      expect(read.createdAt, _created);
      expect(read.origin.appVersion, '3.4.1');
      expect(read.origin.platform, 'android');
      expect(jsonEncode(read.content!.toJson()), jsonEncode(_content.toJson()));
    });

    test('withoutSecrets leaves no token, password, proxy header, pairing or user in an address', () {
      final clear = _content.withoutSecrets();
      expect(clear.hasSecrets, isFalse);
      expect(clear.server!.accessToken, isNull);
      expect(clear.server!.url, 'https://photos.example.org');
      expect(clear.sourceSecrets, isEmpty);
      expect(clear.pairing, isEmpty);
      expect(clear.settings.containsKey('networkCustomHeaders'), isFalse);
      expect(clear.settings['networkLocalEndpoint'], 'http://192.168.1.5:2283');
      expect(jsonDecode(clear.settings['networkExternalEndpointList']!), [
        'https://photos.example.org',
        'https://other.example.org',
      ]);
      final text = SettingsFile(
        origin: _origin,
        createdAt: _created,
        level: SettingsFileLevel.settings,
        content: clear,
      ).encode();
      for (final secret in ['session-token', 'smb-pass', 'secret', ':pw@']) {
        expect(text.contains(secret), isFalse, reason: secret);
      }
      // What is not secret stays
      expect(clear.sources, hasLength(1));
      expect(clear.backupAlbums, hasLength(1));
      expect(clear.settings['themeMode'], 'dark');
    });

    test('the file names the day', () {
      expect(SettingsFile.fileName(DateTime(2026, 1, 5)), 'immuch360-settings-2026-01-05.json');
    });
  });

  group('accounts level', () {
    test('encryption round trip', () async {
      final sealed = await sealSettingsFile(
        content: _content,
        passphrase: 'correct horse',
        origin: _origin,
        createdAt: _created,
        kdf: _fastKdf,
      );
      final text = sealed.encode();
      expect(text.contains('session-token'), isFalse);
      expect(text.contains('smb-pass'), isFalse);
      expect(text.contains('NAS'), isFalse, reason: 'the whole content is encrypted, names included');
      final read = SettingsFile.parse(text);
      expect(read.isEncrypted, isTrue);
      final content = await openSettingsFile(read, passphrase: 'correct horse');
      expect(jsonEncode(content.toJson()), jsonEncode(_content.toJson()));
    });

    test('a wrong passphrase is told as such', () async {
      final sealed = await sealSettingsFile(
        content: _content,
        passphrase: 'correct horse',
        origin: _origin,
        createdAt: _created,
        kdf: _fastKdf,
      );
      final read = SettingsFile.parse(sealed.encode());
      await expectLater(
        openSettingsFile(read, passphrase: 'correct horsE'),
        throwsA(isA<SettingsFileException>().having((e) => e.error, 'error', SettingsFileError.wrongPassphrase)),
      );
      await expectLater(
        openSettingsFile(read),
        throwsA(isA<SettingsFileException>().having((e) => e.error, 'error', SettingsFileError.wrongPassphrase)),
      );
    });

    test('a changed header fails like a wrong passphrase', () async {
      final sealed = await sealSettingsFile(
        content: _content,
        passphrase: 'correct horse',
        origin: _origin,
        createdAt: _created,
        kdf: _fastKdf,
      );
      final json = jsonDecode(sealed.encode()) as Map<String, Object?>;
      json['createdAt'] = '2026-11-12T00:00:00.000Z';
      final read = SettingsFile.parse(jsonEncode(json));
      await expectLater(
        openSettingsFile(read, passphrase: 'correct horse'),
        throwsA(isA<SettingsFileException>().having((e) => e.error, 'error', SettingsFileError.wrongPassphrase)),
      );
    });

    test('the default derivation is Argon2id with the OWASP parameters and a random salt and nonce', () async {
      final a = await sealSettingsFile(
        content: _content,
        passphrase: 'pass phrase',
        origin: _origin,
        createdAt: _created,
      );
      final b = await sealSettingsFile(
        content: _content,
        passphrase: 'pass phrase',
        origin: _origin,
        createdAt: _created,
      );
      final kdf = a.sealed!.kdf;
      expect(kdf.memoryKiB, 19456);
      expect(kdf.iterations, 2);
      expect(kdf.parallelism, 1);
      expect(kdf.salt, hasLength(16));
      expect(a.sealed!.nonce, hasLength(12));
      expect(a.sealed!.kdf.salt, isNot(b.sealed!.kdf.salt));
      expect(a.sealed!.nonce, isNot(b.sealed!.nonce));
      final content = await openSettingsFile(SettingsFile.parse(a.encode()), passphrase: 'pass phrase');
      expect(content.server!.accessToken, 'session-token');
    });

    test('opens a file encrypted by another implementation (argon2-cffi and cryptography in Python)', () async {
      final text = File('test/fixtures/settings_file/accounts_from_python.json').readAsStringSync();
      final file = SettingsFile.parse(text);
      // The key argon2-cffi derived, checked first so that a failure tells which half differs
      final key = deriveSettingsFileKeySync(
        'café passphrase',
        Uint8List.fromList(List.generate(16, (i) => i)),
        19456,
        2,
        1,
      );
      expect(
        key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '90c56556d952ae06abc81ceb738f6a3a3bef328a790a90d323d87e42267a5e87',
      );
      final content = await openSettingsFile(file, passphrase: 'café passphrase');
      expect(content.server!.accessToken, 'token-from-python');
      expect(content.sourceSecrets['0011223344556677']!.password, 'smb-pass');
      expect(content.settings['themeMode'], 'dark');
      expect(content.backupAlbums.single.name, 'Camera');
    });

    test('a file asking for a derivation beyond the bounds is refused before any work', () {
      final json = jsonDecode(File('test/fixtures/settings_file/accounts_from_python.json').readAsStringSync()) as Map;
      ((json['encryption'] as Map)['kdf'] as Map)['memoryKiB'] = 4 * 1024 * 1024;
      expect(
        () => SettingsFile.parse(jsonEncode(json)),
        throwsA(isA<SettingsFileException>().having((e) => e.error, 'error', SettingsFileError.damaged)),
      );
    });
  });

  group('versions and damaged files', () {
    test('a file of a newer format is refused with newerVersion', () {
      final text = jsonEncode({
        'format': 'immuch360-settings',
        'version': SettingsFile.currentVersion + 1,
        'level': 'settings',
        'createdAt': '2027-01-01T00:00:00.000Z',
        'content': {},
      });
      expect(
        () => SettingsFile.parse(text),
        throwsA(isA<SettingsFileException>().having((e) => e.error, 'error', SettingsFileError.newerVersion)),
      );
    });

    test('a file of an older build with fewer sections reads, the missing ones empty', () {
      // As the first builds of the format may write it: no store, no albums, no app block
      final text = jsonEncode({
        'format': 'immuch360-settings',
        'version': 1,
        'level': 'settings',
        'createdAt': '2026-11-11T20:00:00.000Z',
        'content': {
          'server': {'url': 'https://photos.example.org'},
          'settings': {'themeMode': 'light', 'aRetiredSetting': 'true'},
          'sources': [
            {'id': 'a', 'type': 'smb', 'name': 'NAS', 'host': 'nas'},
            'not a source',
          ],
        },
      });
      final file = SettingsFile.parse(text);
      final content = file.content!;
      expect(file.origin.appVersion, '');
      expect(content.server!.url, 'https://photos.example.org');
      expect(content.server!.hasAccount, isFalse);
      expect(content.settings, {'themeMode': 'light', 'aRetiredSetting': 'true'});
      expect(content.store, isEmpty);
      expect(content.backupAlbums, isEmpty);
      expect(content.sources, hasLength(1));
    });

    test('other JSON and other text are not settings files', () {
      for (final text in ['', 'hello', '[]', '{"format":"something-else","version":1}']) {
        expect(
          () => SettingsFile.parse(text),
          throwsA(isA<SettingsFileException>().having((e) => e.error, 'error', SettingsFileError.notASettingsFile)),
          reason: text,
        );
      }
      expect(SettingsFile.looksLikeSettingsFile('{"format": "immuch360-settings"}'), isTrue);
      expect(SettingsFile.looksLikeSettingsFile('{"type": "FeatureCollection"}'), isFalse);
    });

    test('a cut payload is damaged', () {
      final json = jsonDecode(File('test/fixtures/settings_file/accounts_from_python.json').readAsStringSync()) as Map;
      json['payload'] = 'AAAA';
      expect(
        () => SettingsFile.parse(jsonEncode(json)),
        throwsA(isA<SettingsFileException>().having((e) => e.error, 'error', SettingsFileError.damaged)),
      );
    });
  });
}
