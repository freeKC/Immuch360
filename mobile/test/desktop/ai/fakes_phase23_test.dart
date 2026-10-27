import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_container.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:path/path.dart' as p;

import 'fakes/fake_backends.dart';
import 'fakes/fake_gpu_probe.dart';
import 'fakes/fake_panorama_engine.dart';
import 'fakes/fake_process_runner.dart';
import 'fakes/fake_scene_engine.dart';
import 'fakes/fake_stereo_panorama_engine.dart';

void main() {
  late Directory folder;
  late NativeCancelFlag cancel;
  const photo = ImmersiveSource(name: 'salon.jpg', size: 4182311, sha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=', path: '/p');
  const original = DerivedRuleOriginal(name: 'salon.jpg', size: 4182311, sha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=');

  String part(String name) => p.join(folder.path, '.$name.1-1.immuch360.part');

  setUp(() {
    folder = Directory.systemTemp.createTempSync('fakes_phase23');
    cancel = NativeCancelFlag();
  });

  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  group('the fake engines write files our readers read', () {
    test('a scene: a photo, its packet, its scene tail, a version of its original', () async {
      final engine = FakeSceneEngine(qualityFlags: const [ReliefQualityFlag.smallZone]);
      final heard = <ImmersiveProgress>[];
      final job = SceneJob(
        id: 's',
        sources: const [photo],
        partPath: part('salon_scene3D.jpg'),
        glbPartPath: part('salon_scene3D.glb'),
        derivativeId: 'urn:uuid:5c',
        creatorTool: 'Immuch360 Desktop test',
        created: '2026-10-27T10:12:00+01:00',
      );

      final result = await engine.run(job, cancel: cancel, onProgress: heard.add);
      final bytes = File(job.partPath).readAsBytesSync();
      final xmp = ImmersiveXmp.findIn(bytes)! as SceneXmp;

      expect(result.isDone, isTrue);
      expect(result.details, isA<SceneResultDetails>());
      expect(result.bytesWritten, bytes.length);
      expect(heard.map((step) => step.stage).toSet().toList(), ImmersiveStage.scene);
      expect(img.decodeJpg(bytes)!.width, 16);
      expect(xmp.qualityFlags, [ReliefQualityFlag.smallZone]);
      expect(xmp.derivativeId, 'urn:uuid:5c');
      expect(sceneBytesOf(bytes, xmp), File(job.glbPartPath!).readAsBytesSync());
      expect(
        isDerivedFrom(DerivedRuleCandidate(name: 'salon_scene3D.jpg', xmp: StereoPhotoXmp.findIn(bytes)), original),
        isTrue,
      );
      expect(
        decideStereoPhoto(name: 'salon_scene3D.jpg', width: 16, height: 12, xmp: StereoPhotoXmp.findIn(bytes)),
        isNull,
      );
      expect(xmp.request, isNotNull);
    });

    test('a panorama: 2:1, GPano for the 360° viewers, the steps of its generation counted', () async {
      final engine = FakePanoramaEngine();
      final heard = <ImmersiveProgress>[];
      final job = PanoramaJob(
        id: 'p',
        source: photo,
        partPath: part('salon_360.jpg'),
        derivativeId: 'urn:uuid:9a',
        creatorTool: 'Immuch360 Desktop test',
        created: '2026-10-27T10:12:00+01:00',
        generator: 'flux2-klein-base-4b-q8_0',
        steps: 4,
        seed: 7,
      );

      final result = await engine.run(job, cancel: cancel, onProgress: heard.add);
      final bytes = File(job.partPath).readAsBytesSync();
      final xmp = ImmersiveXmp.findIn(bytes)! as PanoramaXmp;
      final decoded = img.decodeJpg(bytes)!;

      expect(result.isDone, isTrue);
      expect((result.details! as PanoramaResultDetails).seed, 7);
      expect([decoded.width, decoded.height], [32, 16]);
      expect(parseGPanoProjectionType(latin1.decode(bytes)), 'equirectangular');
      expect(xmp.seed, 7);
      expect(xmp.steps, 4);
      expect(xmp.origin, ImmersiveOrigin.generatedContent);
      final generation = heard.where((step) => step.steps != null).toList();
      expect(generation.map((step) => step.step), [1, 2, 3, 4]);
      expect(generation.last.remaining, Duration.zero);
      for (var i = 1; i < heard.length; i++) {
        expect(heard[i].perMille, greaterThanOrEqualTo(heard[i - 1].perMille));
      }
    });

    test('a panorama fails with the named failure of its step, and leaves no file', () async {
      final engine = FakePanoramaEngine(failAt: ImmersiveStage.generating, failure: ImmersiveErrorCode.gpuOutOfMemory);
      final job = PanoramaJob(
        id: 'p',
        source: photo,
        partPath: part('salon_360.jpg'),
        derivativeId: 'urn:uuid:9b',
        creatorTool: 'test',
        created: 'now',
        generator: 'g',
        steps: 2,
        seed: 1,
      );

      final result = await engine.run(job, cancel: cancel);

      expect(result.error, ImmersiveErrorCode.gpuOutOfMemory);
      expect(File(job.partPath).existsSync(), isFalse);
    });

    test('the 3D version of a generated panorama: square, two eyes stacked, a version of the photo', () async {
      final mono = FakePanoramaEngine().xmpOf(
        const PanoramaJob(
          id: 'p',
          source: photo,
          partPath: '/unused',
          derivativeId: 'urn:uuid:mono',
          creatorTool: 'test',
          created: 'now',
          generator: 'g',
          steps: 4,
          seed: 7,
        ),
      );
      final job = StereoPanoramaJob(
        id: 'sp',
        source: const ImmersiveSource(name: 'salon_360.jpg', size: 10, sha1: 'cGFub3JhbWE=', path: '/q'),
        photo: photo,
        parent: mono,
        partPath: part('salon_360_3D.jpg'),
        derivativeId: 'urn:uuid:stereo',
        creatorTool: 'test',
        created: 'now',
      );

      final result = await FakeStereoPanoramaEngine().run(job, cancel: cancel);
      final bytes = File(job.partPath).readAsBytesSync();
      final xmp = ImmersiveXmp.findIn(bytes)! as StereoPanoramaXmp;
      final decoded = img.decodeJpg(bytes)!;

      expect(result.details, isA<StereoPanoramaResultDetails>());
      expect(guessStereoLayout(width: decoded.width, height: decoded.height), StereoLayout.topBottom);
      expect(xmp.parentDerivativeId, 'urn:uuid:mono');
      expect(xmp.sourceSha1, photo.sha1);
      expect(xmp.region, mono.region);
      expect(
        isDerivedFrom(DerivedRuleCandidate(name: 'renamed.jpg', xmp: StereoPhotoXmp.findIn(bytes)), original),
        isTrue,
      );
    });

    test('a flat 360° photo is refused: notEnoughRelief, no file', () async {
      final engine = FakeStereoPanoramaEngine(failAt: ImmersiveStage.panoramaDepth);
      final job = StereoPanoramaJob(
        id: 'sp',
        source: const ImmersiveSource(name: 'PANO_0001.jpg', size: 10, sha1: 'cGFub3JhbWE=', path: '/q'),
        partPath: part('PANO_0001_3D.jpg'),
        derivativeId: 'urn:uuid:flat',
        creatorTool: 'test',
        created: 'now',
      );

      expect((await engine.run(job, cancel: cancel)).error, ImmersiveErrorCode.notEnoughRelief);
      expect(File(job.partPath).existsSync(), isFalse);
    });

    test('cancelled between two steps', () async {
      final engine = FakeSceneEngine(holdStage: ImmersiveStage.inpaint);
      final job = SceneJob(
        id: 's',
        sources: const [photo],
        partPath: part('salon_scene3D.jpg'),
        derivativeId: 'urn:uuid:c',
        creatorTool: 'test',
        created: 'now',
      );
      engine.reachedHold.stream.listen((_) {
        cancel.cancel();
        engine.release();
      });

      expect((await engine.run(job, cancel: cancel)).error, ImmersiveErrorCode.cancelled);
      expect(File(job.partPath).existsSync(), isFalse);
    });
  });

  group('the fake backends', () {
    test('the geometry gives the planes it says, the filling paints the holes with the known mean', () {
      final geometry = FakeGeometryBackend(shape: FakeGeometryShape.step);
      final maps = geometry.estimate(Float32List(3 * 8 * 6), width: 8, height: 6);

      expect(maps.points[2], 1.0);
      expect(maps.points[3 * 7 + 2], 4.0);
      expect(maps.mask.every((value) => value == 1), isTrue);
      expect(
        FakeGeometryBackend(shape: FakeGeometryShape.sky).estimate(Float32List(3 * 8 * 8), width: 8, height: 8).mask[0],
        0,
      );

      final filled = FakeInpaintBackend().fill(
        InpaintRegion(
          width: 2,
          height: 1,
          rgb: Uint8List.fromList([10, 20, 30, 0, 0, 0]),
          mask: Uint8List.fromList([255, 0]),
        ),
      );
      expect(filled, [10, 20, 30, 10, 20, 30]);
    });

    test('the generator writes a PNG without green, or fails every named way', () async {
      final control = p.join(folder.path, 'control.png');
      final image = img.Image(width: 16, height: 8)..clear(img.ColorRgb8(0, 255, 0));
      File(control).writeAsBytesSync(img.encodePng(image));
      GeneratorRequest request(String out) => GeneratorRequest(
        controlPath: control,
        outputPath: p.join(folder.path, out),
        workFolder: folder.path,
        prompt: 'fixed',
        steps: 3,
        seed: 1,
        width: 16,
        height: 8,
      );
      final heard = <GeneratorProgress>[];

      await FakeGeneratorBackend().generate(request('good.png'), cancel: cancel, onProgress: heard.add);
      final good = img.decodePng(File(p.join(folder.path, 'good.png')).readAsBytesSync())!;
      expect(heard.map((step) => step.step), [1, 2, 3]);
      expect(good.getPixel(3, 3).g, isNot(255));

      for (final (outcome, code) in [
        (FakeGeneration.outOfMemory, ImmersiveErrorCode.gpuOutOfMemory),
        (FakeGeneration.error, ImmersiveErrorCode.generatorFailed),
      ]) {
        await expectLater(
          FakeGeneratorBackend(outcome: outcome).generate(request('x.png'), cancel: cancel),
          throwsA(isA<BackendException>().having((error) => error.code, 'code', code)),
        );
      }
      final silent = FakeGeneratorBackend(outcome: FakeGeneration.silence);
      final stalled = silent.generate(request('y.png'), cancel: cancel);
      silent.endSilence();
      await expectLater(
        stalled,
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.generatorStalled)),
      );
      await FakeUpscaleBackend().upscale(
        UpscaleRequest(
          inputPath: p.join(folder.path, 'good.png'),
          outputPath: p.join(folder.path, 'x4.png'),
          workFolder: folder.path,
        ),
        cancel: cancel,
      );
      expect(img.decodePng(File(p.join(folder.path, 'x4.png')).readAsBytesSync())!.width, 64);
    });

    test('the probe answers the cases of the gate through the JSON of the native probe', () async {
      final probe = FakeGpuProbe([FakeGpuReports.rtx4060Busy, FakeGpuReports.rtx4060]);

      final busy = await probe.probe();
      final free = await probe.probe();

      expect(busy.bestDiscrete!.freeMemory, 2000 << 20);
      expect(free.bestDiscrete!.name, rtx4060Laptop.name);
      expect((await probe.probe()).bestDiscrete!.freeMemory, 7400 << 20);
      expect(probe.calls, 3);
      expect((await FakeGpuProbe.of(FakeGpuReports.twoCards).probe()).bestDiscrete!.name, rtx4060Laptop.name);
      expect((await FakeGpuProbe.of(FakeGpuReports.integratedOnly).probe()).bestDiscrete, isNull);
      expect((await FakeGpuProbe.of(FakeGpuReports.noVulkan).probe()).problem, GpuProbeProblem.noVulkan);
    });

    test('a process plays its lines and exits, or stays silent until killed', () async {
      final runner = FakeProcessRunner(const [
        FakeProcessScript(lines: [('step 1/2', isError: false), ('warn', isError: true), ('step 2/2', isError: false)]),
        FakeProcessScript(lines: [('step 1/28', isError: false)], hangs: true),
      ]);

      final done = await runner.start(const ProcessLaunch(executable: 'sd-cli', arguments: ['--help']));
      expect(await done.stdoutLines.toList(), ['step 1/2', 'step 2/2']);
      expect(await done.exitCode, 0);

      final hung = await runner.start(const ProcessLaunch(executable: 'sd-cli'));
      final lines = <String>[];
      hung.stdoutLines.listen(lines.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(lines, ['step 1/28']);
      hung.kill();
      expect(await hung.exitCode, FakeRunningProcess.killedCode);
      expect(runner.launches.map((launch) => launch.executable), ['sd-cli', 'sd-cli']);
      expect(runner.processes.map((process) => process.pid).toSet(), hasLength(2));
    });
  });
}
