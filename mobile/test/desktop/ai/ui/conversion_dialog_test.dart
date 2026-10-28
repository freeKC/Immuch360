// "Make 3D (AI)" and its dialog on a computer, with fakes: the entry absent while the AI features are off and greyed
// with its reason when the hardware gate refuses; the dialog that installs the missing components before it offers
// Convert; the question of a network folder, nothing tried there before the yes; the photos skipped and why; the
// choice for a photo that already has a 3D version, handed to the queue and kept; the settings kept, read again; the
// turns of each photo handed to the queue, with the rotation and the edits of Immich said; and the folders of the
// library left alone while the album of the generated photos is not out of the backup. Phase 2: the choice of the type
// once the build makes another one (the fake engine of the scenes), its honesty sentence, components, free space and
// time, the type greyed with its reason, the plan of each photo of a mixed selection, the selection planned again for
// another type, and the type kept for the next dialog. Phase 3: the 360° panorama, not offered while this version holds
// it back, then its sentence, the part invented, "Also make the 3D version" with the components of both, the warning
// of the graphics card, its time, the question on battery, its reasons of the card, and the type asked for by "Make the
// 3D version". The components moved meanwhile, a refusal of one type that greys nothing, and what the user chose kept
// when the type changes.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/scene_glb_export.dart';
import 'package:immich_mobile/desktop/ai/power_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:path/path.dart' as p;

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';
import '../creator/english_texts.dart';
import '../fakes/fake_conversion_engines.dart';
import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_panorama_engine.dart';
import '../fakes/fake_scene_engine.dart';
import '../fakes/fake_stereo_panorama_engine.dart';
import '../fakes/recording_creator_files.dart';
import '../scene/scene_test_support.dart' show exifWithFocal35, insertAfterSoi;
import 'settle_still.dart';

const _gib = 1 << 30;

LocalAsset _photo(String name, {AssetType type = AssetType.image, int width = 4000, int height = 3000}) => LocalAsset(
  id: 'id-$name',
  name: name,
  type: type,
  createdAt: DateTime(2026, 10, 20, 9),
  updatedAt: DateTime(2026, 10, 20, 9),
  width: width,
  height: height,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
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

/// The originals of the test, by name, in the folders of a library root
class _Originals implements ConversionAssetFiles {
  final byName = <String, LibraryOriginal>{};

  @override
  Future<({OriginalLocation location, ConversionSource source})?> locate(BaseAsset asset) async {
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

/// Every folder on a local disk
class _LocalVolumes implements FolderVolumes {
  @override
  FolderVolume? of(String folder) =>
      FolderVolume(volumeKey: 'local', folderKey: 'local:$folder', mountPoint: '/', isNetwork: false);

  @override
  bool isNetworkMount(String folder) => false;
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
  late bool enabled;
  late bool libraryReady;
  late int memory;
  late Abi abi;
  late FakeImmersiveEngine engine;
  late Map<ConversionKind, ConversionEngine> kinds;
  late List<AiComponent> catalogue;
  late Set<AiFeatureGroup> held;
  late GpuReport cards;
  late _Power power;
  late Map<String, int> focals;
  late Set<String> partial;

  final linux = aiComponentsFor(AiPlatform.linuxX64);
  final rules = LibraryPathRules(context: p.context, caseFold: false);

  setUp(() {
    root = Directory.systemTemp.createTempSync('conversion_dialog');
    photos = p.join(root.path, 'Photos');
    nas = p.join(root.path, 'nas');
    chosen = p.join(root.path, 'Downloads', 'Immuch360');
    Directory(photos).createSync();
    Directory(nas).createSync();
    final support = Directory(p.join(root.path, 'support'))..createSync();
    files = RecordingCreatorFiles();
    writer = SafeWriter(
      files: files,
      journal: InflightJournal(settingsDirectory: () async => support),
      processId: 4242,
    );
    store = DesktopAiSettingsStore(settingsDirectory: () async => support);
    service = FakeAiComponentsService(states: {for (final component in linux) component: AiComponentState.installed});
    originals = _Originals();
    facts = {};
    enabled = true;
    libraryReady = true;
    memory = 16 * _gib;
    abi = Abi.linuxX64;
    engine = FakeImmersiveEngine(holdStage: .depth);
    kinds = const {};
    catalogue = aiComponents;
    held = const {AiFeatureGroup.panoramas};
    cards = FakeGpuReports.rtx4060;
    power = _Power();
    focals = {};
    partial = {};
  });

  tearDown(() => root.deleteSync(recursive: true));

  void original(String name, {String? folder, bool network = false}) {
    final where = folder ?? photos;
    final path = p.join(where, name);
    File(path).writeAsBytesSync(List.generate(200, (i) => i & 0xff));
    originals.byName[name] = LibraryOriginal(
      name: name,
      path: path,
      rootId: network ? 'net-//nas/photos' : 'local:$where',
      rootPath: where,
      rootIsNetwork: network,
    );
  }

  List<Override> overrides({List<BaseAsset> selected = const []}) {
    final output = SafeWriterOutput(writer: writer);
    return [
      aiFeaturesEnabledProvider.overrideWith((ref) => enabled),
      aiComponentsServiceProvider.overrideWithValue(service),
      desktopAiGateProvider.overrideWithValue(
        HardwareGate(
          components: _GateFiles(service, root.path),
          facts: () => AiHardwareFacts(abi: abi, processors: 8, physicalMemory: memory),
          loadRuntime: (path) async => (version: '1.31.0', error: null),
          catalogue: catalogue,
          heldGroups: held,
          gpu: FakeGpuProbe.of(cards),
        ),
      ),
      conversionEnginesProvider.overrideWithValue(kinds),
      aiPowerProbeProvider.overrideWithValue(power),
      conversionFocalReaderProvider.overrideWithValue((source) async => focals[source.name]),
      conversionPartialSphereReaderProvider.overrideWithValue((source) async => partial.contains(source.name)),
      conversionFactsReaderProvider.overrideWith(
        (ref) =>
            (asset) async => facts[asset.name] ?? const ConversionPhotoFacts(),
      ),
      conversionAssetFilesProvider.overrideWithValue(originals),
      destinationSessionFactoryProvider.overrideWithValue(
        (jobs, settings) => DestinationSession(
          jobs,
          store: settings,
          writer: writer,
          volumes: _LocalVolumes(),
          downloadFolder: () async => chosen,
          rules: rules,
        ),
      ),
      desktopAiSettingsStoreProvider.overrideWithValue(store),
      aiWriteGuardProvider.overrideWithValue((folder) async => libraryReady),
      safeWriterOutputProvider.overrideWithValue(output),
      aiAppVersionProvider.overrideWith((ref) async => '3.3.0'),
      conversionToolsProvider.overrideWithValue(
        ConversionTools(
          engine: engine,
          engines: kinds,
          output: output,
          finder: ExistingVersionFinder(),
          creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
        ),
      ),
      conversionThumbnailProvider.overrideWithValue((asset) => const ColoredBox(color: Colors.grey)),
      aiFlatPhotoProvider.overrideWith((ref, asset) => true),
      assetsActionProvider.overrideWith((ref, source) => AssetFilter(selected)),
    ];
  }

  /// Until the screen is still (see settleStill), the calls to the files included
  Future<void> settle(WidgetTester tester, {bool Function()? until}) =>
      settleStill(tester, watched: () => files.calls.length, until: until);

  /// desktop_ai.json as the store gives it once the writes of the page are done. Read in the zone of the test and
  /// pumped, never inside runAsync: a read waits for the writes queued before it, whose steps only run when the test
  /// pumps, so a read inside runAsync would wait for ever on a slow machine.
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

  /// Taps [finder] once it is scrolled into view
  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  /// A page with a button that opens the dialog for [assets] (on the type [kind]), in a window the size of a computer
  /// screen
  Future<ProviderContainer> openDialog(WidgetTester tester, List<BaseAsset> assets, {ConversionKind? kind}) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(openConversionDialog(context, ref, assets, kind: kind)),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(const Key('open')));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byKey(const Key('ai_conversion_dialog'))));
  }

  Finder convert() => find.byKey(const Key('ai_conversion_convert'));

  bool convertEnabled(WidgetTester tester) => tester.widget<FilledButton>(convert()).onPressed != null;

  group('the entry', () {
    Future<void> pumpEntry(WidgetTester tester, {required bool menuItem, List<BaseAsset>? selected}) =>
        tester.pumpConsumerWidget(
          Scaffold(
            body: DesktopMakeImmersiveButton(
              source: menuItem ? ActionSource.viewer : ActionSource.timeline,
              menuItem: menuItem,
            ),
          ),
          overrides: overrides(selected: selected ?? [_photo('salon.jpg')]),
        );

    testWidgets('is absent while the AI features are off, in the viewer and in a selection', (tester) async {
      enabled = false;
      await pumpEntry(tester, menuItem: true);
      expect(find.byKey(const Key('ai_make_3d')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester, menuItem: false);
      expect(find.byKey(const Key('ai_make_3d')), findsNothing);
      expect(find.text('Make 3D (AI)'), findsNothing);
    });

    testWidgets('is greyed with its reason when the gate refuses: memory, then the processor', (tester) async {
      memory = 2 * _gib;
      await pumpEntry(tester, menuItem: true);
      await settle(tester);
      expect(find.text('Make 3D (AI)'), findsOneWidget);
      expect(tester.widget<Tooltip>(find.byKey(const Key('ai_make_3d_refused'))).message, 'Not enough memory');
      expect(tester.widget<MenuItemButton>(find.byType(MenuItemButton)).onPressed, isNull);

      memory = 16 * _gib;
      abi = Abi.linuxArm64;
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester, menuItem: false);
      await settle(tester);
      expect(tester.widget<Tooltip>(find.byKey(const Key('ai_make_3d_refused'))).message, 'Not yet on this processor');
    });

    testWidgets('is offered when only the components are missing or damaged: the dialog installs them', (tester) async {
      service = FakeAiComponentsService();
      await pumpEntry(tester, menuItem: false);
      await settle(tester);
      expect(find.text('Make 3D (AI)'), findsOneWidget);
      expect(find.byKey(const Key('ai_make_3d_refused')), findsNothing);

      service = FakeAiComponentsService(states: {for (final component in linux) component: AiComponentState.damaged});
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpEntry(tester, menuItem: false);
      await settle(tester);
      expect(find.text('Make 3D (AI)'), findsOneWidget);
      expect(find.byKey(const Key('ai_make_3d_refused')), findsNothing);
      expect(tester.widget<ImmichColumnButton>(find.byKey(const Key('ai_make_3d'))).disabled, isFalse);
    });

    testWidgets('is absent for a selection of videos only, and for a photo the viewer does not show flat', (
      tester,
    ) async {
      await pumpEntry(tester, menuItem: false, selected: [_photo('clip.mp4', type: AssetType.video)]);
      expect(find.byKey(const Key('ai_make_3d')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpConsumerWidget(
        const Scaffold(body: DesktopMakeImmersiveButton(source: ActionSource.viewer, menuItem: true)),
        overrides: [
          ...overrides(selected: [_photo('sphere.jpg')]),
          aiFlatPhotoProvider.overrideWith((ref, asset) => false),
        ],
      );
      expect(find.byKey(const Key('ai_make_3d')), findsNothing);
    });
  });

  testWidgets('in the viewer, a 360° photo that holds one eye has the entry once the type of its 3D version is in', (
    tester,
  ) async {
    Future<void> pumpSphere() => tester.pumpConsumerWidget(
      const Scaffold(body: DesktopMakeImmersiveButton(source: ActionSource.viewer, menuItem: true)),
      overrides: [
        ...overrides(selected: [_photo('PANO_0001.jpg', width: 8000, height: 4000)]),
        aiFlatPhotoProvider.overrideWith((ref, asset) => false),
        aiMonoPanoramaProvider.overrideWith((ref, asset) => true),
      ],
    );

    await pumpSphere();
    await settle(tester);
    expect(find.byKey(const Key('ai_make_3d')), findsNothing, reason: 'a build without the engine of the 3D version');

    kinds = fakeConversionEngines(stereoPanorama: FakeStereoPanoramaEngine());
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpSphere();
    await settle(tester);
    expect(find.text('Make 3D (AI)'), findsOneWidget);
    expect(tester.widget<MenuItemButton>(find.byType(MenuItemButton)).onPressed, isNotNull);
  });

  testWidgets('with components missing, the dialog shows them and Convert waits until they are installed', (
    tester,
  ) async {
    service = FakeAiComponentsService();
    original('salon.jpg');
    await openDialog(tester, [_photo('salon.jpg')]);

    expect(find.text('Relief estimated by AI from a single photo'), findsOneWidget);
    expect(find.text('A finished conversion does not guarantee a good result.'), findsOneWidget);
    expect(find.byKey(const Key('ai_conversion_install')), findsOneWidget);
    expect(find.text('ONNX Runtime 1.31.0'), findsOneWidget);
    expect(find.text('Depth Anything V2 Small'), findsOneWidget);
    expect(convertEnabled(tester), isFalse);
    expect(service.installs, isEmpty, reason: 'nothing is downloaded before Download');

    await tapIn(tester, find.byKey(const Key('ai_install_download')));
    await settle(tester);

    expect(service.installs, [for (final component in linux) component.id]);
    expect(find.byKey(const Key('ai_conversion_install')), findsNothing);
    expect(convertEnabled(tester), isTrue);
  });

  testWidgets('a network folder: nothing is tried there before the yes; Yes keeps it and checks the folder', (
    tester,
  ) async {
    original('salon.jpg', folder: nas, network: true);
    await openDialog(tester, [_photo('salon.jpg')]);

    expect(
      find.text(
        'Save 3D photos in the folders of this network folder? Immuch360 writes new files there, never the originals.',
      ),
      findsOneWidget,
    );
    expect(files.callsUnder(nas), isEmpty);
    expect(convertEnabled(tester), isFalse);

    await tapIn(tester, find.byKey(const Key('ai_conversion_network_yes')));
    await settle(
      tester,
      until: () => find.byKey(const Key('ai_conversion_network_yes')).evaluate().isEmpty && convertEnabled(tester),
    );

    expect(find.byKey(const Key('ai_conversion_network_yes')), findsNothing);
    expect((await keptSettings(tester)).networkRootsAllowed, ['net-//nas/photos']);
    expect(files.callsUnder(nas).where((call) => call.startsWith('createNew')), hasLength(1));
    expect(convertEnabled(tester), isTrue);

    // Its 3D photo is on the network: never "saved on this computer only"
    final container = ProviderScope.containerOf(tester.element(find.byKey(const Key('ai_conversion_dialog'))));
    await tapIn(tester, convert());
    await settle(tester);
    final job = container.read(conversionQueueProvider).jobs.single;
    expect(container.read(conversionJobInfoProvider)[job.id]!.isNetwork, isTrue);
    engine.release();
    await settle(tester);
  });

  testWidgets('a network folder: No sends the 3D photos to the folder of my choice, the NAS left alone', (
    tester,
  ) async {
    original('salon.jpg', folder: nas, network: true);
    await openDialog(tester, [_photo('salon.jpg')]);

    await tapIn(tester, find.byKey(const Key('ai_conversion_network_no')));
    await settle(tester);

    expect(files.callsUnder(nas), isEmpty);
    expect(find.textContaining(chosen), findsOneWidget);
    expect((await keptSettings(tester)).networkRootsAllowed, isEmpty);
    expect(convertEnabled(tester), isTrue);
  });

  testWidgets('a 3D scene of the library is skipped as a version the app made, in its words', (tester) async {
    original('salon.jpg');
    facts['salon_scene3D.jpg'] = const ConversionPhotoFacts(
      version: (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
    );
    await openDialog(tester, [_photo('salon.jpg'), _photo('salon_scene3D.jpg')]);

    expect(find.text('Skipped (1)'), findsOneWidget);
    expect(find.text('salon_scene3D.jpg: Already an AI version'), findsOneWidget);
  });

  testWidgets('the photos skipped are listed with why, and reach the queue skipped', (tester) async {
    original('salon.jpg');
    facts['sphere.jpg'] = const ConversionPhotoFacts(isPanorama: true);
    facts['trip_180.jpg'] = const ConversionPhotoFacts(isPanorama: true);
    facts['iw3_LRF_Full_SBS.jpg'] = const ConversionPhotoFacts(isStereo: true);
    final container = await openDialog(tester, [
      _photo('salon.jpg'),
      _photo('clip.mp4', type: AssetType.video),
      _photo('sphere.jpg', width: 8000, height: 4000),
      _photo('trip_180.jpg'),
      _photo('iw3_LRF_Full_SBS.jpg'),
      _photo('elsewhere.jpg'),
    ]);

    expect(find.text('Skipped (5)'), findsOneWidget);
    expect(find.text('clip.mp4: Video'), findsOneWidget);
    expect(find.text('sphere.jpg: 360° photo'), findsOneWidget);
    expect(find.text('trip_180.jpg: VR180 photo'), findsOneWidget);
    expect(find.text('iw3_LRF_Full_SBS.jpg: Already a 3D photo'), findsOneWidget);
    expect(find.text('elsewhere.jpg: The original cannot be reached any more'), findsOneWidget);

    await tapIn(tester, convert());
    await settle(tester);

    final jobs = container.read(conversionQueueProvider).jobs;
    expect(jobs.map((job) => job.source.name), [
      'salon.jpg',
      'clip.mp4',
      'sphere.jpg',
      'trip_180.jpg',
      'iw3_LRF_Full_SBS.jpg',
      'elsewhere.jpg',
    ]);
    expect(jobs.skip(1).map((job) => job.skipReason), [
      ConversionSkipReason.video,
      ConversionSkipReason.sphere360,
      ConversionSkipReason.vr180,
      ConversionSkipReason.alreadyStereo,
      ConversionSkipReason.unreachable,
    ]);
    expect(find.byKey(const Key('ai_conversions_panel')), findsOneWidget, reason: 'the panel shows after a launch');
    engine.release();
    await settle(tester);
  });

  testWidgets('"If a 3D version exists": the choice goes to the queue and is kept; the check is the job\'s file', (
    tester,
  ) async {
    original('salon.jpg');
    final container = await openDialog(tester, [_photo('salon.jpg')]);
    expect(
      tester.widget<RadioGroup<ExistingVersionChoice>>(find.byType(RadioGroup<ExistingVersionChoice>)).groupValue,
      ExistingVersionChoice.skip,
      reason: 'skip by default',
    );
    final probe = files.calls.singleWhere((call) => call.startsWith('createNew')).substring('createNew '.length);
    expect(p.dirname(probe), photos, reason: 'next to the original, checked as the dialog opened');

    await tapIn(tester, find.byKey(const Key('ai_conversion_existing_newVersion')));
    await tester.pump();
    await tapIn(tester, convert());
    await settle(tester);

    final job = container.read(conversionQueueProvider).jobs.single;
    expect(job.existing, ExistingVersionChoice.newVersion);
    expect(job.target!.folder, photos);
    expect(job.target!.fileName, 'salon_3D_LRF_Full_SBS.jpg');
    expect((await keptSettings(tester)).skipExisting, isFalse);
    expect(engine.jobs.single.partPath, probe, reason: 'the job writes the partial file of the check');
    engine.release();
    await settle(tester);
    expect(container.read(conversionQueueProvider).jobs.single.state, ConversionState.done);
  });

  testWidgets('the turns of each photo reach the queue and the dialog says so; the edits of Immich are said too', (
    tester,
  ) async {
    original('salon.jpg');
    original('jardin.jpg');
    facts['salon.jpg'] = const ConversionPhotoFacts(quarterTurns: 1);
    facts['jardin.jpg'] = const ConversionPhotoFacts(quarterTurns: 3, serverEdits: true);
    final container = await openDialog(tester, [_photo('salon.jpg'), _photo('jardin.jpg')]);

    expect(find.byKey(const Key('ai_conversion_rotation')), findsOneWidget);
    expect(find.text('The rotation you chose is applied'), findsOneWidget);
    expect(find.text('Edits made in Immich, except the rotation, are not applied'), findsOneWidget);

    await tapIn(tester, convert());
    await settle(tester);
    final jobs = container.read(conversionQueueProvider).jobs;
    expect(jobs.map((job) => job.quarterTurns), [1, 3]);
    final infos = container.read(conversionJobInfoProvider);
    expect((infos[jobs.first.id]!.serverEdits, infos[jobs.last.id]!.serverEdits), (false, true));
    engine.release();
    await settle(tester);
    engine.release();
    await settle(tester);
  });

  testWidgets('a photo neither turned nor edited: no word of rotation nor of edits', (tester) async {
    original('salon.jpg');
    await openDialog(tester, [_photo('salon.jpg')]);
    expect(find.byKey(const Key('ai_conversion_rotation')), findsNothing);
    expect(find.byKey(const Key('ai_conversion_server_edits')), findsNothing);
  });

  testWidgets('the settings kept: the photos that have a version not skipped, and a name taken replaced', (
    tester,
  ) async {
    await tester.runAsync(
      () => store.write(const DesktopAiSettings(skipExisting: false, whenExists: AiWhenExists.replace)),
    );
    original('salon.jpg');
    final container = await openDialog(tester, [_photo('salon.jpg')]);
    expect(
      tester.widget<RadioGroup<ExistingVersionChoice>>(find.byType(RadioGroup<ExistingVersionChoice>)).groupValue,
      ExistingVersionChoice.newVersion,
      reason: 'as kept in desktop_ai.json',
    );

    await tapIn(tester, convert());
    await settle(tester);
    final job = container.read(conversionQueueProvider).jobs.single;
    expect(job.existing, ExistingVersionChoice.newVersion);
    expect(job.whenExists, AiWhenExists.replace);
    engine.release();
    await settle(tester);
  });

  testWidgets('while the album of the generated photos is not out of the backup, the library is left alone', (
    tester,
  ) async {
    libraryReady = false;
    original('salon.jpg');
    await openDialog(tester, [_photo('salon.jpg')]);

    expect(
      find.text('The library is still being read: next to the original will be possible in a moment'),
      findsOneWidget,
    );
    expect(files.callsUnder(photos), isEmpty, reason: 'no partial file in a folder of the library');
    expect(find.textContaining(chosen), findsOneWidget);
    expect(
      tester.widget<RadioListTile<AiDestination>>(find.byKey(const Key('ai_conversion_next_to_original'))).enabled,
      isFalse,
    );
    expect((await keptSettings(tester)).destination, AiDestination.nextToOriginal, reason: 'kept as chosen');
  });

  testWidgets('a hardware refusal is said in the dialog, and Convert stays off', (tester) async {
    memory = 2 * _gib;
    original('salon.jpg');
    await openDialog(tester, [_photo('salon.jpg')]);

    expect(find.byKey(const Key('ai_conversion_refused')), findsOneWidget);
    expect(find.text('Not enough memory'), findsOneWidget);
    expect(convertEnabled(tester), isFalse);
  });

  group('the type of version', () {
    final scene = aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.scene);

    void sceneEngine() => kinds = fakeConversionEngines(scene: FakeSceneEngine());

    ConversionKind chosenType(WidgetTester tester) =>
        tester.widget<RadioGroup<ConversionKind>>(find.byKey(const Key('ai_conversion_types'))).groupValue!;

    /// The partial files the checks of the dialog made, by their final names
    List<String> checked() => [
      for (final call in files.calls)
        if (call.startsWith('createNew ')) p.basename(call.substring('createNew '.length)),
    ];

    testWidgets('a build that makes the 3D photo only: no choice, the dialog of phase 1, with the time of a photo', (
      tester,
    ) async {
      original('salon.jpg');
      await openDialog(tester, [_photo('salon.jpg')]);

      expect(find.byKey(const Key('ai_conversion_types')), findsNothing);
      expect(find.text('Relief estimated by AI from a single photo'), findsOneWidget);
      expect(find.text('About 3 s per photo'), findsOneWidget, reason: 'the timings of the design, 2.8 s');
    });

    testWidgets(
      'the 3D scene: its sentence, its components, its time; Convert makes salon_scene3D.jpg, kept as the type',
      (tester) async {
        sceneEngine();
        original('salon.jpg');
        final container = await openDialog(tester, [_photo('salon.jpg')]);

        expect(chosenType(tester), ConversionKind.sbsFromPhoto, reason: 'the first type while none was chosen');
        expect(find.text('3D photo'), findsOneWidget);
        expect(find.text('3D scene'), findsOneWidget);
        expect(checked().single, startsWith('.salon_3D_LRF_Full_SBS.jpg.'));

        await tapIn(tester, find.byKey(const Key('ai_conversion_type_sceneFromPhoto')));
        await settle(tester);

        expect(chosenType(tester), ConversionKind.sceneFromPhoto);
        expect(find.text('Reconstructed from one photo, explore within its limits'), findsOneWidget);
        expect(find.text('Relief estimated by AI from a single photo'), findsNothing);
        expect(find.text('About 23 s per photo'), findsOneWidget, reason: 'the timings of M2');
        expect(find.byKey(const Key('ai_conversion_install')), findsOneWidget);
        expect(find.text('MoGe-2 ViT-S'), findsOneWidget);
        expect(find.text('LaMa'), findsOneWidget);
        expect(find.text('Depth Anything V2 Small'), findsNothing);
        expect(convertEnabled(tester), isFalse);
        expect(checked().last, startsWith('.salon_scene3D.jpg.'), reason: 'the folder checked for the name of a scene');
        expect(
          Directory(photos).listSync().map((entry) => p.basename(entry.path)).where((name) => name.contains('_SBS')),
          isEmpty,
          reason: 'the partial file of the 3D photo deleted with its session',
        );

        await tapIn(tester, find.byKey(const Key('ai_install_download')));
        await settle(tester);
        expect(service.installs, [
          for (final component in scene)
            if (!linux.contains(component)) component.id,
        ]);
        expect(convertEnabled(tester), isTrue);

        await tapIn(tester, convert());
        await settle(
          tester,
          until: () => container.read(conversionQueueProvider).jobs.single.state == ConversionState.done,
        );
        final job = container.read(conversionQueueProvider).jobs.single;
        expect(job.kind, ConversionKind.sceneFromPhoto);
        expect(job.target!.fileName, 'salon_scene3D.jpg');
        expect(job.state, ConversionState.done);
        expect(File(p.join(photos, 'salon_scene3D.jpg')).existsSync(), isTrue);
        expect((await keptSettings(tester)).lastType, 'sceneFromPhoto');

        // The next dialog starts with the 3D scene
        await tester.pumpWidget(const SizedBox.shrink());
        await openDialog(tester, [_photo('salon.jpg')]);
        expect(chosenType(tester), ConversionKind.sceneFromPhoto);
        expect(find.text('Reconstructed from one photo, explore within its limits'), findsOneWidget);
      },
    );

    testWidgets('"Also save a .glb copy": the scene made gets its .glb next to it, which the panel names', (
      tester,
    ) async {
      sceneEngine();
      for (final component in scene) {
        service.setStatus(component, const AiComponentStatus(AiComponentState.installed));
      }
      await tester.runAsync(() => store.write(const DesktopAiSettings(lastType: 'sceneFromPhoto', exportGlb: true)));
      original('salon.jpg');
      final container = await openDialog(tester, [_photo('salon.jpg')]);

      await tapIn(tester, convert());
      await settle(
        tester,
        until: () {
          final job = container.read(conversionQueueProvider).jobs.single;
          return container.read(sceneGlbCopiesProvider).containsKey(job.id);
        },
      );
      final copy = p.join(photos, 'salon_scene3D.glb');
      expect(File(copy).readAsBytesSync(), FakeSceneTail.fixture.glb);
      expect(
        find.descendant(of: find.byKey(const Key('ai_job_glb')), matching: find.text(copy)),
        findsOneWidget,
        reason: 'the panel shows after the launch',
      );
    });

    testWidgets('a mixed selection: the plan of each photo, planned again for another type', (tester) async {
      sceneEngine();
      for (final component in scene) {
        service.setStatus(component, const AiComponentStatus(AiComponentState.installed));
      }
      original('salon.jpg');
      original('jardin.jpg');
      facts['sphere.jpg'] = const ConversionPhotoFacts(isPanorama: true);
      final container = await openDialog(tester, [
        _photo('salon.jpg'),
        _photo('jardin.jpg'),
        _photo('sphere.jpg', width: 8000, height: 4000),
      ]);

      expect(
        find.descendant(of: find.byKey(const Key('ai_conversion_made')), matching: find.text('3D photo (2)')),
        findsOneWidget,
      );
      expect(find.text('salon.jpg'), findsOneWidget);
      expect(find.text('jardin.jpg'), findsOneWidget);
      expect(find.text('Skipped (1)'), findsOneWidget);
      expect(find.text('sphere.jpg: 360° photo'), findsOneWidget);

      await tapIn(tester, find.byKey(const Key('ai_conversion_type_sceneFromPhoto')));
      await settle(tester);
      expect(find.text('3D scene (2)'), findsOneWidget);
      expect(find.text('sphere.jpg: 360° photo'), findsOneWidget);
      expect(checked().last, matches(RegExp(r'^\.(salon|jardin)_scene3D\.jpg\.')));
      expect(convertEnabled(tester), isTrue);

      await tapIn(tester, convert());
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));
      final jobs = container.read(conversionQueueProvider).jobs;
      expect(jobs.map((job) => (job.kind, job.target?.fileName, job.skipReason)), [
        (ConversionKind.sceneFromPhoto, 'salon_scene3D.jpg', null),
        (ConversionKind.sceneFromPhoto, 'jardin_scene3D.jpg', null),
        (ConversionKind.sceneFromPhoto, null, ConversionSkipReason.sphere360),
      ]);
    });

    testWidgets('the 3D version of a 360° photo: the sphere of a mixed selection, its sentence, PANO_0001_3D.jpg', (
      tester,
    ) async {
      kinds = fakeConversionEngines(scene: FakeSceneEngine(), stereoPanorama: FakeStereoPanoramaEngine());
      original('salon.jpg');
      original('PANO_0001.jpg');
      facts['PANO_0001.jpg'] = const ConversionPhotoFacts(isPanorama: true);
      final container = await openDialog(tester, [
        _photo('salon.jpg'),
        _photo('PANO_0001.jpg', width: 8000, height: 4000),
      ]);

      expect(chosenType(tester), ConversionKind.sbsFromPhoto, reason: 'the first type that takes a photo');
      expect(find.text('3D version of a 360° photo'), findsOneWidget);

      await tapIn(tester, find.byKey(const Key('ai_conversion_type_stereoPanoramaFromPanorama')));
      await settle(tester);

      expect(chosenType(tester), ConversionKind.stereoPanoramaFromPanorama);
      expect(find.text('Relief estimated by AI'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('ai_conversion_made')),
          matching: find.text('3D version of a 360° photo (1)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const Key('ai_conversion_made')), matching: find.text('PANO_0001.jpg')),
        findsOneWidget,
      );
      expect(find.text('salon.jpg: Not a 360° photo'), findsOneWidget, reason: 'the reasons of this type');
      expect(find.byKey(const Key('ai_conversion_install')), findsNothing, reason: 'the components of the 3D photo');
      expect(checked().last, startsWith('.PANO_0001_3D.jpg.'), reason: 'the name already says pano: only _3D');

      await tapIn(tester, convert());
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));
      final jobs = container.read(conversionQueueProvider).jobs;
      expect(jobs.map((job) => (job.kind, job.target?.fileName, job.skipReason, job.state)), [
        (ConversionKind.stereoPanoramaFromPanorama, null, ConversionSkipReason.notSphere, ConversionState.skipped),
        (ConversionKind.stereoPanoramaFromPanorama, 'PANO_0001_3D.jpg', null, ConversionState.done),
      ]);
      expect(File(p.join(photos, 'PANO_0001_3D.jpg')).existsSync(), isTrue);
      expect((await keptSettings(tester)).lastType, 'stereoPanoramaFromPanorama');
    });

    testWidgets('a selection of 360° photos only starts with their 3D version, named _360_3D when the name is plain', (
      tester,
    ) async {
      kinds = fakeConversionEngines(scene: FakeSceneEngine(), stereoPanorama: FakeStereoPanoramaEngine());
      original('beach.jpg');
      facts['beach.jpg'] = const ConversionPhotoFacts(isPanorama: true);
      await openDialog(tester, [_photo('beach.jpg', width: 6000, height: 3000)]);

      expect(chosenType(tester), ConversionKind.stereoPanoramaFromPanorama);
      expect(find.text('Relief estimated by AI'), findsOneWidget);
      expect(checked().single, startsWith('.beach_360_3D.jpg.'));
      expect(convertEnabled(tester), isTrue);
    });

    testWidgets('a phone panorama of part of the sphere in a 2:1 frame is no sphere to go around: skipped', (
      tester,
    ) async {
      kinds = fakeConversionEngines(stereoPanorama: FakeStereoPanoramaEngine());
      original('beach.jpg');
      original('PANO_0002.jpg');
      facts['beach.jpg'] = const ConversionPhotoFacts(isPanorama: true);
      facts['PANO_0002.jpg'] = const ConversionPhotoFacts(isPanorama: true);
      partial.add('PANO_0002.jpg');
      await openDialog(tester, [
        _photo('beach.jpg', width: 6000, height: 3000),
        _photo('PANO_0002.jpg', width: 8000, height: 4000),
      ]);

      expect(chosenType(tester), ConversionKind.stereoPanoramaFromPanorama);
      expect(find.text('PANO_0002.jpg: Not a 360° photo'), findsOneWidget);
      expect(checked().single, startsWith('.beach_360_3D.jpg.'));
    });

    testWidgets('while the AI components are moved, Convert waits and says why; the gate is read again after', (
      tester,
    ) async {
      original('salon.jpg');
      await openDialog(tester, [_photo('salon.jpg')]);
      expect(convertEnabled(tester), isTrue);

      service.moving = true;
      await settle(tester);
      expect(find.text('Moving the AI components: Convert waits for the end'), findsOneWidget);
      expect(find.byKey(const Key('ai_conversion_install')), findsNothing, reason: 'nothing to download meanwhile');
      expect(convertEnabled(tester), isFalse);

      service.moving = false;
      await settle(tester);
      expect(find.byKey(const Key('ai_conversion_moving')), findsNothing);
      expect(convertEnabled(tester), isTrue);
    });

    testWidgets('the entry stays offered when the gate refuses one type only, greyed when it refuses them all', (
      tester,
    ) async {
      sceneEngine();
      // A component of the scenes this version does not have whole: the scene is refused, the 3D photo is not
      catalogue = [
        for (final component in aiComponents)
          if (component.id == lamaInpaintComponent.id)
            AiComponent(
              id: component.id,
              name: component.name,
              version: component.version,
              kind: component.kind,
              platforms: component.platforms,
              assetName: component.assetName,
              installPath: component.installPath,
              size: component.size,
              sha256: null,
              compression: component.compression,
              licence: component.licence,
              licenceUrl: component.licenceUrl,
              features: component.features,
            )
          else
            component,
      ];
      await tester.pumpConsumerWidget(
        const Scaffold(body: DesktopMakeImmersiveButton(source: ActionSource.timeline)),
        overrides: overrides(selected: [_photo('salon.jpg')]),
      );
      await settle(tester);
      expect(find.byKey(const Key('ai_make_3d_refused')), findsNothing);
      expect(tester.widget<ImmichColumnButton>(find.byKey(const Key('ai_make_3d'))).disabled, isFalse);

      memory = 2 * _gib;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpConsumerWidget(
        const Scaffold(body: DesktopMakeImmersiveButton(source: ActionSource.timeline)),
        overrides: overrides(selected: [_photo('salon.jpg')]),
      );
      await settle(tester);
      expect(tester.widget<ImmichColumnButton>(find.byKey(const Key('ai_make_3d'))).disabled, isTrue);
    });

    testWidgets('another type keeps what the user chose: a folder of my choice, the folder picked, a No', (
      tester,
    ) async {
      sceneEngine();
      for (final component in scene) {
        service.setStatus(component, const AiComponentStatus(AiComponentState.installed));
      }
      original('salon.jpg');
      original('jardin.jpg', folder: nas, network: true);
      final picked = p.join(root.path, 'Picked');
      Directory(picked).createSync();
      filePickers = _FolderPicker(picked);
      addTearDown(() => filePickers = const SystemFilePickers());
      final container = await openDialog(tester, [_photo('salon.jpg'), _photo('jardin.jpg')]);

      await tapIn(tester, find.byKey(const Key('ai_conversion_network_no')));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('ai_conversion_chosen_folder')));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('ai_conversion_change_folder')));
      await settle(tester);

      await tapIn(tester, find.byKey(const Key('ai_conversion_type_sceneFromPhoto')));
      await settle(tester);
      expect(
        tester.widget<RadioGroup<AiDestination>>(find.byType(RadioGroup<AiDestination>)).groupValue,
        AiDestination.folder,
      );
      expect(find.byKey(const Key('ai_conversion_network_no')), findsNothing, reason: 'the No answered again');
      expect(files.callsUnder(nas), isEmpty);
      expect(convertEnabled(tester), isTrue);

      await tapIn(tester, convert());
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));
      final jobs = container.read(conversionQueueProvider).jobs;
      expect(jobs.map((job) => (job.kind, job.target?.folder, job.target?.fileName)), [
        (ConversionKind.sceneFromPhoto, picked, 'salon_scene3D.jpg'),
        (ConversionKind.sceneFromPhoto, picked, 'jardin_scene3D.jpg'),
      ]);
    });

    testWidgets('a type the gate refuses stays listed, greyed with its reason', (tester) async {
      sceneEngine();
      // A component of the scenes this version does not have whole
      catalogue = [
        for (final component in aiComponents)
          if (component.id == lamaInpaintComponent.id)
            AiComponent(
              id: component.id,
              name: component.name,
              version: component.version,
              kind: component.kind,
              platforms: component.platforms,
              assetName: component.assetName,
              installPath: component.installPath,
              size: component.size,
              sha256: null,
              compression: component.compression,
              licence: component.licence,
              licenceUrl: component.licenceUrl,
              features: component.features,
            )
          else
            component,
      ];
      original('salon.jpg');
      await openDialog(tester, [_photo('salon.jpg')]);

      final tile = tester.widget<RadioListTile<ConversionKind>>(
        find.byKey(const Key('ai_conversion_type_sceneFromPhoto')),
      );
      expect(tile.enabled, isFalse);
      expect(
        find.descendant(
          of: find.byKey(const Key('ai_conversion_type_sceneFromPhoto')),
          matching: find.text('Not in this version of the app'),
        ),
        findsOneWidget,
      );
      expect(chosenType(tester), ConversionKind.sbsFromPhoto);
      expect(convertEnabled(tester), isTrue, reason: 'the 3D photo runs');
    });

    testWidgets(
      'the components to install: the free space of their drive, or what it lacks, or a drive not connected',
      (tester) async {
        sceneEngine();
        await tester.runAsync(() => store.write(const DesktopAiSettings(lastType: 'sceneFromPhoto')));
        original('salon.jpg');
        Future<void> openWith(AiFreeSpace space) async {
          tester.view.physicalSize = const Size(1600, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpConsumerWidget(
            Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  key: const Key('open'),
                  onPressed: () => unawaited(openConversionDialog(context, ref, [_photo('salon.jpg')])),
                  child: const Text('open'),
                ),
              ),
            ),
            overrides: [
              ...overrides(),
              aiFreeSpaceProvider.overrideWithValue((folder) async => space),
              aiComponentsFolderProvider.overrideWithValue(() async => Directory(p.join(root.path, 'components'))),
            ],
          );
          await tester.tap(find.byKey(const Key('open')));
          await settle(tester);
        }

        await openWith(const AiFreeSpace(free: 50 * _gib, volume: 'C:'));
        expect(find.text('50.0 GiB free on C:'), findsOneWidget);

        service.shortage = const AiSpaceShortage(needed: 2 * _gib, free: _gib ~/ 2, volume: 'C:');
        await tester.pumpWidget(const SizedBox.shrink());
        await openWith(const AiFreeSpace(free: _gib ~/ 2, volume: 'C:'));
        expect(
          find.text(
            'Not enough space on C: (2.0 GiB needed, 512.0 MiB free). Move the AI components to another drive in the '
            'settings.',
          ),
          findsOneWidget,
        );

        final unplugged = p.join(root.path, 'drive-e', 'Immuch360', 'ai-components');
        await tester.runAsync(() => store.update((kept) => kept.copyWith(componentsFolder: () => unplugged)));
        await tester.pumpWidget(const SizedBox.shrink());
        await openWith(const AiFreeSpace(free: 50 * _gib, volume: 'E:'));
        expect(find.text('The folder of the AI components cannot be reached: $unplugged'), findsOneWidget);
      },
    );
  });

  group('the 360° panorama', () {
    final panoramaComponents = aiComponentsFor(
      AiPlatform.linuxX64,
      feature: AiFeature.panorama,
      graphicsMemory: rtx4060Laptop.localMemory,
    );
    final stereoComponents = aiComponentsFor(AiPlatform.linuxX64, feature: AiFeature.stereoPanorama);

    ConversionKind chosenType(WidgetTester tester) =>
        tester.widget<RadioGroup<ConversionKind>>(find.byKey(const Key('ai_conversion_types'))).groupValue!;

    bool alsoStereo(WidgetTester tester) =>
        tester.widget<CheckboxListTile>(find.byKey(const Key('ai_conversion_also_stereo'))).value!;

    /// The engines of the panorama and of its 3D version, the panoramas no longer held back
    void panoramas() {
      kinds = fakeConversionEngines(panorama: FakePanoramaEngine(), stereoPanorama: FakeStereoPanoramaEngine());
      held = const {};
    }

    void installed(Iterable<AiComponent> components) {
      for (final component in components) {
        service.setStatus(component, const AiComponentStatus(AiComponentState.installed));
      }
    }

    /// The partial files the checks of the dialog made, by their final names
    List<String> checkedNames() => [
      for (final call in files.calls)
        if (call.startsWith('createNew ')) p.basename(call.substring('createNew '.length)),
    ];

    Future<void> choosePanorama(WidgetTester tester) async {
      await tapIn(tester, find.byKey(const Key('ai_conversion_type_panoramaFromPhoto')));
      await settle(tester);
    }

    testWidgets('held back by this version, it is not listed, whatever the engine', (tester) async {
      kinds = fakeConversionEngines(panorama: FakePanoramaEngine(), stereoPanorama: FakeStereoPanoramaEngine());
      original('salon.jpg');
      await openDialog(tester, [_photo('salon.jpg')]);

      expect(find.byKey(const Key('ai_conversion_type_panoramaFromPhoto')), findsNothing);
      expect(find.text('360° panorama'), findsNothing);
      expect(find.byKey(const Key('ai_conversion_type_stereoPanoramaFromPanorama')), findsOneWidget);
    });

    testWidgets(
      'its sentence, the part invented, the 3D version checked, the warning, the time; Convert makes both, kept',
      (tester) async {
        panoramas();
        installed([...panoramaComponents, ...stereoComponents]);
        original('salon.jpg');
        final container = await openDialog(tester, [_photo('salon.jpg')]);
        expect(find.text('360° panorama'), findsOneWidget);

        await choosePanorama(tester);
        expect(chosenType(tester), ConversionKind.panoramaFromPhoto);
        expect(find.text("Generated by AI beyond the photo's edges"), findsOneWidget);
        expect(find.text('About 92% of this panorama will be invented by AI'), findsOneWidget);
        expect(
          find.text('The graphics card stays busy for several minutes; games and videos may stutter'),
          findsOneWidget,
        );
        expect(find.text('About 4 min per photo on this graphics card'), findsOneWidget, reason: 'the timings of M3');
        expect(find.text('Also make the 3D version'), findsOneWidget);
        expect(alsoStereo(tester), isTrue, reason: 'checked by default');
        expect(find.text('If a version exists'), findsOneWidget);
        expect(find.text('Skip photos that already have one'), findsOneWidget);
        expect(find.byKey(const Key('ai_conversion_install')), findsNothing);
        expect(convertEnabled(tester), isTrue);

        await tapIn(tester, convert());
        await settle(
          tester,
          until: () {
            final jobs = container.read(conversionQueueProvider).jobs;
            return jobs.length == 2 && jobs.every((job) => job.state.isEnded);
          },
        );
        final jobs = container.read(conversionQueueProvider).jobs;
        expect(jobs.map((job) => (job.kind, job.target?.fileName, job.state)), [
          (ConversionKind.panoramaFromPhoto, 'salon_360.jpg', ConversionState.done),
          (ConversionKind.stereoPanoramaFromPanorama, 'salon_360_3D.jpg', ConversionState.done),
        ]);
        expect(jobs.last.parentId, jobs.first.id);
        final kept = await keptSettings(tester);
        expect(kept.lastType, 'panoramaFromPhoto');
        expect(kept.alsoStereoPanorama, isTrue);
      },
    );

    testWidgets('the 3D version unchecked: its components no longer asked, one job, the choice kept', (tester) async {
      panoramas();
      service = FakeAiComponentsService();
      await tester.runAsync(() => store.write(const DesktopAiSettings(lastType: 'panoramaFromPhoto')));
      original('salon.jpg');
      final container = await openDialog(tester, [_photo('salon.jpg')]);

      expect(chosenType(tester), ConversionKind.panoramaFromPhoto);
      final install = find.byKey(const Key('ai_conversion_install'));
      expect(find.descendant(of: install, matching: find.text('FLUX.2 klein base 4B (Q4_0)')), findsOneWidget);
      expect(find.descendant(of: install, matching: find.text('360 ERP Outpaint LoRA')), findsOneWidget);
      expect(
        find.descendant(of: install, matching: find.text('Depth Anything V2 Small')),
        findsOneWidget,
        reason: 'the model of the 3D version chained after it',
      );
      expect(convertEnabled(tester), isFalse);

      await tapIn(tester, find.byKey(const Key('ai_conversion_also_stereo')));
      await settle(tester);
      expect(alsoStereo(tester), isFalse);
      expect(find.descendant(of: install, matching: find.text('Depth Anything V2 Small')), findsNothing);
      expect(find.descendant(of: install, matching: find.text('FLUX.2 klein base 4B (Q4_0)')), findsOneWidget);

      await tapIn(tester, find.byKey(const Key('ai_install_download')));
      await settle(tester);
      expect(service.installs, [for (final component in panoramaComponents) component.id]);
      expect(convertEnabled(tester), isTrue);

      await tapIn(tester, convert());
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));
      final jobs = container.read(conversionQueueProvider).jobs;
      expect(jobs.map((job) => (job.kind, job.target?.fileName)), [
        (ConversionKind.panoramaFromPhoto, 'salon_360.jpg'),
      ]);
      expect((await keptSettings(tester)).alsoStereoPanorama, isFalse);
    });

    testWidgets('on battery, Convert asks first: Cancel queues nothing, Convert goes', (tester) async {
      panoramas();
      installed([...panoramaComponents, ...stereoComponents]);
      await tester.runAsync(() => store.write(const DesktopAiSettings(lastType: 'panoramaFromPhoto')));
      power.battery = true;
      original('salon.jpg');
      final container = await openDialog(tester, [_photo('salon.jpg')]);

      await tapIn(tester, convert());
      await tester.pumpAndSettle();
      expect(find.text('On battery: a panorama keeps the graphics card busy for several minutes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ai_conversion_battery_cancel')));
      await settle(tester);
      expect(container.read(conversionQueueProvider).jobs, isEmpty);
      expect(find.byKey(const Key('ai_conversion_dialog')), findsOneWidget, reason: 'the dialog stays');
      expect(convertEnabled(tester), isTrue);

      await tapIn(tester, convert());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ai_conversion_battery_go')));
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));
      expect(container.read(conversionQueueProvider).jobs.map((job) => job.kind), [
        ConversionKind.panoramaFromPhoto,
        ConversionKind.stereoPanoramaFromPanorama,
      ]);
    });

    testWidgets('on the mains, or when the system does not tell, nothing is asked; nor for another type', (
      tester,
    ) async {
      panoramas();
      installed([...panoramaComponents, ...stereoComponents]);
      power.battery = false;
      original('salon.jpg');
      final container = await openDialog(tester, [_photo('salon.jpg')]);
      await choosePanorama(tester);
      await tapIn(tester, convert());
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.isNotEmpty);
      expect(find.byKey(const Key('ai_conversion_battery')), findsNothing);

      power.battery = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await openDialog(tester, [_photo('salon.jpg')], kind: ConversionKind.sbsFromPhoto);
      expect(chosenType(tester), ConversionKind.sbsFromPhoto);
      await tapIn(tester, convert());
      await settle(tester);
      expect(
        find.byKey(const Key('ai_conversion_battery')),
        findsNothing,
        reason: 'the 3D photo runs on the processor',
      );
      engine.release();
      await settle(tester);
    });

    testWidgets('greyed with the reason of the card: integrated graphics, a card too small, a Mac', (tester) async {
      panoramas();
      original('salon.jpg');
      Finder reason(String text) =>
          find.descendant(of: find.byKey(const Key('ai_conversion_type_panoramaFromPhoto')), matching: find.text(text));
      bool enabled() => tester
          .widget<RadioListTile<ConversionKind>>(find.byKey(const Key('ai_conversion_type_panoramaFromPhoto')))
          .enabled!;

      cards = FakeGpuReports.integratedOnly;
      await openDialog(tester, [_photo('salon.jpg')]);
      expect(enabled(), isFalse);
      expect(reason("Integrated graphics share the computer's memory: too slow for panoramas"), findsOneWidget);

      cards = FakeGpuReports.sixGigabytes;
      await tester.pumpWidget(const SizedBox.shrink());
      await openDialog(tester, [_photo('salon.jpg')]);
      expect(enabled(), isFalse);
      expect(reason('The graphics card has 6.0 GiB of memory, 360° panoramas need 7.5 GiB'), findsOneWidget);

      abi = Abi.macosArm64;
      cards = FakeGpuReports.mac;
      await tester.pumpWidget(const SizedBox.shrink());
      await openDialog(tester, [_photo('salon.jpg')]);
      expect(enabled(), isFalse);
      expect(reason('Not yet on Mac'), findsOneWidget);
    });

    testWidgets('the part invented follows the focal length the photo tells, the largest of a selection', (
      tester,
    ) async {
      panoramas();
      installed([...panoramaComponents, ...stereoComponents]);
      await tester.runAsync(() => store.write(const DesktopAiSettings(lastType: 'panoramaFromPhoto')));
      original('tele.jpg');
      focals['tele.jpg'] = 85;
      await openDialog(tester, [_photo('tele.jpg')]);
      expect(find.text('About 99% of this panorama will be invented by AI'), findsOneWidget);

      original('wide.jpg');
      focals['wide.jpg'] = 13;
      await tester.pumpWidget(const SizedBox.shrink());
      await openDialog(tester, [_photo('wide.jpg')]);
      expect(find.text('About 81% of this panorama will be invented by AI'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await openDialog(tester, [_photo('wide.jpg'), _photo('tele.jpg')]);
      expect(
        find.text('About 99% of this panorama will be invented by AI'),
        findsOneWidget,
        reason: 'never less than a panorama of the selection invents',
      );
    });

    testWidgets('"Make the 3D version" opens the dialog on the 3D version of the panorama', (tester) async {
      panoramas();
      original('salon_360.jpg');
      facts['salon_360.jpg'] = const ConversionPhotoFacts(
        isPanorama: true,
        version: (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360),
      );
      await tester.runAsync(() => store.write(const DesktopAiSettings(lastType: 'panoramaFromPhoto')));
      await openDialog(tester, [
        _photo('salon_360.jpg', width: 6144, height: 3072),
      ], kind: ConversionKind.stereoPanoramaFromPanorama);

      expect(chosenType(tester), ConversionKind.stereoPanoramaFromPanorama);
      expect(
        tester.widget<Text>(find.byKey(const Key('ai_conversion_honesty'))).data,
        "Generated by AI beyond the photo's edges",
        reason: 'the 3D version of a generated panorama is said as generated, as its file and the panel say it',
      );
      expect(find.text('Relief estimated by AI'), findsNothing);
      expect(find.byKey(const Key('ai_conversion_also_stereo')), findsNothing);
      expect(find.byKey(const Key('ai_conversion_gpu_busy')), findsNothing);
      expect(checkedNames().last, startsWith('.salon_360_3D.jpg.'));

      final container = ProviderScope.containerOf(tester.element(find.byKey(const Key('ai_conversion_dialog'))));
      await tapIn(tester, convert());
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));
      final job = container.read(conversionQueueProvider).jobs.single;
      expect(job.kind, ConversionKind.stereoPanoramaFromPanorama);
      expect(
        container.read(conversionJobInfoProvider)[job.id]!.generatedSource,
        isTrue,
        reason: 'the panel says it under the sentence of the panorama',
      );
    });

    test('the part invented: the solid angle of the photo on the sphere, a phone camera when the EXIF is silent', () {
      expect(panoramaInventedShare(width: 4000, height: 3000, focal35: 26), closeTo(0.9203816426076312, 1e-12));
      expect(panoramaInventedShare(width: 4000, height: 3000), closeTo(0.9203816426076312, 1e-12));
      expect(panoramaInventedShare(), closeTo(0.9203816426076312, 1e-12), reason: 'a frame not known is 4:3');
      expect(panoramaInventedShare(width: 3000, height: 4000, focal35: 85), closeTo(0.9904103030274461, 1e-12));
      expect(panoramaInventedShare(width: 6000, height: 4000, focal35: 50), closeTo(0.9748083588193973, 1e-12));
      expect(panoramaInventedShare(width: 4000, height: 3000, focal35: 0), closeTo(0.9203816426076312, 1e-12));
    });

    test('the focal length read from the EXIF of a JPEG of this computer; nothing from another file', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final read = container.read(conversionFocalReaderProvider);
      final jpeg = insertAfterSoi(img.encodeJpg(img.Image(width: 8, height: 6)), exifWithFocal35(85));
      final withFocal = File(p.join(root.path, 'tele.jpg'))..writeAsBytesSync(jpeg);
      final without = File(p.join(root.path, 'plain.jpg'))
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 8, height: 6)));
      final notJpeg = File(p.join(root.path, 'noise.jpg'))..writeAsBytesSync(List.generate(300, (i) => i & 0xff));
      expect(await read(LocalFileSource(withFocal.path)), 85);
      expect(await read(LocalFileSource(without.path)), isNull);
      expect(await read(LocalFileSource(notJpeg.path)), isNull);
      expect(await read(LocalFileSource(p.join(root.path, 'gone.jpg'))), isNull);
    });

    test(
      'a GPano crop of part of the sphere read from a file of this computer; a whole sphere or no crop is not',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final read = container.read(conversionPartialSphereReaderProvider);
        File jpegWith(String name, String gpano) {
          final xmp =
              '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
              '<rdf:Description xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" '
              'GPano:ProjectionType="equirectangular" $gpano/></rdf:RDF></x:xmpmeta>';
          return File(p.join(root.path, name))..writeAsBytesSync([...xmp.codeUnits, ...List.filled(64, 0)]);
        }

        final half = jpegWith(
          'half.jpg',
          'GPano:FullPanoWidthPixels="8000" GPano:FullPanoHeightPixels="4000" GPano:CroppedAreaImageWidthPixels="4000" '
              'GPano:CroppedAreaImageHeightPixels="2000" GPano:CroppedAreaLeftPixels="2000" GPano:CroppedAreaTopPixels="1000"',
        );
        final whole = jpegWith(
          'whole.jpg',
          'GPano:FullPanoWidthPixels="8000" GPano:FullPanoHeightPixels="4000" GPano:CroppedAreaImageWidthPixels="8000" '
              'GPano:CroppedAreaImageHeightPixels="4000" GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="0"',
        );
        final bare = jpegWith('bare.jpg', '');
        expect(await read(LocalFileSource(half.path)), isTrue);
        expect(await read(LocalFileSource(whole.path)), isFalse);
        expect(await read(LocalFileSource(bare.path)), isFalse);
        expect(await read(LocalFileSource(p.join(root.path, 'gone.jpg'))), isFalse);
      },
    );
  });

  test('each job of a batch comes from its request, a 3D version chained after its panorama from the same one', () {
    ConversionJob job(String id, {String? parent}) => ConversionJob(
      id: id,
      source: LocalFileSource('/photos/$id.jpg'),
      batchIndex: 1,
      batchSize: 2,
      parentId: parent,
    );
    final queue = ConversionQueueState(
      jobs: [
        job('a'),
        job('a3d', parent: 'a'),
        job('b'),
        job('b3d', parent: 'b'),
        job('c'),
      ],
    );
    expect(requestIndexOfJobs(['a', 'a3d', 'b', 'b3d', 'c'], queue), [0, 0, 1, 1, 2]);
    expect(requestIndexOfJobs(['a', 'b', 'c'], queue), [0, 1, 2]);
  });

  test('a photo is skipped before anything runs for what it is', () {
    final photo = _photo('salon.jpg');
    expect(conversionSkipOf(photo, const ConversionPhotoFacts(), linux: true), isNull);
    expect(
      conversionSkipOf(_photo('a.mp4', type: AssetType.video), const ConversionPhotoFacts()),
      ConversionSkipReason.video,
    );
    expect(conversionSkipOf(photo, const ConversionPhotoFacts(isSpatial: true)), ConversionSkipReason.spatial);
    expect(
      conversionSkipOf(_photo('IMG_1.HEIC'), const ConversionPhotoFacts(), linux: true),
      ConversionSkipReason.unreadableFormat,
    );
    expect(conversionSkipOf(_photo('IMG_1.HEIC'), const ConversionPhotoFacts(), linux: false), isNull);
  });

  group('the photos each type takes', () {
    const flatKinds = [ConversionKind.sbsFromPhoto, ConversionKind.sceneFromPhoto, ConversionKind.panoramaFromPhoto];
    const ofPanorama = ConversionKind.stereoPanoramaFromPanorama;
    const generatedPanorama = (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360);
    final sphere = _photo('trip.jpg', width: 8000, height: 4000);

    test('a flat photo makes a 3D photo, a 3D scene or a panorama, never the 3D version of a 360° photo', () {
      final photo = _photo('salon.jpg');
      for (final kind in flatKinds) {
        expect(conversionSkipOf(photo, const ConversionPhotoFacts(), kind: kind), isNull, reason: kind.name);
      }
      expect(conversionSkipOf(photo, const ConversionPhotoFacts(), kind: ofPanorama), ConversionSkipReason.notSphere);
    });

    test('a 360° photo that holds one eye makes its 3D version, and nothing made from a flat photo', () {
      const facts = ConversionPhotoFacts(isPanorama: true);
      expect(conversionSkipOf(sphere, facts, kind: ofPanorama), isNull);
      for (final kind in flatKinds) {
        expect(conversionSkipOf(sphere, facts, kind: kind), ConversionSkipReason.sphere360, reason: kind.name);
      }
      // A panorama the app generated too
      expect(
        conversionSkipOf(
          sphere,
          const ConversionPhotoFacts(isPanorama: true, version: generatedPanorama),
          kind: ofPanorama,
        ),
        isNull,
      );
      // The size not known yet: the engine checks the picture it decodes
      expect(
        conversionSkipOf(
          LocalAsset(
            id: 'unsized',
            name: 'trip.jpg',
            type: AssetType.image,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            playbackStyle: AssetPlaybackStyle.image,
            isEdited: false,
          ),
          facts,
          kind: ofPanorama,
        ),
        isNull,
      );
    });

    test('the 3D version of a 360° photo is refused to a 3D, VR180, raw or partial one, and to our other versions', () {
      const facts = ConversionPhotoFacts(isPanorama: true);
      // Two eyes stacked or side by side in the frame, a 360° 3D panorama the app made
      expect(
        conversionSkipOf(_photo('tb.jpg', width: 4096, height: 4096), facts, kind: ofPanorama),
        ConversionSkipReason.alreadyStereo,
      );
      expect(
        conversionSkipOf(_photo('lr.jpg', width: 8192, height: 2048), facts, kind: ofPanorama),
        ConversionSkipReason.alreadyStereo,
      );
      expect(
        conversionSkipOf(
          sphere,
          const ConversionPhotoFacts(
            isPanorama: true,
            isStereo: true,
            version: (origin: IndexedOrigin.generated, kind: ImmersiveKind.stereoPanorama360),
          ),
          kind: ofPanorama,
        ),
        ConversionSkipReason.alreadyStereo,
      );
      expect(
        conversionSkipOf(_photo('trip_180.jpg', width: 8000, height: 4000), facts, kind: ofPanorama),
        ConversionSkipReason.vr180,
      );
      // The app reads it and shows it as a sphere: not a format it cannot read, a picture not stitched yet
      expect(
        conversionSkipOf(sphere, const ConversionPhotoFacts(isPanorama: true, isRaw360: true), kind: ofPanorama),
        ConversionSkipReason.raw360,
      );
      loadEnglishTexts();
      expect(
        conversionSkipText(StaticTranslations.instance, ConversionSkipReason.raw360),
        'Raw 360° photo, not stitched',
      );
      expect(
        conversionSkipOf(_photo('crop.jpg', width: 8000, height: 2500), facts, kind: ofPanorama),
        ConversionSkipReason.notSphere,
      );
      // A 2:1 frame whose GPano crop leaves part of the sphere out
      expect(
        conversionSkipOf(sphere, const ConversionPhotoFacts(isPanorama: true, partialSphere: true), kind: ofPanorama),
        ConversionSkipReason.notSphere,
      );
      expect(
        conversionSkipOf(
          sphere,
          const ConversionPhotoFacts(
            isPanorama: true,
            version: (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
          ),
          kind: ofPanorama,
        ),
        ConversionSkipReason.alreadyVersion,
      );
      expect(conversionSkipOf(sphere, facts, kind: ofPanorama, linux: true), isNull, reason: 'a JPEG reads everywhere');
    });

    test('a version the app made is never made into a flat kind again, two eyes or not', () {
      final scene = _photo('salon_scene3D.jpg');
      const sceneFacts = ConversionPhotoFacts(
        version: (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
      );
      for (final kind in flatKinds) {
        expect(conversionSkipOf(scene, sceneFacts, kind: kind), ConversionSkipReason.alreadyVersion, reason: kind.name);
        expect(
          conversionSkipOf(scene, const ConversionPhotoFacts(isStereo: true), kind: kind),
          ConversionSkipReason.alreadyStereo,
          reason: kind.name,
        );
      }
    });

    test('our versions that hold two eyes, and those of a kind this build does not know', () {
      expect(versionHoldsTwoEyes((origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto)), isTrue);
      expect(versionHoldsTwoEyes((origin: IndexedOrigin.generated, kind: ImmersiveKind.stereoPanorama360)), isTrue);
      expect(versionHoldsTwoEyes((origin: IndexedOrigin.other, kind: null)), isTrue);
      expect(versionHoldsTwoEyes(generatedPanorama), isFalse);
      expect(versionHoldsTwoEyes((origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene)), isFalse);
    });
  });
}
