// The acceptance tests 15.1, 15.2, 15.3 and 15.8 of the specification on a real computer, by hand only (lot V). The
// real catalogue and service install the components of this computer from IMMUCH360_AI_COMPONENTS_MIRROR (the folder
// .github/desktop/ai/publish_ai_components.py fills, or the address of the published release). Then the queue of the
// app runs the real engine (ONNX Runtime and Depth Anything V2 Small, behind the hardware gate) and the writer of the
// app on a folder library made of the photos of IMMUCH360_AI_PHOTOS, handed over the way the conversion dialog does it:
// the destination session, its checks and their partial files. Each 3D photo is read back by the probe and by the
// library, and the originals are compared byte for byte. Never in the CI, which downloads no model.
//
//   IMMUCH360_AI_COMPONENTS_MIRROR=/path/of/the/mirror IMMUCH360_AI_PHOTOS=~/v/photos IMMUCH360_AI_WORK=~/v/work \
//     flutter test test/desktop/ai/real_conversion_test.dart
//
// Test 2 (offline) is the "next to the original" test run again with no network once the components are installed,
// for instance under `sudo unshare -n sudo -u $USER env ... flutter test --name "next to the original"`. The disk full
// test runs only when IMMUCH360_AI_SMALL_DISK names an empty folder on a small disk (a tmpfs of some 40 MB): a filler
// file leaves too little space for one 3D photo, the queue pauses, the filler goes, Resume makes the photo.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:path/path.dart' as p;

import '../library/library_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final mirror = environment[aiComponentsMirrorVariable];
  final photos = environment['IMMUCH360_AI_PHOTOS'];
  final work = environment['IMMUCH360_AI_WORK'];
  final smallDisk = environment['IMMUCH360_AI_SMALL_DISK'];
  final platform = aiPlatformOf(Abi.current());
  final missing = [
    if (mirror == null) aiComponentsMirrorVariable,
    if (photos == null) 'IMMUCH360_AI_PHOTOS',
    if (work == null) 'IMMUCH360_AI_WORK',
  ];
  final skip = missing.isNotEmpty
      ? 'by hand: set ${missing.join(', ')}'
      : platform == null
      ? 'no AI components for ${Abi.current()}'
      : null;

  late AiComponentsService service;
  late HardwareGate gate;

  setUpAll(() async {
    if (skip != null) {
      return;
    }
    final components = Directory(p.join(work!, 'components'))..createSync(recursive: true);
    service = AiComponentsService(folder: () async => components);
    for (final component in aiComponentsFor(platform!)) {
      if (await service.verifiedFile(component) != null) {
        _say('${component.id}: already installed');
        continue;
      }
      final watch = Stopwatch()..start();
      await service.install(component);
      _say('${component.id}: installed from the mirror in ${watch.elapsedMilliseconds} ms');
    }
    gate = HardwareGate(components: ServiceComponentFiles(service));
    final found = await gate.evaluate();
    expect(found.isAvailable, isTrue, reason: '$found');
    _say(
      'gate: ${found.platform!.name}, ONNX Runtime ${found.runtimeVersion}, ${found.processors} processors, '
      '${(found.physicalMemory ?? 0) >> 20} MiB',
    );
  });

  /// A folder library under the work folder, with [names] copied from the photos into its folder [folder]
  Future<_Bench> bench(String label, {List<String>? names, String folder = 'Photos'}) async {
    final root = Directory(p.join(work!, label));
    if (root.existsSync()) {
      _writable(root);
      root.deleteSync(recursive: true);
    }
    final fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'lin-0000v000';
    final library = Directory(p.join(fixture.files.path, folder))..createSync(recursive: true);
    final chosen = Directory(p.join(root.path, 'chosen'))..createSync(recursive: true);
    final settings = Directory(p.join(root.path, 'settings'))..createSync(recursive: true);
    final all = Directory(photos!).listSync().whereType<File>().where((file) => _isPhoto(file.path)).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final picked = names == null
        ? all
        : [for (final name in names) all.firstWhere((file) => p.basename(file.path) == name)];
    for (final file in picked) {
      file.copySync(p.join(library.path, p.basename(file.path)));
    }
    final rootId = fixture.library().addRoot(library.path).id;
    await fixture.scan();
    return _Bench(
      label: label,
      fixture: fixture,
      rootId: rootId,
      folder: library.path,
      chosen: chosen.path,
      store: DesktopAiSettingsStore(settingsDirectory: () async => settings),
      writer: SafeWriter(journal: InflightJournal(settingsDirectory: () async => settings)),
      originals: {
        for (final file in Directory(library.path).listSync().whereType<File>())
          p.basename(file.path): _Original.of(File(file.path)),
      },
    );
  }

  /// What the conversion dialog does on Convert: a destination session for the photos of [bench], opened, the
  /// chosen folder [chosen] when given, then the queue of the app fed with the requests and the partial files of the
  /// checks
  Future<_Run> launch(_Bench bench, {String? chosen}) async {
    final library = bench.fixture.library();
    final jobs = <DestinationJob>[];
    for (final name in bench.originals.keys.toList()..sort()) {
      final original = LibraryOriginal.of(library, bench.fixture.ids.file(bench.rootId, name));
      expect(original, isNotNull, reason: name);
      jobs.add(DestinationJob(id: name, original: original!));
    }
    final session = DestinationSession(
      jobs,
      store: bench.store,
      writer: bench.writer,
      downloadFolder: () async => bench.chosen,
      rules: bench.fixture.rules,
    );
    await session.open();
    if (chosen != null) {
      await session.chooseFolder(chosen);
    }
    for (final job in jobs) {
      final check = session.checkOf(job.id);
      expect(check?.accepted, isTrue, reason: '${job.id}: ${session.destinations[job.id]} $check');
    }

    final output = SafeWriterOutput(writer: bench.writer, mayWriteInto: (_) async => true);
    final container = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWithValue(
          ConversionTools(
            engine: DesktopAiEngine(gate: gate),
            output: output,
            finder: ExistingVersionFinder(index: LibraryVersionIndex(library: () async => bench.fixture.library())),
            creatorTool: aiCreatorTool('3.3.0', system: Platform.operatingSystem),
            software: aiSoftware('3.3.0'),
          ),
        ),
      ],
    );
    container.listen(conversionQueueProvider, (_, next) => dropUntakenParts(output, next));
    final requests = [
      for (final job in jobs)
        ConversionRequest(
          source: LocalFileSource((job.original as LibraryOriginal).path),
          target: ConversionTarget(folder: session.destinations[job.id]!.folder, fileName: job.finalName),
        ),
    ];
    final watch = Stopwatch()..start();
    final ids = container.read(conversionQueueProvider.notifier).add(requests);
    for (final (index, job) in jobs.indexed) {
      final part = session.takePart(job.id);
      if (part != null) {
        output.adopt(ids[index], part);
      }
    }
    await session.close();
    return _Run(container: container, ids: ids, jobs: jobs, session: session, watch: watch);
  }

  /// Every file of [folder] and below, hidden ones included
  List<String> filesUnder(String folder) => [
    for (final entry in Directory(folder).listSync(recursive: true))
      if (entry is File) p.relative(entry.path, from: folder),
  ]..sort();

  /// The checks of one 3D photo: its frame, our XMP read back, the probe, the colour profile, and the original intact
  Future<void> checkSbs(_Bench bench, String name, ConversionJob job, {required String folder}) async {
    final written = job.writtenPath!;
    expect(p.dirname(written), folder, reason: name);
    expect(p.basename(written), sbsFileNameFor(name));
    final bytes = File(written).readAsBytesSync();
    final header = JpegHeader.read(bytes);
    final original = bench.originals[name]!;

    expect(header.width, job.eyeWidth! * 2, reason: '$name: two eyes side by side');
    expect(header.height, job.eyeHeight, reason: name);
    final xmp = StereoPhotoXmp.findIn(bytes);
    expect(xmp, isNotNull, reason: '$name: our XMP');
    expect(xmp!.kind, ImmersiveKind.stereoPhoto);
    expect(xmp.eyes, StereoEyes.full);
    expect(xmp.eyeOrder, EyeOrder.leftRight);
    expect(xmp.eyeWidth, job.eyeWidth);
    expect(xmp.eyeHeight, job.eyeHeight);
    expect(xmp.origin, ImmersiveOrigin.estimatedDepth);
    expect(xmp.leftEye, LeftEyeSource.original);
    expect(xmp.sourceSha1, original.sha1Base64, reason: '$name: SourceSha1 is the base64 SHA-1 of the original');
    expect(xmp.sourceName, name);
    expect(xmp.sourceSize, original.size);
    expect(xmp.derivativeId, startsWith('urn:uuid:'));
    expect(xmp.depthModelSha256, depthModelOnnxSha256);
    expect(xmp.pipeline, ReliefV1.pipeline);
    expect(xmp.parallax, ReliefV1.parallax);
    expect(xmp.convergence, ReliefV1.convergence);
    expect(xmp.creatorTool, startsWith('Immuch360 Desktop'));

    final probed = probeStereoPhotoHead(bytes.sublist(0, bytes.length.clamp(0, 256 * 1024)), name: p.basename(written));
    expect(probed, isNotNull, reason: '$name: the probe tells a 3D photo');
    expect(probed!.isOurs, isTrue);
    expect(probed.isEstimatedRelief, isTrue);
    expect(probed.canShowIn3d, isTrue);
    expect(probed.request, isNotNull);

    // The profile written is always that of the pixels: the one of a JPEG original as it is, none for the others
    final originalBytes = File(original.path).readAsBytesSync();
    final originalProfile = _isJpeg(name) ? JpegHeader.read(originalBytes).iccProfile : null;
    if (originalProfile == null) {
      expect(header.iccProfile, isNull, reason: '$name: pixels in sRGB, no profile');
    } else {
      expect(header.iccProfile, originalProfile, reason: '$name: the profile of the original copied as it is');
    }
    expect(original.unchanged(), isTrue, reason: '$name: the original is unchanged, byte for byte');
    _say(
      '  $name -> ${p.basename(written)}: ${header.width} x ${header.height}, ${bytes.length} bytes, quality '
      '${header.estimatedQuality}, ${header.subsampling?.name}, profile ${header.iccProfile?.length ?? 'none'}, '
      'flags ${xmp.qualityFlags.map((flag) => flag.xmp).join(',')}${job.reduced ? ', reduced' : ''}',
    );
  }

  test(
    'Test 1: next to the original, in a folder of the library; the library knows each 3D photo as a version',
    () async {
      final bench0 = await bench('t1-next-to-original');
      final run = await launch(bench0);
      await run.allEnded(const Duration(minutes: 40));
      final elapsed = run.watch.elapsed;
      final queue = run.state;
      _say('Test 1: ${queue.jobs.length} photos in ${elapsed.inSeconds} s');

      for (final (index, job) in queue.jobs.indexed) {
        final name = run.jobs[index].id;
        expect(job.state, ConversionState.done, reason: '$name: ${job.error} ${job.message}');
        await checkSbs(bench0, name, job, folder: bench0.folder);
      }
      // Nothing else written: one 3D photo per original, no partial file, hidden or not
      expect(
        filesUnder(bench0.folder),
        [
          for (final name in bench0.originals.keys) ...[name, sbsFileNameFor(name)],
        ]..sort(),
      );
      expect(filesUnder(bench0.chosen), isEmpty);

      // The library reads them back: a version of its original, by the sum of the original, and the original of it
      await bench0.fixture.scan();
      final library = bench0.fixture.library();
      final finder = PhotoVersionsFinder(library);
      for (final name in bench0.originals.keys) {
        final original = bench0.originals[name]!;
        final originalId = bench0.fixture.ids.file(bench0.rootId, name);
        final versionId = bench0.fixture.ids.file(bench0.rootId, sbsFileNameFor(name));
        final indexed = library.index.file(versionId)!;
        expect(indexed.origin, IndexedOrigin.estimated, reason: name);
        expect(indexed.sourceSha1, original.sha1Base64, reason: name);
        expect(indexed.stereo, isNotNull, reason: '$name: indexed as a side by side photo');
        final versions = await finder.find(originalId, checksum: original.sha1Base64);
        expect(versions.versions.map((version) => version.name), [sbsFileNameFor(name)], reason: name);
        expect(versions.versions.single.isEstimatedRelief, isTrue);
        final self = await finder.find(versionId);
        expect(self.isVersion, isTrue, reason: name);
        expect(self.original?.path, original.path, reason: name);
      }
      _say('Test 1: the library lists ${bench0.originals.length} versions, each linked to its original');

      // The same batch again: each photo already has a version with the same settings, skipped by default
      final again = await launch(bench0);
      await again.allEnded(const Duration(minutes: 5));
      expect(again.state.jobs.map((job) => job.state).toSet(), {ConversionState.skipped});
      expect(again.state.jobs.map((job) => job.skipReason).toSet(), {ConversionSkipReason.sameSettingsExists});
      // The partial files of the checks no job took are deleted as their jobs end
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(filesUnder(bench0.folder), hasLength(bench0.originals.length * 2));
      _say('Test 1: the same batch again skips every photo, "a version with the same settings exists"');
      run.container.dispose();
      again.container.dispose();
    },
    timeout: const Timeout(Duration(minutes: 60)),
    skip: skip,
  );

  test(
    'Test 3: a folder of the library without write access; the 3D photos go to the chosen folder',
    () async {
      final bench3 = await bench(
        't3-read-only',
        names: ['flat_wide_street_01.jpg', 'night_street.jpg', 'studio_alpha.png'],
        folder: 'ReadOnly',
      );
      Process.runSync('chmod', ['555', bench3.folder]);
      for (final name in bench3.originals.keys) {
        Process.runSync('chmod', ['444', p.join(bench3.folder, name)]);
      }
      expect(
        () => File(p.join(bench3.folder, 'probe.txt')).writeAsStringSync('x'),
        throwsA(isA<FileSystemException>()),
      );
      try {
        final run = await launch(bench3);
        for (final job in run.jobs) {
          final plan = run.session.destinations[job.id]!;
          expect(plan.kind, DestinationKind.chosenFolder, reason: '${job.id}: $plan');
          expect(plan.reason, DestinationReason.folderReadOnly, reason: '${job.id}: $plan');
          expect(plan.folder, bench3.chosen);
        }
        await run.allEnded(const Duration(minutes: 20));
        for (final (index, job) in run.state.jobs.indexed) {
          final name = run.jobs[index].id;
          expect(job.state, ConversionState.done, reason: '$name: ${job.error} ${job.message}');
          await checkSbs(bench3, name, job, folder: bench3.chosen);
        }
        expect(filesUnder(bench3.folder), bench3.originals.keys.toList()..sort());
        expect(filesUnder(bench3.chosen), [for (final name in bench3.originals.keys) sbsFileNameFor(name)]..sort());
        // The refusal is kept for the root: the next dialog goes to the chosen folder at once
        final kept = await bench3.store.read();
        expect(kept.rootFallbacks.values, contains(bench3.chosen));
        _say('Test 3: ${run.state.jobs.length} photos of a read-only folder saved in the chosen folder');
        run.container.dispose();
      } finally {
        _writable(Directory(bench3.folder));
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
    skip: skip,
  );

  test(
    'Test 8: Cancel all while the second photo is being computed; nothing partial is left, the originals stay',
    () async {
      final bench8 = await bench(
        't8-cancel',
        names: ['flat_the_sky_is_on_fire.jpg', 'flat_wide_street_01.jpg', 'indoor_hall.jpg', 'indoor_studio.jpg'],
      );
      final run = await launch(bench8);
      final second = run.ids[1];
      final reached = await run.waitFor((state) {
        final job = state.byId(second)!;
        return job.state == ConversionState.depth || job.state == ConversionState.rightEye || job.state.isEnded;
      }, const Duration(minutes: 10));
      final at = run.state.byId(second)!.state;
      expect(reached, isTrue);
      expect(at.isEnded, isFalse, reason: 'the second photo had ended before the cancel');
      run.container.read(conversionQueueProvider.notifier).cancelAll();
      await run.allEnded(const Duration(minutes: 5));
      final states = run.state.jobs.map((job) => job.state).toList();
      _say('Test 8: cancelled while the second photo was at "${at.name}": ${states.map((state) => state.name)}');
      expect(states, [
        ConversionState.done,
        ConversionState.cancelled,
        ConversionState.cancelled,
        ConversionState.cancelled,
      ]);
      // Give the worker the time to stop and the writer to delete the partial file
      await Future<void>.delayed(const Duration(seconds: 3));
      final first = run.jobs.first.id;
      expect(filesUnder(bench8.folder), [...bench8.originals.keys, sbsFileNameFor(first)]..sort());
      for (final original in bench8.originals.values) {
        expect(original.unchanged(), isTrue, reason: original.path);
      }
      run.container.dispose();
    },
    timeout: const Timeout(Duration(minutes: 30)),
    skip: skip,
  );

  test(
    'A disk full pauses the queue; once space is freed, Resume makes the photo',
    () async {
      final disk = Directory(smallDisk!);
      expect(disk.listSync(), isEmpty, reason: 'IMMUCH360_AI_SMALL_DISK must be an empty folder');
      final bench9 = await bench('t9-disk-full', names: ['indoor_studio.jpg']);
      // Leaves some 3 MB, enough for the check of the dialog, too little for a 3D photo of some 15 MB
      final free = _freeBytes(disk.path);
      final filler = File(p.join(disk.path, 'filler.bin'));
      final sink = filler.openSync(mode: FileMode.write);
      final block = Uint8List(1 << 20);
      for (var left = free - (3 << 20); left > 0; left -= block.length) {
        sink.writeFromSync(block, 0, left < block.length ? left : block.length);
      }
      sink.closeSync();
      _say('disk full: ${_freeBytes(disk.path) >> 10} KiB left on ${disk.path}');
      try {
        await bench9.store.update((settings) => settings.copyWith(destination: AiDestination.folder));
        final run = await launch(bench9, chosen: disk.path);
        final paused = await run.waitFor((state) => state.isPaused, const Duration(minutes: 10));
        expect(paused, isTrue, reason: '${run.state.jobs}');
        final job = run.state.jobs.single;
        expect(job.state, ConversionState.failed);
        expect(job.error, ImmersiveErrorCode.diskFull);
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(filesUnder(disk.path), ['filler.bin'], reason: 'no partial file left on the full disk');
        _say('disk full: the queue paused, "${job.message}"');

        filler.deleteSync();
        run.container.read(conversionQueueProvider.notifier).resume();
        await run.allEnded(const Duration(minutes: 10));
        final done = run.state.jobs.single;
        expect(done.state, ConversionState.done, reason: '${done.error} ${done.message}');
        await checkSbs(bench9, 'indoor_studio.jpg', done, folder: disk.path);
        expect(filesUnder(disk.path), [sbsFileNameFor('indoor_studio.jpg')]);
        _say('disk full: space freed, Resume made the photo');
        run.container.dispose();
      } finally {
        if (filler.existsSync()) {
          filler.deleteSync();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
    skip: skip ?? (smallDisk == null ? 'set IMMUCH360_AI_SMALL_DISK to an empty folder on a small disk' : null),
  );
}

void _say(String line) {
  // ignore: avoid_print
  print(line);
}

bool _isJpeg(String path) => const ['.jpg', '.jpeg'].contains(p.extension(path).toLowerCase());

bool _isPhoto(String path) => _isJpeg(path) || p.extension(path).toLowerCase() == '.png';

void _writable(Directory folder) {
  if (folder.existsSync()) {
    Process.runSync('chmod', ['-R', 'u+w', folder.path]);
  }
}

int _freeBytes(String folder) {
  final result = Process.runSync('df', ['--output=avail', '-B1', folder]);
  return int.parse((result.stdout as String).trim().split('\n').last.trim());
}

/// An original as it was before the conversions: the SHA-256 and the SHA-1 of its bytes, its size and its date
class _Original {
  _Original(this.path, this.size, this.sha256Hex, this.sha1Base64, this.modified);

  factory _Original.of(File file) {
    final bytes = file.readAsBytesSync();
    return _Original(
      file.path,
      bytes.length,
      sha256.convert(bytes).toString(),
      base64.encode(sha1.convert(bytes).bytes),
      file.lastModifiedSync(),
    );
  }

  final String path;
  final int size;
  final String sha256Hex;
  final String sha1Base64;
  final DateTime modified;

  bool unchanged() {
    final file = File(path);
    return file.lengthSync() == size &&
        sha256.convert(file.readAsBytesSync()).toString() == sha256Hex &&
        file.lastModifiedSync() == modified;
  }
}

class _Bench {
  _Bench({
    required this.label,
    required this.fixture,
    required this.rootId,
    required this.folder,
    required this.chosen,
    required this.store,
    required this.writer,
    required this.originals,
  });

  final String label;
  final TestLibrary fixture;
  final String rootId;
  final String folder;
  final String chosen;
  final DesktopAiSettingsStore store;
  final SafeWriter writer;
  final Map<String, _Original> originals;
}

class _Run {
  _Run({required this.container, required this.ids, required this.jobs, required this.session, required this.watch});

  final ProviderContainer container;
  final List<String> ids;
  final List<DestinationJob> jobs;
  final DestinationSession session;
  final Stopwatch watch;

  ConversionQueueState get state => container.read(conversionQueueProvider);

  Future<bool> waitFor(bool Function(ConversionQueueState state) done, Duration limit) async {
    final end = DateTime.now().add(limit);
    while (!done(state)) {
      if (DateTime.now().isAfter(end)) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return true;
  }

  Future<void> allEnded(Duration limit) async {
    final ended = await waitFor((state) => state.jobs.every((job) => job.state.isEnded), limit);
    expect(ended, isTrue, reason: '${state.jobs.map((job) => '${job.id} ${job.state.name}')}');
  }
}
