// "AI and 3D" in the This computer settings, with fakes: the switch of the AI features (off, the settings of the
// conversions hide, the components stay listed so that their space can be freed); where the 3D photos go and Change;
// what happens when a 3D photo with the same name exists, and the photos that already have one; the network folders
// allowed, each taken back; the backup of the generated photos, which follows their album; and the hardware line.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/generated_album.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/ai_settings_section.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:path/path.dart' as p;

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';

class _Pickers implements FilePickers {
  String? answer;
  final asked = <String?>[];

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) async {
    asked.add(initialDirectory);
    return answer;
  }

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async => null;
}

class _NoFiles implements AiComponentFiles {
  @override
  Future<File?> verifiedFile(AiComponent component) async => null;

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.notInstalled;
}

void main() {
  late Directory root;
  late DesktopAiSettingsStore store;
  late _Pickers pickers;
  late List<bool> switched;
  late List<bool> backups;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ai_settings_section');
    store = DesktopAiSettingsStore(settingsDirectory: () async => root);
    pickers = _Pickers();
    filePickers = pickers;
    switched = [];
    backups = [];
  });

  tearDown(() {
    filePickers = const SystemFilePickers();
    root.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var step = 0; step < 20; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, {bool enabled = true, bool? backsUp = false}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      const Scaffold(body: SingleChildScrollView(child: DesktopAiSettingsSection())),
      overrides: [
        aiFeaturesEnabledProvider.overrideWith((ref) => enabled),
        aiFeaturesSwitchProvider.overrideWithValue((on) async => switched.add(on)),
        aiPlatformProvider.overrideWithValue(AiPlatform.linuxX64),
        aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
        desktopAiSettingsStoreProvider.overrideWithValue(store),
        aiDefaultFolderProvider.overrideWith((ref) async => '/home/me/Downloads/Immuch360'),
        generatedAlbumBackupProvider.overrideWith((ref) => Stream.value(backsUp)),
        aiBackupGeneratedSetterProvider.overrideWithValue((on) async {
          backups.add(on);
          return true;
        }),
        desktopAiGateProvider.overrideWithValue(
          HardwareGate(
            components: _NoFiles(),
            facts: () => const AiHardwareFacts(abi: Abi.linuxX64, processors: 22, physicalMemory: 32 << 30),
          ),
        ),
        aiGpuNameProvider.overrideWith((ref) async => 'NVIDIA GeForce RTX 4060 Laptop GPU'),
      ],
    );
    await settle(tester);
  }

  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle(tester);
  }

  testWidgets('the switch of the AI features; off, the conversions hide and the components stay listed', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('AI and 3D'), findsOneWidget);
    expect(find.text('AI features'), findsOneWidget);
    expect(find.text('Off: no AI button anywhere, nothing downloaded'), findsOneWidget);
    expect(find.text('AI components'), findsOneWidget);
    expect(find.text('Save to'), findsOneWidget);

    await tapIn(tester, find.byKey(const Key('ai_settings_enabled')));
    expect(switched, [false]);

    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester, enabled: false);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('ai_settings_enabled'))).value, isFalse);
    expect(find.text('AI components'), findsOneWidget);
    expect(find.text('Save to'), findsNothing);
    expect(find.byKey(const Key('ai_settings_backup_generated')), findsNothing);
  });

  testWidgets('where the 3D photos go: next to the original by default, a folder of my choice with Change', (
    tester,
  ) async {
    await pump(tester);
    expect(
      tester.widget<RadioGroup<AiDestination>>(find.byType(RadioGroup<AiDestination>)).groupValue,
      AiDestination.nextToOriginal,
    );
    expect(
      find.text('/home/me/Downloads/Immuch360'),
      findsOneWidget,
      reason: 'the download folder until one is chosen',
    );

    await tapIn(tester, find.byKey(const Key('ai_settings_chosen_folder')));
    expect((await tester.runAsync(store.read))!.destination, AiDestination.folder);

    final picked = p.join(root.path, '3D');
    pickers.answer = picked;
    await tapIn(tester, find.byKey(const Key('ai_settings_change_folder')));
    final kept = (await tester.runAsync(store.read))!;
    expect(kept.folder, picked);
    expect(kept.destination, AiDestination.folder);
    expect(find.text(picked), findsOneWidget);
    expect(pickers.asked, ['/home/me/Downloads/Immuch360']);

    await tapIn(tester, find.byKey(const Key('ai_settings_next_to_original')));
    expect((await tester.runAsync(store.read))!.destination, AiDestination.nextToOriginal);
  });

  testWidgets('a 3D photo with the same name, and the photos that already have a 3D version', (tester) async {
    await pump(tester);
    expect(
      tester.widget<RadioGroup<AiWhenExists>>(find.byType(RadioGroup<AiWhenExists>)).groupValue,
      AiWhenExists.keepBoth,
    );
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('ai_settings_skip_existing'))).value, isTrue);

    await tapIn(tester, find.byKey(const Key('ai_settings_when_exists_replace')));
    await tapIn(tester, find.byKey(const Key('ai_settings_skip_existing')));

    final kept = (await tester.runAsync(store.read))!;
    expect(kept.whenExists, AiWhenExists.replace);
    expect(kept.skipExisting, isFalse);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('ai_settings_skip_existing'))).value, isFalse);
  });

  testWidgets('the network folders allowed are listed, and each can be taken back', (tester) async {
    await tester.runAsync(
      () =>
          store.write(const DesktopAiSettings(networkRootsAllowed: ['net-//nas/photos:/2024', 'mnt-/Volumes/photos'])),
    );
    await pump(tester);
    expect(find.text('Network folders allowed'), findsOneWidget);
    expect(find.text('//nas/photos/2024'), findsOneWidget);
    expect(find.text('/Volumes/photos'), findsOneWidget);

    await tapIn(tester, find.byKey(const ValueKey('ai_settings_network_root_remove_net-//nas/photos:/2024')));
    expect((await tester.runAsync(store.read))!.networkRootsAllowed, ['mnt-/Volumes/photos']);
    expect(find.text('//nas/photos/2024'), findsNothing);
  });

  testWidgets('the backup of the generated 3D photos follows their album; greyed until the album exists', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Also back up generated 3D photos'), findsOneWidget);
    expect(
      find.text('Off: generated 3D photos stay on this computer. Select all in the backup albums turns this on too.'),
      findsOneWidget,
    );
    final tile = find.byKey(const Key('ai_settings_backup_generated'));
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tapIn(tester, tile);
    expect(backups, [true]);

    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester, backsUp: true);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester, backsUp: null);
    expect(tester.widget<SwitchListTile>(tile).onChanged, isNull);
  });

  testWidgets('the hardware line: logical processors, memory, the GPU, which is not used yet', (tester) async {
    await pump(tester);
    expect(find.text('22 logical processors, 32.0 GiB of memory'), findsOneWidget);
    expect(
      find.text('NVIDIA GeForce RTX 4060 Laptop GPU\nGPU acceleration: not yet, the processor is used'),
      findsOneWidget,
    );
  });

  test('a network folder allowed reads as a path', () {
    expect(networkRootLabel('net-//nas/photos'), '//nas/photos');
    expect(networkRootLabel('net-//nas/photos:/2024/summer'), '//nas/photos/2024/summer');
    expect(networkRootLabel('mnt-/Volumes/photos'), '/Volumes/photos');
    expect(networkRootLabel('Z:/photos'), 'Z:/photos');
  });
}
