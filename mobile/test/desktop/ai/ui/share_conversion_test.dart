// "Make 3D (AI)" on the photos of a share opened in the app (SMB, WebDAV, DLNA, Plex), with fakes for the media bridge:
// each photo copied once into the cache as the dialog opens, its name and its size shown with a progress, Cancel
// stopping the copies and leaving none; the facts of each photo read from its copy with the probes of a file of this
// computer (its frame, the 360° rules of the scan, two eyes by name, frame or our XMP, a version of ours, the GPano
// crop); the four types of a library photo, each planning the selection with its reasons; and the job reading the
// copy the dialog made, never a second download.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/view_rotation.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:path/path.dart' as p;

import '../../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../../presentation/pages/network/network_viewer_fakes.dart' show MemoryShare;
import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';
import '../fakes/fake_conversion_engines.dart';
import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_panorama_engine.dart';
import '../fakes/fake_scene_engine.dart';
import '../fakes/fake_share_writer.dart';
import '../fakes/fake_stereo_panorama_engine.dart';
import '../fakes/recording_creator_files.dart';
import '../scene/scene_test_support.dart' show exifWithFocal35, insertAfterSoi;
import 'settle_still.dart';

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

/// Every folder on a local disk
class _LocalVolumes implements FolderVolumes {
  @override
  FolderVolume? of(String folder) =>
      FolderVolume(volumeKey: 'local', folderKey: 'local:$folder', mountPoint: '/', isNetwork: false);

  @override
  bool isNetworkMount(String folder) => false;
}

/// The media bridge of the test: the files of the share by path, each request recorded; a file in [held] waits for
/// its gate before its bytes come, a file in [refused] is answered 404
class _Bridge {
  final files = <String, Uint8List>{};
  final asked = <String>[];
  final held = <String, Completer<void>>{};
  final refused = <String>{};

  Future<http.StreamedResponse> fetch(Uri url) async {
    asked.add(Uri.decodeComponent(url.path));
    // The bridge serves the files of a share under its token and the id of the share
    final path = Uri.decodeComponent(url.path).replaceFirst(RegExp('^/token/[^/]+'), '');
    final bytes = files[path];
    if (bytes == null || refused.contains(path)) {
      return http.StreamedResponse(const Stream.empty(), HttpStatus.notFound);
    }
    final gate = held[path];
    Stream<List<int>> body() async* {
      yield bytes.sublist(0, bytes.length ~/ 2);
      if (gate != null) {
        await gate.future;
      }
      yield bytes.sublist(bytes.length ~/ 2);
    }

    return http.StreamedResponse(body(), HttpStatus.ok, contentLength: bytes.length);
  }
}

/// The turns kept on this computer for the files of the shares, as the test gives them
class _Turns extends ViewRotations {
  _Turns(this.entries);

  final Map<String, ViewRotationEntry> entries;

  @override
  Map<String, ViewRotationEntry> build() => entries;
}

void main() {
  late Directory root;
  late String chosen;
  late RecordingCreatorFiles files;
  late SafeWriter safeWriter;
  var staged = 0;
  late DesktopAiSettingsStore store;
  late FakeAiComponentsService service;
  late FakeImmersiveEngine engine;
  late Map<ConversionKind, ConversionEngine> kinds;
  late _Bridge bridge;
  late Map<String, ViewRotationEntry> turns;
  late ShareFolder? Function(NetworkEntry entry) folderOf;
  late FakeShareWriter writer;
  late List<String> checked;
  late ShareVersionLookup? versions;

  final linux = aiComponentsFor(AiPlatform.linuxX64);
  final rules = LibraryPathRules(context: p.context, caseFold: false);
  final modified = DateTime.utc(2026, 10, 1, 12);

  setUp(() {
    root = Directory.systemTemp.createTempSync('share_conversion');
    chosen = p.join(root.path, 'Downloads', 'Immuch360');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    files = RecordingCreatorFiles();
    safeWriter = SafeWriter(
      files: files,
      journal: InflightJournal(settingsDirectory: () async => support),
      processId: 4242,
    );
    store = DesktopAiSettingsStore(settingsDirectory: () async => support);
    service = FakeAiComponentsService(states: {for (final component in linux) component: AiComponentState.installed});
    engine = FakeImmersiveEngine(holdStage: .depth);
    kinds = fakeConversionEngines(
      scene: FakeSceneEngine(),
      panorama: FakePanoramaEngine(),
      stereoPanorama: FakeStereoPanoramaEngine(),
    );
    bridge = _Bridge();
    turns = {};
    // A media server by default: the folder of my choice
    folderOf = (entry) => null;
    writer = FakeShareWriter();
    checked = [];
    versions = null;
  });

  tearDown(() => root.deleteSync(recursive: true));

  String copiesFolder() => p.join(root.path, 'immuch360-ai');

  List<String> copies() => Directory(copiesFolder()).existsSync()
      ? [for (final entry in Directory(copiesFolder()).listSync()) entry.path]
      : [];

  /// A file of the share "nas" at [path], with [bytes]
  NetworkEntry shared(String path, Uint8List bytes) {
    bridge.files[path] = bytes;
    return NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: bytes.length, modified: modified);
  }

  List<Override> overrides() {
    final output = SafeWriterOutput(writer: safeWriter);
    return [
      aiFeaturesEnabledProvider.overrideWith((ref) => true),
      aiComponentsServiceProvider.overrideWithValue(service),
      desktopAiGateProvider.overrideWithValue(
        HardwareGate(
          components: _GateFiles(service, root.path),
          facts: () => const AiHardwareFacts(abi: Abi.linuxX64, processors: 8, physicalMemory: 32 * _gib),
          loadRuntime: (path) async => (version: '1.31.0', error: null),
          catalogue: aiComponents,
          heldGroups: aiHeldFeatureGroups,
          gpu: FakeGpuProbe.of(FakeGpuReports.rtx4060),
        ),
      ),
      conversionEnginesProvider.overrideWithValue(kinds),
      shareConversionSourceProvider.overrideWithValue(
        (entry) => ShareFileSource(
          entry: entry,
          url: () async => Uri(scheme: 'http', host: '127.0.0.1', path: '/token/${entry.sourceId}${entry.path}'),
          fetch: bridge.fetch,
          copiesFolder: () async => Directory(copiesFolder()),
          hash: (path, cancel) async => base64.encode(crypto.sha1.convert(File(path).readAsBytesSync()).bytes),
          versions: versions,
        ),
      ),
      shareFolderOfProvider.overrideWithValue((entry) => folderOf(entry)),
      shareWriterOpenerProvider.overrideWithValue((sourceId) async => writer),
      shareStagingFolderProvider.overrideWithValue(
        () async => (await Directory(p.join(copiesFolder(), 'share-out-${staged++}')).create(recursive: true)).path,
      ),
      destinationSessionFactoryProvider.overrideWithValue(
        (jobs, settings) => DestinationSession(
          jobs,
          store: settings,
          writer: safeWriter,
          volumes: _LocalVolumes(),
          downloadFolder: () async => chosen,
          rules: rules,
          shareProbe: (folder) async {
            checked.add(folder.label);
            return const ProbeResult(ProbeStatus.ready);
          },
        ),
      ),
      desktopAiSettingsStoreProvider.overrideWithValue(store),
      aiWriteGuardProvider.overrideWithValue((folder) async => true),
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
      viewRotationsProvider.overrideWith(() => _Turns(turns)),
    ];
  }

  Future<void> settle(WidgetTester tester, {bool Function()? until}) =>
      settleStill(tester, watched: () => '${files.calls.length} ${bridge.asked.length}', until: until);

  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  /// A page with a button that opens the dialog on [entries] of the share, in a window the size of a computer screen
  Future<ProviderContainer> openDialog(WidgetTester tester, List<NetworkEntry> entries, {bool wait = true}) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(openShareConversionDialog(context, entries)),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(const Key('open')));
    if (wait) {
      await settle(tester, until: () => find.byKey(const Key('ai_conversion_share_copy')).evaluate().isEmpty);
    } else {
      await tester.pump();
    }
    return ProviderScope.containerOf(tester.element(find.byKey(const Key('ai_conversion_dialog'))));
  }

  Finder convert() => find.byKey(const Key('ai_conversion_convert'));

  /// desktop_ai.json once the writes of the page are done, read in the zone of the test and pumped (see the same
  /// helper of conversion_dialog_test.dart: a read inside runAsync would wait for the writes queued before it)
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

  /// The yes given earlier for the share "nas", before the dialog opens
  Future<void> allowNas(WidgetTester tester) => tester.runAsync(
    () => store.update((settings) => settings.copyWith(networkRootsAllowed: const ['net-//nas/photos:/'])),
  );

  bool convertEnabled(WidgetTester tester) => tester.widget<FilledButton>(convert()).onPressed != null;

  ConversionKind chosenType(WidgetTester tester) =>
      tester.widget<RadioGroup<ConversionKind>>(find.byKey(const Key('ai_conversion_types'))).groupValue!;

  group('the facts of a copy', () {
    late Directory folder;

    setUp(() => folder = Directory(p.join(root.path, 'copies'))..createSync());

    String write(String name, Uint8List bytes) {
      final path = p.join(folder.path, name);
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    NetworkEntry entry(String name, {int? size}) =>
        NetworkEntry(sourceId: 'nas', path: '/2024/$name', isDirectory: false, size: size, modified: modified);

    test('a flat photo: its frame read from the file, nothing else, the turns of the page kept', () async {
      final copy = write('salon.jpg', jpegFile(width: 4000, height: 3000));

      final read = await readShareCopyFacts(entry('salon.jpg'), copy, quarterTurns: 1);

      expect((read.width, read.height), (4000, 3000));
      expect(read.facts.isPanorama, isFalse);
      expect(read.facts.isStereo, isFalse);
      expect(read.facts.version, isNull);
      expect(read.facts.quarterTurns, 1);
      expect(read.exif.dateTimeOriginal, isNull, reason: 'the engine reads the EXIF of a JPEG itself');
      expect(conversionSkipOf(shareConversionAsset(entry('salon.jpg'), width: 4000, height: 3000), read.facts), isNull);
    });

    test('a 360° photo by its GPano tags, a raw one by its name, a 2:1 one taken by its frame alone', () async {
      final sphere = write('beach.jpg', jpegFile(width: 6000, height: 3000, segments: [gpanoSegment()]));
      final raw = write('IMG_0001.insp', jpegFile(width: 6080, height: 3040));
      final plain = write('rooftop_night.jpg', jpegFile(width: 8192, height: 4096));

      final beach = await readShareCopyFacts(entry('beach.jpg'), sphere);
      final insp = await readShareCopyFacts(entry('IMG_0001.insp'), raw);
      final rooftop = await readShareCopyFacts(entry('rooftop_night.jpg'), plain);

      expect(beach.facts.isPanorama, isTrue);
      expect(
        conversionSkipOf(
          shareConversionAsset(entry('beach.jpg'), width: 6000, height: 3000),
          beach.facts,
          kind: ConversionKind.stereoPanoramaFromPanorama,
        ),
        isNull,
      );
      expect(insp.facts.isRaw360, isTrue);
      expect(rooftop.facts.isPanorama, isFalse);
      expect(
        conversionSkipOf(
          shareConversionAsset(entry('rooftop_night.jpg'), width: 8192, height: 4096),
          rooftop.facts,
          kind: ConversionKind.stereoPanoramaFromPanorama,
        ),
        isNull,
        reason: 'the rule of the plan for a 2:1 frame',
      );
    });

    test('our 3D photo, by its name and by our XMP alone once renamed: two eyes, a version of ours', () async {
      final xmp = ourXmp(eyeWidth: 3000, eyeHeight: 3000);
      final named = write('salon_3D_LRF_Full_SBS.jpg', jpegFile(width: 6000, height: 3000, xmp: xmp));
      final renamed = write('square.jpg', jpegFile(width: 6000, height: 3000, xmp: xmp));

      for (final (name, copy) in [('salon_3D_LRF_Full_SBS.jpg', named), ('square.jpg', renamed)]) {
        final read = await readShareCopyFacts(entry(name), copy);
        expect(read.facts.isStereo, isTrue, reason: name);
        expect(read.facts.version, (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto), reason: name);
        expect(
          conversionSkipOf(shareConversionAsset(entry(name), width: 6000, height: 3000), read.facts),
          ConversionSkipReason.alreadyStereo,
          reason: name,
        );
      }
    });

    test('a PNG keeps the date of its share for the version, the engine reading no EXIF of it', () async {
      final copy = write('plan.png', pngFile(width: 1200, height: 800));

      final read = await readShareCopyFacts(entry('plan.png'), copy);

      expect((read.width, read.height), (1200, 800));
      final local = modified.toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      expect(
        read.exif.dateTimeOriginal,
        '${local.year}:${two(local.month)}:${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}',
      );
    });

    test('the photo of a share as the plan sees it: its name, its kind, its frame', () {
      final asset = shareConversionAsset(entry('salon.jpg'), width: 4000, height: 3000);
      expect(asset.name, 'salon.jpg');
      expect(asset.isImage, isTrue);
      expect((asset.width, asset.height), (4000, 3000));
      expect(shareConversionAsset(entry('clip.mp4')).isVideo, isTrue);
    });
  });

  testWidgets('each photo copied once as the dialog opens, then planned with the four types of a library photo', (
    tester,
  ) async {
    final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));
    final beach = shared('/2024/beach.jpg', jpegFile(width: 6000, height: 3000, segments: [gpanoSegment()]));
    const clip = NetworkEntry(sourceId: 'nas', path: '/2024/clip.mp4', isDirectory: false, size: 1 << 20);

    await openDialog(tester, [salon, beach, clip]);

    expect(bridge.asked, ['/token/nas/2024/salon.jpg', '/token/nas/2024/beach.jpg'], reason: 'a video is not copied');
    expect(copies(), hasLength(2));
    for (final kind in conversionDialogKinds) {
      expect(find.byKey(Key('ai_conversion_type_${kind.name}')), findsOneWidget, reason: kind.name);
    }
    expect(chosenType(tester), ConversionKind.sbsFromPhoto);
    expect(find.text('beach.jpg: 360° photo'), findsOneWidget);
    expect(find.text('clip.mp4: Video'), findsOneWidget);

    await tapIn(tester, find.byKey(const Key('ai_conversion_type_stereoPanoramaFromPanorama')));
    await settle(tester);

    expect(find.text('salon.jpg: Not a 360° photo'), findsOneWidget);
    expect(find.text('beach.jpg: 360° photo'), findsNothing);
    expect(bridge.asked, hasLength(2), reason: 'another type plans the copies again, no new download');
  });

  testWidgets('the copy shows the name of the photo and its size, and Cancel stops it, leaving no copy', (
    tester,
  ) async {
    final bytes = jpegFile(width: 4000, height: 3000, dataLength: 400000);
    final salon = shared('/2024/salon.jpg', bytes);
    bridge.held['/2024/salon.jpg'] = Completer<void>();
    final half = 'Copying salon.jpg from the share: ${formatBytes(bytes.length ~/ 2)} of ${formatBytes(bytes.length)}';

    await openDialog(tester, [salon], wait: false);
    await settle(tester, until: () => find.text(half).evaluate().isNotEmpty);

    expect(find.byKey(const Key('ai_conversion_share_copy')), findsOneWidget);
    expect(find.text(half), findsOneWidget, reason: 'its name and its size, half copied');
    expect(convertEnabled(tester), isFalse);

    await tester.tap(find.byKey(const Key('ai_conversion_cancel')));
    await tester.pump();
    bridge.held['/2024/salon.jpg']!.complete();
    await settle(tester);

    expect(find.byKey(const Key('ai_conversion_dialog')), findsNothing);
    expect(copies(), isEmpty, reason: 'the copy stopped and deleted');
  });

  testWidgets('a photo the bridge does not give is planned as not reached, the others go on', (tester) async {
    final gone = shared('/2024/gone.jpg', jpegFile(width: 4000, height: 3000));
    final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));
    bridge.refused.add('/2024/gone.jpg');

    await openDialog(tester, [gone, salon]);

    expect(find.text('gone.jpg: The original cannot be reached any more'), findsOneWidget);
    expect(copies(), hasLength(1));
    expect(convertEnabled(tester), isTrue);
  });

  testWidgets('Convert: the job reads the copy the dialog made, no second download, and the copies go with the jobs', (
    tester,
  ) async {
    final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));
    final ours = shared('/2024/old_3D_LRF_Full_SBS.jpg', jpegFile(width: 6000, height: 3000, xmp: ourXmp()));
    final container = await openDialog(tester, [salon, ours]);
    expect(find.text('old_3D_LRF_Full_SBS.jpg: Already a 3D photo'), findsOneWidget);

    await tapIn(tester, convert());
    await settle(tester);

    final jobs = container.read(conversionQueueProvider).jobs;
    expect(jobs.map((job) => (job.source.name, job.state)), [
      ('salon.jpg', ConversionState.depth),
      ('old_3D_LRF_Full_SBS.jpg', ConversionState.skipped),
    ]);
    expect(jobs.first.source, isA<ShareFileSource>());
    expect(bridge.asked, hasLength(2), reason: 'each photo copied once, by the dialog');
    expect(copies(), hasLength(1), reason: 'the copy of a photo skipped goes at once');
    expect(container.read(conversionJobInfoProvider)[jobs.first.id]!.asset, isNull, reason: 'no photo of the app');

    engine.release();
    await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));
    expect(container.read(conversionQueueProvider).jobs.first.state, ConversionState.done);
    expect(copies(), isEmpty, reason: 'the copy deleted with the end of its job');
  });

  testWidgets('the turns the page of the share shows a photo with go to its job, and the dialog says so', (
    tester,
  ) async {
    engine = FakeImmersiveEngine();
    final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));
    final cuisine = shared('/2024/cuisine.jpg', jpegFile(width: 4000, height: 3000));
    turns[viewRotationShareKey('nas', '/2024/salon.jpg')] = ViewRotationEntry(
      1,
      size: salon.size,
      modifiedMs: modified.millisecondsSinceEpoch,
    );
    // Kept for another file under that path: ignored
    turns[viewRotationShareKey('nas', '/2024/cuisine.jpg')] = const ViewRotationEntry(2, size: 1, modifiedMs: 1);
    final container = await openDialog(tester, [salon, cuisine]);

    expect(find.byKey(const Key('ai_conversion_rotation')), findsOneWidget);
    await tapIn(tester, convert());
    await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));

    expect(container.read(conversionQueueProvider).jobs.map((job) => (job.source.name, job.quarterTurns, job.state)), [
      ('salon.jpg', 1, ConversionState.done),
      ('cuisine.jpg', 0, ConversionState.done),
    ]);
  });

  group('where the version goes', () {
    const nas = ShareFolder(
      sourceId: 'nas',
      path: '/2024',
      label: 'smb://nas/photos/2024',
      rootKey: 'net-//nas/photos:/',
      rootLabel: 'smb://nas/photos',
    );

    String? publishedPath(ProviderContainer container) =>
        container.read(sharePublisherProvider).values.where((publish) => publish.path != null).firstOrNull?.path;

    testWidgets('a photo of an SMB share: next to its original after the yes, made here, then on the share', (
      tester,
    ) async {
      engine = FakeImmersiveEngine();
      folderOf = (entry) => nas;
      final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));
      final container = await openDialog(tester, [salon]);

      expect(
        find.text(
          'Save 3D photos in the folders of this network folder? Immuch360 writes new files there, never the originals.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('smb://nas/photos'), findsOneWidget, reason: 'the root of the share it asks for');
      expect(checked, isEmpty, reason: 'nothing tried on the share before the yes');
      expect(convertEnabled(tester), isFalse);

      await tapIn(tester, find.byKey(const Key('ai_conversion_network_yes')));
      await settle(tester, until: () => convertEnabled(tester));

      expect(checked, ['smb://nas/photos/2024']);
      expect(find.byKey(const Key('ai_conversion_next_to_original')), findsOneWidget);
      expect(
        tester.widget<RadioGroup<AiDestination>>(find.byType(RadioGroup<AiDestination>)).groupValue,
        AiDestination.nextToOriginal,
      );
      expect(find.textContaining('smb://nas/photos/2024'), findsOneWidget, reason: 'the folder of the share');

      await tapIn(tester, convert());
      await settle(tester, until: () => publishedPath(container) != null);

      expect(writer.files.keys, ['/2024/salon_3D_LRF_Full_SBS.jpg']);
      expect(writer.files.values.single.take(2), [0xff, 0xd8]);
      expect(copies(), isEmpty, reason: 'neither the copy nor the version stays on this computer');
      expect(find.text('smb://nas/photos/2024/salon_3D_LRF_Full_SBS.jpg'), findsOneWidget, reason: 'the panel');
      expect(find.byKey(const Key('ai_job_view_share')), findsOneWidget);
      expect(find.byKey(const Key('ai_job_open_folder')), findsNothing, reason: 'nothing of it on this computer');
      expect((await keptSettings(tester)).networkRootsAllowed, ['net-//nas/photos:/']);
    });

    testWidgets('a photo of a media server (DLNA, Plex): the folder of my choice, with the reason', (tester) async {
      final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));

      await openDialog(tester, [salon]);

      expect(find.text('This source cannot be written to: choose a folder'), findsOneWidget);
      expect(find.textContaining(chosen), findsOneWidget);
      expect(find.byKey(const Key('ai_conversion_next_to_original')), findsNothing);
      expect(find.byKey(const Key('ai_conversion_network_yes')), findsNothing);
      expect(convertEnabled(tester), isTrue);
    });

    testWidgets('the share refuses the version at the end: kept in the folder of my choice, and said', (tester) async {
      engine = FakeImmersiveEngine();
      folderOf = (entry) => nas;
      writer.failUpload = ShareWriteFailure.readOnly;
      await allowNas(tester);
      final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));
      final container = await openDialog(tester, [salon]);

      await tapIn(tester, convert());
      await settle(
        tester,
        until: () => container.read(sharePublisherProvider).values.any((publish) => publish.state.isEnded),
      );

      expect(writer.files, isEmpty);
      expect(File(p.join(chosen, 'salon_3D_LRF_Full_SBS.jpg')).existsSync(), isTrue);
      expect(
        find.text('Not saved on the share (This folder does not accept new files): kept on this computer'),
        findsOneWidget,
      );
      expect(find.text(p.join(chosen, 'salon_3D_LRF_Full_SBS.jpg')), findsOneWidget);
      expect(find.byKey(const Key('ai_job_open_folder')), findsOneWidget, reason: 'it is on this computer');
    });

    testWidgets('Skip: a version made with the same settings is next to it on the share already', (tester) async {
      engine = FakeImmersiveEngine();
      folderOf = (entry) => nas;
      await allowNas(tester);
      final bytes = jpegFile(width: 4000, height: 3000);
      final salon = shared('/2024/salon.jpg', bytes);
      // Ours, made from these bytes with the settings of this build, as a computer put it there earlier
      final made = MemoryShare(
        const NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: 'nas'),
        files: {
          '/2024/salon.jpg': bytes,
          '/2024/salon_3D_LRF_Full_SBS.jpg': jpegFile(
            width: 8000,
            height: 3000,
            xmp: ourXmp(sourceSize: bytes.length, sourceSha1: base64.encode(crypto.sha1.convert(bytes).bytes)),
          ),
        },
      );
      made.folders['/2024'] = [made.file('/2024/salon.jpg'), made.file('/2024/salon_3D_LRF_Full_SBS.jpg')];
      versions = shareVersionLookup(() async => made, salon);
      final container = await openDialog(tester, [salon]);

      await tapIn(tester, convert());
      await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));

      final job = container.read(conversionQueueProvider).jobs.single;
      expect((job.state, job.skipReason), (ConversionState.skipped, ConversionSkipReason.sameSettingsExists));
      expect(writer.calls, isEmpty, reason: 'nothing written on the share');
    });
  });

  testWidgets('the 360° panorama: the part invented from the focal length the EXIF of the copy tells', (tester) async {
    final photo = insertAfterSoi(jpegFile(width: 4000, height: 3000), exifWithFocal35(13));
    final salon = shared('/2024/salon.jpg', photo);

    await openDialog(tester, [salon]);
    await tapIn(tester, find.byKey(const Key('ai_conversion_type_panoramaFromPhoto')));
    await settle(tester, until: () => find.byKey(const Key('ai_conversion_invented')).evaluate().isNotEmpty);

    final percent = (panoramaInventedShare(width: 4000, height: 3000, focal35: 13) * 100).round();
    expect(percent, isNot((panoramaInventedShare(width: 4000, height: 3000) * 100).round()), reason: 'not the default');
    expect(find.text('About $percent% of this panorama will be invented by AI'), findsOneWidget);
  });
}
