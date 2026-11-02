// The engine of the splat scenes (lib/desktop/ai/splat/splat_engine.dart, lot SP6) on real child processes: the fake
// COLMAP and the fake Brush of lot SP0 compiled by `dart compile exe` (IMMUCH360_FAKE_COLMAP, IMMUCH360_FAKE_BRUSH),
// started through the launcher of the app (the job object on Windows, immuch360-run on Linux, IMMUCH360_RUN_LAUNCHER).
// A scene from the photos to the .spz the app's probe accepts, its steps in order with their counts and the time left;
// Retry from the poses kept, and not when a photo changed; Cancel at every step, within a second, the program gone;
// the failures of each step with their codes. Skipped without the fakes; the test job on Linux and the windows job of
// the desktop workflow compile them.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:path/path.dart' as p;

final _colmap = Platform.environment['IMMUCH360_FAKE_COLMAP'] ?? '';
final _brush = Platform.environment['IMMUCH360_FAKE_BRUSH'] ?? '';
final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];

/// Both fakes, and the launcher on Linux (the job object does it on Windows)
Object _skip() => _colmap.isEmpty || _brush.isEmpty
    ? 'IMMUCH360_FAKE_COLMAP and IMMUCH360_FAKE_BRUSH name no programs'
    : (!Platform.isWindows && (_launcher == null || _launcher!.isEmpty)
          ? 'IMMUCH360_RUN_LAUNCHER names no launcher'
          : false);

const _gib = 1024 * 1024 * 1024;

class _Memory implements MemoryProbe {
  const _Memory();

  @override
  MemoryFacts read() => const MemoryFacts(physical: 16 * _gib, available: 4 * _gib);
}

const _rtx = GpuAdapter(
  name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
  kind: GpuKind.discrete,
  localMemory: 8 * _gib,
  vendorId: 0x10DE,
  deviceId: 0x28A0,
  driverVersion: '616.56',
  vulkanIndex: 0,
);

/// A photo of this computer as a member: read in place, its sum computed at each read
class _FileMember implements SplatMember {
  _FileMember(this.file, this.taken);

  final File file;
  @override
  final DateTime taken;
  var loads = 0;
  var releases = 0;

  @override
  String get name => p.basename(file.path);

  @override
  String? get camera => null;

  @override
  Future<ImmersiveSource> load(NativeCancelFlag cancel) async {
    loads++;
    final bytes = file.readAsBytesSync();
    return ImmersiveSource(
      name: name,
      size: bytes.length,
      sha1: base64.encode(sha1.convert(bytes).bytes),
      path: file.path,
    );
  }

  @override
  Future<void> release() async => releases++;
}

/// What the test gives the engine for the preparation: each member read and copied into one camera, [delay] after each,
/// counting its calls
class _Images {
  _Images({this.delay = Duration.zero, this.usable});

  final Duration delay;

  /// Fewer usable images than members, when given (the others blurred)
  final int? usable;
  var calls = 0;

  Future<SplatPrepared> call(
    List<SplatMember> members, {
    required bool video,
    required String imagesFolder,
    required NativeCancelFlag cancel,
    required void Function(int done, int total) onProgress,
  }) async {
    calls++;
    final folder = Directory(p.join(imagesFolder, video ? 'video' : 'cam1'))..createSync(recursive: true);
    for (final (index, member) in members.indexed) {
      if (cancel.isCancelled) {
        throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled');
      }
      final source = await member.load(cancel);
      try {
        File(source.path!).copySync(p.join(folder.path, '${'${index + 1}'.padLeft(5, '0')}.jpg'));
      } finally {
        await member.release();
      }
      onProgress(index + 1, members.length);
      await Future<void>.delayed(delay);
    }
    final count = usable ?? members.length;
    return SplatPrepared(images: count, total: members.length, blurred: members.length - count);
  }
}

void main() {
  late Directory folder;
  late NativeCancelFlag cancel;
  late Directory root;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('splat-engine-');
    root = Directory(p.join(folder.path, 'work'));
    cancel = NativeCancelFlag();
  });
  tearDown(() {
    cancel.free();
    for (var k = 0; k < 20; k++) {
      try {
        folder.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 100));
      }
    }
  });

  /// [count] photos of 64 x 48, each its own tone, taken a second apart
  List<_FileMember> photos(int count) {
    final photos = Directory(p.join(folder.path, 'photos'))..createSync(recursive: true);
    return [
      for (var k = 0; k < count; k++)
        _FileMember(
          File(p.join(photos.path, 'IMG_${1000 + k}.jpg'))
            ..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(k * 5, 90, 70)))),
          DateTime.utc(2026, 11, 1, 10, 0, k),
        ),
    ];
  }

  ManagedProcessRunner runner() => ManagedProcessRunner(linuxLauncher: _launcher);

  SplatEngine engine({
    _Images? images,
    String colmapMode = 'ok',
    String brushMode = 'ok',
    Map<String, String> colmapMore = const {},
    Map<String, String> brushMore = const {},
  }) => SplatEngine(
    images: (images ?? _Images()).call,
    colmap: ColmapRunner(
      runner: runner(),
      colmap: _colmap,
      memory: const _Memory(),
      processors: 16,
      environment: {'IMMUCH360_FAKE_COLMAP_MODE': colmapMode, 'IMMUCH360_FAKE_COLMAP_STEP_MS': '0', ...colmapMore},
    ),
    brush: BrushRunner(
      runner: runner(),
      brush: _brush,
      cardCheck: () async => const BrushCardReady(_rtx, GpuReport(adapters: [_rtx])),
      cacheRoot: Directory(p.join(folder.path, 'brush-cache')),
      environment: {'IMMUCH360_FAKE_BRUSH_MODE': brushMode, 'IMMUCH360_FAKE_BRUSH_STEP_MS': '0', ...brushMore},
    ),
    roots: [SplatWorkRoot(root)],
  );

  SplatJob job(List<SplatMember> members, {bool ply = false, SplatSettings? settings}) {
    final out = Directory(p.join(folder.path, 'out'))..createSync(recursive: true);
    final spz = File(p.join(out.path, '.salon_splat.spz.1-1.immuch360.part'))..writeAsBytesSync(const []);
    final plyPart = ply
        ? (File(p.join(out.path, '.salon_splat.ply.1-2.immuch360.part'))..writeAsBytesSync(const []))
        : null;
    return SplatJob(
      id: 'conversion-1',
      lead: const ImmersiveSource(name: 'IMG_1000.jpg', size: 1, sha1: 'x', path: 'IMG_1000.jpg'),
      members: members,
      partPath: spz.path,
      plyPartPath: plyPart?.path,
      derivativeId: 'd',
      creatorTool: 'Immuch360 Desktop test',
      created: '2026-11-02T02:00:00',
      settings: settings ?? const SplatSettings(steps: 1000, maxGaussians: 3000),
    );
  }

  List<Directory> workFolders() => root.existsSync() ? root.listSync().whereType<Directory>().toList() : const [];

  test(
    'a scene from 24 photos: every step in order with its counts and the time left, the .spz the probe accepts',
    () async {
      final members = photos(24);
      final progress = <ImmersiveProgress>[];
      final splat = job(
        members,
        ply: true,
        settings: const SplatSettings(steps: 1000, maxGaussians: 3000, subject: SplatSubject.object),
      );
      final result = await engine().run(splat, cancel: cancel, onProgress: progress.add);

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      final details = result.details! as SplatResultDetails;
      expect((details.gaussians, details.images, details.placed, details.subject), (2000, 24, 24, SplatSubject.object));
      expect(details.plyBytes, File(splat.plyPartPath!).lengthSync());
      expect(result.bytesWritten, File(splat.partPath).lengthSync());
      final bytes = File(splat.partPath).readAsBytesSync();
      final head = probeSplatHead(Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, splatHeadBytes)), bytes.length);
      expect(head, isA<SplatHead>());
      head as SplatHead;
      expect((head.format, head.formatVersion, head.gaussians, head.shDegree), (SplatFormat.spz, 2, 2000, 3));
      // The steps of a scene of photos, in their order, never going back
      final stages = [
        for (final (index, entry) in progress.indexed)
          if (index == 0 || progress[index - 1].stage != entry.stage) entry.stage,
      ];
      expect(stages, [
        ImmersiveStage.reading,
        ImmersiveStage.photos,
        ImmersiveStage.features,
        ImmersiveStage.matching,
        ImmersiveStage.mapping,
        ImmersiveStage.training,
        ImmersiveStage.splatCopy,
      ]);
      for (var k = 1; k < progress.length; k++) {
        expect(progress[k].perMille, greaterThanOrEqualTo(progress[k - 1].perMille), reason: '${progress[k]}');
      }
      expect(progress.every((entry) => entry.remaining != null), isTrue);
      expect(progress.lastWhere((x) => x.stage == ImmersiveStage.photos).step, 24);
      expect(progress.lastWhere((x) => x.stage == ImmersiveStage.features).step, 24);
      expect(progress.lastWhere((x) => x.stage == ImmersiveStage.mapping).step, 24);
      expect(
        (
          progress.lastWhere((x) => x.stage == ImmersiveStage.training).step,
          progress.lastWhere((x) => x.stage == ImmersiveStage.training).steps,
        ),
        (1000, 1000),
      );
      expect(
        result.stageTimes.keys,
        containsAll([ImmersiveStage.photos, ImmersiveStage.features, ImmersiveStage.training]),
      );
      // Each member read once and released
      expect(members.every((member) => member.loads == 1 && member.releases == 1), isTrue);
      // Its work folder gone with its file
      expect(workFolders(), isEmpty);
    },
    skip: _skip(),
  );

  test('a video: its frames, one camera, its steps without the photos', () async {
    final members = photos(24);
    final progress = <ImmersiveProgress>[];
    final splat = SplatJob(
      id: 'conversion-2',
      lead: const ImmersiveSource(name: 'walk.mp4', size: 1, sha1: 'x', path: 'walk.mp4'),
      members: members,
      isVideo: true,
      partPath: (File(p.join(folder.path, '.walk_splat.spz.part'))..writeAsBytesSync(const [])).path,
      derivativeId: 'd',
      creatorTool: 't',
      created: 'c',
      settings: const SplatSettings(steps: 400, maxGaussians: 3000),
    );
    final result = await engine().run(splat, cancel: cancel, onProgress: progress.add);

    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    expect((result.details! as SplatResultDetails).fromVideo, isTrue);
    expect(progress.map((x) => x.stage), contains(ImmersiveStage.frames));
    expect(progress.map((x) => x.stage), isNot(contains(ImmersiveStage.photos)));
  }, skip: _skip());

  test(
    'Retry from the poses: the training failed, the folder kept; again, COLMAP and the photos are not run',
    () async {
      final members = photos(24);
      final images = _Images();
      final failed = await engine(images: images, brushMode: 'fail').run(job(members), cancel: cancel);
      expect(failed.error, ImmersiveErrorCode.trainingFailed);
      expect(workFolders(), hasLength(1));
      final state = jsonDecode(File(p.join(workFolders().single.path, splatStateFileName)).readAsStringSync()) as Map;
      expect(state['placed'], 24);
      expect(File(p.join(workFolders().single.path, aiWorkLastUsedName)).existsSync(), isTrue);

      final pids = File(p.join(folder.path, 'colmap.pid'));
      final progress = <ImmersiveProgress>[];
      final again = await engine(
        images: images,
        colmapMore: {'IMMUCH360_FAKE_COLMAP_PID': pids.path},
      ).run(job(members), cancel: cancel, onProgress: progress.add);

      expect(again.isDone, isTrue, reason: '${again.error}: ${again.message}');
      expect(images.calls, 1, reason: 'the photos were not prepared again');
      expect(pids.existsSync(), isFalse, reason: 'COLMAP did not run again');
      expect(progress.map((x) => x.stage).toSet(), {
        ImmersiveStage.reading,
        ImmersiveStage.photos,
        ImmersiveStage.training,
        ImmersiveStage.splatCopy,
      });
      // The photos were read again for their sums, once each
      expect(members.every((member) => member.loads == 2 && member.releases == 2), isTrue);
      expect((again.details! as SplatResultDetails).placed, 24);
      expect(workFolders(), isEmpty);
    },
    skip: _skip(),
  );

  test('a photo changed since: the poses are found again', () async {
    final members = photos(24);
    final images = _Images();
    await engine(images: images, brushMode: 'fail').run(job(members), cancel: cancel);
    members[7].file.writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(1, 2, 3))));

    final pids = File(p.join(folder.path, 'colmap.pid'));
    final again = await engine(
      images: images,
      colmapMore: {'IMMUCH360_FAKE_COLMAP_PID': pids.path},
    ).run(job(members), cancel: cancel);

    expect(again.isDone, isTrue, reason: '${again.error}: ${again.message}');
    expect(images.calls, 2);
    expect(pids.existsSync(), isTrue);
  }, skip: _skip());

  group('Cancel within a second at every step, the program gone, nothing kept before the poses', () {
    // The exhaustive matching counts blocks of 50 images: 60 photos give 4 of them
    for (final (at, count, colmapMode, brushMode, delay) in [
      (ImmersiveStage.photos, 30, 'ok', 'ok', const Duration(milliseconds: 300)),
      (ImmersiveStage.features, 24, 'slow', 'ok', Duration.zero),
      (ImmersiveStage.matching, 60, 'slow', 'ok', Duration.zero),
      (ImmersiveStage.mapping, 24, 'slow', 'ok', Duration.zero),
      (ImmersiveStage.training, 24, 'ok', 'slow', Duration.zero),
    ]) {
      test(at.name, () async {
        final members = photos(count);
        final pid = File(p.join(folder.path, 'program.pid'));
        final watch = Stopwatch();
        final reached = Completer<void>();
        final result =
            engine(
              images: _Images(delay: delay),
              colmapMode: colmapMode,
              brushMode: brushMode,
              colmapMore: {'IMMUCH360_FAKE_COLMAP_PID': pid.path, 'IMMUCH360_FAKE_COLMAP_STEP_MS': '100'},
              brushMore: {'IMMUCH360_FAKE_BRUSH_PID': pid.path, 'IMMUCH360_FAKE_BRUSH_STEP_MS': '300'},
            ).run(
              job(members, settings: const SplatSettings(steps: 4000, maxGaussians: 3000)),
              cancel: cancel,
              onProgress: (progress) {
                // Some way into the step: its second count
                if (progress.stage == at && (progress.step ?? 0) >= 2 && !reached.isCompleted) {
                  reached.complete();
                }
              },
            );
        await reached.future.timeout(const Duration(seconds: 60));
        watch.start();
        cancel.cancel();
        final ended = await result;
        watch.stop();

        expect(ended.error, ImmersiveErrorCode.cancelled);
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)), reason: '${at.name}: ${watch.elapsed}');
        if (at != ImmersiveStage.photos) {
          expect(processImageOf(int.parse(pid.readAsStringSync())), isNull, reason: 'the program is gone');
        }
        // Before the poses nothing is kept; once placed, the folder waits for Retry
        expect(workFolders(), at == ImmersiveStage.training ? hasLength(1) : isEmpty);
      }, skip: _skip());
    }
  });

  group('the failures of each step, with their codes', () {
    test('fewer than 20 usable images: tooFewImages with the counts, nothing kept', () async {
      final result = await engine(images: _Images(usable: 12)).run(job(photos(24)), cancel: cancel);
      expect((result.error, result.message), (ImmersiveErrorCode.tooFewImages, '12/24'));
      expect(workFolders(), isEmpty);
    }, skip: _skip());

    test('no two photos matched: notEnoughOverlap, none placed', () async {
      final result = await engine(colmapMode: 'nomodel').run(job(photos(24)), cancel: cancel);
      expect((result.error, result.message), (ImmersiveErrorCode.notEnoughOverlap, '0/24'));
    }, skip: _skip());

    test('kernels the card refuses: gpuUnavailable, the poses kept for another card', () async {
      final result = await engine(brushMode: 'planes').run(job(photos(24)), cancel: cancel);
      expect(result.error, ImmersiveErrorCode.gpuUnavailable);
      expect(result.message, contains('plane instructions'));
      expect(workFolders(), hasLength(1));
    }, skip: _skip());

    test('the memory of the card too short: gpuOutOfMemory', () async {
      final result = await engine(brushMode: 'oom').run(job(photos(24)), cancel: cancel);
      expect(result.error, ImmersiveErrorCode.gpuOutOfMemory);
    }, skip: _skip());

    test('no work folder with an ASCII path: writeFailed, said', () async {
      final splat = SplatEngine(
        images: _Images().call,
        colmap: ColmapRunner(runner: runner(), colmap: _colmap),
        brush: BrushRunner(
          runner: runner(),
          brush: _brush,
          cardCheck: () async => const BrushCardRefused('gpuNone'),
          cacheRoot: folder,
        ),
        roots: const [],
        pickRoot: (roots) => null,
      );
      final result = await splat.run(job(photos(24)), cancel: cancel);
      expect(result.error, ImmersiveErrorCode.writeFailed);
      expect(result.message, contains('path COLMAP can read'));
    });
  });
}
