import 'dart:convert';

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

/// One install of the app: its database, Store, settings, secure storage and albums
class _Install {
  _Install._(this.db, this.store, this.settings, this.secrets, this.albums, this.container);

  final Drift db;
  final StoreService store;
  final SettingsRepository settings;
  final FakeSecureStorage secrets;
  final _FakeAlbums albums;
  final ProviderContainer container;

  static Future<_Install> create({List<LocalAlbum> albums = const []}) async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await SettingsRepository.reset();
    final settings = await SettingsRepository.ensureInitialized(db);
    final secrets = FakeSecureStorage();
    final fakeAlbums = _FakeAlbums(albums);
    final container = ProviderContainer(
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        secureStorageServiceProvider.overrideWithValue(secrets),
        settingsProvider.overrideWithValue(settings),
        settingsFileAlbumsProvider.overrideWithValue(fakeAlbums),
      ],
    );
    return _Install._(db, store, settings, secrets, fakeAlbums, container);
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
}
