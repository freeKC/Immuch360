// The "Settings file" card of the Library (lot settings tile, release 51): present with its icon and label, hidden
// only on a TV (or a device without a file picker) that has no share to use instead, opening a page whose two entries
// are those of Settings; Export goes through the existing service and share sheet, Restore through the existing
// preview, which writes nothing before Restore. With a remote control: the arrows reach the card, OK opens it, the
// page starts on Export, Back leaves.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_export.page.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_import.page.dart';
import 'package:immich_mobile/presentation/pages/settings_file/settings_file_library.page.dart';
import 'package:immich_mobile/presentation/widgets/settings_file/settings_file_card.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_io.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_share_io.dart';

import '../../../widget_tester_extensions.dart';

const _origin = SettingsFileOrigin(appVersion: '3.4.5', build: '3030050', platform: 'android');

const _nas = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: '192.168.1.10');

class _FakeIo implements SettingsFileIo {
  _FakeIo({this.picked});

  final String? picked;
  final shared = <(String, String)>[];
  var picks = 0;

  @override
  bool get canPick => true;

  @override
  bool get canSave => true;

  @override
  bool get canShare => true;

  @override
  Future<String?> pick() async {
    picks++;
    return picked;
  }

  @override
  Future<bool> save(String text, String fileName) async => true;

  @override
  Future<void> share(String text, String fileName, {Rect? origin}) async => shared.add((text, fileName));
}

class _FakeService extends Fake implements SettingsFileService {
  final built = <SettingsFileLevel>[];
  final restored = <SettingsFileRestoreMode>[];

  @override
  bool get isSignedIn => false;

  @override
  Future<String> buildFile({
    required SettingsFileLevel level,
    required SettingsFileOrigin origin,
    String? passphrase,
    DateTime? now,
  }) async {
    built.add(level);
    return 'the settings file';
  }

  @override
  Future<SettingsFileReport> restore(SettingsFileContent content, SettingsFileRestoreMode mode) async {
    restored.add(mode);
    return const SettingsFileReport([
      SettingsFileReportItem(SettingsFileSection.settings, '2', SettingsFileOutcome.restored),
    ]);
  }
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

void main() {
  late String clearFile;

  setUpAll(() {
    clearFile = SettingsFile(
      origin: _origin,
      createdAt: DateTime.utc(2026, 11, 22, 9),
      level: SettingsFileLevel.settings,
      content: const SettingsFileContent(settings: {'themeMode': 'dark', 'timelineTilesPerRow': '5'}),
    ).encode();
  });

  group('where the card shows', () {
    ProviderContainer device({required bool television, List<NetworkSource> shares = const []}) {
      final container = ProviderContainer(
        overrides: [
          tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: television, isLowRamDevice: false)),
          settingsFileSharesProvider.overrideWithValue(shares),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('on a phone, a tablet, the Quest, a computer: always, shares or not', () {
      expect(device(television: false).read(settingsFileCardProvider), isTrue);
      expect(device(television: false, shares: [_nas]).read(settingsFileCardProvider), isTrue);
    });

    test('on a TV: only with a share to save on and open from, a TV having no file picker as a rule', () {
      expect(device(television: true).read(settingsFileCardProvider), isFalse);
      expect(device(television: true, shares: [_nas]).read(settingsFileCardProvider), isTrue);
    });

    test('on a TV with a share: the share only, the system picker and save dialog not offered', () {
      expect(device(television: true, shares: [_nas]).read(settingsFileSystemPickerProvider), isFalse);
      expect(device(television: true, shares: [_nas]).read(settingsFileSharesOnlyProvider), isTrue);
      expect(device(television: true).read(settingsFileSystemPickerProvider), isTrue);
      expect(device(television: false, shares: [_nas]).read(settingsFileSystemPickerProvider), isTrue);
    });

    test('a device that said it has no file picker: only with a share', () {
      final alone = device(television: false);
      alone.read(settingsFileNoPickerProvider.notifier).state = true;
      expect(alone.read(settingsFileCardProvider), isFalse);
      expect(alone.read(settingsFileSystemPickerProvider), isFalse);

      final withShare = device(television: false, shares: [_nas]);
      withShare.read(settingsFileNoPickerProvider.notifier).state = true;
      expect(withShare.read(settingsFileCardProvider), isTrue);
    });
  });

  Future<(_FakeIo, _FakeService)> pumpCard(WidgetTester tester, {bool tvMode = false, String? picked}) async {
    tester.view
      ..physicalSize = const Size(1200, 2400)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final io = _FakeIo(picked: picked);
    final service = _FakeService();
    await tester.pumpConsumerWidget(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stands for the item above the card in the Library
          OutlinedButton(key: const Key('above'), autofocus: tvMode, onPressed: () {}, child: const Text('above')),
          const Wrap(children: [SettingsFileCollectionCard()]),
        ],
      ),
      overrides: [
        tvModeProvider.overrideWithValue(tvMode),
        settingsFileSharesProvider.overrideWithValue(const []),
        settingsFileIoProvider.overrideWithValue(io),
        settingsFileServiceProvider.overrideWithValue(service),
        settingsFileOriginProvider.overrideWith((ref) async => _origin),
      ],
    );
    await tester.pumpAndSettle();
    return (io, service);
  }

  final card = find.byKey(const Key('settings_file_card'));
  final exportEntry = find.byKey(const Key('settings_file_export'));
  final importEntry = find.byKey(const Key('settings_file_import'));

  testWidgets('the card: the restore icon and "Settings file", a target of the remote', (tester) async {
    await pumpCard(tester);
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Settings file')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.byIcon(Icons.settings_backup_restore_rounded)), findsOneWidget);
    expect(tester.widget(card), isA<RemoteFocusable>());
  });

  testWidgets('a TV without a share has no card', (tester) async {
    await tester.pumpConsumerWidget(
      const Wrap(children: [SettingsFileCollectionCard()]),
      overrides: [
        tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: true, isLowRamDevice: false)),
        settingsFileSharesProvider.overrideWithValue(const []),
      ],
    );
    expect(card, findsNothing);
  });

  testWidgets('a tap opens the page with the two entries of Settings', (tester) async {
    await pumpCard(tester);
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsFileLibraryPage), findsOneWidget);
    expect(find.text('Save your servers, sources and settings to a file, or restore them from one'), findsOneWidget);
    expect(find.descendant(of: exportEntry, matching: find.text('Export the settings')), findsOneWidget);
    expect(find.descendant(of: importEntry, matching: find.text('Restore settings from a file')), findsOneWidget);
  });

  testWidgets('Export: the existing page, the file made by the service and handed to the share sheet', (tester) async {
    final (io, service) = await pumpCard(tester);
    await tester.tap(card);
    await tester.pumpAndSettle();
    await tester.tap(exportEntry);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsFileExportPage), findsOneWidget);
    // The existing warnings about what the file holds
    expect(find.text('The file stays on this device unless you share or save it.'), findsOneWidget);
    expect(find.textContaining('Never in the file'), findsOneWidget);

    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();

    expect(service.built, [SettingsFileLevel.settings]);
    expect(io.shared.single.$1, 'the settings file');
    expect(io.shared.single.$2, startsWith('immuch360-settings-'));
  });

  testWidgets('Restore: pick, preview, nothing written before Restore, then the report and Done', (tester) async {
    final (io, service) = await pumpCard(tester, picked: clearFile);
    await tester.tap(card);
    await tester.pumpAndSettle();
    await tester.tap(importEntry);
    await tester.pumpAndSettle();

    expect(find.byType(SettingsFileImportPage), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings_file_choose')));
    await tester.pumpAndSettle();

    expect(io.picks, 1);
    // What the file holds and what a restore does, before anything is written
    expect(find.text('Settings only'), findsOneWidget);
    expect(find.text('2 settings'), findsOneWidget);
    expect(find.text('Merge'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);
    expect(service.restored, isEmpty);

    await tester.tap(find.byKey(const Key('settings_file_replace')));
    await tester.pumpAndSettle();
    expect(service.restored, isEmpty, reason: 'choosing Replace writes nothing yet');
    await tester.tap(find.byKey(const Key('settings_file_restore')));
    await tester.pumpAndSettle();

    expect(service.restored, [SettingsFileRestoreMode.replace]);
    expect(find.text('Restored'), findsOneWidget);
    expect(find.text('2 settings'), findsOneWidget);
    // Nothing more to do after a restore without an account: Done, no sign in, no restart
    expect(find.descendant(of: find.byKey(const Key('settings_file_finish')), matching: find.text('Done')), findsOne);
    expect(find.byKey(const Key('settings_file_sign_in')), findsNothing);
  });

  testWidgets('with a remote: the arrow reaches the card, OK opens the page on Export, Back leaves', (tester) async {
    await pumpCard(tester, tvMode: true);
    expect(_focusedIn(find.byKey(const Key('above'))), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusedIn(card), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsFileLibraryPage), findsOneWidget);
    expect(_focusedIn(exportEntry), isTrue, reason: 'the page starts on its first entry');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusedIn(importEntry), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsFileImportPage), findsOneWidget);

    // Back of the remote: the page of the card, then the Library
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsFileImportPage), findsNothing);
    expect(find.byType(SettingsFileLibraryPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsFileLibraryPage), findsNothing);
    expect(card, findsOneWidget);
  });

  testWidgets('with a keyboard on a computer: Tab reaches the card, Enter opens it', (tester) async {
    await pumpCard(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_focusedIn(card), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsFileLibraryPage), findsOneWidget);
  });
}
