// The queue of the 3D conversions of a computer (design-final 2026-10-26, section 2.6), run with FakeImmersiveEngine:
// the states in the words of the spec, one job at a time, a failure that stays with its photo, the pause of a disk
// full and Resume, Retry and Retry failed, a version with the same settings skipped, made again or replaced, Cancel and
// Cancel all, Clear finished. The writer of lot A5b is reduced here to what the queue relies on: a .part with a dot
// name next to the target, renamed at the end, "name (1)" when the name is taken.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_immersive_engine.dart';

/// The fake of each photo by its name, else [fallback]; tells which photos ran and how many at once
class _Engines implements ImmersiveEngine {
  _Engines([FakeImmersiveEngine? fallback]) : fallback = fallback ?? FakeImmersiveEngine();

  FakeImmersiveEngine fallback;
  final byName = <String, FakeImmersiveEngine>{};
  final ran = <String>[];
  var _running = 0;
  var mostAtOnce = 0;

  @override
  Future<ImmersiveResult> run(
    ImmersiveJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    ran.add(job.source.name);
    mostAtOnce = math.max(mostAtOnce, ++_running);
    try {
      return await (byName[job.source.name] ?? fallback).run(job, cancel: cancel, onProgress: onProgress);
    } finally {
      _running--;
    }
  }

  @override
  Future<void> dispose() async {}
}

/// The writer of the 3D photos, reduced to what the queue relies on: SafeWriter.commit of lot A5b, which replaces a
/// file of the folder of the .part only, and only when it still carries our XMP with a DerivativeId
class _Output implements ConversionOutput {
  final begun = <String>[];
  final discarded = <String>[];

  /// What each finish was asked
  final finished = <(AiWhenExists, String?)>[];
  ImmersiveErrorCode? failFinish;

  @override
  Future<String> begin(ConversionJob job) async {
    final target = job.target!;
    final path = p.join(target.folder, '.${target.fileName}.$pid-${begun.length + 1}.immuch360.part');
    File(path).writeAsBytesSync(const []);
    begun.add(path);
    return path;
  }

  @override
  Future<ConversionSaved> finish(
    ConversionJob job,
    String partPath, {
    required AiWhenExists whenExists,
    String? replaceName,
  }) async {
    finished.add((whenExists, replaceName));
    final code = failFinish;
    if (code != null) {
      throw ConversionException(code, 'Scripted failure of the rename');
    }
    final target = job.target!;
    final named = p.join(
      p.dirname(partPath),
      whenExists == AiWhenExists.replace ? replaceName ?? target.fileName : target.fileName,
    );
    if (File(named).existsSync()) {
      if (whenExists == AiWhenExists.skip) {
        File(partPath).deleteSync();
        return ConversionSaved(path: named, outcome: ConversionSaveOutcome.skipped);
      }
      final id = StereoPhotoXmp.findIn(File(named).readAsBytesSync())?.derivativeId;
      if (whenExists == AiWhenExists.replace && id != null && id.trim().isNotEmpty) {
        File(partPath).renameSync(named);
        return ConversionSaved(path: named, outcome: ConversionSaveOutcome.replaced);
      }
    }
    var path = target.path;
    for (var n = 1; File(path).existsSync(); n++) {
      path = p.join(
        target.folder,
        '${p.basenameWithoutExtension(target.fileName)} ($n)${p.extension(target.fileName)}',
      );
    }
    File(partPath).renameSync(path);
    return ConversionSaved(path: path, outcome: ConversionSaveOutcome.saved);
  }

  @override
  Future<void> discard(String partPath) async {
    discarded.add(partPath);
    final file = File(partPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}

/// The index of the library as lot A6a fills it: the versions of an original by its sum
class _Index implements DerivedVersionIndex {
  final paths = <String, List<String>>{};

  /// Thrown by each question: the database closed
  Error? error;

  @override
  Future<List<String>> versionPathsOf(String sourceSha1) async {
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    return paths[sourceSha1] ?? const [];
  }
}

String _sumOf(List<int> bytes) => base64.encode(crypto.sha1.convert(bytes).bytes);

/// The sum of the file at [path] in Dart, without an isolate per job
Future<String> _dartSum(String path, NativeCancelFlag cancel) async => _sumOf(File(path).readAsBytesSync());

void main() {
  late Directory root;
  late String photos;
  late _Engines engines;
  late _Output output;
  late _Index index;
  late Future<List<String>> Function(String folder) listFolder;
  late ProviderContainer container;
  late int derivatives;

  setUp(() {
    root = Directory.systemTemp.createTempSync('conversion_queue');
    photos = p.join(root.path, 'photos');
    Directory(photos).createSync();
    engines = _Engines();
    output = _Output();
    index = _Index();
    listFolder = listFileNames;
    derivatives = 0;
    container = ProviderContainer(
      overrides: [
        conversionToolsProvider.overrideWithValue(
          ConversionTools(
            engine: engines,
            output: output,
            finder: ExistingVersionFinder(index: index, listFolder: (folder) => listFolder(folder)),
            creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
            software: 'Immuch360 Desktop 3.3.0',
            now: () => DateTime(2026, 10, 27, 10, 12),
            newDerivativeId: () => 'urn:uuid:00000000-0000-4000-8000-${(++derivatives).toString().padLeft(12, '0')}',
          ),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    root.deleteSync(recursive: true);
  });

  ConversionQueueNotifier queue() => container.read(conversionQueueProvider.notifier);
  ConversionQueueState current() => container.read(conversionQueueProvider);
  ConversionJob job(String id) => current().byId(id)!;

  /// An original in the photos folder, its 3D photo planned next to it
  ConversionRequest photo(String name, {int turns = 0}) {
    final bytes = Uint8List.fromList(List.generate(64, (i) => (i * 7 + name.length) & 0xff));
    final path = p.join(photos, name);
    File(path).writeAsBytesSync(bytes);
    return ConversionRequest(
      source: LocalFileSource(path, hash: _dartSum),
      target: ConversionTarget.nextTo(path),
      quarterTurns: turns,
    );
  }

  /// A 3D photo of ours made from the original at [originalPath], at [name] in [folder], the photos folder by default
  String version(String originalPath, String name, {int turns = 0, String id = 'urn:uuid:old', String? folder}) {
    final bytes = File(originalPath).readAsBytesSync();
    final xmp = StereoPhotoXmp.estimated(
      eyeWidth: 8,
      eyeHeight: 6,
      depthModelSha256: depthModelOnnxSha256,
      sourceName: p.basename(originalPath),
      sourceSize: bytes.length,
      sourceSha1: _sumOf(bytes),
      sourceQuarterTurns: turns,
      created: '2026-10-20T09:00:00+02:00',
      creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
      derivativeId: id,
    );
    return (File(p.join(folder ?? photos, name))..writeAsBytesSync(fakeSbsJpeg(xmp: xmp))).path;
  }

  /// Completes once [test] holds for the state of the queue
  Future<void> until(bool Function(ConversionQueueState state) test) async {
    if (test(current())) {
      return;
    }
    final reached = Completer<void>();
    final subscription = container.listen(conversionQueueProvider, (_, next) {
      if (!reached.isCompleted && test(next)) {
        reached.complete();
      }
    });
    try {
      await reached.future.timeout(const Duration(seconds: 10));
    } finally {
      subscription.close();
    }
  }

  Future<void> allEnded() => until((state) => state.jobs.every((job) => job.state.isEnded));

  /// What the photos folder holds besides the originals
  List<String> leftInFolder(Set<String> originals) => [
    for (final entry in Directory(photos).listSync())
      if (!originals.contains(p.basename(entry.path))) p.basename(entry.path),
  ]..sort();

  test('a job goes through the states in the words of the spec, and its 3D photo lands next to the original', () async {
    final request = photo('salon.jpg', turns: 1);
    final original = File(p.join(photos, 'salon.jpg'));
    final before = original.readAsBytesSync();
    final modified = original.lastModifiedSync();
    final states = <ConversionState>[];
    container.listen(conversionQueueProvider, (_, next) {
      final state = next.jobs.firstOrNull?.state;
      if (state != null && (states.isEmpty || states.last != state)) {
        states.add(state);
      }
    });

    final id = queue().add([request]).single;
    await allEnded();

    expect(states, [
      ConversionState.waiting,
      ConversionState.reading,
      ConversionState.decoding,
      ConversionState.depth,
      ConversionState.rightEye,
      ConversionState.encoding,
      ConversionState.writing,
      ConversionState.done,
    ]);
    expect(states.map((state) => state.phase).toSet().toList(), [
      ConversionPhase.waiting,
      ConversionPhase.preparing,
      ConversionPhase.computing,
      ConversionPhase.finishing,
      ConversionPhase.done,
    ]);
    final done = job(id);
    expect(done.kind, ConversionKind.sbsFromPhoto);
    expect([done.batchIndex, done.batchSize], [1, 1]);
    expect(done.perMille, 1000);
    expect(done.writtenPath, p.join(photos, 'salon_3D_LRF_Full_SBS.jpg'));
    expect([done.eyeWidth, done.eyeHeight], [8, 6]);
    expect(done.replaced, isFalse);
    final xmp = StereoPhotoXmp.findIn(File(done.writtenPath!).readAsBytesSync())!;
    expect(xmp.sourceSha1, _sumOf(before));
    expect(xmp.sourceName, 'salon.jpg');
    expect(xmp.sourceQuarterTurns, 1);
    expect(xmp.derivativeId, 'urn:uuid:00000000-0000-4000-8000-000000000001');
    expect(xmp.created, StereoPhotoXmp.xmpDateTime(DateTime(2026, 10, 27, 10, 12)));
    expect(engines.fallback.jobs.single.exif.software, 'Immuch360 Desktop 3.3.0');
    // Nothing else in the folder, and the original as it was
    expect(leftInFolder({'salon.jpg'}), ['salon_3D_LRF_Full_SBS.jpg']);
    expect(original.readAsBytesSync(), before);
    expect(original.lastModifiedSync(), modified);
    expect(current().hasWork, isFalse);
  });

  test('one job at a time, in their order, each with its place in the batch', () async {
    engines.fallback = FakeImmersiveEngine(holdStage: ImmersiveStage.depth);
    final hold = engines.fallback;
    var held = hold.reachedHold.stream.first;

    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg')]);
    for (final (index, id) in ids.indexed) {
      await held;
      expect(job(id).phase, ConversionPhase.computing);
      expect(current().current?.id, id);
      expect([for (final other in ids.skip(index + 1)) job(other).state], everyElement(ConversionState.waiting));
      expect(current().pending, ids.length - index);
      held = hold.reachedHold.stream.first;
      hold.release();
    }
    await allEnded();

    expect(engines.ran, ['a.jpg', 'b.jpg', 'c.jpg']);
    expect(engines.mostAtOnce, 1);
    expect([for (final id in ids) (job(id).batchIndex, job(id).batchSize)], [(1, 3), (2, 3), (3, 3)]);
    expect([for (final id in ids) job(id).state], everyElement(ConversionState.done));
  });

  test('a failure stays with its photo: the others are done, and nothing of it is left', () async {
    engines.byName['b.jpg'] = FakeImmersiveEngine(
      failAt: ImmersiveStage.depth,
      failure: ImmersiveErrorCode.decodeFailed,
    );

    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg')]);
    await allEnded();

    expect([for (final id in ids) job(id).state], [ConversionState.done, ConversionState.failed, ConversionState.done]);
    expect(job(ids[1]).error, ImmersiveErrorCode.decodeFailed);
    expect(job(ids[1]).message, contains('depth'));
    expect(job(ids[1]).writtenPath, isNull);
    expect(output.discarded, [output.begun[1]]);
    expect(leftInFolder({'a.jpg', 'b.jpg', 'c.jpg'}), ['a_3D_LRF_Full_SBS.jpg', 'c_3D_LRF_Full_SBS.jpg']);
    expect(current().isPaused, isFalse);
  });

  test('a disk full pauses the queue; Resume runs that photo again and goes on', () async {
    engines.byName['b.jpg'] = FakeImmersiveEngine(failAt: ImmersiveStage.writing, failure: ImmersiveErrorCode.diskFull);

    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg')]);
    await until((state) => state.isPaused);
    // Nothing starts while paused
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      [for (final id in ids) job(id).state],
      [ConversionState.done, ConversionState.failed, ConversionState.waiting],
    );
    expect(job(ids[1]).error, ImmersiveErrorCode.diskFull);
    expect(engines.ran, ['a.jpg', 'b.jpg']);
    expect(current().hasWork, isTrue);
    expect(leftInFolder({'a.jpg', 'b.jpg', 'c.jpg'}), ['a_3D_LRF_Full_SBS.jpg']);

    // Space freed
    engines.byName.remove('b.jpg');
    queue().resume();
    await allEnded();

    expect(current().isPaused, isFalse);
    expect([for (final id in ids) job(id).state], everyElement(ConversionState.done));
    expect(engines.ran, ['a.jpg', 'b.jpg', 'b.jpg', 'c.jpg']);
  });

  test('a disk full while the 3D photo is renamed pauses the queue too', () async {
    output.failFinish = ImmersiveErrorCode.diskFull;

    final ids = queue().add([photo('a.jpg'), photo('b.jpg')]);
    await until((state) => state.isPaused);

    expect(job(ids[0]).error, ImmersiveErrorCode.diskFull);
    expect(job(ids[1]).state, ConversionState.waiting);
    expect(output.discarded, [output.begun.single]);
    expect(leftInFolder({'a.jpg', 'b.jpg'}), isEmpty);

    output.failFinish = null;
    queue().resume();
    await allEnded();
    expect([for (final id in ids) job(id).state], everyElement(ConversionState.done));
  });

  test('Retry runs a failed photo again, Retry failed every one of them', () async {
    engines.byName['b.jpg'] = FakeImmersiveEngine(
      failAt: ImmersiveStage.depth,
      failure: ImmersiveErrorCode.modelFailed,
    );
    engines.byName['c.jpg'] = FakeImmersiveEngine(
      failAt: ImmersiveStage.encoding,
      failure: ImmersiveErrorCode.outOfMemory,
    );

    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg')]);
    await allEnded();
    expect([job(ids[1]).state, job(ids[2]).state], everyElement(ConversionState.failed));

    engines.byName.clear();
    queue().retry(ids[0]);
    expect(job(ids[0]).state, ConversionState.done);
    queue().retry(ids[1]);
    await until((state) => state.byId(ids[1])!.state == ConversionState.done);
    expect(job(ids[2]).state, ConversionState.failed);
    expect(job(ids[1]).error, isNull);

    queue().retryFailed();
    await allEnded();
    expect([for (final id in ids) job(id).state], everyElement(ConversionState.done));
    expect(engines.ran, ['a.jpg', 'b.jpg', 'c.jpg', 'b.jpg', 'c.jpg']);
  });

  group('a photo that already has a 3D version', () {
    test('with the same settings is skipped by default, without running', () async {
      final request = photo('salon.jpg');
      final existing = version(p.join(photos, 'salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');

      final id = queue().add([request]).single;
      await allEnded();

      expect(job(id).state, ConversionState.skipped);
      expect(job(id).skipReason, ConversionSkipReason.sameSettingsExists);
      expect(job(id).existingVersionPath, existing);
      expect(engines.ran, isEmpty);
      expect(output.begun, isEmpty);
    });

    test('an original edited in place at the same size since then is converted again: its sum is read now', () async {
      final request = photo('salon.jpg');
      final original = p.join(photos, 'salon.jpg');
      version(original, 'salon_3D_LRF_Full_SBS.jpg');
      // Turned outside the app, one byte of the EXIF changed, before any scan
      File(original).writeAsBytesSync([...File(original).readAsBytesSync()]..[10] ^= 0xff);

      final id = queue().add([request]).single;
      await allEnded();

      expect(job(id).state, ConversionState.done);
      expect(job(id).writtenPath, p.join(photos, 'salon_3D_LRF_Full_SBS (1).jpg'));
      expect(
        StereoPhotoXmp.findIn(File(job(id).writtenPath!).readAsBytesSync())!.sourceSha1,
        _sumOf(File(original).readAsBytesSync()),
      );
    });

    test('with other settings does not count: the new one goes beside it', () async {
      final request = photo('salon.jpg');
      version(p.join(photos, 'salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg', turns: 1);

      final id = queue().add([request]).single;
      await allEnded();

      expect(job(id).state, ConversionState.done);
      expect(job(id).writtenPath, p.join(photos, 'salon_3D_LRF_Full_SBS (1).jpg'));
    });

    test('Make a new version keeps the old one and gives the new one its own DerivativeId', () async {
      final request = photo('salon.jpg');
      final existing = version(p.join(photos, 'salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');
      final old = File(existing).readAsBytesSync();

      final id = queue().add([request], existing: ExistingVersionChoice.newVersion).single;
      await allEnded();

      expect(job(id).state, ConversionState.done);
      expect(job(id).writtenPath, p.join(photos, 'salon_3D_LRF_Full_SBS (1).jpg'));
      expect(File(existing).readAsBytesSync(), old);
      expect(StereoPhotoXmp.findIn(File(job(id).writtenPath!).readAsBytesSync())!.derivativeId, isNot('urn:uuid:old'));
    });

    test('Replace takes the place of that version, read again just before', () async {
      final request = photo('salon.jpg');
      final existing = version(p.join(photos, 'salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');

      final id = queue().add([request], existing: ExistingVersionChoice.replace).single;
      await allEnded();

      expect(job(id).state, ConversionState.done);
      expect(job(id).replaced, isTrue);
      expect(job(id).writtenPath, existing);
      expect(job(id).existingVersionPath, existing);
      expect(output.finished, [(AiWhenExists.replace, 'salon_3D_LRF_Full_SBS.jpg')]);
      expect(
        StereoPhotoXmp.findIn(File(existing).readAsBytesSync())!.derivativeId,
        'urn:uuid:00000000-0000-4000-8000-000000000001',
      );
      expect(leftInFolder({'salon.jpg'}), ['salon_3D_LRF_Full_SBS.jpg']);
    });

    test('known by the index in another folder, with the same settings, is skipped too', () async {
      final request = photo('salon.jpg');
      final original = p.join(photos, 'salon.jpg');
      final other = (Directory(p.join(root.path, 'other'))..createSync()).path;
      final moved = version(original, 'salon_3D_LRF_Full_SBS.jpg', folder: other);
      index.paths[_sumOf(File(original).readAsBytesSync())] = [moved];

      final id = queue().add([request]).single;
      await allEnded();

      expect(job(id).state, ConversionState.skipped);
      expect(job(id).existingVersionPath, moved);
      expect(engines.ran, isEmpty);
    });

    test('an index that fails leaves the neighbours to tell, and a search that fails never fails the photo', () async {
      index.error = StateError('The database is closed');
      final first = photo('salon.jpg');
      final existing = version(p.join(photos, 'salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');
      final skipped = queue().add([first]).single;
      await allEnded();

      expect(job(skipped).state, ConversionState.skipped);
      expect(job(skipped).existingVersionPath, existing);

      listFolder = (folder) async => throw StateError('The drive went to sleep');
      final converted = queue().add([photo('plage.jpg')]).single;
      await allEnded();

      expect(job(converted).state, ConversionState.done);
      expect(job(converted).error, isNull);
      expect(engines.ran, ['plage.jpg']);
    });

    test(
      'Replace only takes a version of the destination folder: one elsewhere stays, the new one goes there',
      () async {
        final request = photo('salon.jpg');
        final original = p.join(photos, 'salon.jpg');
        final other = (Directory(p.join(root.path, 'other'))..createSync()).path;
        final moved = version(original, 'salon_3D_LRF_Full_SBS.jpg', folder: other);
        final old = File(moved).readAsBytesSync();
        index.paths[_sumOf(File(original).readAsBytesSync())] = [moved];

        final id = queue().add([request], existing: ExistingVersionChoice.replace).single;
        await allEnded();

        expect(job(id).state, ConversionState.done);
        expect(job(id).writtenPath, p.join(photos, 'salon_3D_LRF_Full_SBS.jpg'));
        expect(job(id).replaced, isFalse);
        expect(job(id).existingVersionPath, isNull);
        expect(output.finished, [(AiWhenExists.keepBoth, null)]);
        expect(File(moved).readAsBytesSync(), old);
        expect(Directory(other).listSync().map((entry) => p.basename(entry.path)), ['salon_3D_LRF_Full_SBS.jpg']);
      },
    );

    test('Replace never takes the place of a file that is no longer ours: both are kept', () async {
      engines.fallback = FakeImmersiveEngine(holdStage: ImmersiveStage.encoding);
      final held = engines.fallback.reachedHold.stream.first;
      final request = photo('salon.jpg');
      final existing = version(p.join(photos, 'salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');

      final id = queue().add([request], existing: ExistingVersionChoice.replace).single;
      await held;
      // Another tool wrote over it meanwhile
      File(existing).writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]);
      engines.fallback.release();
      await allEnded();

      // The writer read it again at the rename and kept both: the job says so
      expect(output.finished, [(AiWhenExists.replace, 'salon_3D_LRF_Full_SBS.jpg')]);
      expect(job(id).state, ConversionState.done);
      expect(job(id).replaced, isFalse);
      expect(job(id).existingVersionPath, isNull);
      expect(job(id).writtenPath, p.join(photos, 'salon_3D_LRF_Full_SBS (1).jpg'));
      expect(File(existing).readAsBytesSync(), [0xff, 0xd8, 0xff, 0xd9]);
    });

    test('a name taken with Skip chosen for such files: skipped, nothing left', () async {
      final request = photo('salon.jpg');
      File(p.join(photos, 'salon_3D_LRF_Full_SBS.jpg')).writeAsBytesSync([1, 2, 3]);

      final id = queue().add([request], whenExists: AiWhenExists.skip).single;
      await allEnded();

      expect(output.finished, [(AiWhenExists.skip, null)]);
      expect(job(id).state, ConversionState.skipped);
      expect(job(id).skipReason, ConversionSkipReason.nameTaken);
      expect(leftInFolder({'salon.jpg'}), ['salon_3D_LRF_Full_SBS.jpg']);
      expect(File(p.join(photos, 'salon_3D_LRF_Full_SBS.jpg')).readAsBytesSync(), [1, 2, 3]);
    });

    test('a name taken by another version of ours is replaced when Replace is chosen for such files', () async {
      final request = photo('salon.jpg');
      final turned = version(p.join(photos, 'salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg', turns: 1);

      final id = queue().add([request], whenExists: AiWhenExists.replace).single;
      await allEnded();

      expect(output.finished, [(AiWhenExists.replace, null)]);
      expect(job(id).replaced, isTrue);
      expect(job(id).writtenPath, turned);
      expect(leftInFolder({'salon.jpg'}), ['salon_3D_LRF_Full_SBS.jpg']);
    });

    test('Make a new version never replaces, even with Replace chosen for a name taken', () async {
      final request = photo('salon.jpg');
      final existing = version(p.join(photos, 'salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');
      final old = File(existing).readAsBytesSync();

      final id = queue()
          .add([request], existing: ExistingVersionChoice.newVersion, whenExists: AiWhenExists.replace)
          .single;
      await allEnded();

      expect(output.finished, [(AiWhenExists.keepBoth, null)]);
      expect(job(id).replaced, isFalse);
      expect(job(id).writtenPath, p.join(photos, 'salon_3D_LRF_Full_SBS (1).jpg'));
      expect(File(existing).readAsBytesSync(), old);
    });
  });

  test('a photo skipped from the start never runs and keeps its reason', () async {
    final ids = queue().add([
      ConversionRequest(source: LocalFileSource(p.join(photos, 'clip.mp4')), skip: ConversionSkipReason.video),
      photo('a.jpg'),
    ]);
    await allEnded();

    expect(job(ids[0]).state, ConversionState.skipped);
    expect(job(ids[0]).skipReason, ConversionSkipReason.video);
    expect(job(ids[1]).state, ConversionState.done);
    expect(engines.ran, ['a.jpg']);
  });

  test('an original that cannot be reached fails with that reason, and the next photo runs', () async {
    final ids = queue().add([
      ConversionRequest(
        source: LocalFileSource(p.join(photos, 'gone.jpg')),
        target: ConversionTarget.nextTo(p.join(photos, 'gone.jpg')),
      ),
      photo('a.jpg'),
    ]);
    await allEnded();

    expect(job(ids[0]).state, ConversionState.failed);
    expect(job(ids[0]).error, ImmersiveErrorCode.sourceLost);
    expect(job(ids[1]).state, ConversionState.done);
  });

  test('Cancel stops a photo waiting or under way, Cancel all the rest; no file is left', () async {
    engines.fallback = FakeImmersiveEngine(holdStage: ImmersiveStage.rightEye);
    final hold = engines.fallback;
    var held = hold.reachedHold.stream.first;

    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg'), photo('d.jpg')]);
    await held;
    queue().cancel(ids[3]);
    expect(job(ids[3]).state, ConversionState.cancelled);
    queue().cancel(ids[0]);
    held = hold.reachedHold.stream.first;
    hold.release();
    await held;
    expect(job(ids[0]).state, ConversionState.cancelled);
    expect(job(ids[1]).phase, ConversionPhase.computing);

    queue().cancelAll();
    expect(job(ids[2]).state, ConversionState.cancelled);
    hold.release();
    await allEnded();

    expect([for (final id in ids) job(id).state], everyElement(ConversionState.cancelled));
    expect(engines.ran, ['a.jpg', 'b.jpg']);
    expect(output.discarded, output.begun);
    expect(leftInFolder({'a.jpg', 'b.jpg', 'c.jpg', 'd.jpg'}), isEmpty);
    expect(current().hasWork, isFalse);

    // A cancelled photo can be run again
    engines.fallback = FakeImmersiveEngine();
    queue().retry(ids[0]);
    await allEnded();
    expect(job(ids[0]).state, ConversionState.done);
  });

  test('Clear finished forgets the jobs that ended, not those to come', () async {
    engines.byName['b.jpg'] = FakeImmersiveEngine(failAt: ImmersiveStage.decoding);
    final hold = FakeImmersiveEngine(holdStage: ImmersiveStage.depth);
    engines.byName['c.jpg'] = hold;
    final held = hold.reachedHold.stream.first;

    final ids = queue().add([photo('a.jpg'), photo('b.jpg'), photo('c.jpg'), photo('d.jpg')]);
    await held;
    queue().clearFinished();

    expect([for (final job in current().jobs) job.id], [ids[2], ids[3]]);
    hold.release();
    await allEnded();
    queue().clearFinished();
    expect(current().jobs, isEmpty);
  });

  test('closing the provider stops the job under way and leaves no file', () async {
    engines.fallback = FakeImmersiveEngine(holdStage: ImmersiveStage.encoding);
    final held = engines.fallback.reachedHold.stream.first;
    queue().add([photo('a.jpg')]);
    await held;

    container.dispose();
    engines.fallback.release();
    for (var wait = 0; output.discarded.isEmpty && wait < 500; wait++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(output.discarded, output.begun);
    expect(leftInFolder({'a.jpg'}), isEmpty);
    container = ProviderContainer();
  });

  group('LocalFileSource', () {
    late String path;
    late List<int> bytes;

    setUp(() {
      bytes = List.generate(3000, (i) => i * 31 & 0xff);
      path = (File(p.join(photos, 'salon.jpg'))..writeAsBytesSync(bytes)).path;
    });

    test('computes the sum on the bytes at each run, even after an edit that kept the size', () async {
      final cancel = NativeCancelFlag();
      addTearDown(cancel.free);
      final source = LocalFileSource(path);

      final before = await source.prepare(cancel);
      // A turn written in the EXIF in place: one byte changed, the same size, before any scan
      final edited = [...bytes]..[100] ^= 0xff;
      File(path).writeAsBytesSync(edited);
      final after = await source.prepare(cancel);

      expect(before.sha1, _sumOf(bytes));
      expect(after.sha1, _sumOf(edited));
      expect(after.size, before.size);
      expect([after.name, after.size, after.path], ['salon.jpg', bytes.length, path]);
      expect(source.folder, photos);
    });

    test('the sum is the SHA-1 of the bytes in base64, computed in an isolate', () async {
      final cancel = NativeCancelFlag();
      addTearDown(cancel.free);

      expect((await LocalFileSource(path).prepare(cancel)).sha1, _sumOf(bytes));
    });

    test('a cancel during the sum, and a file gone, are told by their code', () async {
      final cancel = NativeCancelFlag()..cancel();
      addTearDown(cancel.free);

      await expectLater(
        LocalFileSource(path).prepare(cancel),
        throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.cancelled)),
      );
      await expectLater(
        LocalFileSource(p.join(photos, 'gone.jpg')).prepare(cancel),
        throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.sourceLost)),
      );
    });
  });

  test('the name planned for a 3D photo is one Windows accepts, whatever the name of the original', () {
    expect(ConversionTarget.nextTo(p.join(photos, 'salon.jpg')).path, p.join(photos, 'salon_3D_LRF_Full_SBS.jpg'));
    // A name from a server or a share, saved in a folder of this computer
    final shared = ConversionTarget.inFolder(photos, 'plage: 14h?.jpg');
    expect(shared.folder, photos);
    expect(shared.fileName, 'plage_ 14h__3D_LRF_Full_SBS.jpg');
    expect(ConversionTarget.nextTo(p.join(photos, 'a|b.jpeg')).fileName, 'a_b_3D_LRF_Full_SBS.jpg');
  });

  test('without the tools of the screens, a photo fails and says why', () async {
    final bare = ProviderContainer();
    addTearDown(bare.dispose);

    final id = bare.read(conversionQueueProvider.notifier).add([photo('a.jpg')]).single;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final failed = bare.read(conversionQueueProvider).byId(id)!;
    expect(failed.state, ConversionState.failed);
    expect(failed.message, contains('tools'));
  });
}
