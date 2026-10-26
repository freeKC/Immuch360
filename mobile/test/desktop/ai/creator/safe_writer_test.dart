import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_immersive_engine.dart';
import '../fakes/recording_creator_files.dart';

/// The original of the jobs of these tests
const salon = OriginalIdentity(name: 'salon.jpg', size: 1234, sha1: 'c2Fsb24uanBn');

/// A 3D photo of ours, with or without its DerivativeId, made from salon.jpg unless told otherwise
Uint8List ourVersion({
  String? derivativeId = 'urn:uuid:11111111-2222-4333-8444-555555555555',
  String? sourceName = 'salon.jpg',
  int? sourceSize = 1234,
  String? sourceSha1 = 'c2Fsb24uanBn',
}) => fakeSbsJpeg(
  xmp: StereoPhotoXmp(
    eyes: StereoEyes.full,
    eyeOrder: EyeOrder.leftRight,
    origin: ImmersiveOrigin.estimatedDepth,
    sourceName: sourceName,
    sourceSize: sourceSize,
    sourceSha1: sourceSha1,
    derivativeId: derivativeId,
  ),
);

/// A JPEG of the user that is no 3D photo of ours: the bytes of a photo with no XMP at all
Uint8List userPhoto() =>
    Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, ...utf8.encode('a photo'), 0xff, 0xd9]);

/// The error of a full disk as this computer reports it
OSError diskFullError() => OSError('No space left on device', Platform.isWindows ? 112 : 28);

void main() {
  late Directory root;
  late Directory folder;
  late Directory support;
  late RecordingCreatorFiles files;
  late InflightJournal journal;
  late SafeWriter writer;

  File journalFile() => File(p.join(support.path, InflightJournal.fileName));
  List<String> noted() => journalFile().existsSync()
      ? [
          for (final part in (jsonDecode(journalFile().readAsStringSync()) as Map)['parts'] as List)
            (part as Map)['path'] as String,
        ]
      : const [];
  List<String> namesIn(Directory directory) =>
      directory.listSync().map((entity) => p.basename(entity.path)).toList()..sort();

  setUp(() {
    root = Directory.systemTemp.createTempSync('ai_safe_writer');
    folder = Directory(p.join(root.path, 'Photos'))..createSync();
    support = Directory(p.join(root.path, 'support'))..createSync();
    files = RecordingCreatorFiles();
    journal = InflightJournal(settingsDirectory: () async => support);
    writer = SafeWriter(files: files, journal: journal, processId: 4242);
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('the partial file', () {
    test('is hidden from the scan and from the share browser, and named after the final name', () {
      final name = partFileName('salon_3D_LRF_Full_SBS.jpg', processId: 4242, sequence: 7);

      expect(name, '.salon_3D_LRF_Full_SBS.jpg.4242-7.immuch360.part');
      expect(name, startsWith('.'));
      expect(isSkippedFileName(name), isTrue);
      expect(isPartFileName(name), isTrue);
      expect(partFileProcess(name), 4242);
      expect(isPartFileName('salon.jpg'), isFalse);
      expect(isPartFileName('.salon.jpg'), isFalse);
      expect(partFileProcess('salon_3D_LRF_Full_SBS.jpg'), isNull);
    });

    test('is noted in the journal before it exists, and nothing takes the final name meanwhile', () async {
      final notedAtCreation = <String>[];
      final checking = _OnCreate(() => notedAtCreation.addAll(noted()));
      writer = SafeWriter(files: checking, journal: journal, processId: 4242);

      final part = await writer.createPart(folder.path, 'salon_3D_LRF_Full_SBS.jpg');

      expect(notedAtCreation, [part.path]);
      expect(noted(), [part.path]);
      expect(File(part.path).lengthSync(), 0);
      expect(p.dirname(part.path), folder.path);
      expect(part.finalName, 'salon_3D_LRF_Full_SBS.jpg');
      expect(namesIn(folder), [p.basename(part.path)]);
    });

    test('two parts of the same photo never share a name', () async {
      final first = await writer.createPart(folder.path, 'salon_3D_LRF_Full_SBS.jpg');
      final second = await writer.createPart(folder.path, 'salon_3D_LRF_Full_SBS.jpg');

      expect(first.path, isNot(second.path));
      expect(noted(), unorderedEquals([first.path, second.path]));
    });

    test('a folder that refuses it is told, and nothing stays noted', () async {
      files.failures[folder.path] = OSError('Access denied', Platform.isWindows ? 5 : 13);

      await expectLater(
        writer.createPart(folder.path, 'salon_3D_LRF_Full_SBS.jpg'),
        throwsA(isA<CreatorWriteException>().having((error) => error.failure, 'failure', WriteFailure.readOnly)),
      );
      expect(noted(), isEmpty);
      expect(namesIn(folder), isEmpty);
    });

    test('discarded: deleted and forgotten', () async {
      final part = await writer.createPart(folder.path, 'salon_3D_LRF_Full_SBS.jpg');

      await writer.discard(part);

      expect(File(part.path).existsSync(), isFalse);
      expect(noted(), isEmpty);
      expect(journalFile().existsSync(), isFalse);
    });
  });

  group('the final name, reserved at the end', () {
    Future<PartFile> written(Uint8List bytes) async {
      final part = await writer.createPart(folder.path, 'salon_3D_LRF_Full_SBS.jpg');
      File(part.path).writeAsBytesSync(bytes);
      return part;
    }

    test('free: the partial file takes it, and the journal is emptied', () async {
      final part = await written(ourVersion());
      expect(File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg')).existsSync(), isFalse);

      final saved = await writer.commit(part, original: salon);

      expect(saved.outcome, SaveOutcome.saved);
      expect(saved.path, p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'));
      expect(File(saved.path).readAsBytesSync(), ourVersion());
      expect(namesIn(folder), ['salon_3D_LRF_Full_SBS.jpg']);
      expect(noted(), isEmpty);
    });

    test('taken, keep both: "name (1)", the existing file untouched', () async {
      final existing = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(ourVersion());
      final part = await written(userPhoto());

      final saved = await writer.commit(part, original: salon);

      expect(saved.outcome, SaveOutcome.saved);
      expect(p.basename(saved.path), 'salon_3D_LRF_Full_SBS (1).jpg');
      expect(existing.readAsBytesSync(), ourVersion());
      expect(namesIn(folder), ['salon_3D_LRF_Full_SBS (1).jpg', 'salon_3D_LRF_Full_SBS.jpg']);
    });

    test('taken, replace: one of ours with its DerivativeId is replaced, read again just before', () async {
      final existing = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(ourVersion());
      final part = await written(userPhoto());

      final saved = await writer.commit(part, original: salon, whenExists: AiWhenExists.replace);

      expect(saved.outcome, SaveOutcome.replaced);
      expect(saved.path, existing.path);
      expect(existing.readAsBytesSync(), userPhoto());
      expect(namesIn(folder), ['salon_3D_LRF_Full_SBS.jpg']);
      expect(files.calls, contains('readHead ${existing.path}'));
      expect(noted(), isEmpty);
    });

    test('taken, replace: a file without our XMP is never replaced, both are kept', () async {
      final existing = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(userPhoto());
      final part = await written(ourVersion());

      final saved = await writer.commit(part, original: salon, whenExists: AiWhenExists.replace);

      expect(saved.outcome, SaveOutcome.saved);
      expect(p.basename(saved.path), 'salon_3D_LRF_Full_SBS (1).jpg');
      expect(existing.readAsBytesSync(), userPhoto());
    });

    test('taken, replace: one of ours without a DerivativeId is never replaced, both are kept', () async {
      final existing = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'))
        ..writeAsBytesSync(ourVersion(derivativeId: null));
      final part = await written(ourVersion());

      final saved = await writer.commit(part, original: salon, whenExists: AiWhenExists.replace);

      expect(saved.outcome, SaveOutcome.saved);
      expect(p.basename(saved.path), 'salon_3D_LRF_Full_SBS (1).jpg');
      expect(existing.readAsBytesSync(), ourVersion(derivativeId: null));
    });

    test('replace: another version of the folder, found by the queue, takes the new one', () async {
      final older = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS (1).jpg'))..writeAsBytesSync(ourVersion());
      final part = await written(userPhoto());

      final saved = await writer.commit(
        part,
        original: salon,
        whenExists: AiWhenExists.replace,
        replacing: 'salon_3D_LRF_Full_SBS (1).jpg',
      );

      expect(saved.outcome, SaveOutcome.replaced);
      expect(saved.path, older.path);
      expect(older.readAsBytesSync(), userPhoto());
      expect(namesIn(folder), ['salon_3D_LRF_Full_SBS (1).jpg']);
    });

    test('replace never takes the original, even one that carries our XMP', () async {
      final original = File(p.join(folder.path, 'salon.jpg'))..writeAsBytesSync(ourVersion());
      final part = await written(userPhoto());

      final saved = await writer.commit(
        part,
        original: OriginalIdentity(name: 'salon.jpg', size: 1234, sha1: salon.sha1, path: original.path),
        whenExists: AiWhenExists.replace,
        replacing: 'salon.jpg',
      );

      expect(saved.outcome, SaveOutcome.saved);
      expect(p.basename(saved.path), 'salon_3D_LRF_Full_SBS.jpg');
      expect(original.readAsBytesSync(), ourVersion());
    });

    test('replace: the 3D photo of salon.jpg is never taken by that of salon.heic, both are kept', () async {
      final ofTheJpeg = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(ourVersion());
      final part = await written(userPhoto());

      final saved = await writer.commit(
        part,
        original: const OriginalIdentity(name: 'salon.heic', size: 4321, sha1: 'c2Fsb24uaGVpYw=='),
        whenExists: AiWhenExists.replace,
      );

      expect(saved.outcome, SaveOutcome.saved);
      expect(p.basename(saved.path), 'salon_3D_LRF_Full_SBS (1).jpg');
      expect(ofTheJpeg.readAsBytesSync(), ourVersion());
      expect(namesIn(folder), ['salon_3D_LRF_Full_SBS (1).jpg', 'salon_3D_LRF_Full_SBS.jpg']);
    });

    test('replace: without a SourceSha1, the same SourceName and SourceSize tell the same original', () async {
      final existing = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'))
        ..writeAsBytesSync(ourVersion(sourceSha1: null));
      final part = await written(userPhoto());

      final replaced = await writer.commit(part, original: salon, whenExists: AiWhenExists.replace);

      expect(replaced.outcome, SaveOutcome.replaced);
      expect(existing.readAsBytesSync(), userPhoto());

      existing.writeAsBytesSync(ourVersion(sourceSha1: null, sourceSize: 999));
      final kept = await writer.commit(await written(userPhoto()), original: salon, whenExists: AiWhenExists.replace);

      expect(kept.outcome, SaveOutcome.saved);
      expect(existing.readAsBytesSync(), ourVersion(sourceSha1: null, sourceSize: 999));
    });

    test('replace: a version the queue found is replaced in the folder of the new one only', () async {
      final elsewhere = Directory(p.join(root.path, 'Moved'))..createSync();
      final moved = File(p.join(elsewhere.path, 'salon_3D_LRF_Full_SBS (3).jpg'))..writeAsBytesSync(ourVersion());
      // The same name in the folder of the new one, which the queue did not name
      final sameName = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS (3).jpg'))..writeAsBytesSync(ourVersion());
      final above = File(p.join(root.path, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(ourVersion());
      final here = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS (2).jpg'))..writeAsBytesSync(ourVersion());

      final notMoved = await writer.commit(
        await written(userPhoto()),
        original: salon,
        whenExists: AiWhenExists.replace,
        replacing: moved.path,
      );
      final upward = await writer.commit(
        await written(userPhoto()),
        original: salon,
        whenExists: AiWhenExists.replace,
        replacing: p.join('..', 'salon_3D_LRF_Full_SBS.jpg'),
      );
      final byPath = await writer.commit(
        await written(userPhoto()),
        original: salon,
        whenExists: AiWhenExists.replace,
        replacing: here.path,
      );

      expect(moved.readAsBytesSync(), ourVersion());
      expect(sameName.readAsBytesSync(), ourVersion());
      expect(above.readAsBytesSync(), ourVersion());
      expect(notMoved.outcome, SaveOutcome.saved);
      expect(notMoved.path, p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'));
      expect(upward.outcome, SaveOutcome.saved);
      expect(upward.path, p.join(folder.path, 'salon_3D_LRF_Full_SBS (1).jpg'));
      expect(byPath.outcome, SaveOutcome.replaced);
      expect(byPath.path, here.path);
      expect(here.readAsBytesSync(), userPhoto());
    });

    test('taken, skip: the existing file stays, the partial one goes', () async {
      final existing = File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg'))..writeAsBytesSync(userPhoto());
      final part = await written(ourVersion());

      final saved = await writer.commit(part, original: salon, whenExists: AiWhenExists.skip);

      expect(saved.outcome, SaveOutcome.skipped);
      expect(saved.path, existing.path);
      expect(existing.readAsBytesSync(), userPhoto());
      expect(namesIn(folder), ['salon_3D_LRF_Full_SBS.jpg']);
      expect(noted(), isEmpty);
    });

    test('free, skip: written as usual', () async {
      final part = await written(ourVersion());

      final saved = await writer.commit(part, original: salon, whenExists: AiWhenExists.skip);

      expect(saved.outcome, SaveOutcome.saved);
      expect(namesIn(folder), ['salon_3D_LRF_Full_SBS.jpg']);
    });

    test('a disk full at the end: told as such, the partial file deleted, nothing under the final name', () async {
      final part = await written(ourVersion());
      files.failures[folder.path] = diskFullError();

      await expectLater(
        writer.commit(part, original: salon),
        throwsA(isA<CreatorWriteException>().having((error) => error.failure, 'failure', WriteFailure.diskFull)),
      );
      expect(namesIn(folder), isEmpty);
      expect(noted(), isEmpty);
    });
  });

  group('a failure at the end', () {
    test('a rename that fails: nothing under the final name, not even the empty reservation', () async {
      final part = await writer.createPart(folder.path, 'salon_3D_LRF_Full_SBS.jpg');
      File(part.path).writeAsBytesSync(ourVersion());
      files.renameFailures[folder.path] = OSError('Input/output error', Platform.isWindows ? 1117 : 5);

      await expectLater(writer.commit(part, original: salon), throwsA(isA<CreatorWriteException>()));

      expect(files.calls, contains('reserve ${p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg')}'));
      expect(namesIn(folder), isEmpty);
      expect(noted(), isEmpty);
    });
  });

  group('the original of a job', () {
    for (final whenExists in AiWhenExists.values) {
      test('keeps its bytes and its date through a whole job (${whenExists.name})', () async {
        final original = File(p.join(folder.path, 'salon.jpg'))
          ..writeAsBytesSync(userPhoto())
          ..setLastModifiedSync(DateTime(2024, 5, 17, 9, 30));
        File(p.join(folder.path, 'salon_3D_LRF_Full_SBS.jpg')).writeAsBytesSync(ourVersion());
        final bytes = original.readAsBytesSync();
        final modified = original.lastModifiedSync();
        final engine = FakeImmersiveEngine();
        final cancel = NativeCancelFlag();
        addTearDown(cancel.free);

        final part = await writer.createPart(folder.path, sbsTargetName('salon.jpg'));
        final source = ImmersiveSource(name: 'salon.jpg', size: bytes.length, sha1: salon.sha1!, path: original.path);
        final result = await engine.run(
          ImmersiveJob(
            id: 'job-1',
            source: source,
            partPath: part.path,
            derivativeId: StereoPhotoXmp.newDerivativeId(),
            creatorTool: 'Immuch360 Desktop (test)',
            created: '2026-10-27T10:12:00+01:00',
          ),
          cancel: cancel,
        );
        expect(result.isDone, isTrue);
        await writer.commit(
          part,
          original: OriginalIdentity.of(source),
          whenExists: whenExists,
          replacing: 'salon.jpg',
        );

        expect(original.readAsBytesSync(), bytes);
        expect(original.lastModifiedSync(), modified);
        expect(files.calls.where((call) => call.endsWith(original.path) && !call.startsWith('exists')), isEmpty);
        await engine.dispose();
      });
    }
  });

  group('the start', () {
    test('deletes the partial files an earlier session left, and only those', () async {
      final leftover = File(p.join(folder.path, partFileName('a_3D_LRF_Full_SBS.jpg', processId: 99, sequence: 3)))
        ..writeAsBytesSync([1, 2, 3]);
      final photo = File(p.join(folder.path, 'salon.jpg'))..writeAsBytesSync(userPhoto());
      final gone = p.join(folder.path, partFileName('b_3D_LRF_Full_SBS.jpg', processId: 99, sequence: 4));
      final unplugged = p.join(
        root.path,
        'Unplugged',
        partFileName('c_3D_LRF_Full_SBS.jpg', processId: 98, sequence: 1),
      );
      final ofThisSession = File(
        p.join(folder.path, partFileName('d_3D_LRF_Full_SBS.jpg', processId: 4242, sequence: 9)),
      )..createSync();
      for (final path in [leftover.path, photo.path, gone, unplugged, ofThisSession.path]) {
        await journal.add(path);
      }

      final deleted = await SafeWriter(
        files: files,
        journal: InflightJournal(settingsDirectory: () async => support),
        processId: 4242,
      ).cleanUpAtStart();

      expect(deleted, 1);
      expect(leftover.existsSync(), isFalse);
      expect(photo.existsSync(), isTrue);
      expect(ofThisSession.existsSync(), isTrue);
      expect(noted(), unorderedEquals([unplugged, ofThisSession.path]));
      expect(files.calls.where((call) => call.startsWith('delete')), ['delete ${leftover.path}']);
    });

    test('a folder out of reach for more than a month is no longer looked for', () async {
      String unplugged(String name, int process) =>
          p.join(root.path, 'Unplugged', partFileName('${name}_3D_LRF_Full_SBS.jpg', processId: process, sequence: 1));
      String daysAgo(int days) => DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String();
      final recent = unplugged('a', 97);
      final old = unplugged('b', 96);
      final undated = unplugged('c', 95);
      journalFile().writeAsStringSync(
        jsonEncode({
          'parts': [
            {'path': recent, 'noted': daysAgo(29)},
            {'path': old, 'noted': daysAgo(31)},
            undated,
          ],
        }),
      );

      expect(await writer.cleanUpAtStart(), 0);

      expect(noted(), unorderedEquals([recent, undated]));
      expect(files.calls.where((call) => call.startsWith('delete')), isEmpty);
    });

    test('with no journal: nothing to do', () async {
      expect(await writer.cleanUpAtStart(), 0);
      expect(files.calls, isEmpty);
    });

    test('a damaged journal is read as empty', () async {
      journalFile().writeAsStringSync('{not json');

      expect(await writer.cleanUpAtStart(), 0);
      expect(await journal.paths(), isEmpty);
    });
  });

  group('the failures of the system', () {
    FileSystemException failure(int code) => FileSystemException('Write failed', '/x', OSError('', code));

    test('ENOSPC (28) is a full disk on Linux and macOS', () {
      expect(writeFailureOf(failure(28), windows: false), WriteFailure.diskFull);
      expect(writeFailureOf(failure(28), windows: false).errorCode, ImmersiveErrorCode.diskFull);
    });

    test('ERROR_DISK_FULL (112) and ERROR_HANDLE_DISK_FULL (39) are a full disk on Windows', () {
      expect(writeFailureOf(failure(112), windows: true), WriteFailure.diskFull);
      expect(writeFailureOf(failure(39), windows: true), WriteFailure.diskFull);
      expect(writeFailureOf(const OSError('', 112), windows: true), WriteFailure.diskFull);
    });

    test('each code is read with the codes of its own system', () {
      // 28 is "out of paper" on Windows, 39 ENOTEMPTY and 112 EHOSTDOWN on Linux
      expect(writeFailureOf(failure(28), windows: true), isNot(WriteFailure.diskFull));
      expect(writeFailureOf(failure(39), windows: false), isNot(WriteFailure.diskFull));
      expect(writeFailureOf(failure(112), windows: false), isNot(WriteFailure.diskFull));
    });

    test('a folder that refuses, one that is not there, and the rest', () {
      expect(writeFailureOf(failure(13), windows: false), WriteFailure.readOnly);
      expect(writeFailureOf(failure(30), windows: false), WriteFailure.readOnly);
      expect(writeFailureOf(failure(5), windows: true), WriteFailure.readOnly);
      expect(writeFailureOf(failure(19), windows: true), WriteFailure.readOnly);
      expect(writeFailureOf(failure(2), windows: false), WriteFailure.folderMissing);
      expect(writeFailureOf(failure(53), windows: true), WriteFailure.folderMissing);
      expect(writeFailureOf(failure(9999), windows: true), WriteFailure.other);
      expect(writeFailureOf(const FileSystemException('no code')), WriteFailure.other);
      expect(writeFailureOf(StateError('not a write')), WriteFailure.other);
      expect(WriteFailure.readOnly.errorCode, ImmersiveErrorCode.readOnly);
      expect(WriteFailure.folderMissing.errorCode, ImmersiveErrorCode.writeFailed);
    });

    test('the message keeps the words of the system', () {
      final error = CreatorWriteException.of(
        const FileSystemException('Cannot create file', '/x/y', OSError('No space left on device', 28)),
        windows: false,
      );

      expect(error.failure, WriteFailure.diskFull);
      expect(error.message, 'Cannot create file: No space left on device');
    });
  });
}

/// Calls [onCreate] when the partial file is about to be created
class _OnCreate extends RecordingCreatorFiles {
  _OnCreate(this.onCreate);

  final void Function() onCreate;

  @override
  Future<void> createNew(String path) {
    onCreate();
    return super.createNew(path);
  }
}
