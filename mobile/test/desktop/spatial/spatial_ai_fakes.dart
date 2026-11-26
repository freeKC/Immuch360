// The AI of a computer for the tests of "Spatial 2.5D" on a plain photo: the hardware gate over a fake components
// service, the real queue of the conversions with FakeImmersiveEngine and the real writer over a temporary folder, the
// conversion dialog with its originals in a folder of the library, as test/desktop/ai/ui/conversion_dialog_test.dart
// sets them up.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/power_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:path/path.dart' as p;

import '../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../ai/fakes/fake_gpu_probe.dart';
import '../ai/fakes/fake_immersive_engine.dart';
import '../ai/fakes/recording_creator_files.dart';

const _gib = 1 << 30;

/// The files the gate checks, from the states of the fake service
class _GateFiles implements AiComponentFiles {
  _GateFiles(this.service, this.folder);

  final FakeAiComponentsService service;
  final String folder;

  @override
  Future<File?> verifiedFile(AiComponent component) async =>
      stateOf(component) == AiComponentState.installed ? File(p.join(folder, component.id)) : null;

  @override
  AiComponentState stateOf(AiComponent component) => service.statusOf(component).state;
}

/// The originals of the test, by name, in a folder of a library root
class _Originals implements ConversionAssetFiles {
  final byName = <String, LibraryOriginal>{};

  @override
  Future<({OriginalLocation location, ConversionSource source})?> locate(BaseAsset asset) async {
    final original = byName[asset.name];
    return original == null ? null : (location: original, source: LocalFileSource(original.path));
  }
}

/// Every folder on a local disk
class _LocalVolumes implements FolderVolumes {
  @override
  FolderVolume? of(String folder) =>
      FolderVolume(volumeKey: 'local', folderKey: 'local:$folder', mountPoint: '/', isNetwork: false);

  @override
  bool isNetworkMount(String folder) => false;
}

class _Power implements PowerProbe {
  @override
  bool? onBattery() => false;
}

/// See the top of this file. Set what a test changes ([engine], [memory], [held], [service], [enabled], [kinds])
/// before [overrides]
class SpatialAiWorld {
  SpatialAiWorld() {
    root = Directory.systemTemp.createTempSync('spatial_ai');
    photos = p.join(root.path, 'Photos');
    Directory(photos).createSync();
    final support = Directory(p.join(root.path, 'support'))..createSync();
    writer = SafeWriter(
      files: RecordingCreatorFiles(),
      journal: InflightJournal(settingsDirectory: () async => support),
      processId: 4242,
    );
    store = DesktopAiSettingsStore(settingsDirectory: () async => support);
  }

  late final Directory root;

  /// The folder of the library the originals are in
  late final String photos;
  late final SafeWriter writer;
  late final DesktopAiSettingsStore store;

  var service = FakeAiComponentsService(
    states: {for (final component in aiComponentsFor(AiPlatform.linuxX64)) component: AiComponentState.installed},
  );
  var engine = FakeImmersiveEngine();
  var memory = 16 * _gib;
  var enabled = true;
  Set<AiFeatureGroup> held = const {};
  Map<ConversionKind, ConversionEngine> kinds = const {};
  final _originals = _Originals();

  /// A photo [name] of the library, a file of [photos]; its path
  String original(String name) {
    final path = p.join(photos, name);
    File(path).writeAsBytesSync(List.generate(200, (i) => i & 0xff));
    _originals.byName[name] = LibraryOriginal(
      name: name,
      path: path,
      rootId: 'local:$photos',
      rootPath: photos,
      rootIsNetwork: false,
    );
    return path;
  }

  List<Override> overrides() {
    final output = SafeWriterOutput(writer: writer);
    final rules = LibraryPathRules(context: p.context, caseFold: false);
    return [
      aiFeaturesEnabledProvider.overrideWith((ref) => enabled),
      aiComponentsServiceProvider.overrideWithValue(service),
      desktopAiGateProvider.overrideWithValue(
        HardwareGate(
          components: _GateFiles(service, root.path),
          facts: () => AiHardwareFacts(abi: Abi.linuxX64, processors: 8, physicalMemory: memory),
          loadRuntime: (path) async => (version: '1.31.0', error: null),
          catalogue: aiComponents,
          heldGroups: held,
          gpu: FakeGpuProbe.of(FakeGpuReports.rtx4060),
        ),
      ),
      conversionEnginesProvider.overrideWithValue(kinds),
      aiPowerProbeProvider.overrideWithValue(_Power()),
      conversionFocalReaderProvider.overrideWithValue((source) async => null),
      conversionPartialSphereReaderProvider.overrideWithValue((source) async => false),
      conversionFileProbeProvider.overrideWithValue((source, asset) async => null),
      conversionFactsReaderProvider.overrideWith(
        (ref) =>
            (asset) async => const ConversionPhotoFacts(),
      ),
      conversionAssetFilesProvider.overrideWithValue(_originals),
      destinationSessionFactoryProvider.overrideWithValue(
        (jobs, settings) => DestinationSession(
          jobs,
          store: settings,
          writer: writer,
          volumes: _LocalVolumes(),
          downloadFolder: () async => p.join(root.path, 'Downloads'),
          rules: rules,
        ),
      ),
      desktopAiSettingsStoreProvider.overrideWithValue(store),
      aiWriteGuardProvider.overrideWithValue((folder) async => true),
      safeWriterOutputProvider.overrideWithValue(output),
      aiAppVersionProvider.overrideWith((ref) async => '3.4.8'),
      conversionToolsProvider.overrideWithValue(
        ConversionTools(
          engine: engine,
          engines: kinds,
          output: output,
          finder: ExistingVersionFinder(),
          creatorTool: 'Immuch360 Desktop 3.4.8 (linux)',
        ),
      ),
      conversionThumbnailProvider.overrideWithValue((asset) => const ColoredBox(color: Colors.grey)),
    ];
  }

  void dispose() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // A file the writer still holds on Windows: the temporary folder goes with the runner
    }
  }
}
