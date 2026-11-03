// The engine of the splat scenes (lib/desktop/ai/splat/splat_engine.dart, lot SP6) on real child processes: the fake
// COLMAP and the fake Brush of lot SP0 compiled by `dart compile exe` (IMMUCH360_FAKE_COLMAP, IMMUCH360_FAKE_BRUSH),
// started through the launcher of the app (the job object on Windows, immuch360-run on Linux, IMMUCH360_RUN_LAUNCHER).
// A scene from the photos to the .spz the app's probe accepts, its steps in order with their counts and the time left;
// Retry from the poses kept, and not when a photo changed; Cancel at every step, within a second, the program gone;
// the failures of each step with their codes, the logs of a failure kept in the logs folder of the app and the command
// of COLMAP named; after a failure of COLMAP, the work folder kept with its images, its database and its models,
// named in the result and in the log of the failure, and a Retry from its images (lot SPF1); a scene of fewer than
// half of its images placed made all the same, the count told from the poses on; the folder a failure left gone when
// another scene starts (lot SPF2). Skipped without the fakes; the test job on Linux and the windows job of the desktop
// workflow compile them.

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
import 'package:logging/logging.dart';
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

/// An original of the server as a member: it says its sum (the checksum Immich gives) without being read; [knownSha1]
/// is what the server says, the sum of its file unless the test changes it
class _ServerMember extends _FileMember implements SplatMemberSum {
  _ServerMember(super.file, super.taken) : knownSha1 = base64.encode(sha1.convert(file.readAsBytesSync()).bytes);

  @override
  String? knownSha1;
}

/// What the test gives the engine for the preparation, as the app does it: 200 photos at most, each read and copied
/// into one camera, or SplatV1.videoFrames frames of the one video, [delay] after each image and [onEach] called, counting
/// its calls
class _Images {
  _Images({this.delay = Duration.zero, this.usable, this.onEach, this.after});

  final Duration delay;

  /// Fewer usable images than taken, when given (the others blurred)
  final int? usable;

  /// Called after each image, as the time it takes passes
  final void Function()? onEach;

  /// Called with the images folder once they are prepared
  final void Function(String imagesFolder)? after;
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
    void checkCancel() {
      if (cancel.isCancelled) {
        throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled');
      }
    }

    Future<void> next(int index, int total) async {
      onEach?.call();
      onProgress(index + 1, total);
      await Future<void>.delayed(delay);
    }

    final int total;
    if (video) {
      // The frames of a video of up to two minutes
      total = SplatV1.videoFrames;
      final source = await members.single.load(cancel);
      try {
        for (var index = 0; index < total; index++) {
          checkCancel();
          File(source.path!).copySync(p.join(folder.path, '${'${index + 1}'.padLeft(5, '0')}.jpg'));
          await next(index, total);
        }
      } finally {
        await members.single.release();
      }
    } else {
      final taken = members.take(SplatV1.maxPhotos).toList();
      total = taken.length;
      for (final (index, member) in taken.indexed) {
        checkCancel();
        final source = await member.load(cancel);
        try {
          File(source.path!).copySync(p.join(folder.path, '${'${index + 1}'.padLeft(5, '0')}.jpg'));
        } finally {
          await member.release();
        }
        await next(index, total);
      }
    }
    after?.call(imagesFolder);
    final count = usable ?? total;
    return SplatPrepared(images: count, total: total, blurred: total - count);
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

  /// What the engine logs from now to the end of the test (the tests run with the log off)
  List<String> listenToLog() {
    final said = <String>[];
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final listening = Logger.root.onRecord.listen((record) => said.add(record.message));
    addTearDown(() async {
      await listening.cancel();
      Logger.root.level = previous;
    });
    return said;
  }

  SplatEngine engine({
    _Images? images,
    String colmapMode = 'ok',
    String brushMode = 'ok',
    Map<String, String> colmapMore = const {},
    Map<String, String> brushMore = const {},
    Duration Function()? elapsed,
    Duration colmapStall = SplatV1.colmapSilence,
    Directory? failureLogs,
  }) => SplatEngine(
    images: (images ?? _Images()).call,
    colmap: ColmapRunner(
      runner: runner(),
      colmap: _colmap,
      memory: const _Memory(),
      processors: 16,
      stallTimeout: colmapStall,
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
    elapsed: elapsed,
    failureLogs: failureLogs,
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
      final said = listenToLog();
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
      // Its work folder kept, marked used, until the queue saved its file, as its log says; then gone
      expect(said.where((line) => line.contains('The work folder')), [
        'The work folder ${workFolders().single.path} is kept until the file is saved',
      ]);
      expect(workFolders(), hasLength(1));
      expect(File(p.join(workFolders().single.path, aiWorkLastUsedName)).existsSync(), isTrue);
      await result.afterSaved!();
      expect(workFolders(), isEmpty);
    },
    skip: _skip(),
  );

  /// A clock of the engine: the time that passes, and [simulated] more, which the preparation adds to as a decoder
  /// would take it
  var simulated = Duration.zero;
  Duration Function() clock() {
    simulated = Duration.zero;
    final watch = Stopwatch()..start();
    return () => watch.elapsed + simulated;
  }

  /// A video of this computer as the one member of its job, as the queue gives it
  _FileMember video() {
    final file = File(p.join(folder.path, 'walk.mp4'))
      ..writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(90, 60, 30))));
    return _FileMember(file, DateTime.utc(2026, 11, 1, 10));
  }

  SplatJob videoJob(_FileMember member) => SplatJob(
    id: 'conversion-2',
    lead: const ImmersiveSource(name: 'walk.mp4', size: 1, sha1: 'x', path: 'walk.mp4'),
    members: [member],
    isVideo: true,
    partPath: (File(p.join(folder.path, '.walk_splat.spz.part'))..writeAsBytesSync(const [])).path,
    derivativeId: 'd',
    creatorTool: 't',
    created: 'c',
    settings: const SplatSettings(steps: 400, maxGaussians: 3000),
  );

  test('a video, its one member: its frames, one camera, its steps without the photos', () async {
    final progress = <ImmersiveProgress>[];
    final result = await engine().run(videoJob(video()), cancel: cancel, onProgress: progress.add);

    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    expect((result.details! as SplatResultDetails).fromVideo, isTrue);
    expect((result.details! as SplatResultDetails).images, SplatV1.videoFrames);
    expect(progress.map((x) => x.stage), contains(ImmersiveStage.frames));
    expect(progress.map((x) => x.stage), isNot(contains(ImmersiveStage.photos)));
  }, skip: _skip());

  test(
    'the time of a video of one member: its 150 frames told from the start and their time kept as it went',
    () async {
      final elapsed = clock();
      final progress = <ImmersiveProgress>[];
      final result = await engine(
        images: _Images(onEach: () => simulated += const Duration(milliseconds: 100)),
        elapsed: elapsed,
      ).run(videoJob(video()), cancel: cancel, onProgress: progress.add);

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      // The defaults of a video, for the 150 frames they are kept for, the training at 400 steps of 20 000
      const told = 5000 + 60000 + 15000 + 286000 + 36000 + 306000 * 400 / 20000 + 10000 + 1000;
      expect(progress.first.remaining!.inMilliseconds, closeTo(told, 1000));
      final frames = progress.firstWhere((x) => x.stage == ImmersiveStage.frames);
      expect((frames.step, frames.steps), (0, SplatV1.videoFrames));
      // 150 frames of 100 ms: 15 s, kept as they went (the times are kept for 150 frames)
      expect(result.stageTimes[ImmersiveStage.frames]!.inMilliseconds, closeTo(15000, 3000));
    },
    skip: _skip(),
  );

  test('more than 200 photos: the 200 taken, counted, told and kept from the start', () async {
    final elapsed = clock();
    final progress = <ImmersiveProgress>[];
    final result = await engine(
      images: _Images(onEach: () => simulated += const Duration(milliseconds: 100)),
      elapsed: elapsed,
      colmapMode: 'nomodel',
    ).run(job(photos(250)), cancel: cancel, onProgress: progress.add);

    expect(result.error, ImmersiveErrorCode.notEnoughOverlap);
    // The defaults of photos for 200 of them, their exhaustive matching by their pairs, 1 000 steps of 20 000
    const scale = 200 / 150;
    const pairs = 200 * 199 / (150 * 149);
    const told =
        5000 + 45000 * scale + 15000 * scale + 195000 * pairs + 50000 * scale + 450000 * 1000 / 20000 + 10000 + 1000;
    expect(progress.first.remaining!.inMilliseconds, closeTo(told, 1000));
    final first = progress.firstWhere((x) => x.stage == ImmersiveStage.photos);
    expect((first.step, first.steps), (0, SplatV1.maxPhotos));
    // 200 photos of 100 ms: 20 s, kept as 15 s for the 150 the times are kept for
    expect(result.stageTimes[ImmersiveStage.photos]!.inMilliseconds, closeTo(15000, 3000));
  }, skip: _skip());

  test('Retry from the poses: the training failed, the folder kept; again, COLMAP and the photos are not run', () async {
    final members = photos(24);
    final images = _Images();
    final said = listenToLog();
    final logs = Directory(p.join(folder.path, 'app-logs'));
    final failed = await engine(images: images, brushMode: 'fail', failureLogs: logs).run(job(members), cancel: cancel);
    expect(failed.error, ImmersiveErrorCode.trainingFailed);
    expect(workFolders(), hasLength(1));
    expect(
      said,
      contains(
        'The work folder ${workFolders().single.path} is kept until the next scene or a day, for Retry from its poses',
      ),
    );
    // The logs of COLMAP and of Brush kept with the failure, its folder kept too
    final kept = logs.listSync().whereType<File>().single.readAsStringSync();
    expect(kept, contains('failed: trainingFailed: '));
    expect(kept, contains('===== colmap-features.log, '));
    expect(kept, contains('===== brush.log, '));
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
    await again.afterSaved!();
    expect(workFolders(), isEmpty);
  }, skip: _skip());

  test(
    'Retry from the poses of originals of the server: their sums taken from the server, none downloaded again',
    () async {
      final members = [for (final member in photos(24)) _ServerMember(member.file, member.taken)];
      final images = _Images();
      final failed = await engine(images: images, brushMode: 'fail').run(job(members), cancel: cancel);
      expect(failed.error, ImmersiveErrorCode.trainingFailed);

      final again = await engine(images: images).run(job(members), cancel: cancel);
      expect(again.isDone, isTrue, reason: '${again.error}: ${again.message}');
      expect(images.calls, 1, reason: 'the poses were taken again');
      expect(members.every((member) => member.loads == 1), isTrue, reason: 'read by the preparation only');
      await again.afterSaved!();

      // An original changed on the server since: its new sum makes the poses again
      await engine(images: images, brushMode: 'fail').run(job(members), cancel: cancel);
      members[3].knownSha1 = base64.encode(List.filled(20, 7));
      final changed = await engine(images: images).run(job(members), cancel: cancel);
      expect(changed.isDone, isTrue, reason: '${changed.error}: ${changed.message}');
      expect(images.calls, 3);
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

  test('which work folder stays when a job ends: until saved, a day once placed, a day after a failure of COLMAP', () {
    expect(splatWorkKept(done: true, placed: false, prepared: true), isTrue);
    expect(
      splatWorkKept(done: false, placed: true, prepared: true, failure: ImmersiveErrorCode.trainingFailed),
      isTrue,
    );
    expect(splatWorkKept(done: false, placed: true, prepared: true, failure: ImmersiveErrorCode.cancelled), isTrue);
    // The images prepared, COLMAP failed: kept for Retry and for a diagnosis (the frames of 3 November were lost)
    for (final code in [
      ImmersiveErrorCode.notEnoughOverlap,
      ImmersiveErrorCode.posesFailed,
      ImmersiveErrorCode.posesStalled,
      ImmersiveErrorCode.outOfMemory,
    ]) {
      expect(splatWorkKept(done: false, placed: false, prepared: true, failure: code), isTrue, reason: code.name);
    }
    // A Cancel, and a full disk, which the folder would fill more
    expect(splatWorkKept(done: false, placed: false, prepared: true, failure: ImmersiveErrorCode.cancelled), isFalse);
    expect(splatWorkKept(done: false, placed: false, prepared: true, failure: ImmersiveErrorCode.diskFull), isFalse);
    // Before the images were prepared: nothing worth keeping
    expect(
      splatWorkKept(done: false, placed: false, prepared: false, failure: ImmersiveErrorCode.tooFewImages),
      isFalse,
    );
  });

  test(
    'COLMAP placed too few: the work folder kept a day with its images, database and models, named in the result and '
    'in the log of the failure; Retry from its images, COLMAP run again; gone a day later',
    () async {
      final members = photos(24);
      final images = _Images();
      final said = listenToLog();
      final logs = Directory(p.join(folder.path, 'app-logs'));
      // A fifth placed: 4 of 24
      final failed = await engine(
        images: images,
        colmapMode: 'few',
        failureLogs: logs,
      ).run(job(members), cancel: cancel);

      expect((failed.error, failed.message), (ImmersiveErrorCode.notEnoughOverlap, '4/24'));
      final kept = workFolders().single;
      expect(failed.keptFolder, kept.path);
      final work = SplatWorkFolder(kept);
      expect(work.images.listSync(recursive: true).whereType<File>(), hasLength(24));
      expect(work.database.existsSync(), isTrue);
      expect(Directory(p.join(work.sparse.path, '0')).existsSync(), isTrue);
      expect(work.logOf('colmap-mapping').existsSync(), isTrue);
      expect(File(p.join(kept.path, aiWorkLastUsedName)).existsSync(), isTrue);
      // A Retry of the same images would place the same ones: kept for a diagnosis (lot SPF2)
      expect(said, contains('The work folder ${kept.path} is kept until the next scene or a day, for a diagnosis'));
      final text = logs.listSync().whereType<File>().single.readAsStringSync();
      expect(text, contains('failed: notEnoughOverlap: 4/24\n'));
      expect(
        text,
        contains(
          'The work folder is kept until the next scene or a day, for a diagnosis (its images, the database and the '
          'models of COLMAP; a Retry of the same images would place the same ones)\nWork folder: ${kept.path}\n',
        ),
      );

      final pids = File(p.join(folder.path, 'colmap.pid'));
      final again = await engine(
        images: images,
        colmapMore: {'IMMUCH360_FAKE_COLMAP_PID': pids.path},
      ).run(job(members), cancel: cancel);
      expect(again.isDone, isTrue, reason: '${again.error}: ${again.message}');
      expect(images.calls, 1, reason: 'the photos were not prepared again');
      expect(pids.existsSync(), isTrue, reason: 'COLMAP ran again');
      expect(members.every((member) => member.loads == 2), isTrue, reason: 'read again for their sums');
      expect((again.details! as SplatResultDetails).placed, 24);
      await again.afterSaved!();
      expect(workFolders(), isEmpty);

      // Failed again, then a day later: the sweep of the next job takes it
      await engine(images: images, colmapMode: 'few').run(job(members), cancel: cancel);
      expect(workFolders(), hasLength(1));
      touchAiWorkFolder(workFolders().single, at: DateTime.now().subtract(const Duration(hours: 25)));
      expect(await deleteOldSplatWork([SplatWorkRoot(root)]), 1);
      expect(workFolders(), isEmpty);
    },
    skip: _skip(),
  );

  test('the folder a failure left goes when another scene starts, whatever its age, and with it every other one (lot '
      'SPF2): a failure keeps its folder until the next scene or a day', () async {
    final failed = await engine(colmapMode: 'few').run(job(photos(24)), cancel: cancel);
    final first = Directory(failed.keptFolder!);
    expect(workFolders().map((work) => work.path), [first.path]);
    // A folder of another scene, left by an earlier session an hour ago
    final other = Directory(p.join(root.path, splatWorkFolderName('f' * 40)))..createSync(recursive: true);
    touchAiWorkFolder(other, at: DateTime.now().subtract(const Duration(hours: 1)));

    final again = await engine(colmapMode: 'few').run(job(photos(30)), cancel: cancel);
    expect(again.keptFolder, isNotNull);
    expect(workFolders().map((work) => work.path), [again.keptFolder]);
    expect((first.existsSync(), other.existsSync()), (false, false));
  }, skip: _skip());

  test('a photo changed after a failure of COLMAP: the images are prepared again', () async {
    final members = photos(24);
    final images = _Images();
    await engine(images: images, colmapMode: 'few').run(job(members), cancel: cancel);
    members[5].file.writeAsBytesSync(img.encodeJpg(img.Image(width: 64, height: 48)..clear(img.ColorRgb8(9, 8, 7))));
    final again = await engine(images: images).run(job(members), cancel: cancel);
    expect(again.isDone, isTrue, reason: '${again.error}: ${again.message}');
    expect(images.calls, 2);
    await again.afterSaved!();
  }, skip: _skip());

  test('two fifths placed: made all the same, the count told from the poses to the end and in the result', () async {
    final progress = <ImmersiveProgress>[];
    final result = await engine(
      colmapMode: 'incomplete',
    ).run(job(photos(60)), cancel: cancel, onProgress: progress.add);

    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    final details = result.details! as SplatResultDetails;
    expect((details.placed, details.images, details.isIncomplete), (24, 60, true));
    expect(result.keptFolder, isNull);
    // Nothing said before the poses, then the count with every progress
    expect(progress.where((x) => x.stage == ImmersiveStage.features).map((x) => x.placed).toSet(), {null});
    final after = progress.where((x) => x.stage == ImmersiveStage.training || x.stage == ImmersiveStage.splatCopy);
    expect(after, isNotEmpty);
    expect(after.map((x) => x.placed).toSet(), {const SplatPlaced(24, 60)});
    await result.afterSaved!();
  }, skip: _skip());

  test(
    'a work folder that cannot be deleted at once: tried again without holding the isolate, then left for a day',
    () async {
      // A folder of the work folder whose file cannot be deleted, as Windows holds a file a moment after its program
      final images = _Images(
        after: (imagesFolder) {
          final held = Directory(p.join(p.dirname(p.dirname(imagesFolder)), 'held'))..createSync();
          File(p.join(held.path, 'export.ply')).writeAsStringSync('held');
          Process.runSync('chmod', ['500', held.path]);
          addTearDown(() => Process.runSync('chmod', ['700', held.path]));
        },
      );
      // The longest the isolate went without running a timer of 10 ms, to the end of the job
      var longest = Duration.zero;
      final beat = Stopwatch()..start();
      void tick() {
        if (beat.elapsed > longest) {
          longest = beat.elapsed;
        }
        beat.reset();
      }

      final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => tick());
      // Too few usable images: a failure before COLMAP, whose folder goes at once
      final result = await engine(
        images: _Images(usable: 12, after: images.after),
      ).run(job(photos(24)), cancel: cancel);
      tick();
      timer.cancel();

      expect(result.error, ImmersiveErrorCode.tooFewImages);
      expect(workFolders(), hasLength(1), reason: 'it stays until it is a day old');
      expect(File(p.join(workFolders().single.path, aiWorkLastUsedName)).existsSync(), isTrue);
      expect(longest, lessThan(const Duration(milliseconds: 500)));
    },
    skip: Platform.isWindows || Process.runSync('id', ['-u']).stdout.toString().trim() == '0'
        ? 'a folder that cannot be deleted needs chmod, as another user than root'
        : _skip(),
  );

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
    test('COLMAP silent at the matching: posesStalled naming the command and its last lines; the logs of the job kept '
        'in the logs folder of the app though its work folder went', () async {
      final logs = Directory(p.join(folder.path, 'app-logs'));
      final result = await engine(
        colmapMode: 'silent',
        colmapMore: {'IMMUCH360_FAKE_COLMAP_MODE_AT': 'exhaustive_matcher'},
        colmapStall: const Duration(seconds: 2),
        failureLogs: logs,
      ).run(job(photos(24)), cancel: cancel);

      expect(result.error, ImmersiveErrorCode.posesStalled);
      expect(
        result.message,
        startsWith('COLMAP (exhaustive_matcher) wrote nothing for 2 s and was stopped; its last lines:\n'),
      );
      expect(result.message, contains('Generating exhaustive image pairs...'));
      // Its images kept a day with what COLMAP wrote, for Retry and for a diagnosis (lot SPF1)
      expect(workFolders(), hasLength(1));
      expect(result.keptFolder, workFolders().single.path);
      final kept = logs.listSync().whereType<File>().single;
      expect(p.basename(kept.path), matches(RegExp(r'^splat-[0-9a-f]{16}-\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d\.log$')));
      final text = kept.readAsStringSync();
      expect(
        text,
        startsWith(
          'Splat scene conversion-1 (IMG_1000.jpg, 24 photos, place) failed: posesStalled: '
          'COLMAP (exhaustive_matcher) wrote nothing for 2 s',
        ),
      );
      expect(text, contains('===== colmap-features.log, '));
      expect(text, contains('Processed file [24/24]'));
      expect(text, contains('===== colmap-matching.log, '));
      expect(text, contains('Generating exhaustive image pairs...'));
    }, skip: _skip());

    test(
      'COLMAP failing at the extraction: posesFailed naming the command, its log kept; a Cancel keeps none',
      () async {
        final logs = Directory(p.join(folder.path, 'app-logs'));
        final result = await engine(colmapMode: 'fail', failureLogs: logs).run(job(photos(24)), cancel: cancel);

        expect(result.error, ImmersiveErrorCode.posesFailed);
        expect(result.message, startsWith('COLMAP (feature_extractor) ended with 1: '));
        expect(result.message, contains('(fake failure)'));
        expect(workFolders(), hasLength(1), reason: 'its images kept a day');
        final text = logs.listSync().whereType<File>().single.readAsStringSync();
        expect(text, contains('failed: posesFailed: COLMAP (feature_extractor) ended with 1: '));
        expect(text, contains('===== colmap-features.log, '));
        expect(text, contains('=== Feature extraction ==='));

        // Cancelled at the extraction: no log kept
        final again = Directory(p.join(folder.path, 'app-logs-cancel'));
        final reached = Completer<void>();
        final cancelled =
            engine(colmapMode: 'slow', colmapMore: {'IMMUCH360_FAKE_COLMAP_STEP_MS': '100'}, failureLogs: again).run(
              job(photos(24)),
              cancel: cancel,
              onProgress: (progress) {
                if (progress.stage == ImmersiveStage.features && (progress.step ?? 0) >= 2 && !reached.isCompleted) {
                  reached.complete();
                }
              },
            );
        await reached.future.timeout(const Duration(seconds: 60));
        cancel.cancel();
        final ended = await cancelled;
        expect(ended.error, ImmersiveErrorCode.cancelled);
        expect(ended.keptFolder, isNull);
        expect(again.existsSync() ? again.listSync() : const <FileSystemEntity>[], isEmpty);
        // A Cancel keeps no folder, not even the one of the failure before (the same photos, the same key)
        expect(workFolders(), isEmpty);
      },
      skip: _skip(),
    );

    test('fewer than 20 usable images: tooFewImages with the counts, nothing kept', () async {
      final result = await engine(images: _Images(usable: 12)).run(job(photos(24)), cancel: cancel);
      expect((result.error, result.message), (ImmersiveErrorCode.tooFewImages, '12/24'));
      expect(workFolders(), isEmpty);
    }, skip: _skip());

    test('no two photos matched: notEnoughOverlap, none placed, the images kept a day', () async {
      final result = await engine(colmapMode: 'nomodel').run(job(photos(24)), cancel: cancel);
      expect((result.error, result.message), (ImmersiveErrorCode.notEnoughOverlap, '0/24'));
      expect(result.keptFolder, workFolders().single.path);
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
