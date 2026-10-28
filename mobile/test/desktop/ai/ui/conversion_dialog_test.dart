// "Make 3D (AI)" and its dialog on a computer, with fakes: the entry absent while the AI features are off and greyed
// with its reason when the hardware gate refuses; the dialog that installs the missing components before it offers
// Convert; the question of a network folder, nothing tried there before the yes; the photos skipped and why; the
// choice for a photo that already has a 3D version, handed to the queue and kept; the settings kept, read again; the
// turns of each photo handed to the queue, with the rotation and the edits of Immich said; and the folders of the
// library left alone while the album of the generated photos is not out of the backup. Phase 2: the choice of the type
// once the build makes another one (the fake engine of the scenes), its honesty sentence, components, free space and
// time, the type greyed with its reason, the plan of each photo of a mixed selection, the selection planned again for
// another type, and the type kept for the next dialog.

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
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/scene_glb_export.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
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
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_scene_engine.dart';
import '../fakes/fake_stereo_panorama_engine.dart';
import '../fakes/recording_creator_files.dart';
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
        ),
      ),
      conversionEnginesProvider.overrideWithValue(kinds),
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

  /// A page with a button that opens the dialog for [assets], in a window the size of a computer screen
  Future<ProviderContainer> openDialog(WidgetTester tester, List<BaseAsset> assets) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(openConversionDialog(context, ref, assets)),
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
