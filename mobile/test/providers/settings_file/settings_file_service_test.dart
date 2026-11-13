import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/settings_file/settings_file_crypto.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import '../network/fakes.dart';

const _origin = SettingsFileOrigin(appVersion: '3.4.1', build: '3030044', platform: 'android');

/// The albums of a device, in memory
class _FakeAlbums implements SettingsFileAlbums {
  _FakeAlbums(this.albums);

  List<LocalAlbum> albums;

  @override
  Future<List<LocalAlbum>> all() async => albums;

  @override
  Future<void> setChoice(LocalAlbum album, BackupSelection selection) async {
    albums = [for (final a in albums) a.id == album.id ? a.copyWith(backupSelection: selection) : a];
  }

  BackupSelection choiceOf(String id) => albums.firstWhere((a) => a.id == id).backupSelection;
}

LocalAlbum _album(String id, String name, [BackupSelection selection = BackupSelection.none]) =>
    LocalAlbum(id: id, name: name, updatedAt: DateTime(2026), backupSelection: selection);

const _smb = NetworkSource(
  id: '00112233aabbccdd',
  type: NetworkSourceType.smb,
  name: 'NAS photos',
  host: '192.168.1.10',
  share: 'photo',
  username: 'alice',
);

const _plex = NetworkSource(
  id: 'ffeeddccbbaa0011',
  type: NetworkSourceType.plex,
  name: 'Plex at home',
  host: '192.168.1.20',
  useTls: true,
  discoveryId: '0123456789abcdef0123456789abcdef01234567',
  plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
);

const _tapo = NetworkSource(
  id: '1234567812345678',
  type: NetworkSourceType.tapo,
  name: 'Garden',
  host: '192.168.1.30',
  username: 'camuser',
  useTls: true,
  camera: TapoCameraInfo(model: 'C200'),
);

/// The server of a restored account, in memory: what each address answers, and what the app did with it
class _FakeServerLink implements SettingsFileServerLink {
  _FakeServerLink(this.store, this.settings);

  final StoreService store;
  final SettingsRepository settings;

  /// What the server answers at each address; an address missing does not answer
  Map<String, SettingsFileSessionCheck> answers = {
    'https://photos.example.org/api': SettingsFileSessionCheck.valid,
    'https://photos.example.org': SettingsFileSessionCheck.valid,
  };

  ({String name, String email})? user = (name: 'Alice', email: 'alice@example.org');

  /// The addresses connected to, with whether resolved, and the token given to the HTTP clients
  final connects = <(String, bool, String)>[];

  /// The proxy headers and the Store's token at the first connect: what the first request goes out with
  Map<String, String>? headersAtConnect;
  String? storedTokenAtConnect;
  String? _address;
  var forgotten = false;

  @override
  Future<void> connect(String address, {required bool resolve, required String token}) async {
    headersAtConnect ??= settings.appConfig.network.customHeaders;
    storedTokenAtConnect ??= store.tryGet(StoreKey.accessToken);
    connects.add((address, resolve, token));
    if (!answers.containsKey(address)) {
      _address = null;
      throw const SocketException('no answer');
    }
    _address = address;
  }

  @override
  Future<SettingsFileSessionCheck> check() async => answers[_address] ?? SettingsFileSessionCheck.unreachable;

  /// The server ends the session while the user is loaded (signed out on the web at that moment)
  var endSessionAtLoadUser = false;

  @override
  Future<({String name, String email})?> loadUser(String token) async {
    if (endSessionAtLoadUser && _address != null) {
      answers[_address!] = SettingsFileSessionCheck.refused;
      return null;
    }
    return user;
  }

  @override
  Future<void> forget() async {
    forgotten = true;
    await store.delete(StoreKey.accessToken);
    await store.delete(StoreKey.currentUser);
  }
}

/// One install of the app: its database, Store, settings, secure storage and albums
class _Install {
  _Install._(this.db, this.store, this.settings, this.secrets, this.albums, this.container, this.server);

  final Drift db;
  final StoreService store;
  final SettingsRepository settings;
  final FakeSecureStorage secrets;
  final _FakeAlbums albums;
  final ProviderContainer container;
  final _FakeServerLink server;

  static Future<_Install> create({List<LocalAlbum> albums = const []}) async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await SettingsRepository.reset();
    final settings = await SettingsRepository.ensureInitialized(db);
    final secrets = FakeSecureStorage();
    final fakeAlbums = _FakeAlbums(albums);
    final server = _FakeServerLink(store, settings);
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secrets),
        settingsProvider.overrideWithValue(settings),
        settingsFileAlbumsProvider.overrideWithValue(fakeAlbums),
        settingsFileServerLinkProvider.overrideWithValue(server),
      ],
    );
    return _Install._(db, store, settings, secrets, fakeAlbums, container, server);
  }

  SettingsFileService get service => container.read(settingsFileServiceProvider);

  NetworkSourcesNotifier get sources => container.read(networkSourcesProvider.notifier);

  List<NetworkSource> get sourceList => container.read(networkSourcesProvider);

  Future<void> dispose() async {
    container.dispose();
    await store.dispose();
    await SettingsRepository.reset();
    await db.close();
  }
}

/// The install of FreeKC's case: a server account, a share, a Plex server, a camera, settings and backup albums
Future<_Install> _fullInstall() async {
  final a = await _Install.create(
    albums: [
      _album('-1739773001', 'Camera', BackupSelection.selected),
      _album('540528482', 'Screenshots', BackupSelection.excluded),
      _album('99', 'WhatsApp Images'),
    ],
  );
  await a.store.put(StoreKey.serverUrl, 'https://photos.example.org');
  await a.store.put(StoreKey.serverEndpoint, 'https://photos.example.org/api');
  await a.store.put(StoreKey.accessToken, 'session-token-a');
  await a.store.put(StoreKey.deviceId, 'device-of-a');
  await a.store.put(StoreKey.plexClientIdentifier, 'plex-client-of-a');
  await a.store.put(StoreKey.phoneShareId, 'share-id-of-a');
  await a.store.put(StoreKey.djiObstacleFarCm, 250);
  await a.store.put(StoreKey.playFromPhoneAsk, true);
  await a.store.put(StoreKey.pairedScreens, '[{"sessionId":"s1","label":"Living room TV"}]');
  await a.settings.write(SettingsKey.themeMode, ThemeMode.dark);
  await a.settings.write(SettingsKey.timelineTilesPerRow, 5);
  await a.settings.write(SettingsKey.backupEnabled, true);
  await a.settings.write(SettingsKey.networkLocalEndpoint, 'http://192.168.1.5:2283');
  await a.settings.write(SettingsKey.networkCustomHeaders, {'X-Proxy-Token': 'proxy-secret'});
  await a.sources.add(_smb, password: 'smb-pass');
  await a.sources.add(_plex, password: 'plex-token');
  await a.sources.add(_tapo, password: 'tplink-pass', cameraPassword: 'camera-pass');
  return a;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Two installs, one after the other: each its own database
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('accounts level: export, then import on a new install brings everything back', () async {
    final a = await _fullInstall();
    final text = await a.service.buildFile(
      level: SettingsFileLevel.accounts,
      origin: _origin,
      passphrase: 'correct horse battery',
    );
    await a.dispose();

    final b = await _Install.create();
    final file = SettingsFile.parse(text);
    final content = await openSettingsFile(file, passphrase: 'correct horse battery');
    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);

    expect(report.accountRestored, isTrue);
    expect(b.store.tryGet(StoreKey.serverUrl), 'https://photos.example.org');
    expect(b.store.tryGet(StoreKey.serverEndpoint), 'https://photos.example.org/api');
    expect(b.store.tryGet(StoreKey.accessToken), 'session-token-a');
    // The values of the device stay its own
    expect(b.store.tryGet(StoreKey.deviceId), isNull);
    expect(b.store.tryGet(StoreKey.plexClientIdentifier), isNull);
    expect(b.store.tryGet(StoreKey.phoneShareId), isNull);
    // Settings, Store values, pairing
    expect(b.settings.appConfig.read(SettingsKey.themeMode), ThemeMode.dark);
    expect(b.settings.appConfig.read(SettingsKey.timelineTilesPerRow), 5);
    expect(b.settings.appConfig.read(SettingsKey.backupEnabled), isTrue);
    expect(b.settings.appConfig.read(SettingsKey.networkLocalEndpoint), 'http://192.168.1.5:2283');
    expect(b.settings.appConfig.read(SettingsKey.networkCustomHeaders), {'X-Proxy-Token': 'proxy-secret'});
    expect(b.store.tryGet(StoreKey.djiObstacleFarCm), 250);
    expect(b.store.tryGet(StoreKey.playFromPhoneAsk), isTrue);
    expect(b.store.tryGet(StoreKey.pairedScreens), contains('Living room TV'));
    // Sources and their secrets, the Plex token and the camera passwords on this device only
    expect(b.sourceList.map((s) => s.name), ['NAS photos', 'Plex at home', 'Garden']);
    expect(await b.sources.readPassword(_smb.id), 'smb-pass');
    expect(await b.sources.readPassword(_plex.id), 'plex-token');
    expect(await b.sources.readPassword(_tapo.id), 'tplink-pass');
    expect(await b.sources.readCameraPassword(_tapo.id), 'camera-pass');
    expect(b.secrets.writtenDeviceOnly, containsAll([_plex.secretKey, _tapo.secretKey, _tapo.cameraSecretKey]));
    // The albums are not listed yet on the new install: they wait for its first scan
    expect(report.where(SettingsFileOutcome.waiting).single.section, SettingsFileSection.backupAlbums);
    b.albums.albums = [_album('-1739773001', 'Camera'), _album('540528482', 'Screenshots'), _album('7', 'Other')];
    await b.service.applyPendingBackupAlbums();
    expect(b.albums.choiceOf('-1739773001'), BackupSelection.selected);
    expect(b.albums.choiceOf('540528482'), BackupSelection.excluded);
    expect(b.albums.choiceOf('7'), BackupSelection.none);
    expect(b.store.tryGet(StoreKey.pendingBackupAlbums), isNull);
    await b.dispose();
  });

  test('settings level: no secret leaves, the account is not restored, the address fills the sign in form', () async {
    final a = await _fullInstall();
    final text = await a.service.buildFile(level: SettingsFileLevel.settings, origin: _origin);
    await a.dispose();
    for (final secret in [
      'session-token-a',
      'smb-pass',
      'plex-token',
      'tplink-pass',
      'camera-pass',
      'proxy-secret',
      'device-of-a',
      'plex-client-of-a',
      'share-id-of-a',
      'Living room TV',
    ]) {
      expect(text.contains(secret), isFalse, reason: secret);
    }

    final b = await _Install.create(albums: [_album('x', 'Camera')]);
    final content = await openSettingsFile(SettingsFile.parse(text));
    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);
    expect(report.accountRestored, isFalse);
    expect(b.store.tryGet(StoreKey.serverUrl), 'https://photos.example.org');
    expect(b.store.tryGet(StoreKey.serverEndpoint), 'https://photos.example.org/api');
    expect(b.store.tryGet(StoreKey.accessToken), isNull);
    expect(b.sourceList, hasLength(3));
    expect(await b.sources.readPassword(_smb.id), isNull);
    expect(b.settings.appConfig.read(SettingsKey.themeMode), ThemeMode.dark);
    // Matched by name on another device (another id); Screenshots is not on it
    expect(b.albums.choiceOf('x'), BackupSelection.selected);
    expect(report.items.where((i) => i.reason == SettingsFileSkipReason.notOnThisDevice).map((i) => i.label), [
      'Screenshots',
    ]);
    await b.dispose();
  });

  test('merge on a signed in install keeps its account and its sources, adds the others', () async {
    final a = await _fullInstall();
    final content = await a.service.collect();
    await a.dispose();

    final b = await _Install.create();
    await b.store.put(StoreKey.serverUrl, 'https://other.example.net');
    await b.store.put(StoreKey.accessToken, 'session-token-b');
    await b.settings.write(SettingsKey.networkLocalEndpoint, 'http://10.0.0.2:2283');
    await b.sources.add(_smb.copyWith(), password: 'b-pass');
    const own = NetworkSource(id: 'bbbbbbbbbbbbbbbb', type: NetworkSourceType.dlna, name: 'TV', host: '10.0.0.9');
    await b.sources.add(own);

    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);
    expect(report.accountRestored, isFalse);
    expect(b.store.tryGet(StoreKey.accessToken), 'session-token-b');
    expect(b.store.tryGet(StoreKey.serverUrl), 'https://other.example.net');
    expect(
      report.items.any((i) => i.section == SettingsFileSection.account && i.reason == SettingsFileSkipReason.signedIn),
      isTrue,
    );
    // The network settings belong to the other server: not applied
    expect(b.settings.appConfig.read(SettingsKey.networkLocalEndpoint), 'http://10.0.0.2:2283');
    expect(b.settings.appConfig.read(SettingsKey.networkCustomHeaders), isEmpty);
    expect(report.items.any((i) => i.reason == SettingsFileSkipReason.otherServer), isTrue);
    // Its share kept with its password, the two others added, its own DLNA kept
    expect(b.sourceList.map((s) => s.name), ['NAS photos', 'TV', 'Plex at home', 'Garden']);
    expect(await b.sources.readPassword(_smb.id), 'b-pass');
    expect(report.items.where((i) => i.reason == SettingsFileSkipReason.alreadyHere).map((i) => i.label), [
      'NAS photos',
    ]);
    // The pairing list names sessions of another account: not restored
    expect(b.store.tryGet(StoreKey.pairedScreens), isNull);
    await b.dispose();
  });

  test('replace removes the sources, settings and album choices the file does not hold', () async {
    final a = await _Install.create();
    await a.settings.write(SettingsKey.themeMode, ThemeMode.light);
    await a.sources.add(_smb, password: 'smb-pass');
    final content = await a.service.collect();
    await a.dispose();

    final b = await _Install.create(
      albums: [_album('1', 'Camera'), _album('2', 'Downloads', BackupSelection.selected)],
    );
    await b.settings.write(SettingsKey.timelineTilesPerRow, 2);
    await b.store.put(StoreKey.djiObstacleNearCm, 50);
    await b.sources.add(_plex, password: 'plex-token');
    final withAlbum = SettingsFileContent(
      settings: content.settings,
      sources: content.sources,
      sourceSecrets: content.sourceSecrets,
      backupAlbums: const [SettingsFileBackupAlbum(id: '1', name: 'Camera', choice: SettingsFileAlbumChoice.selected)],
    );
    await b.service.restore(withAlbum, SettingsFileRestoreMode.replace);

    expect(b.settings.appConfig.read(SettingsKey.themeMode), ThemeMode.light);
    expect(b.settings.appConfig.read(SettingsKey.timelineTilesPerRow), 4, reason: 'back to the default');
    expect(b.store.tryGet(StoreKey.djiObstacleNearCm), isNull);
    expect(b.sourceList.map((s) => s.name), ['NAS photos']);
    expect(await b.secrets.read(_plex.secretKey), isNull, reason: 'the removed source forgets its token');
    expect(b.albums.choiceOf('1'), BackupSelection.selected);
    expect(b.albums.choiceOf('2'), BackupSelection.none);
    await b.dispose();
  });

  test('a file of an older or later build: unknown settings and source types are skipped and listed', () async {
    final b = await _Install.create();
    final content = SettingsFileContent.fromJson(
      jsonDecode('''{
        "settings": {"themeMode": "dark", "aSettingOfALaterBuild": "1", "timelineTilesPerRow": "not a number"},
        "store": {"djiObstacleFarCm": "not an int", "aStoreKeyOfALaterBuild": true},
        "sources": [{"id": "x1", "type": "ftp", "name": "FTP of a later build", "host": "h"}]
      }'''),
    );
    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);
    expect(b.settings.appConfig.read(SettingsKey.themeMode), ThemeMode.dark);
    final skipped = {for (final item in report.where(SettingsFileOutcome.skipped)) item.label: item.reason};
    expect(skipped, {
      'aSettingOfALaterBuild': SettingsFileSkipReason.unknownToThisBuild,
      'timelineTilesPerRow': SettingsFileSkipReason.unreadable,
      'djiObstacleFarCm': SettingsFileSkipReason.unreadable,
      'aStoreKeyOfALaterBuild': SettingsFileSkipReason.unknownToThisBuild,
      'FTP of a later build': SettingsFileSkipReason.unknownToThisBuild,
    });
    expect(b.sourceList, isEmpty);
    await b.dispose();
  });

  test('an accounts level file needs a passphrase of 8 characters or more', () async {
    final a = await _Install.create();
    await expectLater(
      a.service.buildFile(level: SettingsFileLevel.accounts, origin: _origin, passphrase: 'short'),
      throwsArgumentError,
    );
    await a.dispose();
  });

  /// An accounts file of FreeKC's case, opened on a new install: the content to restore
  Future<SettingsFileContent> accountsContent() async {
    final a = await _fullInstall();
    final content = await a.service.collect();
    await a.dispose();
    return content;
  }

  // Issue of 13 Nov 2026: the import wrote the token into the Store only. The session travels as a cookie of the
  // native HTTP clients, which only a sign in sets, and the API client of an install started without a server has no
  // address: the app came back signed out while the sources and settings were there.
  for (final mode in SettingsFileRestoreMode.values) {
    test(
      'accounts level on an empty install, ${mode.name}: the session goes to the server and the user is signed in',
      () async {
        final content = await accountsContent();
        final b = await _Install.create();
        final report = await b.service.restore(content, mode);

        expect(b.server.connects, [('https://photos.example.org/api', false, 'session-token-a')]);
        // The proxy headers of the file were in place for the first request, and the token stored
        expect(b.server.headersAtConnect, {'X-Proxy-Token': 'proxy-secret'});
        expect(b.server.storedTokenAtConnect, 'session-token-a');
        expect(report.accountRestored, isTrue);
        expect(report.signIn?.result, SettingsFileSignInResult.signedIn);
        expect(report.signIn?.name, 'Alice');
        expect(report.signIn?.email, 'alice@example.org');
        expect(report.items.first.toString(), 'account https://photos.example.org restored');
        expect(b.store.tryGet(StoreKey.accessToken), 'session-token-a');
        expect(b.server.forgotten, isFalse);
        await b.dispose();
      },
    );
  }

  test('a session the server refused: the token is forgotten, the address kept for the sign in form', () async {
    final content = await accountsContent();
    final b = await _Install.create();
    b.server.answers = {'https://photos.example.org/api': SettingsFileSessionCheck.refused};
    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);

    expect(report.signIn?.result, SettingsFileSignInResult.refused);
    expect(report.accountRestored, isFalse);
    expect(b.server.forgotten, isTrue);
    expect(b.store.tryGet(StoreKey.accessToken), isNull);
    expect(b.store.tryGet(StoreKey.serverUrl), 'https://photos.example.org');
    expect(b.store.tryGet(StoreKey.serverEndpoint), 'https://photos.example.org/api');
    expect(report.items.take(2).map((i) => i.toString()), [
      'server https://photos.example.org restored',
      'account https://photos.example.org skipped sessionRefused',
    ]);
    // The rest of the file is restored all the same
    expect(b.sourceList, hasLength(3));
    expect(b.settings.appConfig.read(SettingsKey.themeMode), ThemeMode.dark);
    await b.dispose();
  });

  test('no answer at any address: the account is kept for the next start, nothing forgotten', () async {
    final content = await accountsContent();
    final b = await _Install.create();
    b.server.answers = {};
    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);

    expect(report.signIn?.result, SettingsFileSignInResult.unreachable);
    expect(report.accountRestored, isTrue);
    expect(b.server.forgotten, isFalse);
    expect(b.store.tryGet(StoreKey.accessToken), 'session-token-a');
    await b.dispose();
  });

  test('the old address does not answer: the address the user typed is resolved again', () async {
    const content = SettingsFileContent(
      server: SettingsFileServer(
        url: 'https://photos.example.org',
        endpoint: 'http://192.168.1.5:2283/api',
        accessToken: 'session-token-a',
      ),
    );
    final b = await _Install.create();
    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);

    expect(b.server.connects, [
      ('http://192.168.1.5:2283/api', false, 'session-token-a'),
      ('https://photos.example.org', true, 'session-token-a'),
    ]);
    expect(report.signIn?.result, SettingsFileSignInResult.signedIn);
    await b.dispose();
  });

  test('a file without the API address: the address typed is resolved, the sign in form filled when refused', () async {
    const content = SettingsFileContent(
      server: SettingsFileServer(url: 'https://photos.example.org', accessToken: 'session-token-a'),
    );
    final b = await _Install.create();
    b.server.answers = {'https://photos.example.org': SettingsFileSessionCheck.refused};
    final report = await b.service.restore(content, SettingsFileRestoreMode.replace);

    expect(b.server.connects, [('https://photos.example.org', true, 'session-token-a')]);
    expect(report.signIn?.result, SettingsFileSignInResult.refused);
    expect(b.store.tryGet(StoreKey.serverEndpoint), 'https://photos.example.org');
    await b.dispose();
  });

  test('valid session but no user from the server: told as not answering, the account kept', () async {
    final content = await accountsContent();
    final b = await _Install.create();
    b.server.user = null;
    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);

    expect(report.signIn?.result, SettingsFileSignInResult.unreachable);
    expect(b.store.tryGet(StoreKey.accessToken), 'session-token-a');
    await b.dispose();
  });

  test('session ended while the user loads: asked again, refused, the token forgotten', () async {
    final content = await accountsContent();
    final b = await _Install.create();
    b.server.endSessionAtLoadUser = true;
    final report = await b.service.restore(content, SettingsFileRestoreMode.merge);

    expect(report.signIn?.result, SettingsFileSignInResult.refused);
    expect(report.accountRestored, isFalse);
    expect(b.server.forgotten, isTrue);
    expect(b.store.tryGet(StoreKey.accessToken), isNull);
    await b.dispose();
  });

  test('no account restored, no request to the server: settings level, and an install signed in already', () async {
    final a = await _fullInstall();
    final settingsText = await a.service.buildFile(level: SettingsFileLevel.settings, origin: _origin);
    final content = await a.service.collect();
    await a.dispose();

    final b = await _Install.create();
    final fromSettings = await b.service.restore(
      await openSettingsFile(SettingsFile.parse(settingsText)),
      SettingsFileRestoreMode.merge,
    );
    expect(fromSettings.signIn, isNull);
    expect(b.server.connects, isEmpty);
    await b.dispose();

    final c = await _Install.create();
    await c.store.put(StoreKey.serverUrl, 'https://other.example.net');
    await c.store.put(StoreKey.accessToken, 'session-token-c');
    final signedIn = await c.service.restore(content, SettingsFileRestoreMode.merge);
    expect(signedIn.signIn, isNull);
    expect(c.server.connects, isEmpty);
    expect(c.store.tryGet(StoreKey.accessToken), 'session-token-c');
    await c.dispose();
  });
}
