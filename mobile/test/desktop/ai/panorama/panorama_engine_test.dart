// The engine of the 360° panoramas generated around a photo, pano-v1 (lot P3, design-final 2026-10-27, sections 4.3,
// 4.5 and 10.1 point 6), on the fakes of lot C0 at small sizes: the whole chain from a JPEG to the .part, its steps in
// order with "step k of n" and the time left, the XMP with GPano, the IPTC, the region and the coverage, the photo
// pasted back to the pixel, a photo much larger than the frame reduced to its density first, the seam and its flag,
// the field of view from the EXIF, MoGe-2 or the guess, the turns of the photo, a refused image made once more then
// refused, the named failures of the generator, the cancel, the components, the source changed, a photo that is not a
// JPEG; the steps sent to isolates of their own as the app runs them; then the same chain through the runner of lot P2
// and the compiled fake sd-cli (IMMUCH360_FAKE_SD_CLI).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_projection.dart';
import 'package:immich_mobile/desktop/ai/panorama/panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/panorama/panorama_prompt.dart';
import 'package:immich_mobile/desktop/ai/panorama/photo_fov.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_backends.dart';
import '../fakes/fake_engine_tools.dart';
import '../scene/scene_test_support.dart';

/// The sizes of the tests: a control frame of 64 x 32, a generation of 48 x 24, a panorama of 192 x 96
const _sizes = PanoramaSizes(
  controlWidth: 64,
  controlHeight: 32,
  generationWidth: 48,
  generationHeight: 24,
  scale: 4,
  padding: 4,
);

String _sha1Of(List<int> bytes) => base64.encode(crypto.sha1.convert(bytes).bytes);

/// The models of the processor, fakes the steps take as they are when they run inline
class _Models implements PanoramaModelsSpec {
  _Models({this.geometry, InpaintBackend? inpaint}) : inpaint = inpaint ?? FakeInpaintBackend();

  final GeometryBackend? geometry;
  final InpaintBackend inpaint;
  var geometryOpened = 0;
  var inpaintOpened = 0;

  @override
  GeometryBackend? openGeometry() {
    if (geometry != null) {
      geometryOpened++;
    }
    return geometry;
  }

  @override
  InpaintBackend openInpaint() {
    inpaintOpened++;
    return inpaint;
  }

  @override
  String get inpaintSha256 => inpaint.modelSha256;
}

/// A sendable spec of the fakes, for the steps sent to isolates of their own
class _SentModels implements PanoramaModelsSpec {
  const _SentModels();

  @override
  GeometryBackend? openGeometry() => FakeGeometryBackend(shape: FakeGeometryShape.floor);

  @override
  InpaintBackend openInpaint() => FakeInpaintBackend();

  @override
  String get inpaintSha256 => '4' * 64;
}

/// A filling that changes nothing: the seam stays as the generator left it
class _Untouched implements InpaintBackend {
  @override
  int get regionMax => 512;

  @override
  String get modelSha256 => '4' * 64;

  @override
  Uint8List fill(InpaintRegion region) => Uint8List.fromList(region.rgb);

  @override
  void close() {}
}

/// The fake generator, one outcome after the other
class _Sequence implements GeneratorBackend {
  _Sequence(List<FakeGeneration> outcomes)
    : _outcomes = [for (final outcome in outcomes) FakeGeneratorBackend(outcome: outcome)];

  final List<FakeGeneratorBackend> _outcomes;
  final requests = <GeneratorRequest>[];

  @override
  String get generatorSha256 => _outcomes.first.generatorSha256;

  @override
  String get loraSha256 => _outcomes.first.loraSha256;

  @override
  Future<void> generate(
    GeneratorRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) {
    requests.add(request);
    final next = _outcomes.length > 1 ? _outcomes.removeAt(0) : _outcomes.single;
    return next.generate(request, cancel: cancel, onProgress: onProgress);
  }
}

/// A generator that fails with [code] at once
class _Failing implements GeneratorBackend {
  _Failing(this.code);

  final ImmersiveErrorCode code;
  var calls = 0;

  @override
  String get generatorSha256 => '1' * 64;

  @override
  String get loraSha256 => '2' * 64;

  @override
  Future<void> generate(
    GeneratorRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) async {
    calls++;
    throw BackendException(code, 'failed as asked');
  }
}

List<SbsCodec> _dartCodecs() => const [DartSbsCodec()];

void main() {
  late Directory folder;
  late AiWorkFolders work;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('panorama_engine_test_');
    work = AiWorkFolders(Directory(p.join(folder.path, aiWorkFolderName)));
    cancel = NativeCancelFlag();
  });
  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  /// A photo of 48 x 32 with a focal length of 26 mm equivalent in its EXIF, or without EXIF
  String photo({bool focal = true}) =>
      scenePhoto(folder, 'salon.jpg', width: 48, height: 32, exif: focal ? exifWithFocal35(26) : null);

  /// A photo of [width] x [height] in a checkerboard of single pixels, with a focal length of 26 mm equivalent: read
  /// pixel by pixel instead of reduced to the density of the frame, it aliases
  String finePhoto(int width, int height) {
    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final light = (x + y).isEven;
        image.setPixelRgb(x, y, light ? 230 : 20, light ? 210 : 40, light ? 30 : 200);
      }
    }
    final path = p.join(folder.path, 'fine.jpg');
    File(path).writeAsBytesSync(insertAfterSoi(img.encodeJpg(image, quality: 95), exifWithFocal35(26)));
    return path;
  }

  /// Each pixel of [written] (192 x 96) where the photo is whole is the photo reduced to the density of the panorama,
  /// read at that point
  void expectPastedBack(SbsPicture written, SbsDecoded photoPixels, double hfov) {
    expect((written.width, written.height), (192, 96));
    final reduced = photoForFrame(photoPixels, hfov: hfov, frameWidth: 192);
    final colour = Float64List(3);
    var whole = 0;
    for (var y = 0; y < 96; y++) {
      for (var x = 0; x < 192; x++) {
        final point = photoPointOf(x, y, 192, 96, photoWidth: reduced.width, photoHeight: reduced.height, hfov: hfov);
        if (point == null) {
          continue;
        }
        final (u, v) = point;
        final edge = [
          u / reduced.width,
          1 - u / reduced.width,
          v / reduced.height,
          1 - v / reduced.height,
        ].reduce((a, b) => a < b ? a : b);
        if (edge < PanoV1.pasteFeather) {
          continue;
        }
        whole++;
        readPhoto(reduced, u, v, colour);
        final at = 4 * (y * 192 + x);
        expect(written.rgba.sublist(at, at + 3), [for (final c in colour) toByte(c)], reason: '($x, $y)');
      }
    }
    expect(whole, greaterThan(100));
  }

  PanoramaJob jobOf(String path, {int turns = 0, int seed = 1002, String? sha1}) {
    final bytes = File(path).readAsBytesSync();
    return PanoramaJob(
      id: 'panorama-1',
      source: ImmersiveSource(name: p.basename(path), size: bytes.length, sha1: sha1 ?? _sha1Of(bytes), path: path),
      partPath: p.join(folder.path, '.salon_360.jpg.42-1.immuch360.part'),
      derivativeId: 'derivative-1',
      creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
      created: '2026-10-28T17:00:00+01:00',
      generator: 'flux2-klein-base-4b-q4_0',
      steps: 4,
      seed: seed,
      quarterTurns: turns,
    );
  }

  PanoramaEngine engineOf({
    GeneratorBackend? generator,
    UpscaleBackend? upscaler,
    PanoramaModelsSpec? models,
    Map<String, int?> requiredFiles = const {},
    PanoramaPhotoDecoder? decodeOther,
    List<SbsCodec> Function()? codecs,
    PanoramaCompute compute = panoramaInline,
  }) => PanoramaEngine(
    generator: generator ?? FakeGeneratorBackend(),
    upscaler: upscaler ?? FakeUpscaleBackend(),
    models: models ?? _Models(),
    folders: work,
    requiredFiles: requiredFiles,
    decodeOther: decodeOther,
    codecs: codecs ?? _dartCodecs,
    compute: compute,
    sizes: _sizes,
  );

  bool workLeft() => work.root.existsSync() && work.root.listSync().isNotEmpty;

  group('a photo becomes a 360° panorama', () {
    test('its steps in order, the generator asked with the control frame, the file with its XMP', () async {
      final path = photo();
      final before = File(path).readAsBytesSync();
      final job = jobOf(path);
      final generator = FakeGeneratorBackend();
      final upscaler = FakeUpscaleBackend();
      final models = _Models();
      final heard = <ImmersiveProgress>[];
      final controls = <List<int>>[];
      final engine = engineOf(
        generator: _Watching(generator, (request) => controls.add(File(request.controlPath).readAsBytesSync())),
        upscaler: upscaler,
        models: models,
      );

      final result = await engine.run(job, cancel: cancel, onProgress: heard.add);

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      final stages = <ImmersiveStage>[];
      for (final progress in heard) {
        if (stages.isEmpty || stages.last != progress.stage) {
          stages.add(progress.stage);
        }
      }
      expect(stages, ImmersiveStage.panorama);
      expect(heard.map((progress) => progress.perMille), orderedEquals([...heard.map((p) => p.perMille)]..sort()));
      expect(heard.last.perMille, 1000);
      final steps = heard.where((progress) => progress.stage == ImmersiveStage.generating).toList();
      expect(steps.map((progress) => progress.step), [1, 2, 3, 4]);
      expect(steps.map((progress) => progress.steps), everyElement(4));
      expect(steps.map((progress) => progress.remaining), [
        const Duration(seconds: 36),
        const Duration(seconds: 24),
        const Duration(seconds: 12),
        Duration.zero,
      ]);

      final request = generator.requests.single;
      expect(request.prompt, panoramaPrompt);
      expect(request.seed, 1002);
      expect(request.steps, 4);
      expect((request.width, request.height), (48, 24));
      expect(request.guidance, PanoV1.guidance);
      expect(request.loraStrength, PanoV1.loraStrength);
      final control = img.decodePng(Uint8List.fromList(controls.single))!;
      expect((control.width, control.height), (64, 32));
      final corner = control.getPixel(0, 0);
      expect((corner.r, corner.g, corner.b), (0, 255, 0));
      expect(upscaler.requests.single.scale, 4);

      final fov = photoFovOfExif(48, 32, 26)!;
      final details = result.details! as PanoramaResultDetails;
      expect((details.width, details.height), (192, 96));
      expect(details.seed, 1002);
      expect(details.steps, 4);
      expect(details.sourceCoverage, inExclusiveRange(0.05, 0.12));

      final written = File(job.partPath).readAsBytesSync();
      expect(result.bytesWritten, written.length);
      final decoded = const DartSbsCodec().decodeJpeg(written);
      expect((decoded.width, decoded.height), (192, 96));
      final xmp = ImmersiveXmp.findIn(written)! as PanoramaXmp;
      expect(xmp.kind, ImmersiveKind.panorama360);
      expect(xmp.origin, ImmersiveOrigin.generatedContent);
      expect(xmp.pipeline, PanoV1.pipeline);
      expect((xmp.width, xmp.height), (192, 96));
      expect(xmp.region!.yaw, 0);
      expect(xmp.region!.pitch, 0);
      expect(xmp.region!.hfov, closeTo(fov.hfov, 0.005));
      expect(xmp.region!.vfov, closeTo(fov.vfov, 0.005));
      expect(xmp.sourceCoverage, closeTo(details.sourceCoverage, 0.0001));
      expect(xmp.generator, 'flux2-klein-base-4b-q4_0');
      expect(xmp.generatorSha256, generator.generatorSha256);
      expect(xmp.generatorLora, panoramaLoraComponent.id);
      expect(xmp.generatorLoraSha256, generator.loraSha256);
      expect(xmp.upscaler, upscalerComponent.id);
      expect(xmp.seed, 1002);
      expect(xmp.steps, 4);
      expect(xmp.sourceName, 'salon.jpg');
      expect(xmp.sourceSize, before.length);
      expect(xmp.sourceSha1, _sha1Of(before));
      expect(xmp.derivativeId, 'derivative-1');
      expect(xmp.created, job.created);
      expect(xmp.creatorTool, job.creatorTool);
      expect(xmp.description, panoramaDescription);
      expect(xmp.digitalSourceType, iptcCompositeWithTrainedAlgorithmicMedia);
      expect(xmp.qualityFlags, [ReliefQualityFlag.mostlyInvented]);
      expect(result.qualityFlags, [ReliefQualityFlag.mostlyInvented]);
      final packet = latin1.decode(written.sublist(0, 4096), allowInvalid: true);
      expect(packet, contains('GPano:ProjectionType="equirectangular"'));
      expect(packet, contains('GPano:FullPanoWidthPixels="192"'));
      expect(packet, isNot(contains('InitialViewHeadingDegrees')));

      expect(models.inpaintOpened, 1);
      expect((models.inpaint as FakeInpaintBackend).closed, isTrue);
      expect(models.geometryOpened, 0);
      expect(File(path).readAsBytesSync(), before);
      expect(workLeft(), isFalse);
      expect(result.stageTimes.keys, containsAll([ImmersiveStage.generating, ImmersiveStage.upscale]));
    });

    test('the photo itself pasted back to the pixel where it is whole', () async {
      final path = photo();
      final recording = RecordingCodec(const DartSbsCodec());
      final result = await engineOf(codecs: () => [recording]).run(jobOf(path), cancel: cancel);
      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      expectPastedBack(recording.pictures.single, recording.decoded.last, photoFovOfExif(48, 32, 26)!.hfov);
    });

    test(
      'a photo much larger than the frame: reduced to its density for the control frame and the paste back',
      () async {
        // A photo of 12 to 50 Mpx read pixel by pixel would alias in the frame the LoRA sees and in the region pasted
        // back; here a checkerboard of single pixels over 512 x 340, far more than 1.5 pixels of the photo per pixel of
        // a frame of 64 or of a panorama of 192
        final path = finePhoto(512, 340);
        final recording = RecordingCodec(const DartSbsCodec());
        final controls = <List<int>>[];
        final result = await engineOf(
          generator: _Watching(
            FakeGeneratorBackend(),
            (request) => controls.add(File(request.controlPath).readAsBytesSync()),
          ),
          codecs: () => [recording],
        ).run(jobOf(path), cancel: cancel);
        expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
        final photoPixels = recording.decoded.first;
        expect((photoPixels.width, photoPixels.height), (512, 340));
        final hfov = photoFovOfExif(512, 340, 26)!.hfov;

        final reduced = photoForFrame(photoPixels, hfov: hfov, frameWidth: 64);
        expect(reduced.width, lessThan(512 ~/ 4), reason: 'the photo is reduced for the frame');
        final expected = projectPhoto(reduced, hfov: hfov, width: 64, height: 32);
        final control = img.decodePng(Uint8List.fromList(controls.single))!;
        expect((control.width, control.height), (64, 32));
        var inside = 0;
        for (var y = 0; y < 32; y++) {
          for (var x = 0; x < 64; x++) {
            final pixel = control.getPixel(x, y);
            final at = 4 * (y * 64 + x);
            inside += expected.inside[y * 64 + x] == 0 ? 0 : 1;
            expect(
              [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()],
              expected.rgba.sublist(at, at + 3),
              reason: '($x, $y)',
            );
          }
        }
        expect(inside, greaterThan(20));

        expect(photoForFrame(photoPixels, hfov: hfov, frameWidth: 192).width, lessThan(512 ~/ 2));
        expectPastedBack(recording.pictures.single, recording.decoded.last, hfov);
      },
    );

    test('the steps sent to isolates of their own, as the app runs them; the generator asked from this one', () async {
      final generator = FakeGeneratorBackend();
      final result = await engineOf(
        generator: generator,
        models: const _SentModels(),
        compute: panoramaInIsolate,
      ).run(jobOf(photo(focal: false)), cancel: cancel);
      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      // The fake counts its calls here: the generator, a child process in the app, starts from the engine's isolate
      expect(generator.requests, hasLength(1));
      expect(result.qualityFlags, contains(ReliefQualityFlag.fovGuessed));
    });
  });

  group('the seam', () {
    test('filled in: its band given to the filling, no flag once it meets', () async {
      final inpaint = FakeInpaintBackend();
      final result = await engineOf(models: _Models(inpaint: inpaint)).run(jobOf(photo()), cancel: cancel);
      expect(result.isDone, isTrue);
      final region = inpaint.regions.single;
      expect((region.width, region.height), (48, 24));
      expect(region.mask.where((value) => value == 0).length, 4 * 24);
      expect(result.qualityFlags, isNot(contains(ReliefQualityFlag.seam)));
    });

    test('still visible after the filling: the flag seam', () async {
      final result = await engineOf(models: _Models(inpaint: _Untouched())).run(jobOf(photo()), cancel: cancel);
      expect(result.isDone, isTrue);
      expect(result.qualityFlags, contains(ReliefQualityFlag.seam));
      final xmp = ImmersiveXmp.findIn(File(jobOf(photo()).partPath).readAsBytesSync())! as PanoramaXmp;
      expect(xmp.qualityFlags, contains(ReliefQualityFlag.seam));
    });
  });

  group('the field of view', () {
    test('without EXIF, MoGe-2: its focal length, fovGuessed, the model given back', () async {
      final geometry = FakeGeometryBackend(shape: FakeGeometryShape.floor, focal: 1.2);
      final models = _Models(geometry: geometry);
      final job = jobOf(photo(focal: false));
      final result = await engineOf(models: models).run(job, cancel: cancel);
      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      expect(geometry.calls, 1);
      expect(geometry.closed, isTrue);
      final xmp = ImmersiveXmp.findIn(File(job.partPath).readAsBytesSync())! as PanoramaXmp;
      expect(xmp.region!.hfov, closeTo(photoFovOfModel(48, 32, 1.2).hfov, 0.05));
      expect(xmp.qualityFlags, contains(ReliefQualityFlag.fovGuessed));
    });

    test('without EXIF nor model: the 65° M3 guessed', () async {
      final job = jobOf(photo(focal: false));
      final result = await engineOf().run(job, cancel: cancel);
      expect(result.isDone, isTrue);
      final xmp = ImmersiveXmp.findIn(File(job.partPath).readAsBytesSync())! as PanoramaXmp;
      expect(xmp.region!.hfov, 65);
      expect(xmp.qualityFlags, contains(ReliefQualityFlag.fovGuessed));
    });

    test('a photo turned a quarter by the user: its frame as seen, taller than wide', () async {
      final job = jobOf(photo(), turns: 1);
      final result = await engineOf().run(job, cancel: cancel);
      expect(result.isDone, isTrue);
      final xmp = ImmersiveXmp.findIn(File(job.partPath).readAsBytesSync())! as PanoramaXmp;
      final fov = photoFovOfExif(32, 48, 26)!;
      expect(xmp.region!.hfov, closeTo(fov.hfov, 0.005));
      expect(xmp.region!.vfov, greaterThan(xmp.region!.hfov));
      expect(xmp.sourceQuarterTurns, 1);
    });
  });

  group('a refused image', () {
    test('grey twice: made once more with the next seed, then outputRejected, nothing written', () async {
      final generator = _Sequence([FakeGeneration.grey]);
      final job = jobOf(photo());
      final result = await engineOf(generator: generator).run(job, cancel: cancel);
      expect(result.error, ImmersiveErrorCode.outputRejected);
      expect(result.message, contains('grey'));
      expect(generator.requests.map((request) => request.seed), [1002, 1003]);
      expect(File(job.partPath).existsSync(), isFalse);
      expect(workLeft(), isFalse);
    });

    test('green left once, then a good one: the panorama of the second seed', () async {
      final generator = _Sequence([FakeGeneration.green, FakeGeneration.good]);
      final job = jobOf(photo());
      final result = await engineOf(generator: generator).run(job, cancel: cancel);
      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      expect((result.details! as PanoramaResultDetails).seed, 1003);
      expect((ImmersiveXmp.findIn(File(job.partPath).readAsBytesSync())! as PanoramaXmp).seed, 1003);
    });

    test('refused by the generator itself (sd-cli checks its image): made once more too', () async {
      final generator = _Rejecting(FakeGeneratorBackend());
      final result = await engineOf(generator: generator).run(jobOf(photo()), cancel: cancel);
      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
      expect(generator.calls, 2);
    });
  });

  test('the named failures of the generator end the job at once, never made again', () async {
    for (final code in [
      ImmersiveErrorCode.gpuOutOfMemory,
      ImmersiveErrorCode.gpuBusy,
      ImmersiveErrorCode.generatorFailed,
      ImmersiveErrorCode.generatorStalled,
    ]) {
      final generator = _Failing(code);
      final job = jobOf(photo());
      final result = await engineOf(generator: generator).run(job, cancel: cancel);
      expect(result.error, code);
      expect(generator.calls, 1, reason: code.name);
      expect(File(job.partPath).existsSync(), isFalse);
      expect(workLeft(), isFalse);
    }
  });

  test('cancelled during the generation: cancelled, nothing written, nothing left', () async {
    final job = jobOf(photo());
    final upscaler = FakeUpscaleBackend();
    final result = await engineOf(upscaler: upscaler).run(
      job,
      cancel: cancel,
      onProgress: (progress) {
        if (progress.stage == ImmersiveStage.generating && progress.step == 2) {
          cancel.cancel();
        }
      },
    );
    expect(result.error, ImmersiveErrorCode.cancelled);
    expect(upscaler.requests, isEmpty);
    expect(File(job.partPath).existsSync(), isFalse);
    expect(workLeft(), isFalse);
  });

  test('cancelled before it starts: nothing asked of anyone', () async {
    final generator = FakeGeneratorBackend();
    cancel.cancel();
    final result = await engineOf(generator: generator).run(jobOf(photo()), cancel: cancel);
    expect(result.error, ImmersiveErrorCode.cancelled);
    expect(generator.requests, isEmpty);
  });

  test('a .part the write probe left empty is left empty after a failure', () async {
    final job = jobOf(photo());
    File(job.partPath).writeAsBytesSync(const []);
    final result = await engineOf(generator: _Failing(ImmersiveErrorCode.generatorFailed)).run(job, cancel: cancel);
    expect(result.error, ImmersiveErrorCode.generatorFailed);
    expect(File(job.partPath).lengthSync(), 0);
  });

  test('a component missing or damaged: componentsMissing before anything runs', () async {
    final model = File(p.join(folder.path, 'model.gguf'))..writeAsBytesSync([1, 2, 3]);
    final generator = FakeGeneratorBackend();
    final missing = await engineOf(
      generator: generator,
      requiredFiles: {p.join(folder.path, 'none.gguf'): 3},
    ).run(jobOf(photo()), cancel: cancel);
    expect(missing.error, ImmersiveErrorCode.componentsMissing);
    final damaged = await engineOf(
      generator: generator,
      requiredFiles: {model.path: 4},
    ).run(jobOf(photo()), cancel: cancel);
    expect(damaged.error, ImmersiveErrorCode.componentsMissing);
    expect(damaged.message, contains('damaged'));
    expect(generator.requests, isEmpty);
  });

  test('the photo changed since it was queued: sourceLost', () async {
    final result = await engineOf().run(jobOf(photo(), sha1: 'AAAA'), cancel: cancel);
    expect(result.error, ImmersiveErrorCode.sourceLost);
  });

  test('a photo that is not a JPEG: the decoder of the app, or unsupportedFormat without one', () async {
    final png = File(p.join(folder.path, 'salon.png'))
      ..writeAsBytesSync(img.encodePng(img.Image(width: 30, height: 20)..clear(img.ColorRgb8(90, 120, 30))));
    final without = await engineOf().run(jobOf(png.path), cancel: cancel);
    expect(without.error, ImmersiveErrorCode.unsupportedFormat);
    var asked = 0;
    final job = jobOf(png.path);
    final result = await engineOf(
      decodeOther: (bytes, {maxWidth}) async {
        asked++;
        return SbsDecoded(
          width: 30,
          height: 20,
          rgba: Uint8List.fromList([
            for (var i = 0; i < 600; i++) ...[90, 120, 30, 255],
          ]),
        );
      },
    ).run(job, cancel: cancel);
    expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    expect(asked, 1);
    expect((ImmersiveXmp.findIn(File(job.partPath).readAsBytesSync())! as PanoramaXmp).region!.hfov, 65);
  });

  group('through the runner of sd-cli and the compiled fake sd-cli', () {
    final fake = Platform.environment['IMMUCH360_FAKE_SD_CLI'];
    final launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];
    final withoutFake = fake == null || (Platform.isLinux && launcher == null)
        ? 'IMMUCH360_FAKE_SD_CLI (and on Linux IMMUCH360_RUN_LAUNCHER) not given'
        : null;

    PanoramaEngine engineWith(
      String mode,
      ManagedProcessRunner runner, {
      Duration stall = const Duration(seconds: 180),
    }) {
      final settings = SdCppSettings(
        stallTimeout: stall,
        sdCli: fake!,
        models: SdCppModels(
          diffusionModel: p.join(folder.path, 'flux.gguf'),
          vae: p.join(folder.path, 'vae.safetensors'),
          textEncoder: p.join(folder.path, 'qwen.gguf'),
          lora: p.join(folder.path, 'lora', 'flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors'),
          upscaler: p.join(folder.path, 'RealESRGAN_x4plus.pth'),
        ),
        device: 'Vulkan0',
        environment: {'IMMUCH360_FAKE_SD_CLI_MODE': mode},
      );
      return engineOf(
        generator: SdCppGenerator(runner: runner, settings: settings, generatorSha256: '1' * 64, loraSha256: '2' * 64),
        upscaler: SdCppUpscaler(runner: runner, settings: settings, modelSha256: '5' * 64),
      );
    }

    test('a panorama made, its steps heard; grey refused twice; short of memory; cut into segments', () async {
      final runner = ManagedProcessRunner(
        linuxLauncher: Platform.isLinux ? launcher : null,
        journal: ProcessJournal(File(p.join(folder.path, 'processes.json'))),
      );
      final heard = <ImmersiveProgress>[];
      final job = jobOf(photo());
      final made = await engineWith('ok', runner).run(job, cancel: cancel, onProgress: heard.add);
      expect(made.isDone, isTrue, reason: '${made.error}: ${made.message}');
      expect(heard.where((progress) => progress.stage == ImmersiveStage.generating).map((progress) => progress.step), [
        1,
        2,
        3,
        4,
      ]);
      expect(const DartSbsCodec().decodeJpeg(File(job.partPath).readAsBytesSync()).width, 192);

      for (final (mode, code) in [
        ('grey', ImmersiveErrorCode.outputRejected),
        ('oom', ImmersiveErrorCode.gpuOutOfMemory),
        ('segments', ImmersiveErrorCode.gpuBusy),
      ]) {
        final failed = await engineWith(mode, runner).run(jobOf(photo()), cancel: cancel);
        expect(failed.error, code, reason: mode);
      }
      expect(runner.journal!.read(), isEmpty);
      expect(workLeft(), isFalse);
    }, skip: withoutFake);

    test('a generator that fails, one that says nothing, one cancelled: named, stopped, gone', () async {
      final runner = ManagedProcessRunner(
        linuxLauncher: Platform.isLinux ? launcher : null,
        journal: ProcessJournal(File(p.join(folder.path, 'processes.json'))),
      );
      final failed = await engineWith('fail', runner).run(jobOf(photo()), cancel: cancel);
      expect(failed.error, ImmersiveErrorCode.generatorFailed);
      expect(failed.message, contains('load the control image failed'));

      final silent = await engineWith(
        'silent',
        runner,
        stall: const Duration(seconds: 1),
      ).run(jobOf(photo()), cancel: cancel);
      expect(silent.error, ImmersiveErrorCode.generatorStalled);

      final slow = NativeCancelFlag();
      addTearDown(slow.free);
      final job = jobOf(photo());
      final pids = <int>[];
      final watch = Stopwatch();
      final cancelled = await engineWith('slow', runner).run(
        job,
        cancel: slow,
        onProgress: (progress) {
          if (progress.stage == ImmersiveStage.generating && progress.step == 1 && !slow.isCancelled) {
            pids.addAll(runner.journal!.read().map((entry) => entry.pid));
            watch.start();
            slow.cancel();
          }
        },
      );
      expect(cancelled.error, ImmersiveErrorCode.cancelled);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(pids, hasLength(1));
      expect(processImageOf(pids.single), isNull, reason: 'sd-cli is gone');
      expect(runner.journal!.read(), isEmpty, reason: 'every sd-cli ended and left the journal');
      expect(File(job.partPath).existsSync(), isFalse);
      expect(workLeft(), isFalse);
    }, skip: withoutFake);
  });
}

/// [inner], showing each request to [onRequest] while its files exist
class _Watching implements GeneratorBackend {
  _Watching(this.inner, this.onRequest);

  final GeneratorBackend inner;
  final void Function(GeneratorRequest request) onRequest;

  @override
  String get generatorSha256 => inner.generatorSha256;

  @override
  String get loraSha256 => inner.loraSha256;

  @override
  Future<void> generate(
    GeneratorRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) {
    onRequest(request);
    return inner.generate(request, cancel: cancel, onProgress: onProgress);
  }
}

/// [inner], whose first image is refused as sd-cli refuses one it checked: deleted, outputRejected
class _Rejecting implements GeneratorBackend {
  _Rejecting(this.inner);

  final GeneratorBackend inner;
  var calls = 0;

  @override
  String get generatorSha256 => inner.generatorSha256;

  @override
  String get loraSha256 => inner.loraSha256;

  @override
  Future<void> generate(
    GeneratorRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) async {
    calls++;
    await inner.generate(request, cancel: cancel, onProgress: onProgress);
    if (calls == 1) {
      File(request.outputPath).deleteSync();
      throw const BackendException(ImmersiveErrorCode.outputRejected, 'The generated image was refused: a grey image');
    }
  }
}
