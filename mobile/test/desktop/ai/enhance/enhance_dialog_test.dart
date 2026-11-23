// The dialog of "Enhance (AI)" and its comparison view, with the facts of a computer given by the test.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_compare.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_dialog.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_files.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/enhance/natural_backend.dart';
import 'package:immich_mobile/desktop/ai/enhance/rebuild_backend.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart' show encodePngPicture;
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_enhance_manifest.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';
import 'package:path/path.dart' as p;

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/recording_creator_files.dart';
import '../ui/settle_still.dart';

const _gib = 1 << 30;

LocalAsset _photo(String name, {int width = 4000, int height = 3000, AssetType type = AssetType.image}) => LocalAsset(
  id: 'id-$name',
  name: name,
  type: type,
  createdAt: DateTime(2026, 11, 23, 9),
  updatedAt: DateTime(2026, 11, 23, 9),
  width: width,
  height: height,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
);

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

class _LocalVolumes implements FolderVolumes {
  @override
  FolderVolume? of(String folder) =>
      FolderVolume(volumeKey: 'local', folderKey: 'local:$folder', mountPoint: '/', isNetwork: false);

  @override
  bool isNetworkMount(String folder) => false;
}

/// The computer of the test and the files of its levels
class _Facts implements EnhanceDialogFacts {
  _Facts(this.machineNow);

  EnhanceMachine machineNow;
  final files = <EnhanceLevel, EnhanceComponentsFound>{};

  @override
  Future<EnhanceMachine> machine() async => machineNow;

  @override
  Future<EnhanceComponentsFound> filesOf(EnhanceLevel level, AiPlatform platform) async =>
      files[level] ?? (files: _ready(level), missing: const <AiComponent>[], notInThisVersion: false);
}

EnhanceFiles _ready(EnhanceLevel level) => switch (level) {
  EnhanceLevel.sharpen => const EnhanceFiles(
    sharpen: SharpenFiles(sdCli: 'sd-cli', upscaler: 'x4plus.pth'),
  ),
  EnhanceLevel.rebuild => const EnhanceFiles(
    rebuild: RebuildFiles(sdCli: 'sd-cli', dit: 'dit', vae: 'vae'),
  ),
  EnhanceLevel.natural => const EnhanceFiles(
    natural: VosrFiles(library: 'ort', imageEncoder: 'a', vaeEncoder: 'b', transformer: 'c', vaeDecoder: 'd'),
  ),
};

const _pc = EnhanceMachine(
  platform: AiPlatform.windowsX64,
  physicalMemory: 16 * _gib,
  freeMemory: 8 * _gib,
  processors: 24,
  card: EnhanceCard(name: 'NVIDIA GeForce RTX 4060 Laptop GPU', dedicated: true, localMemory: 8 * _gib),
);

void main() {
  late Directory root;
  late String photos;
  late String chosen;
  late SafeWriter writer;
  late DesktopAiSettingsStore store;
  late _Originals originals;
  late _Facts facts;

  setUp(() {
    root = Directory.systemTemp.createTempSync('enhance_dialog');
    photos = p.join(root.path, 'Photos');
    chosen = p.join(root.path, 'Downloads', 'Immuch360');
    Directory(photos).createSync();
    final support = Directory(p.join(root.path, 'support'))..createSync();
    writer = SafeWriter(
      files: RecordingCreatorFiles(),
      journal: InflightJournal(settingsDirectory: () async => support),
      processId: 4242,
    );
    store = DesktopAiSettingsStore(settingsDirectory: () async => support);
    originals = _Originals();
    facts = _Facts(_pc);
  });

  tearDown(() => root.deleteSync(recursive: true));

  void original(String name) {
    final path = p.join(photos, name);
    File(path).writeAsBytesSync(List.generate(200, (i) => i & 0xff));
    originals.byName[name] = LibraryOriginal(
      name: name,
      path: path,
      rootId: 'local:$photos',
      rootPath: photos,
      rootIsNetwork: false,
    );
  }

  List<Override> overrides({List<BaseAsset> selected = const []}) {
    final output = SafeWriterOutput(writer: writer);
    return [
      aiFeaturesEnabledProvider.overrideWith((ref) => true),
      aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
      conversionAssetFilesProvider.overrideWithValue(originals),
      destinationSessionFactoryProvider.overrideWithValue(
        (jobs, settings) => DestinationSession(
          jobs,
          store: settings,
          writer: writer,
          volumes: _LocalVolumes(),
          downloadFolder: () async => chosen,
          rules: LibraryPathRules(context: p.context, caseFold: false),
        ),
      ),
      desktopAiSettingsStoreProvider.overrideWithValue(store),
      safeWriterOutputProvider.overrideWithValue(output),
      aiAppVersionProvider.overrideWith((ref) async => '3.4.6'),
      enhanceDialogFactsProvider.overrideWithValue(facts),
      conversionToolsProvider.overrideWithValue(
        ConversionTools(
          engine: FakeImmersiveEngine(),
          // No engine for the enhanced photos: each job fails at once and nothing runs
          output: output,
          finder: ExistingVersionFinder(),
          creatorTool: 'Immuch360 Desktop 3.4.6 (windows)',
        ),
      ),
      assetsActionProvider.overrideWith((ref, source) => AssetFilter(selected)),
    ];
  }

  /// A page whose button opens the dialog for [assets]; the dialog's answer goes to [answer]
  Future<ProviderContainer> open(WidgetTester tester, List<BaseAsset> assets, {List<bool?>? answer}) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () async {
              final result = await showDialog<bool>(
                context: context,
                builder: (_) => EnhanceDialog(assets: assets),
              );
              answer?.add(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(const Key('open')));
    await settleStill(tester);
    return ProviderScope.containerOf(tester.element(find.byKey(const Key('ai_enhance_dialog'))));
  }

  Finder start() => find.byKey(const Key('ai_enhance_start'));

  bool startEnabled(WidgetTester tester) => tester.widget<FilledButton>(start()).onPressed != null;

  Future<void> choose(WidgetTester tester, EnhanceLevel level) async {
    final tile = find.byKey(Key('ai_enhance_level_${level.name}'));
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await settleStill(tester);
  }

  testWidgets('offers the three levels, Sharpen first at 60 %, with its time and the honesty lines', (tester) async {
    original('salon.jpg');
    await open(tester, [_photo('salon.jpg')]);
    for (final level in EnhanceLevel.values) {
      expect(find.byKey(Key('ai_enhance_level_${level.name}')), findsOneWidget);
    }
    expect(tester.widget<ListTile>(find.byKey(const Key('ai_enhance_level_sharpen'))).selected, isTrue);
    expect(find.text('Strength: 60 %'), findsOneWidget);
    expect(find.text('About 2 min for this photo on this computer'), findsOneWidget);
    expect(find.byKey(const Key('ai_enhance_invented')), findsOneWidget);
    expect(find.byKey(const Key('ai_enhance_rebuild_faces')), findsNothing);
    expect(find.text('Strong camera shake is not repaired.'), findsOneWidget);
    expect(find.byKey(const Key('ai_enhance_saved_beside')), findsOneWidget);
    expect(startEnabled(tester), isTrue);

    await choose(tester, EnhanceLevel.rebuild);
    expect(find.text('Strength: 70 %'), findsOneWidget);
    expect(find.byKey(const Key('ai_enhance_rebuild_faces')), findsOneWidget);
    await choose(tester, EnhanceLevel.natural);
    expect(find.text('Strength: 100 %'), findsOneWidget);
  });

  testWidgets('Enhance hands every photo to the queue at the level and strength chosen', (tester) async {
    original('salon.jpg');
    original('jardin.png');
    final answers = <bool?>[];
    final container = await open(tester, [_photo('salon.jpg'), _photo('jardin.png')], answer: answers);
    expect(find.text('About 4 min for 2 photos on this computer'), findsOneWidget);
    await choose(tester, EnhanceLevel.rebuild);
    final slider = find.byKey(const Key('ai_enhance_strength'));
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(-2000, 0));
    await settleStill(tester);
    expect(find.text('Strength: 0 %'), findsOneWidget);
    await tester.ensureVisible(start());
    await tester.tap(start());
    await settleStill(tester);
    expect(answers, [true]);
    final jobs = container.read(conversionQueueProvider).jobs;
    expect(jobs.map((job) => job.kind).toSet(), {ConversionKind.enhanceRebuild});
    expect(jobs.map((job) => job.enhance).toSet(), {const EnhanceSettings(level: EnhanceLevel.rebuild, strength: 0)});
    expect(jobs.map((job) => job.target!.fileName), ['salon_enhanced.jpg', 'jardin_enhanced.jpg']);
    expect(jobs.map((job) => job.target!.folder).toSet(), {photos});
    expect(jobs.map((job) => job.existing).toSet(), {ExistingVersionChoice.newVersion});
  });

  testWidgets('a photo of the server goes to the folder of my choice, said with its reason', (tester) async {
    final copy = p.join(root.path, 'copy.jpg');
    File(copy).writeAsBytesSync(List.generate(100, (i) => i));
    originals.servers['server.jpg'] = copy;
    await open(tester, [_photo('server.jpg')]);
    expect(find.byKey(const Key('ai_enhance_saved_folder')), findsOneWidget);
    expect(find.text('Photos of a server or of a share go to this folder.'), findsOneWidget);
    expect(find.byKey(const Key('ai_enhance_change_folder')), findsOneWidget);
  });

  testWidgets('on a Mac: Natural is chosen, the levels of the graphics card say why they wait', (tester) async {
    facts.machineNow = const EnhanceMachine(platform: AiPlatform.macosArm64, physicalMemory: 16 * _gib, processors: 10);
    original('salon.jpg');
    await open(tester, [_photo('salon.jpg')]);
    expect(tester.widget<ListTile>(find.byKey(const Key('ai_enhance_level_natural'))).selected, isTrue);
    expect(tester.widget<ListTile>(find.byKey(const Key('ai_enhance_level_sharpen'))).enabled, isFalse);
    expect(tester.widget<ListTile>(find.byKey(const Key('ai_enhance_level_rebuild'))).enabled, isFalse);
    expect(find.textContaining('Not on a Mac yet'), findsNWidgets(2));
    expect(find.text('Times measured on a processor of 24 threads; fewer threads take longer.'), findsOneWidget);
  });

  testWidgets('says to close other programs, and waits for an engine not published yet', (tester) async {
    facts.machineNow = const EnhanceMachine(
      platform: AiPlatform.windowsX64,
      physicalMemory: 16 * _gib,
      freeMemory: 2 * _gib,
      processors: 24,
      card: EnhanceCard(name: 'RTX', dedicated: true, localMemory: 8 * _gib),
    );
    facts.files[EnhanceLevel.rebuild] = (files: null, missing: const <AiComponent>[], notInThisVersion: true);
    original('salon.jpg');
    await open(tester, [_photo('salon.jpg')]);
    await choose(tester, EnhanceLevel.rebuild);
    expect(find.textContaining('Close other programs first: 2'), findsOneWidget);
    expect(find.byKey(const Key('ai_enhance_not_yet')), findsOneWidget);
    expect(startEnabled(tester), isFalse);
  });

  testWidgets('names the folder of the developer override when its files are used', (tester) async {
    facts.files[EnhanceLevel.sharpen] = (
      files: const EnhanceFiles(
        sharpen: SharpenFiles(sdCli: 'a', upscaler: 'b'),
        fromProbe: true,
      ),
      missing: const <AiComponent>[],
      notInThisVersion: false,
    );
    original('salon.jpg');
    await open(tester, [_photo('salon.jpg')]);
    expect(find.byKey(const Key('ai_enhance_override')), findsOneWidget);
  });

  testWidgets('lists the components to download, and a video is skipped', (tester) async {
    facts.files[EnhanceLevel.natural] = (files: null, missing: vosrComponents, notInThisVersion: false);
    original('salon.jpg');
    await open(tester, [_photo('salon.jpg'), _photo('clip.mp4', type: AssetType.video)]);
    await choose(tester, EnhanceLevel.natural);
    expect(find.byKey(const Key('ai_enhance_install_natural')), findsOneWidget);
    expect(startEnabled(tester), isFalse);
    expect(find.textContaining('1 skipped'), findsOneWidget);
  });

  testWidgets('Escape closes the dialog without handing anything to the queue', (tester) async {
    original('salon.jpg');
    final answers = <bool?>[];
    final container = await open(tester, [_photo('salon.jpg')], answer: answers);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleStill(tester);
    expect(find.byKey(const Key('ai_enhance_dialog')), findsNothing);
    expect(answers, [null]);
    expect(container.read(conversionQueueProvider).jobs, isEmpty);
  });

  testWidgets('the entry shows for photos when the AI features are on', (tester) async {
    await tester.pumpConsumerWidget(
      const Scaffold(body: DesktopEnhanceButton(source: ActionSource.timeline)),
      overrides: overrides(selected: [_photo('salon.jpg')]),
    );
    expect(find.byKey(const Key('ai_enhance')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpConsumerWidget(
      const Scaffold(body: DesktopEnhanceButton(source: ActionSource.timeline)),
      overrides: overrides(selected: [_photo('clip.mp4', type: AssetType.video)]),
    );
    expect(find.byKey(const Key('ai_enhance')), findsNothing);
  });

  testWidgets('the comparison moves its divider with the keys and closes with Escape', (tester) async {
    String png(String name, int value) {
      final rgba = Uint8List(40 * 30 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba.fillRange(i, i + 3, value);
        rgba[i + 3] = 255;
      }
      final path = p.join(root.path, name);
      File(path).writeAsBytesSync(encodePngPicture(SbsDecoded(width: 40, height: 30, rgba: rgba)));
      return path;
    }

    final before = png('before.png', 40);
    final after = png('after.png', 200);
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(showEnhanceCompare(context, originalPath: before, enhancedPath: after)),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await settleStill(tester);
    expect(find.byKey(const Key('ai_enhance_compare')), findsOneWidget);
    double divider() => tester.widget<Slider>(find.byKey(const Key('ai_enhance_compare_slider'))).value;
    expect(divider(), 0.5);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(divider(), closeTo(0.45, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(divider(), closeTo(0.55, 1e-9));
    await tester.tap(find.byKey(const Key('ai_enhance_compare_size')));
    await tester.pump();
    expect(find.text('Fit'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleStill(tester);
    expect(find.byKey(const Key('ai_enhance_compare')), findsNothing);
  });

  test('the levels the components serve on each system', () {
    expect(enhanceComponentsOf(EnhanceLevel.sharpen, AiPlatform.windowsX64), [
      sdCppWindowsComponent,
      upscalerComponent,
    ]);
    expect(enhanceComponentsOf(EnhanceLevel.rebuild, AiPlatform.linuxX64), [
      sdCppSeedVr2LinuxComponent,
      seedVr2DitComponent,
      seedVr2VaeComponent,
    ]);
    expect(enhanceComponentsOf(EnhanceLevel.natural, AiPlatform.macosArm64).first, onnxRuntimeMacArmComponent);
    expect(enhanceComponentsOf(EnhanceLevel.sharpen, AiPlatform.macosArm64), isEmpty);
    expect(enhanceComponentsOf(EnhanceLevel.rebuild, AiPlatform.macosArm64), isEmpty);
    // The engine of Rebuild details waits for its CI run: never offered before
    expect(sdCppSeedVr2WindowsComponent.isComplete, isFalse);
    expect(seedVr2DitComponent.parts.fold<int>(0, (sum, part) => sum + part.size), seedVr2DitComponent.size);
    expect(seedVr2DitComponent.parts.every((part) => part.size < aiReleaseAssetLimit), isTrue);
    expect(vosrComponents.every((component) => component.size! < aiReleaseAssetLimit), isTrue);
    expect(naturalPhysicalMemory, lessThan(16 * _gib));
  });

  test(
    'the folder of the developer override: off by default, Windows only, each level when all its files are there',
    () {
      expect(enhanceProbeFolder(environment: const {}, windows: true), isNull);
      final folder = Directory(p.join(root.path, 'probe'))..createSync();
      expect(enhanceProbeFolder(environment: {enhanceProbeVariable: folder.path}, windows: false), isNull);
      expect(enhanceProbeFolder(environment: {enhanceProbeVariable: folder.path}, windows: true), folder.path);
      expect(enhanceProbeFiles(EnhanceLevel.sharpen, folder.path), isNull);
      for (final path in [
        ['engines', 'shipped', 'sd-cpp-vulkan-win-x64', 'sd-cli.exe'],
        ['engines', 'shipped', 'models', 'RealESRGAN_x4plus.pth'],
      ]) {
        File(p.joinAll([folder.path, ...path]))
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
      final files = enhanceProbeFiles(EnhanceLevel.sharpen, folder.path)!;
      expect(files.fromProbe, isTrue);
      expect(files.sharpen!.sdCli, endsWith('sd-cli.exe'));
      expect(enhanceProbeFiles(EnhanceLevel.rebuild, folder.path), isNull);
      expect(enhanceProbeFiles(EnhanceLevel.natural, folder.path), isNull);
    },
  );
}
