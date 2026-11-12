import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/domain/services/settings_file/settings_file_crypto.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_import.page.dart';
import 'package:immich_mobile/providers/settings_file/settings_file.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_io.dart';

import '../../../widget_tester_extensions.dart';

const _origin = SettingsFileOrigin(appVersion: '3.4.1', build: '3030044', platform: 'android');

final _created = DateTime.utc(2026, 11, 11, 21, 30);

const _content = SettingsFileContent(
  server: SettingsFileServer(
    url: 'https://photos.example.org',
    endpoint: 'https://photos.example.org/api',
    accessToken: 'session-token',
  ),
  settings: {'themeMode': 'dark', 'timelineTilesPerRow': '5'},
  store: {'djiObstacleFarCm': 250},
  sources: [
    {'id': 'a1', 'type': 'smb', 'name': 'NAS photos', 'host': '192.168.1.10'},
    {'id': 'b2', 'type': 'plex', 'name': 'Plex at home', 'host': '192.168.1.20'},
  ],
  sourceSecrets: {'a1': SettingsFileSourceSecrets(password: 'smb-pass')},
  backupAlbums: [
    SettingsFileBackupAlbum(id: '1', name: 'Camera', choice: SettingsFileAlbumChoice.selected),
    SettingsFileBackupAlbum(id: '2', name: 'Screenshots', choice: SettingsFileAlbumChoice.excluded),
  ],
);

class _FakeIo implements SettingsFileIo {
  _FakeIo(this.text);

  final String? text;

  @override
  bool get canPick => true;

  @override
  bool get canSave => true;

  @override
  bool get canShare => true;

  @override
  Future<String?> pick() async => text;

  @override
  Future<bool> save(String text, String fileName) async => true;

  @override
  Future<void> share(String text, String fileName, {Rect? origin}) async {}
}

class _FakeService extends Fake implements SettingsFileService {
  _FakeService({this.signedIn = false});

  final bool signedIn;
  final restored = <(SettingsFileContent, SettingsFileRestoreMode)>[];

  @override
  bool get isSignedIn => signedIn;

  @override
  Future<SettingsFileReport> restore(SettingsFileContent content, SettingsFileRestoreMode mode) async {
    restored.add((content, mode));
    return const SettingsFileReport([
      SettingsFileReportItem(SettingsFileSection.settings, '3', SettingsFileOutcome.restored),
      SettingsFileReportItem(SettingsFileSection.sources, 'Plex at home', SettingsFileOutcome.restored),
      SettingsFileReportItem(
        SettingsFileSection.sources,
        'NAS photos',
        SettingsFileOutcome.skipped,
        SettingsFileSkipReason.alreadyHere,
      ),
      SettingsFileReportItem(SettingsFileSection.backupAlbums, '2', SettingsFileOutcome.waiting),
    ]);
  }
}

void main() {
  late String clearFile;
  late String sealedFile;

  setUpAll(() async {
    clearFile = SettingsFile(
      origin: _origin,
      createdAt: _created,
      level: SettingsFileLevel.settings,
      content: _content.withoutSecrets(),
    ).encode();
    sealedFile = (await sealSettingsFile(
      content: _content,
      passphrase: 'correct horse',
      origin: _origin,
      createdAt: _created,
      kdf: SettingsFileKdf(salt: List.filled(16, 1), memoryKiB: 64, iterations: 1),
    )).encode();
  });

  Future<_FakeService> pumpPage(
    WidgetTester tester, {
    String? initialText,
    String? picked,
    bool signedIn = false,
  }) async {
    tester.view
      ..physicalSize = const Size(1200, 4000)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final service = _FakeService(signedIn: signedIn);
    await tester.pumpConsumerWidget(
      SettingsFileImportPage(initialText: initialText),
      overrides: [
        settingsFileServiceProvider.overrideWithValue(service),
        settingsFileIoProvider.overrideWithValue(_FakeIo(picked)),
      ],
    );
    return service;
  }

  testWidgets('the preview of a settings level file tells what it holds, nothing is written before Restore', (
    tester,
  ) async {
    final service = await pumpPage(tester, initialText: clearFile);

    expect(find.textContaining('Made by Immuch360 3.4.1 on android'), findsOneWidget);
    expect(find.text('Settings only'), findsOneWidget);
    expect(find.text('Immich server: https://photos.example.org'), findsOneWidget);
    expect(find.byIcon(Icons.key_rounded), findsNothing, reason: 'no account at this level');
    expect(find.text('3 settings'), findsOneWidget);
    expect(find.text('NAS photos'), findsOneWidget);
    expect(find.text('SMB · 192.168.1.10'), findsOneWidget);
    expect(find.text('Plex at home'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('backed up'), findsOneWidget);
    expect(find.text('Screenshots'), findsOneWidget);
    expect(find.text('excluded'), findsOneWidget);
    expect(find.textContaining('password included'), findsNothing);
    expect(service.restored, isEmpty);

    await tester.tap(find.byKey(const Key('settings_file_replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_file_restore')));
    await tester.pumpAndSettle();

    expect(service.restored.single.$2, SettingsFileRestoreMode.replace);
    expect(service.restored.single.$1.server!.accessToken, isNull);
    // The report
    expect(find.text('Restored'), findsOneWidget);
    expect(find.text('3 settings'), findsOneWidget);
    expect(find.text('Plex at home'), findsOneWidget);
    expect(find.text("2 backup albums will be chosen once this device's photos are read"), findsOneWidget);
    expect(find.text('Not restored'), findsOneWidget);
    expect(find.text('NAS photos'), findsOneWidget);
    expect(find.text('already here'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('merge is the choice by default', (tester) async {
    final service = await pumpPage(tester, initialText: clearFile);
    await tester.tap(find.byKey(const Key('settings_file_restore')));
    await tester.pumpAndSettle();
    expect(service.restored.single.$2, SettingsFileRestoreMode.merge);
  });

  testWidgets('a file picked opens its preview', (tester) async {
    await pumpPage(tester, picked: clearFile);
    expect(find.byKey(const Key('settings_file_restore')), findsNothing);
    await tester.tap(find.byKey(const Key('settings_file_choose')));
    await tester.pumpAndSettle();
    expect(find.text('Immich server: https://photos.example.org'), findsOneWidget);
    expect(find.byKey(const Key('settings_file_restore')), findsOneWidget);
  });

  testWidgets('an accounts level file asks its passphrase, tells a wrong one, then shows the accounts', (tester) async {
    await pumpPage(tester, initialText: sealedFile, signedIn: true);
    expect(find.text('Immich server: https://photos.example.org'), findsNothing, reason: 'encrypted until opened');
    expect(find.byKey(const Key('settings_file_open_passphrase')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('settings_file_open_passphrase')), 'wrong horse');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('settings_file_open')));
      // The derivation runs in an isolate
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('Wrong passphrase'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('settings_file_open_passphrase')), 'correct horse');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('settings_file_open')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('Settings, accounts and passwords'), findsOneWidget);
    expect(find.text('Immich server: https://photos.example.org'), findsOneWidget);
    expect(find.byIcon(Icons.key_rounded), findsOneWidget);
    // This install is signed in: the file's account will not be used, and the preview says so
    expect(
      find.text("This app is signed in already: the file's account will not be used. Sign out first to use it."),
      findsOneWidget,
    );
    expect(find.text('SMB · 192.168.1.10 · password included'), findsOneWidget);
    expect(find.text('Plex · 192.168.1.20'), findsOneWidget);
  });

  testWidgets('a file of another kind is told as such', (tester) async {
    await pumpPage(tester, initialText: '{"type": "FeatureCollection"}');
    expect(find.text('This is not an Immuch360 settings file.'), findsOneWidget);
    expect(find.byKey(const Key('settings_file_restore')), findsNothing);
  });

  testWidgets('a file of a newer format asks for an update', (tester) async {
    final newer = jsonEncode({
      'format': 'immuch360-settings',
      'version': SettingsFile.currentVersion + 1,
      'level': 'settings',
      'createdAt': '2027-01-01T00:00:00.000Z',
      'content': {},
    });
    await pumpPage(tester, initialText: newer);
    expect(
      find.text('This file was made by a newer version of Immuch360. Update the app, then try again.'),
      findsOneWidget,
    );
  });
}
