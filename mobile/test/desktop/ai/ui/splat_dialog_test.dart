// "Make a splat scene (AI)" and its dialog on a computer (plan 2026-11-01, sections 2.1 and 4.1, lot SP7), with fakes:
// the entry of a selection and of the menu of the viewer of a video, absent while the AI features or the splat scenes
// are off, while the version holds their group back or has no engine for them, greyed with the reason of the gate;
// the dialog with what it is, the photos taken and those left out with why, 200 photos at most spread in time, the
// lenses, the refusals before anything runs and the warning of few photos, "What did you film?", the copy for the
// headset and its .ply, the components to install, the answer of the gate and the card it found, the time on this
// computer, the name and the folder, the question of a network folder, the line of the headset for a folder of the
// network or of this computer, the free space of the work files, the question on battery, and what "Make the scene"
// hands to the queue, kept for the next dialog.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/power_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/ai/ui/splat_dialog.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:path/path.dart' as p;

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';
import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/recording_creator_files.dart';
import 'settle_still.dart';

const _gib = 1 << 30;

/// A photo, or a video of [durationMs], taken [minute] minutes after 9:00
LocalAsset _asset(String name, {AssetType type = AssetType.image, int minute = 0, int? durationMs}) => LocalAsset(
  id: 'id-$name',
  name: name,
  type: type,
  createdAt: DateTime(2026, 10, 20, 9).add(Duration(minutes: minute)),
  updatedAt: DateTime(2026, 10, 20, 9),
  width: 4000,
  height: 3000,
  durationMs: durationMs,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
);

LocalAsset _video(String name, Duration duration) =>
    _asset(name, type: AssetType.video, durationMs: duration.inMilliseconds);

/// A component of the splat scenes as the catalogue of the test build holds it, with its size and its sum
AiComponent _complete(AiComponent component) => AiComponent(
  id: component.id,
  name: component.name,
  version: component.version,
  kind: component.kind,
  platforms: component.platforms,
  assetName: component.assetName,
  installPath: component.installPath,
  size: 40 << 20,
  sha256: 'a' * 64,
  compression: component.compression,
  licence: component.licence,
  licenceUrl: component.licenceUrl,
  features: component.features,
  releaseTag: component.releaseTag,
  archiveFiles: [AiArchiveFile(path: 'bin/program.exe', size: 40 << 20, sha256: 'b' * 64, executable: true)],
  minGraphicsMemory: component.minGraphicsMemory,
);

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

/// What the gate of the test answers for a splat scene, until the gate of the splat scenes (lot SP6) is in
enum _SplatAnswer {
  /// Available, the card not named: the answer of the 3D photo, its components installed
  available,

  /// Available on the card of the probe: the answer of the panorama on that card
  availableWithCard,

  /// The answer of the gate of this build for the splat scene itself: its memory, its components, its group
  asIs,
}

/// The gate of the test: [splat] says what it answers for a splat scene; the other features as the real gate does
class _Gate extends HardwareGate {
  _Gate({
    required super.components,
    required super.facts,
    required super.catalogue,
    required super.heldGroups,
    required super.gpu,
    required this.splat,
  }) : super(loadRuntime: (path) async => (version: '1.31.0', error: null));

  final _SplatAnswer Function() splat;

  @override
  Future<AiGateResult> evaluate({AiFeature feature = AiFeature.stereoPhoto, int? graphicsMemory}) {
    if (feature != AiFeature.splatScene) {
      return super.evaluate(feature: feature, graphicsMemory: graphicsMemory);
    }
    return switch (splat()) {
      _SplatAnswer.available => super.evaluate(),
      _SplatAnswer.availableWithCard => super.evaluate(feature: AiFeature.panorama),
      _SplatAnswer.asIs => super.evaluate(feature: feature, graphicsMemory: graphicsMemory),
    };
  }
}

/// The originals of the test, by name, in the folders of a library root, or on the server ([servers]: the file its
/// copy would be)
class _Originals implements ConversionAssetFiles {
  final byName = <String, LibraryOriginal>{};
  final servers = <String, String>{};

  @override
  Future<({OriginalLocation location, ConversionSource source})?> locate(BaseAsset asset) async {
    if (servers[asset.name] case final copy?) {
      return (location: ServerOriginal(name: asset.name), source: LocalFileSource(copy));
    }
    final original = byName[asset.name];
    return original == null ? null : (location: original, source: LocalFileSource(original.path));
  }
}

/// The folder dialog of the test: it answers [answer]
class _FolderPicker implements FilePickers {
  _FolderPicker(this.answer);

  final String answer;

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) async => answer;

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async => null;
}

/// On battery or not, as the test says
class _Power implements PowerProbe {
  bool? battery;

  @override
  bool? onBattery() => battery;
}

/// Every folder on a local disk, but those under [network]
class _Volumes implements FolderVolumes {
  final network = <String>{};

  bool _onNetwork(String folder) => network.any((root) => folder == root || p.isWithin(root, folder));

  @override
  FolderVolume? of(String folder) => FolderVolume(
    volumeKey: _onNetwork(folder) ? 'nas' : 'local',
    folderKey: 'local:$folder',
    mountPoint: '/',
    isNetwork: _onNetwork(folder),
  );

  @override
  bool isNetworkMount(String folder) => false;
}

/// The engine of the splat scenes registered by the test: the dialog never runs it
class _UnusedSplatEngine implements ImmersiveEngine {
  @override
  Future<ImmersiveResult> run(
    ImmersiveJobSpec job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async => const ImmersiveResult.failed(ImmersiveErrorCode.componentsMissing);

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory root;
  late String photos;
  late String nas;
  late String chosen;
  late RecordingCreatorFiles files;
  late SafeWriter writer;
  late DesktopAiSettingsStore store;
  late FakeAiComponentsService service;
  late _Originals originals;
  late Map<String, ConversionPhotoFacts> facts;
  late Map<String, int> focals;
  late Set<String> videos360;
  late bool enabled;
  late int memory;
  late _SplatAnswer splat;
  late GpuReport cards;
  late Set<AiFeatureGroup> held;
  late Map<ConversionKind, ConversionEngine> engines;
  late _Power power;
  late _Volumes volumes;
  late AiFreeSpace? workSpaceShort;
  late List<SplatLaunch> launches;
  late List<String> focalReads;

  final windows = aiComponentsFor(AiPlatform.windowsX64);
  final panorama = aiComponentsFor(AiPlatform.windowsX64, feature: AiFeature.panorama);
  final splatComponents = [
    for (final component in aiComponents)
      if (component.features.contains(AiFeature.splatScene)) _complete(component),
  ];
  final catalogue = [
    for (final component in aiComponents)
      if (!component.features.contains(AiFeature.splatScene)) component,
    ...splatComponents,
  ];
  final rules = LibraryPathRules(context: p.context, caseFold: false);

  setUp(() {
    root = Directory.systemTemp.createTempSync('splat_dialog');
    photos = p.join(root.path, 'Photos', 'salon');
    nas = p.join(root.path, 'nas');
    chosen = p.join(root.path, 'Downloads', 'Immuch360');
    Directory(photos).createSync(recursive: true);
    Directory(nas).createSync();
    final support = Directory(p.join(root.path, 'support'))..createSync();
    files = RecordingCreatorFiles();
    writer = SafeWriter(
      files: files,
      journal: InflightJournal(settingsDirectory: () async => support),
      processId: 4242,
    );
    store = DesktopAiSettingsStore(settingsDirectory: () async => support);
    service = FakeAiComponentsService(
      states: {
        for (final component in [...windows, ...panorama]) component: AiComponentState.installed,
      },
    );
    originals = _Originals();
    facts = {};
    focals = {};
    videos360 = {};
    enabled = true;
    memory = 16 * _gib;
    splat = _SplatAnswer.available;
    cards = FakeGpuReports.rtx4060;
    held = const {};
    engines = {
      ConversionKind.splatScene: ConversionEngine(engine: _UnusedSplatEngine(), settingsKey: (source, turns) => null),
    };
    power = _Power();
    volumes = _Volumes();
    workSpaceShort = null;
    launches = [];
    focalReads = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// The original of [name] in [folder] of a root of the library, on the network with [network], kept online only by
  /// OneDrive with [cloudOnly]
  void original(String name, {String? folder, bool network = false, bool cloudOnly = false}) {
    final where = folder ?? photos;
    Directory(where).createSync(recursive: true);
    final path = p.join(where, name);
    File(path).writeAsBytesSync(List.generate(200, (i) => i & 0xff));
    final rootPath = network ? nas : p.dirname(photos);
    originals.byName[name] = LibraryOriginal(
      name: name,
      path: path,
      rootId: network ? 'net-//nas/photos' : 'local:$rootPath',
      rootPath: rootPath,
      rootIsNetwork: network,
      cloudOnly: cloudOnly,
    );
  }

  /// [count] photos of the folder of the salon, a minute apart, with their originals
  List<LocalAsset> salon(int count, {String? folder, bool network = false, int from = 0}) => [
    for (var index = from; index < from + count; index++) ...[
      () {
        final name = 'IMG_${index.toString().padLeft(4, '0')}.jpg';
        original(name, folder: folder, network: network);
        return _asset(name, minute: index);
      }(),
    ],
  ];

  List<Override> overrides({List<BaseAsset> selected = const []}) {
    final output = SafeWriterOutput(writer: writer);
    return [
      aiFeaturesEnabledProvider.overrideWith((ref) => enabled),
      aiComponentsServiceProvider.overrideWithValue(service),
      desktopAiGateProvider.overrideWithValue(
        _Gate(
          components: _GateFiles(service, root.path),
          facts: () => AiHardwareFacts(abi: Abi.windowsX64, processors: 24, physicalMemory: memory),
          catalogue: catalogue,
          heldGroups: held,
          gpu: FakeGpuProbe.of(cards),
          splat: () => splat,
        ),
      ),
      conversionEnginesProvider.overrideWithValue(engines),
      aiPowerProbeProvider.overrideWithValue(power),
      conversionFocalReaderProvider.overrideWithValue((source) async {
        focalReads.add(source.name);
        return focals[source.name];
      }),
      conversionFactsReaderProvider.overrideWith(
        (ref) =>
            (asset) async => facts[asset.name] ?? const ConversionPhotoFacts(),
      ),
      splatVideo360ReaderProvider.overrideWithValue((video) async => videos360.contains(video.name)),
      splatWorkSpaceShortProvider.overrideWith((ref) async => workSpaceShort),
      conversionAssetFilesProvider.overrideWithValue(originals),
      destinationSessionFactoryProvider.overrideWithValue(
        (jobs, settings) => DestinationSession(
          jobs,
          store: settings,
          writer: writer,
          volumes: volumes,
          downloadFolder: () async => chosen,
          rules: rules,
        ),
      ),
      desktopAiSettingsStoreProvider.overrideWithValue(store),
      aiWriteGuardProvider.overrideWithValue((folder) async => true),
      safeWriterOutputProvider.overrideWithValue(output),
      conversionToolsProvider.overrideWithValue(
        ConversionTools(
          engine: FakeImmersiveEngine(),
          engines: engines,
          output: output,
          finder: ExistingVersionFinder(),
          creatorTool: 'Immuch360 Desktop 3.3.0 (windows)',
        ),
      ),
      conversionThumbnailProvider.overrideWithValue((asset) => const ColoredBox(color: Colors.grey)),
      splatLauncherProvider.overrideWithValue((launch) {
        launches.add(launch);
        return ['splat-${launches.length}'];
      }),
      assetsActionProvider.overrideWith((ref, source) => AssetFilter(selected)),
    ];
  }

  /// Until the screen is still (see settleStill), the calls to the files included
  Future<void> settle(WidgetTester tester, {bool Function()? until}) =>
      settleStill(tester, watched: () => files.calls.length, until: until);

  /// desktop_ai.json as the store gives it once the writes of the page are done (see the test of the conversion
  /// dialog)
  Future<DesktopAiSettings> keptSettings(WidgetTester tester) async {
    DesktopAiSettings? read;
    Object? failure;
    unawaited(store.read().then((settings) => read = settings, onError: (Object error) => failure = error));
    for (var step = 0; step < 500 && read == null && failure == null; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    if (failure != null) {
      fail('desktop_ai.json could not be read: $failure');
    }
    return read ?? fail('desktop_ai.json was not read in time');
  }

  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  Finder start() => find.byKey(const Key('ai_splat_start'));

  bool startEnabled(WidgetTester tester) => tester.widget<FilledButton>(start()).onPressed != null;

  /// Whether the dialog read its selection and checked its folder: Make the scene enabled, or what keeps it greyed on
  /// the screen. The check of a folder writes a real file, which a loaded machine may take a while to do with nothing
  /// changing on the screen meanwhile (see settle_still.dart).
  bool dialogSettled(WidgetTester tester) {
    if (find.byKey(const Key('ai_splat_dialog')).evaluate().isEmpty) {
      return true;
    }
    if (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
      return false;
    }
    const greyed = [
      'ai_splat_refusal',
      'ai_splat_install',
      'ai_splat_gate_refused',
      'ai_splat_work_space',
      'ai_conversion_network_yes',
    ];
    return startEnabled(tester) || greyed.any((key) => find.byKey(Key(key)).evaluate().isNotEmpty);
  }

  /// A page with a button that opens the dialog for [assets], in a window the size of a computer screen
  Future<void> openDialog(WidgetTester tester, List<BaseAsset> assets) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(openSplatDialog(context, ref, assets)),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(selected: assets),
    );
    await tester.tap(find.byKey(const Key('open')));
    await settle(tester, until: () => dialogSettled(tester));
  }

  group('the entry', () {
    Future<void> pumpEntry(WidgetTester tester, {bool menuItem = false, List<BaseAsset>? selected}) async {
      await tester.pumpConsumerWidget(
        Scaffold(
          body: DesktopMakeSplatButton(
            source: menuItem ? ActionSource.viewer : ActionSource.timeline,
            menuItem: menuItem,
          ),
        ),
        overrides: overrides(selected: selected ?? [_asset('IMG_0001.jpg')]),
      );
      await settle(tester);
    }

    Finder entry() => find.byKey(const Key('ai_make_splat'));

    testWidgets('is offered for photos of a selection and for a video, with its name', (tester) async {
      await pumpEntry(tester);
      expect(find.text('Make a splat scene (AI)'), findsOneWidget);
      expect(tester.widget<ImmichColumnButton>(entry()).disabled, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester, selected: [_video('salon.mp4', const Duration(minutes: 1))]);
      expect(entry(), findsOneWidget, reason: 'one video of a selection');

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester, menuItem: true, selected: [_video('salon.mp4', const Duration(minutes: 1))]);
      expect(entry(), findsOneWidget, reason: 'the menu of the viewer of a video');
      expect(tester.widget<MenuItemButton>(find.byType(MenuItemButton)).onPressed, isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester, menuItem: true);
      expect(entry(), findsNothing, reason: 'the viewer of one photo has "Make 3D (AI)"');
    });

    testWidgets('is absent while the AI features are off, and while "Splat scenes" is off', (tester) async {
      enabled = false;
      await pumpEntry(tester);
      expect(entry(), findsNothing);

      enabled = true;
      await tester.runAsync(() => store.write(const DesktopAiSettings(splatScenes: false)));
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester);
      expect(entry(), findsNothing);

      await tester.runAsync(() => store.write(const DesktopAiSettings()));
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester);
      expect(entry(), findsOneWidget, reason: 'on by default');
    });

    testWidgets('is absent while this version holds the splat scenes back, or has no engine for them', (tester) async {
      held = aiHeldFeatureGroups;
      await pumpEntry(tester);
      expect(entry(), findsNothing);

      held = const {};
      engines = const {};
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester);
      expect(entry(), findsNothing);
    });

    testWidgets('is greyed with the reason of the gate: memory, integrated graphics', (tester) async {
      splat = _SplatAnswer.asIs;
      memory = 2 * _gib;
      await pumpEntry(tester);
      expect(tester.widget<Tooltip>(find.byKey(const Key('ai_make_splat_refused'))).message, 'Not enough memory');
      expect(tester.widget<ImmichColumnButton>(entry()).disabled, isTrue);

      memory = 16 * _gib;
      splat = _SplatAnswer.availableWithCard;
      cards = FakeGpuReports.integratedOnly;
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester);
      expect(
        tester.widget<Tooltip>(find.byKey(const Key('ai_make_splat_refused'))).message,
        'Integrated graphics are not supported for splat scenes yet: a dedicated graphics card with Vulkan is needed',
      );
    });

    testWidgets('is offered when only its components are missing: the dialog installs them', (tester) async {
      splat = _SplatAnswer.asIs;
      await pumpEntry(tester);
      expect(entry(), findsOneWidget);
      expect(find.byKey(const Key('ai_make_splat_refused')), findsNothing);
    });

    testWidgets('is absent for a selection without photos or videos', (tester) async {
      await pumpEntry(tester, selected: const []);
      expect(entry(), findsNothing);
    });
  });

  testWidgets('150 photos of one folder: what it is, the photos, the subject, the copy, the time, the name, the folder, '
      'the headset, then Make the scene', (tester) async {
    await openDialog(tester, salon(150));

    expect(find.text('Make a splat scene (AI)'), findsOneWidget);
    expect(
      find.text(
        'A Gaussian splat rebuilt from your photos, to walk through in a Meta Quest 3 or 3S. Only what the photos saw '
        'is rebuilt: places no photo saw stay empty or blurred.',
      ),
      findsOneWidget,
    );
    expect(find.text('A finished conversion does not guarantee a good result.'), findsOneWidget);
    expect(find.text('150 photos, from 1 folder'), findsOneWidget);
    expect(find.byKey(const Key('ai_splat_left_out_sphere360')), findsNothing);
    expect(find.text('What did you film?'), findsOneWidget);
    expect(
      tester.widget<RadioGroup<SplatSubject>>(find.byType(RadioGroup<SplatSubject>)).groupValue,
      SplatSubject.place,
    );
    expect(find.text('A place: a room, a street, a garden'), findsOneWidget);
    expect(find.text('An object, walked around'), findsOneWidget);
    expect(
      find.text('Walk along the walls looking across the room, then through the middle, one step between two photos.'),
      findsOneWidget,
    );
    expect(find.textContaining('Even light, no zoom, nothing moving.'), findsOneWidget);
    expect(find.text('For the headset: up to 150,000 gaussians, about 3.4 MiB (.spz)'), findsOneWidget);
    expect(find.text('Also save a .ply for other 3D apps'), findsOneWidget);
    expect(find.text('The same gaussians, about 33.8 MiB'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('ai_splat_keep_ply'))).value, isFalse);
    expect(
      find.text(
        'About 13 min on this computer: 5 min on the processor to place the photos, 8 min on the graphics card to '
        'train the splat',
      ),
      findsOneWidget,
    );
    expect(find.text('The graphics card stays busy for several minutes; games and videos may stutter'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('ai_splat_name'))).controller!.text, 'salon');
    expect(find.text('salon_splat.spz'), findsOneWidget);
    expect(find.text('Next to the photos'), findsOneWidget);
    expect(find.textContaining(photos), findsOneWidget);
    expect(
      find.text(
        "Your headset cannot see this folder: choose a folder on your NAS, or copy the file to the headset's Download "
        'folder.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ai_splat_install')), findsNothing);
    expect(startEnabled(tester), isTrue);

    await tapIn(tester, start());
    await settle(tester);

    expect(find.byKey(const Key('ai_splat_dialog')), findsNothing);
    expect(find.byKey(const Key('ai_conversions_panel')), findsOneWidget, reason: 'the panel shows the job');
    final launch = launches.single;
    expect(launch.fromVideo, isFalse);
    expect(launch.name, 'salon');
    expect(launch.subject, SplatSubject.place);
    expect(launch.keepPly, isFalse);
    expect(launch.isNetwork, isFalse);
    expect(launch.target.folder, photos);
    expect(launch.target.fileName, 'salon_splat.spz');
    expect(launch.members, hasLength(150));
    expect(
      [for (final member in launch.members) member.asset.name],
      [for (var index = 0; index < 150; index++) 'IMG_${index.toString().padLeft(4, '0')}.jpg'],
    );
    expect(launch.members.first.source, isA<LocalFileSource>());
    expect(launch.label, 'salon (150 photos)');
  });

  testWidgets('the photos left out with their reason, 200 at most spread in time, and the lenses', (tester) async {
    final selection = salon(505);
    facts['PANO_1.jpg'] = const ConversionPhotoFacts(isPanorama: true);
    facts['PANO_2.jpg'] = const ConversionPhotoFacts(isPanorama: true);
    facts['PANO_3.jpg'] = const ConversionPhotoFacts(isRaw360: true);
    facts['salon_3D_LRF_Full_SBS.jpg'] = const ConversionPhotoFacts(isStereo: true);
    for (final name in ['PANO_1.jpg', 'PANO_2.jpg', 'PANO_3.jpg', 'salon_3D_LRF_Full_SBS.jpg']) {
      original(name);
    }
    for (var index = 0; index < 505; index++) {
      focals['IMG_${index.toString().padLeft(4, '0')}.jpg'] = index < 400 ? 26 : 13;
    }
    await openDialog(tester, [
      ...selection,
      _asset('PANO_1.jpg', minute: 1),
      _asset('PANO_2.jpg', minute: 2),
      _asset('PANO_3.jpg', minute: 3),
      _asset('salon_3D_LRF_Full_SBS.jpg', minute: 4),
      _asset('gone.jpg', minute: 5),
    ]);

    expect(find.text('200 photos, from 1 folder'), findsOneWidget);
    expect(find.text('3 photos left out: 360° photos are not taken yet'), findsOneWidget);
    expect(find.text('1 photo left out: Already a 3D photo'), findsOneWidget);
    expect(find.text('1 photo left out: The original cannot be reached any more'), findsOneWidget);
    expect(find.text('200 photos at most: 200 of these 505 are used, spread evenly in time'), findsOneWidget);
    expect(find.text('Photos from 2 lenses (26 mm, 13 mm): one lens gives better results'), findsOneWidget);
    // The time follows the 200 photos: their pairs make the matching longer
    expect(find.textContaining('About 16 min on this computer: 8 min on the processor'), findsOneWidget);
    expect(startEnabled(tester), isTrue);

    await tapIn(tester, start());
    await settle(tester);
    final members = launches.single.members;
    expect(members, hasLength(200));
    expect(members.first.asset.name, 'IMG_0000.jpg');
    expect(members.last.asset.name, 'IMG_0504.jpg');
    expect(launches.single.label, 'salon (200 photos)');
  });

  group('the refusals before anything runs, Make the scene greyed', () {
    Future<void> refused(WidgetTester tester, List<BaseAsset> assets, String sentence) async {
      await openDialog(tester, assets);
      expect(find.text(sentence), findsOneWidget);
      expect(startEnabled(tester), isFalse);
      expect(find.text('What did you film?'), findsNothing, reason: 'nothing to choose for a refused selection');
      expect(find.byKey(const Key('ai_splat_name')), findsNothing);
      await tapIn(tester, find.byKey(const Key('ai_splat_cancel')));
      await settle(tester);
      expect(launches, isEmpty);
    }

    testWidgets('12 photos', (tester) async {
      await refused(
        tester,
        salon(12),
        'A splat scene needs at least 20 photos of the same place, taken from different spots; 50 to 200 is best.',
      );
      expect(find.text('12 photos, from 1 folder'), findsNothing, reason: 'the dialog closed');
    });

    testWidgets('photos and a video together', (tester) async {
      original('salon.mp4');
      await refused(tester, [
        ...salon(30),
        _video('salon.mp4', const Duration(minutes: 1)),
      ], 'Choose photos or one video, not both.');
    });

    testWidgets('two videos', (tester) async {
      original('a.mp4');
      original('b.mp4');
      await refused(tester, [
        _video('a.mp4', const Duration(minutes: 1)),
        _video('b.mp4', const Duration(minutes: 1)),
      ], 'One video at a time.');
    });

    testWidgets('a video of 6 s', (tester) async {
      original('short.mp4');
      await refused(tester, [
        _video('short.mp4', const Duration(seconds: 6)),
      ], 'This video is 6 s long: film the place for 30 s to 2 min, walking slowly.');
    });

    testWidgets('a video of 6 min 10 s', (tester) async {
      original('long.mp4');
      await refused(tester, [
        _video('long.mp4', const Duration(minutes: 6, seconds: 10)),
      ], 'This video is 6 min 10 s long: a splat scene takes 5 min of video at most.');
    });

    testWidgets('a 360° video', (tester) async {
      original('VID_360.mp4');
      videos360.add('VID_360.mp4');
      await refused(tester, [_video('VID_360.mp4', const Duration(minutes: 1))], '360° videos are not taken yet');
    });

    testWidgets('too little space for the work files', (tester) async {
      workSpaceShort = const AiFreeSpace(free: 900 << 20, volume: r'C:\');
      await openDialog(tester, salon(60));
      expect(find.text(r'Not enough free space for the work files: about 2.0 GiB are needed on C:\'), findsOneWidget);
      expect(startEnabled(tester), isFalse);
    });
  });

  testWidgets('a warning, not a refusal, for 30 photos', (tester) async {
    await openDialog(tester, salon(30));
    expect(find.text('Few photos: the scene may have holes. 50 to 200 is better.'), findsOneWidget);
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('a video: its frames, its name, its folder and its time; Make the scene hands it alone', (tester) async {
    original('Salon tour.mp4');
    await openDialog(tester, [_video('Salon tour.mp4', const Duration(minutes: 1, seconds: 51))]);

    expect(
      find.text('1 video, 1 min 51 s: about 150 frames will be taken, the sharpest of each moment'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.byKey(const Key('ai_splat_name'))).controller!.text, 'Salon tour');
    expect(find.text('Next to the video'), findsOneWidget);
    expect(
      find.text(
        'About 8 min on this computer: 3 min on the processor to place the photos, 5 min on the graphics card to '
        'train the splat',
      ),
      findsOneWidget,
    );
    await tapIn(tester, start());
    await settle(tester);
    final launch = launches.single;
    expect(launch.fromVideo, isTrue);
    expect([for (final member in launch.members) member.asset.name], ['Salon tour.mp4']);
    expect(launch.target.fileName, 'Salon tour_splat.spz');
    expect(launch.label, 'Salon tour.mp4');
  });

  testWidgets('a video whose length the library could not read (0): not refused, its frames as for two minutes', (
    tester,
  ) async {
    original('Salon tour.mkv');
    await openDialog(tester, [_asset('Salon tour.mkv', type: AssetType.video, durationMs: 0)]);

    expect(find.byKey(const Key('ai_splat_refusal')), findsNothing);
    expect(find.textContaining('0 s long'), findsNothing);
    expect(find.text('1 video, …: about 150 frames will be taken, the sharpest of each moment'), findsOneWidget);
    expect(startEnabled(tester), isTrue);
    await tapIn(tester, start());
    await settle(tester);
    expect(launches.single.fromVideo, isTrue);
  });

  testWidgets('an object, and the .ply: handed to the queue, kept for the next dialog', (tester) async {
    final selection = salon(60);
    await openDialog(tester, selection);
    await tapIn(tester, find.byKey(const Key('ai_splat_subject_object')));
    await tester.pump();
    expect(
      find.text(
        'Walk around it twice, at its height then from a little above, the object filling about half of the picture. '
        'Do not move it.',
      ),
      findsOneWidget,
    );
    await tapIn(tester, find.byKey(const Key('ai_splat_keep_ply')));
    await tester.pump();
    await tapIn(tester, start());
    await settle(tester);

    expect(launches.single.subject, SplatSubject.object);
    expect(launches.single.keepPly, isTrue);
    final kept = await keptSettings(tester);
    expect(kept.splatSubject, SplatSubject.object);
    expect(kept.splatKeepPly, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await openDialog(tester, selection);
    expect(
      tester.widget<RadioGroup<SplatSubject>>(find.byType(RadioGroup<SplatSubject>)).groupValue,
      SplatSubject.object,
    );
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('ai_splat_keep_ply'))).value, isTrue);
  });

  testWidgets('the name: any name, its file under it; none, Make the scene greyed with why', (tester) async {
    await openDialog(tester, salon(60));
    await tester.enterText(find.byKey(const Key('ai_splat_name')), 'St. Paul');
    await tester.pump();
    expect(find.text('St. Paul_splat.spz'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('ai_splat_name')), '  ');
    await tester.pump();
    expect(find.text('Give the scene a name'), findsOneWidget);
    expect(startEnabled(tester), isFalse);

    await tester.enterText(find.byKey(const Key('ai_splat_name')), 'Room 2.5');
    await tester.pump();
    expect(startEnabled(tester), isTrue);
    await tapIn(tester, start());
    await settle(tester);
    expect(launches.single.name, 'Room 2.5');
    expect(launches.single.target.fileName, 'Room 2.5_splat.spz');
  });

  testWidgets('the components missing: COLMAP and Brush with their licences, Make the scene waits', (tester) async {
    splat = _SplatAnswer.asIs;
    await openDialog(tester, salon(60));

    expect(find.byKey(const Key('ai_splat_install')), findsOneWidget);
    expect(find.byKey(const Key('ai_install_row_colmap-cpu-win-x64')), findsOneWidget);
    expect(find.byKey(const Key('ai_install_row_brush-vulkan-win-x64')), findsOneWidget);
    expect(find.text('Licence: BSD-3-Clause'), findsOneWidget);
    expect(find.text('Licence: Apache-2.0'), findsOneWidget);
    expect(startEnabled(tester), isFalse);
    expect(service.installs, isEmpty, reason: 'nothing is downloaded before Download');
  });

  testWidgets('the gate: its refusal in words, or the card it found', (tester) async {
    splat = _SplatAnswer.availableWithCard;
    cards = FakeGpuReports.integratedOnly;
    await openDialog(tester, salon(60));
    expect(
      find.text(
        'Integrated graphics are not supported for splat scenes yet: a dedicated graphics card with Vulkan is needed',
      ),
      findsOneWidget,
    );
    expect(startEnabled(tester), isFalse);
    await tapIn(tester, find.byKey(const Key('ai_splat_cancel')));
    await settle(tester);

    // The probe of another computer
    cards = FakeGpuReports.rtx4060;
    await tester.pumpWidget(const SizedBox.shrink());
    await openDialog(tester, salon(60));
    expect(
      find.text('NVIDIA GeForce RTX 4060 Laptop GPU, 8.0 GiB, Vulkan 1.4: splat scenes available'),
      findsOneWidget,
    );
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('photos of a network folder: the question first, then the line of the headset for a share', (
    tester,
  ) async {
    await openDialog(tester, salon(60, folder: p.join(nas, 'salon'), network: true));

    expect(
      find.text(
        'Save 3D photos in the folders of this network folder? Immuch360 writes new files there, never the originals.',
      ),
      findsOneWidget,
    );
    expect(files.callsUnder(nas), isEmpty);
    expect(find.byKey(const Key('ai_splat_headset')), findsNothing);
    expect(startEnabled(tester), isFalse);

    await tapIn(tester, find.byKey(const Key('ai_conversion_network_yes')));
    await settle(
      tester,
      until: () => find.byKey(const Key('ai_conversion_network_yes')).evaluate().isEmpty && startEnabled(tester),
    );
    expect(
      find.text(
        "In the headset: open this folder in Network shares, then salon_splat.spz, Explore the splat scene. Turn on "
        "Large splats (experimental) in the headset's settings to see all 150,000 gaussians.",
      ),
      findsOneWidget,
    );
    await tapIn(tester, start());
    await settle(tester);
    expect(launches.single.isNetwork, isTrue);
    expect(launches.single.target.folder, p.join(nas, 'salon'));
  });

  testWidgets('a network folder answered No: the folder of my choice, the headset cannot see it', (tester) async {
    await openDialog(tester, salon(60, folder: p.join(nas, 'salon'), network: true));
    await tapIn(tester, find.byKey(const Key('ai_conversion_network_no')));
    await settle(tester, until: () => startEnabled(tester));
    expect(files.callsUnder(nas), isEmpty);
    expect(find.textContaining(chosen), findsOneWidget);
    expect(find.textContaining('Your headset cannot see this folder'), findsOneWidget);
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('a folder of my choice on the NAS, picked with Change: the line of the headset for a share', (
    tester,
  ) async {
    final picked = p.join(nas, 'splats');
    Directory(picked).createSync();
    volumes.network.add(nas);
    filePickers = _FolderPicker(picked);
    addTearDown(() => filePickers = const SystemFilePickers());
    await openDialog(tester, salon(60));

    await tapIn(tester, find.byKey(const Key('ai_splat_chosen_folder')));
    await settle(tester, until: () => find.byKey(const Key('ai_conversion_change_folder')).evaluate().isNotEmpty);
    await tapIn(tester, find.byKey(const Key('ai_conversion_change_folder')));
    await settle(tester, until: () => startEnabled(tester) && find.textContaining(picked).evaluate().isNotEmpty);
    expect(find.textContaining(picked), findsOneWidget);
    expect(find.textContaining('In the headset: open this folder in Network shares'), findsOneWidget);

    await tapIn(tester, start());
    await settle(tester);
    expect(launches.single.target.folder, picked);
    expect(launches.single.isNetwork, isTrue);
  });

  testWidgets('photos of the server: the folder of my choice, with why', (tester) async {
    final selection = [
      for (var index = 0; index < 40; index++)
        () {
          final name = 'S_$index.jpg';
          originals.servers[name] = p.join(root.path, 'copies', name);
          return _asset(name, minute: index);
        }(),
    ];
    await openDialog(tester, selection);
    expect(find.text('This source cannot be written to: choose a folder'), findsOneWidget);
    expect(find.textContaining(chosen), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('ai_splat_name'))).controller!.text, 'S_0');
    await tapIn(tester, start());
    await settle(tester);
    expect(launches.single.target.folder, chosen);
    expect(launches.single.members, hasLength(40));
  });

  testWidgets('on battery, the question first: Cancel leaves the dialog, Continue makes the scene', (tester) async {
    power.battery = true;
    await openDialog(tester, salon(60));
    await tapIn(tester, start());
    await settle(tester);
    expect(find.text('On battery: a splat scene keeps the graphics card busy for about 8 min'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai_splat_battery_cancel')));
    await settle(tester);
    expect(launches, isEmpty);
    expect(find.byKey(const Key('ai_splat_dialog')), findsOneWidget);

    await tapIn(tester, start());
    await settle(tester);
    await tester.tap(find.byKey(const Key('ai_splat_battery_go')));
    await settle(tester);
    expect(launches, hasLength(1));
    expect(find.byKey(const Key('ai_splat_dialog')), findsNothing);
  });

  testWidgets('the lenses are read for the photos used only, never for a file kept online only', (tester) async {
    final selection = salon(505);
    // OneDrive downloads a file kept online only as soon as its head is read: the first and the last are used, the
    // second is not (200 of 505 spread in time)
    for (final name in ['IMG_0000.jpg', 'IMG_0001.jpg', 'IMG_0504.jpg']) {
      original(name, cloudOnly: true);
    }
    for (var index = 0; index < 505; index++) {
      focals['IMG_${index.toString().padLeft(4, '0')}.jpg'] = index < 400 ? 26 : 13;
    }
    await openDialog(tester, selection);

    expect(find.text('200 photos, from 1 folder'), findsOneWidget);
    expect(find.text('Photos from 2 lenses (26 mm, 13 mm): one lens gives better results'), findsOneWidget);
    expect(focalReads, hasLength(198), reason: 'the 200 photos used, but the two kept online only');
    expect(focalReads, isNot(anyElement(isIn(['IMG_0000.jpg', 'IMG_0001.jpg', 'IMG_0504.jpg']))));
    await tapIn(tester, start());
    await settle(tester);
    final used = {for (final member in launches.single.members) member.asset.name};
    expect(used, containsAll(['IMG_0000.jpg', 'IMG_0504.jpg']), reason: 'kept online only, but used');
    expect(used, containsAll(focalReads));
  });

  group('the room of the work files', () {
    Future<AiFreeSpace?> shortWith(Map<String, AiFreeSpace> drives) async {
      final container = ProviderContainer(
        overrides: [
          aiFreeSpaceProvider.overrideWithValue((folder) async => drives[folder.path]),
          aiComponentsFolderProvider.overrideWithValue(() async => Directory('/components')),
        ],
      );
      addTearDown(container.dispose);
      final listened = container.listen(splatWorkSpaceShortProvider.future, (_, _) {});
      return listened.read();
    }

    test('is looked for on the drive of the temporary files, where the work folder goes, never on that of the '
        'components', () async {
      final temporary = Directory.systemTemp.path;
      const short = AiFreeSpace(free: 900 << 20, volume: r'C:\');
      const roomy = AiFreeSpace(free: 400 * _gib, volume: r'D:\');
      expect((await shortWith({temporary: short, '/components': roomy}))?.volume, r'C:\');
      expect(await shortWith({temporary: const AiFreeSpace(free: 3 * _gib, volume: r'C:\')}), isNull);
      expect(await shortWith(const {}), isNull, reason: 'not known: the work itself says a full drive');
    });
  });
}
