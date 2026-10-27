// "Make 3D (AI)" and its dialog on a computer, with fakes: the entry absent while the AI features are off and greyed
// with its reason when the hardware gate refuses; the dialog that installs the missing components before it offers
// Convert; the question of a network folder, nothing tried there before the yes; the photos skipped and why; the
// choice for a photo that already has a 3D version, handed to the queue and kept; the settings kept, read again; the
// turns of each photo handed to the queue, with the rotation and the edits of Immich said; and the folders of the
// library left alone while the album of the generated photos is not out of the backup.

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
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:path/path.dart' as p;

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/recording_creator_files.dart';

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
        ),
      ),
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

  /// Lets the real files be read and written: each step waits for the real event loop, then a frame
  Future<void> settle(WidgetTester tester) async {
    for (var step = 0; step < 30; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

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
    await settle(tester);

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
}
