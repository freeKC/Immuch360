// DartImmersiveEngine (lot A4b): the original read on the root isolate, a photo that is not a JPEG decoded there by
// the engine of Flutter, the job run in the worker isolate with FakeBackendSpec and the Dart codec; the files of the
// model checked before each job; one job at a time; a worker that dies. The real ONNX Runtime with the tiny model:
// test/desktop/ai/ort/ort_engine_test.dart; the real model on real photos, by hand: engine_real_model_test.dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/native_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_engine_tools.dart';
import '../fakes/fake_thread_priority.dart';
import 'engine_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory folder;
  late NativeCancelFlag cancel;
  setUp(() {
    folder = Directory.systemTemp.createTempSync('dart_immersive_engine_test_');
    cancel = NativeCancelFlag();
  });
  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  DartImmersiveEngine engineWith({
    FakeBackendSpec backend = const FakeBackendSpec(),
    SbsCodecChoice codec = SbsCodecChoice.dart,
    Map<String, int?> requiredFiles = const {},
    OtherPhotoDecoder? decodeOther,
  }) {
    final engine = DartImmersiveEngine(
      setup: AiWorkerSetup(
        backend: backend,
        codec: codec,
        memory: const FixedMemoryProbe(),
        priority: FakeThreadPriority(threads: {1: 'main'}),
      ),
      requiredFiles: requiredFiles,
      decodeOther: decodeOther,
    );
    addTearDown(engine.dispose);
    return engine;
  }

  test('reads the original by its path and makes its 3D photo in the worker', () async {
    final engine = engineWith();
    final path = codecFixturePath('exif_camera.jpg');
    final part = partIn(folder, 'exif_camera.jpg');
    final progress = <ImmersiveProgress>[];
    final result = await engine.run(
      jobFor(path, partPath: part),
      cancel: cancel,
      onProgress: progress.add,
    );

    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    expect((result.eyeWidth, result.eyeHeight), (32, 64));
    final out = File(part).readAsBytesSync();
    expect(StereoPhotoXmp.findIn(out)!.sourceSha1, sha1OfFile(path));
    expect(progress.first, const ImmersiveProgress(ImmersiveStage.reading, 0));
    expect(progress.last, const ImmersiveProgress(ImmersiveStage.writing, 1000));
    expect(result.stageTimes.keys.toSet(), ImmersiveStage.sbs.toSet());
    expect(engine.lastOutcome!.decoder, 'dart');
    expect(engine.isRunning, isFalse);
  });

  test('a source given as bytes: a server original or a file of a share, copied before', () async {
    final path = codecFixturePath('orientation_3.jpg');
    final part = partIn(folder, 'orientation_3.jpg');
    final result = await engineWith().run(jobFor(path, partPath: part, asBytes: true), cancel: cancel);
    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    expect(StereoPhotoXmp.findIn(File(part).readAsBytesSync())!.sourceName, 'orientation_3.jpg');
  });

  test('a PNG decoded by the engine of Flutter on the root isolate, then made 3D in the worker', () async {
    final engine = engineWith();
    final part = partIn(folder, 'transparent.png');
    final result = await engine.run(jobFor(codecFixturePath('transparent.png'), partPath: part), cancel: cancel);
    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    expect(engine.lastOutcome!.decoder, 'engine');
    expect(JpegHeader.read(File(part).readAsBytesSync()).iccProfile, isNull);
  });

  test('a photo turned a quarter is decoded whole, then capped once turned', () async {
    final widths = <int?>[];
    final engine = engineWith(
      decodeOther: (bytes, {maxWidth}) async {
        widths.add(maxWidth);
        return SbsDecoded(width: 32, height: 16, rgba: Uint8List(32 * 16 * 4));
      },
    );
    for (final turns in [0, 1, 2, 3]) {
      final job = jobFor(
        codecFixturePath('transparent.png'),
        partPath: partIn(folder, 't$turns.png'),
        quarterTurns: turns,
      );
      expect((await engine.run(job, cancel: cancel)).isDone, isTrue);
    }
    expect(widths, [8192, null, 8192, null]);
  });

  test('the original gone: sourceLost, nothing written', () async {
    final path = p.join(folder.path, 'gone.jpg');
    File(codecFixturePath('orientation_1.jpg')).copySync(path);
    final job = jobFor(path, partPath: partIn(folder, 'gone.jpg'));
    File(path).deleteSync();
    final result = await engineWith().run(job, cancel: cancel);
    expect(result.error, ImmersiveErrorCode.sourceLost);
    expect(folder.listSync(), isEmpty);
  });

  test('a format this system cannot decode is unsupportedFormat, a damaged PNG decodeFailed', () async {
    final engine = engineWith(
      decodeOther: (bytes, {maxWidth}) async => throw const SbsCodecException('The engine could not decode the photo'),
    );
    // The head of a HEIC: its ftyp box and brand
    final heic = p.join(folder.path, 'photo.heic');
    File(heic).writeAsBytesSync([0, 0, 0, 24, ...'ftypheic'.codeUnits, 0, 0, 0, 0, ...'mif1heic'.codeUnits, 1, 2, 3]);
    var result = await engine.run(jobFor(heic, partPath: partIn(folder, 'photo.heic')), cancel: cancel);
    expect(result.error, ImmersiveErrorCode.unsupportedFormat);
    expect(result.message, startsWith('heif: '));

    final png = p.join(folder.path, 'broken.png');
    File(png).writeAsBytesSync(File(codecFixturePath('transparent.png')).readAsBytesSync().sublist(0, 40));
    result = await engine.run(jobFor(png, partPath: partIn(folder, 'broken.png')), cancel: cancel);
    expect(result.error, ImmersiveErrorCode.decodeFailed);
    expect(folder.listSync().where((entry) => entry.path.endsWith('.part')), isEmpty);
  });

  test('a component removed or damaged meanwhile: componentsMissing, before anything is read', () async {
    final library = File(p.join(folder.path, 'libonnxruntime.so'))..writeAsBytesSync(List.filled(100, 1));
    final model = File(p.join(folder.path, 'model.onnx'))..writeAsBytesSync(List.filled(50, 2));
    final engine = engineWith(requiredFiles: {library.path: null, model.path: 50});
    final job = jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg'));
    expect((await engine.run(job, cancel: cancel)).isDone, isTrue);

    model.writeAsBytesSync(List.filled(49, 2));
    var result = await engine.run(job, cancel: cancel);
    expect(result.error, ImmersiveErrorCode.componentsMissing);
    expect(result.message, contains('49 bytes, not 50'));

    library.deleteSync();
    result = await engine.run(job, cancel: cancel);
    expect(result.error, ImmersiveErrorCode.componentsMissing);
    expect(result.message, contains(library.path));
  });

  test('cancelled before it starts: nothing read, nothing written', () async {
    cancel.cancel();
    final result = await engineWith().run(
      jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')),
      cancel: cancel,
    );
    expect(result.error, ImmersiveErrorCode.cancelled);
    expect(folder.listSync(), isEmpty);
  });

  test('one job at a time: a second call waits for the first', () async {
    final engine = engineWith(backend: const FakeBackendSpec(delay: Duration(milliseconds: 200)));
    final order = <String>[];
    final second = NativeCancelFlag();
    addTearDown(second.free);
    final first = engine.run(
      jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')),
      cancel: cancel,
      onProgress: (progress) => order.add('a ${progress.stage.name}'),
    );
    final next = engine.run(
      jobFor(codecFixturePath('orientation_2.jpg'), partPath: partIn(folder, 'b.jpg')),
      cancel: second,
      onProgress: (progress) => order.add('b ${progress.stage.name}'),
    );
    final results = await Future.wait([first, next]);
    expect(results.every((result) => result.isDone), isTrue);
    final lastOfA = order.lastIndexWhere((step) => step.startsWith('a '));
    final firstOfB = order.indexWhere((step) => step.startsWith('b '));
    expect(lastOfA, lessThan(firstOfB), reason: order.join(', '));
  });

  test('a worker that dies fails its job with modelFailed; the next job gets a new worker', () async {
    final engine = engineWith(backend: const FakeBackendSpec(endIsolateInRun: true));
    for (final name in ['a.jpg', 'b.jpg']) {
      final result = await engine.run(
        jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, name)),
        cancel: cancel,
      );
      expect(result.error, ImmersiveErrorCode.modelFailed, reason: name);
      expect(result.message, contains('stopped'));
      expect(engine.worker, isNull);
    }
  });

  test('the native codec when this build has it, at every size', () async {
    final engine = engineWith(codec: SbsCodecChoice.auto);
    final result = await engine.run(
      jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg')),
      cancel: cancel,
    );
    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    expect((engine.lastOutcome!.decoder, engine.lastOutcome!.encoder), ('native', 'native'));
  }, skip: NativeSbsCodec.available ? null : 'no native codec in this run: ${NativeSbsCodec.unavailableReason}');

  test('after dispose: no job, the worker closed', () async {
    final engine = engineWith();
    final job = jobFor(codecFixturePath('orientation_1.jpg'), partPath: partIn(folder, 'a.jpg'));
    expect((await engine.run(job, cancel: cancel)).isDone, isTrue);
    final worker = engine.worker!;
    await engine.dispose();
    for (var i = 0; i < 50 && worker.isAlive; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(worker.isAlive, isFalse);
    final result = await engine.run(job, cancel: cancel);
    expect(result.error, ImmersiveErrorCode.modelFailed);
  });

  group('the format of a photo by its first bytes', () {
    test('each signature', () {
      Uint8List bytes(List<int> head) => Uint8List.fromList([...head, ...List.filled(16, 0)]);
      expect(photoFormatOf(bytes([0xFF, 0xD8, 0xFF, 0xE0])), PhotoFormat.jpeg);
      expect(photoFormatOf(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), PhotoFormat.png);
      expect(photoFormatOf(bytes('GIF89a'.codeUnits)), PhotoFormat.gif);
      expect(photoFormatOf(bytes([...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WEBP'.codeUnits])), PhotoFormat.webp);
      expect(photoFormatOf(bytes('BM'.codeUnits)), PhotoFormat.bmp);
      expect(photoFormatOf(bytes([0x49, 0x49, 0x2A, 0x00])), PhotoFormat.tiff);
      expect(photoFormatOf(bytes([0x4D, 0x4D, 0x00, 0x2A])), PhotoFormat.tiff);
      expect(photoFormatOf(bytes([0, 0, 0, 24, ...'ftypheic'.codeUnits])), PhotoFormat.heif);
      expect(photoFormatOf(bytes([0, 0, 0, 24, ...'ftypmif1'.codeUnits])), PhotoFormat.heif);
      expect(photoFormatOf(bytes([0, 0, 0, 24, ...'ftypavif'.codeUnits])), PhotoFormat.avif);
      expect(photoFormatOf(bytes([0, 0, 0, 24, ...'ftypisom'.codeUnits])), PhotoFormat.unknown);
      expect(photoFormatOf(Uint8List(0)), PhotoFormat.unknown);
      expect(photoFormatOf(File(codecFixturePath('display_p3.heic')).readAsBytesSync()), PhotoFormat.heif);
    });

    test("decoded by Flutter's own codecs: PNG, GIF, WebP, BMP", () {
      expect(
        [
          for (final format in PhotoFormat.values)
            if (format.isEngineOwn) format,
        ],
        [PhotoFormat.png, PhotoFormat.gif, PhotoFormat.webp, PhotoFormat.bmp],
      );
    });
  });
}
