// A settings file on a network share set up in the app (lot settings tile, release 51): the way of a TV without a file
// picker or save dialog, and an in-app import on iOS. The restore page offers the shares beside the system picker, the
// browser shows the folders and the JSON files only, Back goes up a folder; the export page saves in the folder chosen.
// A device that answers "no file picker" drops the system buttons and points at the shares.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_export.page.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_import.page.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_share.page.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_io.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_share_io.dart';

import '../../../widget_tester_extensions.dart';

const _origin = SettingsFileOrigin(appVersion: '3.4.5', build: '3030050', platform: 'android');

const _nas = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: '192.168.1.10');
const _dav = NetworkSource(id: 'dav', type: NetworkSourceType.webdav, name: 'Cloud', host: 'dav.example.org');

NetworkEntry _dir(String path) => NetworkEntry(sourceId: 'nas', path: path, isDirectory: true);
NetworkEntry _file(String path) => NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: 100);

class _FakeIo implements SettingsFileIo {
  _FakeIo({this.noPicker = false});

  final bool noPicker;

  @override
  bool get canPick => true;

  @override
  bool get canSave => true;

  @override
  bool get canShare => true;

  @override
  Future<String?> pick() async {
    if (noPicker) {
      throw const SettingsFileIoException(SettingsFileIoError.noPicker);
    }
    return null;
  }

  @override
  Future<bool> save(String text, String fileName) async {
    if (noPicker) {
      throw const SettingsFileIoException(SettingsFileIoError.noPicker);
    }
    return true;
  }

  @override
  Future<void> share(String text, String fileName, {Rect? origin}) async {}
}

const _settingsPath = '/Backups/immuch360-settings-2026-11-22.json';

class _FakeShareIo implements SettingsFileShareIo {
  _FakeShareIo({required this.file, this.failSave});

  /// The text of the settings file of the share
  final String file;
  final Exception? failSave;
  final listed = <String>[];
  final read_ = <String>[];
  final saved = <(String, String, String, String)>[];

  static final _tree = {
    '/': [_dir('/Backups'), _file('/photo.jpg'), _file('/notes.JSON')],
    '/Backups': [
      _dir('/Backups/Old'),
      _file('/Backups/.immuch360-settings.json.0123456789abcdef.partial'),
      _file(_settingsPath),
    ],
    '/Backups/Old': <NetworkEntry>[],
  };

  @override
  Future<List<NetworkEntry>> list(String sourceId, String path) async {
    listed.add('$sourceId:$path');
    final entries = _tree[path];
    if (entries == null) {
      throw const NetworkFileSystemException('No such folder', isNotFound: true);
    }
    return entries;
  }

  @override
  Future<String> read(String sourceId, String path) async {
    read_.add('$sourceId:$path');
    return file;
  }

  @override
  Future<String> save(String text, String fileName, {required String sourceId, required String folder}) async {
    if (failSave != null) {
      throw failSave!;
    }
    saved.add((text, fileName, sourceId, folder));
    return sharePathIn(folder, fileName);
  }
}

class _FakeService extends Fake implements SettingsFileService {
  @override
  bool get isSignedIn => false;

  @override
  Future<String> buildFile({
    required SettingsFileLevel level,
    required SettingsFileOrigin origin,
    String? passphrase,
    DateTime? now,
  }) async => 'the settings file';
}

void main() {
  late String clearFile;

  setUpAll(() {
    clearFile = SettingsFile(
      origin: _origin,
      createdAt: DateTime.utc(2026, 11, 22, 9),
      level: SettingsFileLevel.settings,
      content: const SettingsFileContent(settings: {'themeMode': 'dark'}),
    ).encode();
  });

  test('the browser shows folders, JSON files only to open, never hidden files', () {
    expect(settingsFileShareEntryShown(_dir('/Backups'), SettingsFileShareMode.save), isTrue);
    expect(settingsFileShareEntryShown(_dir('/Backups'), SettingsFileShareMode.open), isTrue);
    expect(settingsFileShareEntryShown(_file('/a.json'), SettingsFileShareMode.open), isTrue);
    expect(settingsFileShareEntryShown(_file('/a.JSON'), SettingsFileShareMode.open), isTrue);
    expect(settingsFileShareEntryShown(_file('/a.json'), SettingsFileShareMode.save), isFalse);
    expect(settingsFileShareEntryShown(_file('/photo.jpg'), SettingsFileShareMode.open), isFalse);
    expect(settingsFileShareEntryShown(_file('/.a.json.0123.partial'), SettingsFileShareMode.open), isFalse);
    expect(settingsFileShareEntryShown(_dir('/.hidden'), SettingsFileShareMode.open), isFalse);
  });

  Future<_FakeShareIo> pump(
    WidgetTester tester,
    Widget page, {
    List<NetworkSource> shares = const [_nas],
    bool noPicker = false,
    Exception? failSave,
    bool tvMode = false,
  }) async {
    tester.view
      ..physicalSize = const Size(1200, 2400)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final shareIo = _FakeShareIo(file: clearFile, failSave: failSave);
    await tester.pumpConsumerWidget(
      page,
      overrides: [
        tvModeProvider.overrideWithValue(tvMode),
        settingsFileSharesProvider.overrideWithValue(shares),
        settingsFileShareIoProvider.overrideWithValue(shareIo),
        settingsFileIoProvider.overrideWithValue(_FakeIo(noPicker: noPicker)),
        settingsFileServiceProvider.overrideWithValue(_FakeService()),
        settingsFileOriginProvider.overrideWith((ref) async => _origin),
      ],
    );
    await tester.pumpAndSettle();
    return shareIo;
  }

  final chooseShare = find.byKey(const Key('settings_file_choose_share'));
  final chooseFile = find.byKey(const Key('settings_file_choose'));
  final settingsJson = find.byKey(const Key('settings_file_share_entry_immuch360-settings-2026-11-22.json'));
  final backups = find.byKey(const Key('settings_file_share_entry_Backups'));

  group('restore', () {
    testWidgets('no share set up: the system picker only', (tester) async {
      await pump(tester, const SettingsFileImportPage(), shares: const []);
      expect(chooseShare, findsNothing);
      expect(chooseFile, findsOneWidget);
    });

    testWidgets('a share: its folders, the JSON files, Back goes up, the file opens its preview', (tester) async {
      final io = await pump(tester, const SettingsFileImportPage());
      expect(find.text('Choose on a network share'), findsOneWidget);
      expect(chooseFile, findsOneWidget);

      await tester.tap(chooseShare);
      await tester.pumpAndSettle();
      // One share: its start folder straight away
      expect(find.byType(SettingsFileSharePage), findsOneWidget);
      expect(find.text('Choose a settings file'), findsOneWidget);
      expect(find.text('NAS · /'), findsOneWidget);
      expect(backups, findsOneWidget);
      expect(find.text('notes.JSON'), findsOneWidget);
      expect(find.text('photo.jpg'), findsNothing);

      await tester.tap(backups);
      await tester.pumpAndSettle();
      expect(find.text('NAS · /Backups'), findsOneWidget);
      expect(settingsJson, findsOneWidget);
      expect(find.textContaining('.partial'), findsNothing);

      // Back: up one folder, not out of the browser
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('NAS · /'), findsOneWidget);

      await tester.tap(backups);
      await tester.pumpAndSettle();
      await tester.tap(settingsJson);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsFileSharePage), findsNothing);
      expect(find.text('Settings only'), findsOneWidget);
      expect(find.byKey(const Key('settings_file_restore')), findsOneWidget);
      expect(io.listed, ['nas:/', 'nas:/Backups', 'nas:/', 'nas:/Backups']);
      expect(io.read_, ['nas:$_settingsPath']);
    });

    testWidgets('an empty folder says it holds no settings file', (tester) async {
      await pump(tester, const SettingsFileImportPage());
      await tester.tap(chooseShare);
      await tester.pumpAndSettle();
      await tester.tap(backups);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_file_share_entry_Old')));
      await tester.pumpAndSettle();
      expect(find.text('No settings file in this folder'), findsOneWidget);
    });

    testWidgets('two shares: the list of the shares first, Back from a share returns to it', (tester) async {
      await pump(tester, const SettingsFileImportPage(), shares: const [_nas, _dav]);
      await tester.tap(chooseShare);
      await tester.pumpAndSettle();
      expect(find.text('NAS'), findsOneWidget);
      expect(find.text('Cloud'), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings_file_share_nas')));
      await tester.pumpAndSettle();
      expect(backups, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings_file_share_dav')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsFileSharePage), findsNothing);
      expect(chooseShare, findsOneWidget);
    });

    testWidgets('a device without a file picker drops its button and points at the shares', (tester) async {
      await pump(tester, const SettingsFileImportPage(), noPicker: true);
      await tester.tap(chooseFile);
      await tester.pumpAndSettle();
      expect(find.text('This device has no file picker. Use a network share instead.'), findsOneWidget);
      expect(chooseFile, findsNothing);
      expect(chooseShare, findsOneWidget);
    });

    testWidgets('with a remote: OK on a folder opens it, Back goes up', (tester) async {
      await pump(tester, const SettingsFileSharePage(mode: SettingsFileShareMode.open), tvMode: true);
      // The first entry has the focus
      expect(_focusedIn(backups), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('NAS · /Backups'), findsOneWidget);
      // The new folder starts on its first entry too
      expect(_focusedIn(find.byKey(const Key('settings_file_share_entry_Old'))), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_focusedIn(settingsJson), isTrue);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('NAS · /'), findsOneWidget);
    });
  });

  group('export', () {
    Future<void> saveInBackups(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('settings_file_save_share')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a folder'), findsOneWidget);
      // Folders only: no file to pick here
      expect(find.text('notes.JSON'), findsNothing);
      await tester.tap(backups);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_file_share_save_here')));
      await tester.pumpAndSettle();
    }

    testWidgets('no share set up: no share button', (tester) async {
      await pump(tester, const SettingsFileExportPage(), shares: const []);
      expect(find.byKey(const Key('settings_file_save_share')), findsNothing);
      expect(find.byKey(const Key('settings_file_save')), findsOneWidget);
    });

    testWidgets('Save on a network share: the folder chosen, the file of the service, said saved', (tester) async {
      final io = await pump(tester, const SettingsFileExportPage());
      expect(find.text('Save on a network share'), findsOneWidget);
      await saveInBackups(tester);

      expect(find.byType(SettingsFileSharePage), findsNothing);
      final (text, name, sourceId, folder) = io.saved.single;
      expect(text, 'the settings file');
      expect(name, startsWith('immuch360-settings-'));
      expect(sourceId, 'nas');
      expect(folder, '/Backups');
      expect(find.text('Settings file saved on NAS'), findsOneWidget);
    });

    testWidgets('Back in the folder browser leaves the export as it was', (tester) async {
      final io = await pump(tester, const SettingsFileExportPage());
      await tester.tap(find.byKey(const Key('settings_file_save_share')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsFileSharePage), findsNothing);
      expect(io.saved, isEmpty);
      final button = tester.widget<ButtonStyleButton>(find.byKey(const Key('settings_file_save_share')));
      expect(button.onPressed, isNotNull, reason: 'ready for another try');
    });

    testWidgets('a folder that refuses new files is told so', (tester) async {
      await pump(
        tester,
        const SettingsFileExportPage(),
        failSave: const ShareWriteException(ShareWriteFailure.readOnly),
      );
      await saveInBackups(tester);
      expect(find.text('This folder does not accept new files. Choose another one.'), findsOneWidget);
    });

    testWidgets('a device without a save dialog drops its button and points at the shares', (tester) async {
      await pump(tester, const SettingsFileExportPage(), noPicker: true);
      await tester.tap(find.byKey(const Key('settings_file_save')));
      await tester.pumpAndSettle();
      expect(find.text('This device has no file picker. Use a network share instead.'), findsOneWidget);
      expect(find.byKey(const Key('settings_file_save')), findsNothing);
      expect(find.byKey(const Key('settings_file_save_share')), findsOneWidget);
    });
  });

  group('reading a file of a share', () {
    test('the text of a settings file', () async {
      final fileSystem = _BytesFileSystem(utf8.encode(clearFile));
      expect(await readSettingsFileOnShare(fileSystem, _settingsPath), clearFile);
      expect(fileSystem.asked, [(_settingsPath, settingsFileMaxBytes + 1)]);
    });

    test('a file larger than a settings file is refused without reading more', () async {
      final fileSystem = _BytesFileSystem(Uint8List(settingsFileMaxBytes + 1));
      await expectLater(
        readSettingsFileOnShare(fileSystem, '/big.json'),
        throwsA(isA<SettingsFileIoException>().having((e) => e.error, 'error', SettingsFileIoError.tooLarge)),
      );
    });
  });
}

bool _focusedIn(Finder finder) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) {
    return false;
  }
  return finder.evaluate().any((element) {
    if (element == focused) {
      return true;
    }
    var found = false;
    focused.visitAncestorElements((ancestor) {
      found = ancestor == element;
      return !found;
    });
    return found;
  });
}

/// A share holding one file of these bytes
class _BytesFileSystem extends NetworkFileSystem {
  _BytesFileSystem(this.bytes);

  final Uint8List bytes;
  final asked = <(String, int)>[];

  @override
  NetworkSource get source => _nas;

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) async => _file(path);

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    asked.add((path, length));
    final end = offset + length > bytes.length ? bytes.length : offset + length;
    return Uint8List.sublistView(bytes, offset, end);
  }

  @override
  Future<void> close() async {}
}
