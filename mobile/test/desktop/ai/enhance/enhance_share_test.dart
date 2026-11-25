// "Enhance (AI)" on the photos of a share opened in the app (release 53), with fakes for the media bridge and the
// writer of the shares: each photo copied once as the dialog opens, with its name, its bytes and Cancel; where the
// results go said before anything runs (beside the original on an SMB or WebDAV share, never over a file; the folder
// of my choice for a media server); the job reading the copy; the result written on the share; and "Compare" of such a
// result, its original and its result fetched again.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_compare.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_dialog.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_files.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_layout.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_remote_compare.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart' show encodePngPicture;
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/view_rotation.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:path/path.dart' as p;

import '../../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../widget_tester_extensions.dart';
import '../creator/english_texts.dart';
import '../fakes/fake_immersive_engine.dart';
import '../fakes/fake_share_writer.dart';
import '../fakes/recording_creator_files.dart';
import '../ui/settle_still.dart';

const _gib = 1 << 30;

/// Every folder on a local disk
class _LocalVolumes implements FolderVolumes {
  @override
  FolderVolume? of(String folder) =>
      FolderVolume(volumeKey: 'local', folderKey: 'local:$folder', mountPoint: '/', isNetwork: false);

  @override
  bool isNetworkMount(String folder) => false;
}

/// The media bridge of the test: the files of the share by path, each request recorded; a file in [held] waits for
/// its gate before its second half comes
class _Bridge {
  final files = <String, Uint8List>{};
  final asked = <String>[];
  final held = <String, Completer<void>>{};

  Future<http.StreamedResponse> fetch(Uri url, {Future<void>? abort}) async {
    final path = Uri.decodeComponent(url.path).replaceFirst(RegExp('^/token/[^/]+'), '');
    asked.add(path);
    final bytes = files[path];
    if (bytes == null) {
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

class _Turns extends ViewRotations {
  @override
  Map<String, ViewRotationEntry> build() => const {};
}

/// The computer of the test: a card of 8 GB, every level ready
class _Facts implements EnhanceDialogFacts {
  @override
  Future<EnhanceMachine> machine() async => const EnhanceMachine(
    platform: AiPlatform.windowsX64,
    physicalMemory: 32 * _gib,
    freeMemory: 16 * _gib,
    processors: 24,
    card: EnhanceCard(name: 'NVIDIA GeForce RTX 4060 Laptop GPU', dedicated: true, localMemory: 8 * _gib),
  );

  @override
  Future<EnhanceComponentsFound> filesOf(EnhanceLevel level, AiPlatform platform) async => (
    files: const EnhanceFiles(
      sharpen: SharpenFiles(sdCli: 'sd-cli', upscaler: 'x4plus.pth'),
    ),
    missing: const <AiComponent>[],
    notInThisVersion: false,
  );
}

class _Memory implements MemoryProbe {
  const _Memory();

  @override
  MemoryFacts read() => const MemoryFacts(physical: 32 * _gib, available: 16 * _gib);
}

/// An engine of Enhance: what it read, and a JPEG of its own as the result
class _Enhance implements ImmersiveEngine {
  final read = <String>[];
  final layouts = <EnhanceLayout>[];

  @override
  Future<ImmersiveResult> run(
    covariant EnhanceJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    read.add(job.source.path!);
    layouts.add(job.layout);
    File(job.partPath).writeAsBytesSync(Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]));
    return ImmersiveResult.made(
      details: EnhanceResultDetails(width: 8, height: 8, level: job.level, strength: job.strength, model: 'fake'),
      bytesWritten: 7,
    );
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory root;
  late String chosen;
  late SafeWriter safeWriter;
  var staged = 0;
  late DesktopAiSettingsStore store;
  late _Bridge bridge;
  late ShareFolder? Function(NetworkEntry entry) folderOf;
  late FakeShareWriter writer;
  late _Enhance enhance;
  final modified = DateTime.utc(2026, 11, 25, 12);

  const nas = ShareFolder(
    sourceId: 'nas',
    path: '/2024',
    label: 'smb://nas/photos/2024',
    rootKey: 'net-//nas/photos:/',
    rootLabel: 'smb://nas/photos',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('enhance_share');
    chosen = p.join(root.path, 'Downloads', 'Immuch360');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    safeWriter = SafeWriter(
      files: RecordingCreatorFiles(),
      journal: InflightJournal(settingsDirectory: () async => support),
      processId: 4242,
    );
    store = DesktopAiSettingsStore(settingsDirectory: () async => support);
    bridge = _Bridge();
    folderOf = (entry) => null;
    writer = FakeShareWriter();
    enhance = _Enhance();
  });

  tearDown(() => root.deleteSync(recursive: true));

  String copiesFolder() => p.join(root.path, 'immuch360-ai');

  List<String> copies() => Directory(copiesFolder()).existsSync()
      ? [for (final entry in Directory(copiesFolder()).listSync()) entry.path]
      : [];

  NetworkEntry shared(String path, Uint8List bytes) {
    bridge.files[path] = bytes;
    return NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: bytes.length, modified: modified);
  }

  ShareFileSource shareSource(NetworkEntry entry) => ShareFileSource(
    entry: entry,
    url: () async => Uri(scheme: 'http', host: '127.0.0.1', path: '/token/${entry.sourceId}${entry.path}'),
    fetch: bridge.fetch,
    copiesFolder: () async => Directory(copiesFolder()),
    hash: (path, cancel) async => base64.encode(crypto.sha1.convert(File(path).readAsBytesSync()).bytes),
  );

  List<Override> overrides() {
    final output = SafeWriterOutput(writer: safeWriter);
    return [
      aiFeaturesEnabledProvider.overrideWith((ref) => true),
      aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
      shareConversionSourceProvider.overrideWithValue(shareSource),
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
          rules: LibraryPathRules(context: p.context, caseFold: false),
          shareProbe: (folder) async => const ProbeResult(ProbeStatus.ready),
        ),
      ),
      desktopAiSettingsStoreProvider.overrideWithValue(store),
      aiWriteGuardProvider.overrideWithValue((folder) async => true),
      safeWriterOutputProvider.overrideWithValue(output),
      aiAppVersionProvider.overrideWith((ref) async => '3.4.7'),
      enhanceDialogFactsProvider.overrideWithValue(_Facts()),
      conversionToolsProvider.overrideWithValue(
        ConversionTools(
          engine: FakeImmersiveEngine(),
          engines: {
            for (final level in EnhanceLevel.values)
              ConversionKind.enhanceAt(level): ConversionEngine(engine: enhance, settingsKey: (_, _) => null),
          },
          output: output,
          finder: ExistingVersionFinder(),
          creatorTool: 'Immuch360 Desktop 3.4.7 (windows)',
          memory: const _Memory(),
        ),
      ),
      conversionThumbnailProvider.overrideWithValue((asset) => const ColoredBox(color: Colors.grey)),
      viewRotationsProvider.overrideWith(_Turns.new),
    ];
  }

  Future<void> settle(WidgetTester tester, {bool Function()? until}) =>
      settleStill(tester, watched: () => '${bridge.asked.length} ${writer.calls.length}', until: until);

  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  Future<ProviderContainer> openDialog(WidgetTester tester, List<NetworkEntry> entries, {bool wait = true}) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(openShareEnhanceDialog(context, entries)),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(const Key('open')));
    if (wait) {
      await settle(tester, until: () => find.byKey(const Key('ai_enhance_start')).evaluate().isNotEmpty);
    } else {
      await tester.pump();
    }
    return ProviderScope.containerOf(tester.element(find.byKey(const Key('ai_enhance_dialog'))));
  }

  Finder start() => find.byKey(const Key('ai_enhance_start'));

  bool startEnabled(WidgetTester tester) => tester.widget<FilledButton>(start()).onPressed != null;

  testWidgets('the copy shows the name of the photo and its size, and Cancel stops it, leaving no copy', (
    tester,
  ) async {
    final bytes = jpegFile(width: 4000, height: 3000, dataLength: 400000);
    final salon = shared('/2024/salon.jpg', bytes);
    bridge.held['/2024/salon.jpg'] = Completer<void>();
    final half = 'Copying salon.jpg from the share: ${formatBytes(bytes.length ~/ 2)} of ${formatBytes(bytes.length)}';

    await openDialog(tester, [salon], wait: false);
    await settle(tester, until: () => find.text(half).evaluate().isNotEmpty);
    expect(find.byKey(const Key('ai_enhance_share_copy')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai_enhance_cancel')));
    await tester.pump();
    bridge.held['/2024/salon.jpg']!.complete();
    await settle(tester);

    expect(find.byKey(const Key('ai_enhance_dialog')), findsNothing);
    expect(copies(), isEmpty, reason: 'the copy stopped and deleted');
  });

  testWidgets('a photo of an SMB share: said beside its original on the share, then written there, never over a file', (
    tester,
  ) async {
    folderOf = (entry) => nas;
    await tester.runAsync(
      () => store.update((settings) => settings.copyWith(networkRootsAllowed: const ['net-//nas/photos:/'])),
    );
    // A result of an earlier run is there: the new one takes the next free name
    writer.files['/2024/salon_enhanced.jpg'] = Uint8List.fromList([1]);
    final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));
    final container = await openDialog(tester, [salon]);

    expect(
      find.text(
        'Saved beside each original on the share, in smb://nas/photos/2024, as name_enhanced.jpg, never over another '
        'file. The original is never changed.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ai_enhance_saved_folder')), findsNothing);
    await settle(tester, until: () => startEnabled(tester));
    await tapIn(tester, start());
    await settle(
      tester,
      until: () => container.read(sharePublisherProvider).values.any((publish) => publish.state.isEnded),
    );

    expect(enhance.read, hasLength(1));
    expect(bridge.asked, ['/2024/salon.jpg'], reason: 'copied once, by the dialog');
    expect(writer.files.keys, containsAll(['/2024/salon_enhanced.jpg', '/2024/salon_enhanced (1).jpg']));
    expect(writer.files['/2024/salon_enhanced.jpg'], [1], reason: 'the earlier file is never written over');
    expect(copies(), isEmpty, reason: 'neither the copy nor the result stays on this computer');
    final job = container.read(conversionQueueProvider).jobs.single;
    expect(container.read(conversionJobInfoProvider)[job.id]!.asset, isNull, reason: 'no photo of the app');
    // Compare is offered: the original and the result are fetched again
    expect(find.byKey(const Key('ai_job_enhance_compare')), findsOneWidget);
  });

  testWidgets('a share not allowed yet: the question speaks of the enhanced photos, never of 3D photos', (
    tester,
  ) async {
    folderOf = (entry) => nas;
    final salon = shared('/2024/salon.jpg', jpegFile(width: 4000, height: 3000));
    await openDialog(tester, [salon]);

    expect(
      find.text(
        'Save the enhanced photos in the folders of this network folder? Immuch360 writes new files there, never over '
        'the originals.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('3D photos'), findsNothing);
  });

  testWidgets('a photo of a media server: the folder of my choice, said with why, before anything runs', (
    tester,
  ) async {
    final salon = shared('/Photos/salon.jpg', jpegFile(width: 4000, height: 3000));
    final container = await openDialog(tester, [salon]);

    expect(find.byKey(const Key('ai_enhance_saved_folder')), findsOneWidget);
    expect(find.textContaining(chosen), findsOneWidget);
    expect(
      find.text('DLNA, Plex, Jellyfin and Emby servers take no new file: the results go to this folder.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('ai_enhance_saved_share')), findsNothing);
    await tapIn(tester, start());
    await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));

    final job = container.read(conversionQueueProvider).jobs.single;
    expect(job.state, ConversionState.done);
    expect(p.dirname(job.writtenPath!), chosen);
    expect(p.basename(job.writtenPath!), 'salon_enhanced.jpg');
    expect(writer.calls, isEmpty);
  });

  testWidgets('a 360° photo and a 3D photo of a share are enhanced as such, a video skipped', (tester) async {
    final pano = shared(
      '/2024/theta.jpg',
      jpegFile(
        width: 4096,
        height: 2048,
        xmpText:
            '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
            '<rdf:Description rdf:about="" xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" '
            'GPano:ProjectionType="equirectangular" GPano:UsePanoramaViewer="True"/></rdf:RDF></x:xmpmeta>',
      ),
    );
    final sbs = shared('/2024/beach_3D_LRF_Full_SBS.jpg', jpegFile(width: 8000, height: 3000));
    const clip = NetworkEntry(sourceId: 'nas', path: '/2024/clip.mp4', isDirectory: false, size: 10);
    final container = await openDialog(tester, [pano, sbs, clip]);

    expect(find.byKey(const Key('ai_enhance_layout_sphere')), findsOneWidget);
    expect(find.byKey(const Key('ai_enhance_layout_stereo')), findsOneWidget);
    expect(find.textContaining('1 skipped'), findsOneWidget);
    await tapIn(tester, start());
    await settle(tester, until: () => container.read(conversionQueueProvider).jobs.every((job) => job.state.isEnded));

    expect(enhance.layouts, [const EnhanceLayout(sphere: true), const EnhanceLayout(eyes: EnhanceEyes.sideBySide)]);
  });

  testWidgets('the entries: "Enhance (AI)" in the bar of a selection of a share, greyed without a photo', (
    tester,
  ) async {
    final opened = <List<NetworkEntry>>[];
    const photo = NetworkEntry(sourceId: 'nas', path: '/2024/salon.jpg', isDirectory: false);
    const video = NetworkEntry(sourceId: 'nas', path: '/2024/clip.mp4', isDirectory: false);
    var launched = 0;
    Future<void> pump(List<NetworkEntry> entries) => tester.pumpConsumerWidget(
      Scaffold(
        body: DesktopShareEnhanceButton(entries: entries, onLaunched: () => launched++),
      ),
      overrides: [
        aiFeaturesEnabledProvider.overrideWith((ref) => true),
        shareEnhanceOpenerProvider.overrideWithValue((context, entries) async {
          opened.add(entries);
          return true;
        }),
      ],
    );
    await pump([video]);
    expect(tester.widget<FilledButton>(find.byKey(const Key('ai_enhance'))).onPressed, isNull);
    await pump([photo, video]);
    await tester.tap(find.byKey(const Key('ai_enhance')));
    await tester.pump();
    expect(opened, [
      [photo, video],
    ]);
    expect(launched, 1);
  });

  test('Compare of a result on a share: the original and the result fetched again, and deleted after', () async {
    final salon = shared('/2024/salon.jpg', jpegFile(width: 40, height: 30));
    bridge.files['/2024/salon_enhanced.jpg'] = Uint8List.fromList([0xFF, 0xD8, 9, 0xFF, 0xD9]);
    final source = shareSource(salon);
    const target = ShareVersionTarget(folder: nas, fallbackFolder: '/tmp');
    const publish = SharePublish(target, state: SharePublishState.saved, path: '/2024/salon_enhanced.jpg');
    expect(canCompareRemote(source, publish: publish), isTrue);
    expect(canCompareRemote(source), isFalse, reason: 'its result is nowhere this computer can read');

    final pair = await fetchEnhanceCompare(source, shareSource, publish: publish, isCancelled: () => false);
    expect(File(pair.original).readAsBytesSync(), bridge.files['/2024/salon.jpg']);
    expect(File(pair.enhanced).readAsBytesSync(), [0xFF, 0xD8, 9, 0xFF, 0xD9]);
    expect(source.copyPath, isNull, reason: 'a copy of its own, never that of the job');
    await pair.release();
    expect(copies(), isEmpty);
  });

  testWidgets('Compare of a result on a share opens once both came, and deletes the copies as it closes', (
    tester,
  ) async {
    Uint8List png(int value) {
      final rgba = Uint8List(40 * 30 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba.fillRange(i, i + 3, value);
        rgba[i + 3] = 255;
      }
      return encodePngPicture(SbsDecoded(width: 40, height: 30, rgba: rgba));
    }

    final salon = shared('/2024/salon.jpg', png(40));
    bridge.files['/2024/salon_enhanced.jpg'] = png(200);
    const target = ShareVersionTarget(folder: nas, fallbackFolder: '/tmp');
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(
              showRemoteEnhanceCompare(
                context,
                shareSource(salon),
                publish: const SharePublish(target, state: SharePublishState.saved, path: '/2024/salon_enhanced.jpg'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(const Key('open')));
    await settle(tester, until: () => find.byType(EnhanceCompareDialog).evaluate().isNotEmpty);
    expect(find.byType(EnhanceCompareDialog), findsOneWidget);
    expect(copies(), hasLength(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester, until: () => copies().isEmpty);
    expect(copies(), isEmpty);
  });

  testWidgets('Compare that cannot fetch a photo says why in words of the app, never those of the share', (
    tester,
  ) async {
    // The result is no longer on the share: the bridge answers 404
    final salon = shared('/2024/salon.jpg', jpegFile(width: 40, height: 30));
    const target = ShareVersionTarget(folder: nas, fallbackFolder: '/tmp');
    await tester.pumpConsumerWidget(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(
              showRemoteEnhanceCompare(
                context,
                shareSource(salon),
                publish: const SharePublish(target, state: SharePublishState.saved, path: '/2024/gone_enhanced.jpg'),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: overrides(),
    );
    await tester.tap(find.byKey(const Key('open')));
    await settle(tester, until: () => find.byKey(const Key('ai_enhance_compare_failed')).evaluate().isNotEmpty);
    final said = tester.widget<Text>(find.byKey(const Key('ai_enhance_compare_failed'))).data!;
    expect(
      said,
      'The photos could not be fetched for the comparison: the share or the server cannot be reached, or the photo is '
      'no longer there',
    );
    expect(said, isNot(contains('answered')));
    expect(copies(), isEmpty, reason: 'the copy of the original deleted with the failure');
  });

  test('the reasons of a failed Compare, in words of the app', () {
    loadEnglishTexts();
    final t = StaticTranslations.instance;
    expect(
      enhanceCompareFailureText(t, const ConversionException(ImmersiveErrorCode.cancelled)),
      t.ai_immersive_state_cancelled,
    );
    expect(
      enhanceCompareFailureText(t, const ConversionException(ImmersiveErrorCode.diskFull, 'ENOSPC at /tmp/x')),
      t.ai_immersive_failed_disk_full,
    );
    expect(
      enhanceCompareFailureText(t, const ConversionException(ImmersiveErrorCode.writeFailed, 'errno 13')),
      t.ai_enhance_compare_copy_failed,
    );
    for (final error in [
      const ConversionException(ImmersiveErrorCode.sourceLost, 'http://127.0.0.1:4711/file?token=x: 404'),
      StateError('http://127.0.0.1:4711/'),
    ]) {
      final said = enhanceCompareFailureText(t, error);
      expect(said, t.ai_enhance_compare_unreachable);
      expect(said, isNot(contains('127.0.0.1')));
    }
  });
}
