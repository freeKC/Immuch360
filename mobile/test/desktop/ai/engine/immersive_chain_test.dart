// The chain of one job, run in the test's own isolate (lot A4b): FakeDepthBackend and DartSbsCodec on the fixtures of
// the codec, fakes for the memory and the thread priorities. The worker isolate around it: ai_worker_test.dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;

import '../codec/codec_fixtures.dart';
import '../fakes/fake_depth_backend.dart';
import '../fakes/fake_engine_tools.dart';
import '../fakes/fake_thread_priority.dart';
import 'engine_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('immersive_chain_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  /// A chain on the fakes, the Dart codec recorded
  ({ImmersiveChain chain, FakeDepthBackend backend, RecordingCodec codec, FakeThreadPriority priority}) chainOn({
    FakeDepthBackend? backend,
    DepthBackend? other,
    List<SbsCodec>? codecs,
    int? available = 8 * 1024 * 1024 * 1024,
    MemoryProbe? memory,
    PartWriter? writePart,
  }) {
    final fake = backend ?? FakeDepthBackend();
    final codec = RecordingCodec(const DartSbsCodec());
    final priority = FakeThreadPriority(threads: {1: 'main'});
    return (
      chain: ImmersiveChain(
        backend: other ?? fake,
        codecs: codecs ?? [codec],
        memory: memory ?? FixedMemoryProbe(available: available),
        priority: ComputePriority(priority),
        writePart: writePart ?? writePartFile,
      ),
      backend: fake,
      codec: codec,
      priority: priority,
    );
  }

  ChainOutcome runOn(
    ImmersiveChain chain,
    ImmersiveJob job, {
    bool Function()? isCancelled,
    void Function(ImmersiveProgress progress)? onProgress,
    SbsDecoded? decoded,
  }) => chain.run(
    job,
    ChainOriginal(bytes: File(job.source.path!).readAsBytesSync(), decoded: decoded),
    isCancelled: isCancelled ?? () => false,
    onProgress: onProgress,
  );

  group('a JPEG made into a full side by side 3D photo', () {
    test('a JPEG of 2W x H, its XMP complete, the sum of native_sha1.dart, the left eye the decoded original', () {
      final path = codecFixturePath('orientation_1.jpg');
      final part = partIn(folder, 'orientation_1.jpg');
      final tools = chainOn();
      final job = jobFor(path, partPath: part);
      final outcome = runOn(tools.chain, job);
      final result = outcome.result;

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      expect((result.eyeWidth, result.eyeHeight, result.reduced), (32, 16, false));
      final out = File(part).readAsBytesSync();
      expect(result.bytesWritten, out.length);
      final image = img.decodeJpg(out)!;
      expect((image.width, image.height), (64, 16));

      final xmp = StereoPhotoXmp.findIn(out)!;
      expect(
        xmp,
        StereoPhotoXmp.estimated(
          eyeWidth: 32,
          eyeHeight: 16,
          depthModelSha256: depthModelOnnxSha256,
          sourceName: 'orientation_1.jpg',
          sourceSize: File(path).lengthSync(),
          sourceSha1: sha1OfFile(path),
          sourceQuarterTurns: 0,
          created: '2026-10-27T10:12:00+01:00',
          creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
          derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000001',
          qualityFlags: result.qualityFlags,
        ),
      );
      expect(xmp.sourceSha1, sha1OfFile(path, engine: const DartSha1Engine()));
      expect(xmp.isEstimatedRelief, isTrue);
      expect(xmp.leftEye, LeftEyeSource.original);

      // The left eye of the pair is the decoded original, byte for byte, before the JPEG
      final picture = tools.codec.pictures.single;
      expect((picture.width, picture.height), (64, 16));
      final original = const DartSbsCodec().decodeJpeg(File(path).readAsBytesSync());
      expect(leftEyeOf(picture), original.rgba);
      // The right eye is computed and opaque
      final right = rightEyeOf(picture);
      expect([for (var alpha = 3; alpha < right.length; alpha += 4) right[alpha]], everyElement(255));
      expect((outcome.decoder, outcome.encoder), ('dart', 'dart'));
    });

    test('the near half comes out of the screen, the far half goes behind it, 1 % of the width each', () {
      // The map of the step: the left half far, the right half near. An eye of 200: the far moves 2 pixels to the
      // right in the right eye, the near 2 pixels to the left (crossed, in front of the screen)
      final path = stripesJpeg(folder, 'stripes.jpg');
      final tools = chainOn(backend: FakeDepthBackend(shape: FakeDepthShape.step));
      final result = runOn(tools.chain, jobFor(path, partPath: partIn(folder, 'stripes.jpg'))).result;
      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      final picture = tools.codec.pictures.single;
      final left = leftEyeOf(picture);
      final right = rightEyeOf(picture);
      for (var y = 0; y < picture.height; y++) {
        for (var x = 10; x < 90; x++) {
          final at = 4 * (y * 200 + x);
          expect(right.sublist(at, at + 3), left.sublist(at - 8, at - 5), reason: 'far, row $y, column $x');
        }
        for (var x = 110; x < 190; x++) {
          final at = 4 * (y * 200 + x);
          expect(right.sublist(at, at + 3), left.sublist(at + 8, at + 11), reason: 'near, row $y, column $x');
        }
      }
    });

    test('turned upright by its EXIF orientation, then by the quarter turns the user gave', () {
      final path = codecFixturePath('orientation_6.jpg');
      final part = partIn(folder, 'orientation_6.jpg');
      final tools = chainOn();
      final result = runOn(tools.chain, jobFor(path, partPath: part, quarterTurns: 1)).result;

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      // Stored 16 x 32, upright 32 x 16, then a quarter turn clockwise: 16 x 32
      expect((result.eyeWidth, result.eyeHeight), (16, 32));
      final decoded = const DartSbsCodec().decodeJpeg(File(path).readAsBytesSync());
      expect(leftEyeOf(tools.codec.pictures.single), orientDecoded(decoded, orientation: 6, quarterTurns: 1).rgba);
      final out = File(part).readAsBytesSync();
      expect(StereoPhotoXmp.findIn(out)!.sourceQuarterTurns, 1);
      expect(exifOrientation(JpegHeader.read(out).exif), 1);
    });

    test("the EXIF keeps the original's date and place, without make, model nor thumbnail; the job's own first", () {
      final path = codecFixturePath('exif_camera.jpg');
      final camera = codecExpected['exifCamera'] as Map<String, dynamic>;
      final part = partIn(folder, 'exif_camera.jpg');
      var result = runOn(chainOn().chain, jobFor(path, partPath: part)).result;
      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      // Orientation 6: stored 64 x 32, an eye of 32 x 64
      expect((result.eyeWidth, result.eyeHeight), (32, 64));
      var out = File(part).readAsBytesSync();
      var exif = JpegHeader.read(out).exif;
      var kept = keptExif(exif);
      expect(kept.dateTimeOriginal, camera['dateTimeOriginal']);
      expect(kept.offsetTimeOriginal, camera['offsetTimeOriginal']);
      expect(kept.latitude, closeTo(camera['latitude'] as double, 1e-4));
      expect(kept.longitude, closeTo(camera['longitude'] as double, 1e-4));
      expect(exifOrientation(exif), 1);
      final text = String.fromCharCodes(exif!);
      expect(text, isNot(contains(camera['make'] as String)));
      expect(text, isNot(contains(camera['model'] as String)));
      expect(text, isNot(contains(camera['software'] as String)));
      expect(text, contains('Immuch360 Desktop 3.3.0'));

      result = runOn(
        chainOn().chain,
        jobFor(
          path,
          partPath: part,
          exif: const ImmersiveExif(dateTimeOriginal: '2026:01:02 03:04:05', offsetTimeOriginal: '+01:00'),
        ),
      ).result;
      expect(result.isDone, isTrue);
      out = File(part).readAsBytesSync();
      exif = JpegHeader.read(out).exif;
      kept = keptExif(exif);
      expect((kept.dateTimeOriginal, kept.offsetTimeOriginal), ('2026:01:02 03:04:05', '+01:00'));
      expect(kept.latitude, closeTo(camera['latitude'] as double, 1e-4), reason: 'the place of the original');
    });

    test('the profile of the pixels, the quality and the subsampling of the original', () {
      String convert(String name) {
        final part = partIn(folder, name);
        final result = runOn(chainOn().chain, jobFor(codecFixturePath(name), partPath: part)).result;
        expect(result.isDone, isTrue, reason: '$name: ${result.error}: ${result.message}');
        return part;
      }

      expect(
        JpegHeader.read(File(convert('display_p3.jpg')).readAsBytesSync()).iccProfile,
        codecFixture('display_p3.icc'),
      );
      final low = JpegHeader.read(File(convert('quality_75.jpg')).readAsBytesSync());
      expect(low.estimatedQuality, inInclusiveRange(84, 86), reason: 'a quality of 75 kept at 85');
      expect(low.iccProfile, isNull);
      final chroma = JpegHeader.read(File(convert('subsampling_420.jpg')).readAsBytesSync());
      expect(chroma.subsampling, ChromaSubsampling.s420);
    });

    test('a photo that is not a JPEG: the pixels the engine decoded, no profile, quality 92', () async {
      final path = codecFixturePath('transparent.png');
      final decoded = await decodeWithEngine(File(path).readAsBytesSync(), windows: false);
      final part = partIn(folder, 'transparent.png');
      final outcome = runOn(chainOn().chain, jobFor(path, partPath: part), decoded: decoded);
      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      expect(outcome.decoder, 'engine');
      final header = JpegHeader.read(File(part).readAsBytesSync());
      expect(header.iccProfile, isNull);
      expect(header.estimatedQuality, inInclusiveRange(91, 93));
      expect((outcome.result.eyeWidth, outcome.result.eyeHeight), (32, 16));
    });

    test('wider than the cap of an eye: reduced by area average, and the job says so', () {
      final part = partIn(folder, 'orientation_1.jpg');
      final tools = chainOn();
      final result = runOn(
        tools.chain,
        jobFor(codecFixturePath('orientation_1.jpg'), partPath: part, maxEyeWidth: 16),
      ).result;
      expect(result.isDone, isTrue);
      expect((result.eyeWidth, result.eyeHeight, result.reduced), (16, 8, true));
      expect(StereoPhotoXmp.findIn(File(part).readAsBytesSync())!.eyeWidth, 16);
      expect(tools.codec.pictures.single.width, 32);

      // Turned a quarter, the cap holds for the turned photo: 32 x 16 stored, 16 x 32 turned, 8 x 16 capped
      final turned = runOn(
        chainOn().chain,
        jobFor(codecFixturePath('orientation_1.jpg'), partPath: part, maxEyeWidth: 8, quarterTurns: 1),
      ).result;
      expect((turned.eyeWidth, turned.eyeHeight, turned.reduced), (8, 16, true));
    });

    test('the flags of the eye, its luma read in the pair', () {
      // A grey of 30 is not dark (under 20 is); read across the two halves of the pair it would look like 15
      final grey = syntheticJpeg(folder, 'grey30.jpg', luma: 30, width: 48, height: 32, square: false);
      final dark = syntheticJpeg(folder, 'grey8.jpg', luma: 8, width: 48, height: 32, square: false);
      final notDark = runOn(chainOn().chain, jobFor(grey, partPath: partIn(folder, 'grey30.jpg'))).result;
      final isDark = runOn(chainOn().chain, jobFor(dark, partPath: partIn(folder, 'grey8.jpg'))).result;
      expect(notDark.qualityFlags, isNot(contains(ReliefQualityFlag.dark)));
      expect(isDark.qualityFlags, contains(ReliefQualityFlag.dark));
      final constant = runOn(
        chainOn(backend: FakeDepthBackend(shape: FakeDepthShape.constant)).chain,
        jobFor(grey, partPath: partIn(folder, 'grey30.jpg')),
      ).result;
      expect(constant.qualityFlags, contains(ReliefQualityFlag.lowRelief));
      expect(
        StereoPhotoXmp.findIn(File(partIn(folder, 'grey30.jpg')).readAsBytesSync())!.qualityFlags,
        constant.qualityFlags,
      );
    });

    test('the session of the model is kept after a job, and given back on demand', () {
      final tools = chainOn();
      expect(tools.chain.sessionOpen, isFalse);
      runOn(tools.chain, jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')));
      expect(tools.chain.sessionOpen, isTrue);
      expect(tools.backend.closed, isFalse);
      tools.chain.closeSession();
      expect((tools.chain.sessionOpen, tools.backend.closed), (false, true));
    });
  });

  group('cancelled', () {
    final path = codecFixturePath('orientation_1.jpg');

    for (final stage in ImmersiveStage.sbs) {
      test('at ${stage.name}: nothing written, the .part as it was', () {
        for (final existed in [false, true]) {
          final part = partIn(folder, 'orientation_1.jpg');
          if (existed) {
            File(part).writeAsBytesSync(const []);
          } else if (File(part).existsSync()) {
            File(part).deleteSync();
          }
          var cancelled = false;
          final tools = chainOn();
          final result = runOn(
            tools.chain,
            jobFor(path, partPath: part),
            isCancelled: () => cancelled,
            onProgress: (progress) => cancelled = cancelled || progress.stage == stage,
          ).result;
          expect(result.error, ImmersiveErrorCode.cancelled, reason: '${stage.name}, existed: $existed');
          expect(File(part).existsSync(), existed);
          if (existed) {
            expect(File(part).lengthSync(), 0);
          }
          expect(folder.listSync().map((entry) => p.basename(entry.path)), existed ? [p.basename(part)] : isEmpty);
          // The model ran to its end only once the depth step started
          expect(tools.backend.calls, stage.index > ImmersiveStage.depth.index ? 1 : 0, reason: stage.name);
        }
      });
    }

    test('in the middle of the right eye: read every 64 rows', () {
      final tall = syntheticJpeg(folder, 'tall.jpg', height: 300);
      final part = partIn(folder, 'tall.jpg');
      var cancelled = false;
      final rows = <int>[];
      final result = runOn(
        chainOn().chain,
        jobFor(tall, partPath: part),
        isCancelled: () => cancelled,
        onProgress: (progress) {
          if (progress.stage == ImmersiveStage.rightEye && progress.perMille > ChainProgress.rightEye) {
            rows.add(progress.perMille);
            cancelled = true;
          }
        },
      ).result;
      expect(result.error, ImmersiveErrorCode.cancelled);
      expect(rows, hasLength(1), reason: 'stopped at the next check, 64 rows later');
      expect(File(part).existsSync(), isFalse);
      expect(result.stageTimes.keys, contains(ImmersiveStage.rightEye));
    });

    test('while the model runs: the run goes to its end, its map is dropped', () {
      var cancelled = false;
      final backend = SlowDepthBackend(FakeDepthBackend(), onEstimate: () => cancelled = true);
      final tools = chainOn(other: backend);
      final part = partIn(folder, 'orientation_1.jpg');
      final result = runOn(tools.chain, jobFor(path, partPath: part), isCancelled: () => cancelled).result;
      expect(result.error, ImmersiveErrorCode.cancelled);
      expect(backend.inner.calls, 1);
      expect(File(part).existsSync(), isFalse);
    });

    test('after the write: the .part is put back as it was', () {
      for (final existed in [false, true]) {
        final part = partIn(folder, 'orientation_1.jpg');
        if (existed) {
          File(part).writeAsBytesSync(const []);
        }
        var cancelled = false;
        final tools = chainOn(
          writePart: (path, bytes) {
            writePartFile(path, bytes);
            cancelled = true;
          },
        );
        final result = runOn(tools.chain, jobFor(path, partPath: part), isCancelled: () => cancelled).result;
        expect(result.error, ImmersiveErrorCode.cancelled);
        expect(File(part).existsSync(), existed);
        if (existed) {
          expect(File(part).lengthSync(), 0);
          File(part).deleteSync();
        }
      }
    });
  });

  group('failures', () {
    final path = codecFixturePath('orientation_1.jpg');

    test('not enough memory for the photo: refused before it is decoded, the model never run', () {
      final tools = chainOn(available: 1000 * 1000);
      final part = partIn(folder, 'orientation_1.jpg');
      final outcome = runOn(tools.chain, jobFor(path, partPath: part));
      expect(outcome.result.error, ImmersiveErrorCode.outOfMemory);
      expect(outcome.result.message, matches(RegExp(r'needs about \d+ MB of memory, 1 MB are free')));
      expect(outcome.memoryNeed, greaterThan(1000 * 1000));
      expect(tools.codec.decoded, isEmpty);
      expect(tools.backend.calls, 0);
      expect(File(part).existsSync(), isFalse);
    });

    test('the session not open yet counts in the need: refused first, accepted once a job opened it', () {
      // 32 x 16, an eye as large: the need with the session open and with it still to open
      final open = jobMemoryNeed(sourceWidth: 32, sourceHeight: 16, eyeWidth: 32, eyeHeight: 16);
      final closed = jobMemoryNeed(sourceWidth: 32, sourceHeight: 16, eyeWidth: 32, eyeHeight: 16, sessionOpen: false);
      final memory = SettableMemoryProbe((open + closed) ~/ 2);
      final tools = chainOn(memory: memory);

      var outcome = runOn(tools.chain, jobFor(path, partPath: partIn(folder, 'a.jpg')));
      expect((outcome.result.error, outcome.memoryNeed), (ImmersiveErrorCode.outOfMemory, closed));
      expect(tools.backend.calls, 0);

      memory.available = 8 * 1024 * 1024 * 1024;
      expect(runOn(tools.chain, jobFor(path, partPath: partIn(folder, 'b.jpg'))).result.isDone, isTrue);
      expect(tools.chain.sessionOpen, isTrue);

      memory.available = (open + closed) ~/ 2;
      outcome = runOn(tools.chain, jobFor(path, partPath: partIn(folder, 'c.jpg')));
      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      expect(outcome.memoryNeed, open);
    });

    test('a photo the engine decoded is checked too, the model never run', () async {
      final png = codecFixturePath('transparent.png');
      final decoded = await decodeWithEngine(File(png).readAsBytesSync(), windows: false);
      final tools = chainOn(available: 1000 * 1000);
      final outcome = runOn(tools.chain, jobFor(png, partPath: partIn(folder, 'transparent.png')), decoded: decoded);
      expect(outcome.result.error, ImmersiveErrorCode.outOfMemory);
      expect(outcome.memoryNeed, greaterThan(1000 * 1000));
      expect(tools.backend.calls, 0);
      expect(File(partIn(folder, 'transparent.png')).existsSync(), isFalse);
    });

    test('a photo turned a quarter is checked for the eye it gives once turned, JPEG or not', () async {
      // 32 x 16 stored, 16 x 32 turned, capped at 8 wide: an eye of 8 x 16 (8 x 4 if the turn were forgotten)
      final need = jobMemoryNeed(sourceWidth: 32, sourceHeight: 16, eyeWidth: 8, eyeHeight: 16, sessionOpen: false);
      final jpeg = runOn(
        chainOn().chain,
        jobFor(path, partPath: partIn(folder, 'orientation_1.jpg'), maxEyeWidth: 8, quarterTurns: 1),
      );
      expect((jpeg.result.isDone, jpeg.memoryNeed), (true, need));

      final png = codecFixturePath('transparent.png');
      final decoded = await decodeWithEngine(File(png).readAsBytesSync(), windows: false);
      final engine = runOn(
        chainOn().chain,
        jobFor(png, partPath: partIn(folder, 'transparent.png'), maxEyeWidth: 8, quarterTurns: 1),
        decoded: decoded,
      );
      expect((engine.result.isDone, engine.memoryNeed), (true, need));
    });

    test('a system that does not say its free memory (macOS) is not refused on it', () {
      final result = runOn(
        chainOn(available: null).chain,
        jobFor(path, partPath: partIn(folder, 'orientation_1.jpg')),
      ).result;
      expect(result.isDone, isTrue);
    });

    test('a codec without memory for the photo: outOfMemory, not tried again in Dart', () {
      for (final message in ['outOfMemory: 192 MB refused', 'tooLarge: 20000 x 20000 is over 120 Mpx']) {
        final tools = chainOn();
        final refusing = RefusingCodec(message);
        final result = runOn(
          chainOn(codecs: [refusing, tools.codec]).chain,
          jobFor(path, partPath: partIn(folder, 'orientation_1.jpg')),
        ).result;
        expect(result.error, ImmersiveErrorCode.outOfMemory, reason: message);
        expect(result.message, message);
        expect(tools.codec.decoded, isEmpty);
      }
    });

    test('a codec that refuses a file hands it to the next one, for decoding and for encoding', () {
      final tools = chainOn();
      final refusing = RefusingCodec('decodeFailed: unsupported marker');
      final outcome = runOn(
        chainOn(codecs: [refusing, tools.codec]).chain,
        jobFor(path, partPath: partIn(folder, 'orientation_1.jpg')),
      );
      expect(outcome.result.isDone, isTrue);
      expect((outcome.decoder, outcome.encoder), ('dart', 'dart'));
      expect(refusing.calls, 2);
    });

    test('a damaged JPEG, or no JPEG at all: decodeFailed', () {
      final bytes = File(path).readAsBytesSync();
      final cut = p.join(folder.path, 'cut.jpg');
      File(cut).writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 3));
      final notJpeg = p.join(folder.path, 'not.jpg');
      File(notJpeg).writeAsBytesSync(List.filled(64, 7));
      for (final file in [cut, notJpeg]) {
        final result = runOn(chainOn().chain, jobFor(file, partPath: partIn(folder, 'x.jpg'))).result;
        expect(result.error, ImmersiveErrorCode.decodeFailed, reason: file);
        expect(result.message, isNotEmpty);
      }
    });

    test('the model fails: modelFailed with its message; a map of another size too', () {
      var result = runOn(
        chainOn(backend: FakeDepthBackend(failure: 'CreateSession: the model is damaged')).chain,
        jobFor(path, partPath: partIn(folder, 'orientation_1.jpg')),
      ).result;
      expect((result.error, result.message), (ImmersiveErrorCode.modelFailed, 'CreateSession: the model is damaged'));
      result = runOn(
        chainOn(other: WrongSizeBackend()).chain,
        jobFor(path, partPath: partIn(folder, 'orientation_1.jpg')),
      ).result;
      expect(result.error, ImmersiveErrorCode.modelFailed);
      expect(result.message, contains('10 x 10'));
    });

    test('a run of the model that fails once its session is open gives the session back at once', () {
      // The fake opens its session as the run starts, then fails: the memory of the session is not left taken
      final tools = chainOn(backend: FakeDepthBackend(failure: 'Run: not enough memory'));
      final result = runOn(tools.chain, jobFor(path, partPath: partIn(folder, 'orientation_1.jpg'))).result;
      expect(result.error, ImmersiveErrorCode.modelFailed);
      expect(tools.backend.calls, 1);
      expect((tools.chain.sessionOpen, tools.backend.closed), (false, true));
    });

    test('the photo changed after it was chosen: sourceLost, never a 3D photo with the sum of another', () {
      final part = partIn(folder, 'orientation_1.jpg');
      final result = runOn(chainOn().chain, jobFor(path, partPath: part, sha1: 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=')).result;
      expect(result.error, ImmersiveErrorCode.sourceLost);
      expect(result.message, contains(sha1OfFile(path)));
      expect(File(part).existsSync(), isFalse);
    });

    test('the write fails: disk full, folder read only or gone, the .part as it was', () {
      final windows = Platform.isWindows;
      for (final (code, expected) in [
        (windows ? 112 : 28, ImmersiveErrorCode.diskFull),
        (windows ? 39 : 28, ImmersiveErrorCode.diskFull),
        (windows ? 5 : 13, ImmersiveErrorCode.readOnly),
        (windows ? 1117 : 5, ImmersiveErrorCode.writeFailed),
      ]) {
        final part = partIn(folder, 'orientation_1.jpg');
        final tools = chainOn(
          writePart: (path, bytes) {
            File(path).writeAsBytesSync(bytes.sublist(0, 10));
            throw FileSystemException('Cannot write', path, OSError('the system says no', code));
          },
        );
        final result = runOn(tools.chain, jobFor(path, partPath: part)).result;
        expect(result.error, expected, reason: 'code $code');
        expect(result.message, 'the system says no');
        expect(File(part).existsSync(), isFalse, reason: 'code $code');
      }

      final gone = p.join(folder.path, 'gone', 'x.part');
      final result = runOn(chainOn().chain, jobFor(path, partPath: gone)).result;
      expect(result.error, ImmersiveErrorCode.writeFailed);
    });
  });

  group('progress, times and priority', () {
    test('every step in order, the thousandths never going back, the end at 1000; a time for each step', () {
      final progress = <ImmersiveProgress>[];
      final tall = syntheticJpeg(folder, 'tall.jpg', height: 200);
      final result = runOn(
        chainOn().chain,
        jobFor(tall, partPath: partIn(folder, 'tall.jpg')),
        onProgress: progress.add,
      ).result;
      expect(result.isDone, isTrue);
      expect(progress.map((step) => step.stage).toSet().toList(), [
        ImmersiveStage.reading,
        ImmersiveStage.decoding,
        ImmersiveStage.depth,
        ImmersiveStage.rightEye,
        ImmersiveStage.encoding,
        ImmersiveStage.writing,
      ]);
      for (var index = 1; index < progress.length; index++) {
        expect(progress[index].perMille, greaterThanOrEqualTo(progress[index - 1].perMille));
        expect(progress[index].stage.index, greaterThanOrEqualTo(progress[index - 1].stage.index));
      }
      expect(progress.where((step) => step.stage == ImmersiveStage.rightEye).length, greaterThan(3));
      expect(progress.last, const ImmersiveProgress(ImmersiveStage.writing, 1000));
      expect(result.stageTimes.keys.toSet(), ImmersiveStage.sbs.toSet());
    });

    test("the job's thread lowered for its body and put back after it, even when it fails", () {
      for (final backend in [FakeDepthBackend(), FakeDepthBackend(failure: 'broken')]) {
        final tools = chainOn(backend: backend);
        runOn(tools.chain, jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')));
        expect(tools.priority.calls.first, 'lowerCurrent');
        expect(tools.priority.calls.last, 'restore');
        // A model other than ONNX Runtime has no session threads to lower
        expect(tools.priority.calls.where((call) => call == 'threads'), isEmpty);
      }
    });
  });

  group('the eye capped', () {
    test('fits as it is: the same pixels, not a copy', () {
      final eye = SbsDecoded(width: 4, height: 2, rgba: Uint8List(32));
      expect(fitEye(eye, maxWidth: 4, maxHeight: 8), same(eye));
      expect(fittedEyeSize(4, 2, maxWidth: 4, maxHeight: 8), (4, 2));
    });

    test('reduced by area average, exactly, the profile kept', () {
      // 4 x 2 to 2 x 1: each pixel of the result is the mean of a 2 x 2 square
      final rgba = Uint8List.fromList([
        0, 0, 0, 255, 100, 10, 20, 255, 200, 200, 200, 255, 50, 50, 50, 255, //
        100, 10, 20, 255, 0, 30, 40, 255, 100, 100, 100, 255, 150, 150, 150, 255,
      ]);
      final profile = Uint8List.fromList([1, 2, 3]);
      final fitted = fitEye(
        SbsDecoded(width: 4, height: 2, rgba: rgba, iccProfile: profile),
        maxWidth: 2,
        maxHeight: 4,
      );
      expect((fitted.width, fitted.height), (2, 1));
      expect(fitted.rgba, [50, 13, 20, 255, 125, 125, 125, 255]);
      expect(fitted.iccProfile, same(profile));
    });

    test('three to two pixels: each covers one and a half, weighted by its share', () {
      final rgba = Uint8List.fromList([0, 0, 0, 255, 90, 90, 90, 255, 180, 180, 180, 255]);
      final fitted = fitEye(SbsDecoded(width: 3, height: 1, rgba: rgba), maxWidth: 2, maxHeight: 1);
      // (0 * 1 + 90 * 0.5) / 1.5 = 30, (90 * 0.5 + 180 * 1) / 1.5 = 150
      expect(fitted.rgba, [30, 30, 30, 255, 150, 150, 150, 255]);
    });

    test('a tall photo capped at twice the width of an eye in height', () {
      expect(fittedEyeSize(4000, 40000, maxWidth: 8192, maxHeight: 16384), (1638, 16384));
      expect(fittedEyeSize(12000, 4000, maxWidth: 8192, maxHeight: 16384), (8192, 2731));
    });
  });

  test("the EXIF of the job first, then the original's, the date with its offset and the place as a whole", () {
    const original = ImmersiveExif(
      dateTimeOriginal: '2025:05:03 09:20:00',
      offsetTimeOriginal: '+02:00',
      latitude: -33.8,
      longitude: -70.6,
      altitude: 512.5,
      software: 'FC3582 firmware',
    );
    expect(
      mergedExif(const ImmersiveExif(software: 'Immuch360'), original),
      isA<ImmersiveExif>()
          .having((e) => e.dateTimeOriginal, 'date', '2025:05:03 09:20:00')
          .having((e) => e.offsetTimeOriginal, 'offset', '+02:00')
          .having((e) => e.altitude, 'altitude', 512.5)
          .having((e) => e.software, 'software', 'Immuch360'),
    );
    final mine = mergedExif(
      const ImmersiveExif(dateTimeOriginal: '2026:01:01 00:00:00', latitude: 1, longitude: 2),
      original,
    );
    expect((mine.dateTimeOriginal, mine.offsetTimeOriginal), ('2026:01:01 00:00:00', null));
    expect((mine.latitude, mine.longitude, mine.altitude), (1, 2, null));
    expect(mine.software, isNull, reason: 'never the software of the original');
  });
}

/// A memory whose free part the test changes between two jobs
class SettableMemoryProbe implements MemoryProbe {
  SettableMemoryProbe(this.available);

  int? available;

  @override
  MemoryFacts read() => MemoryFacts(physical: 16 * 1024 * 1024 * 1024, available: available);
}
