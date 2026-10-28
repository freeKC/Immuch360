import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

void main() {
  const source = ImmersiveSource(name: 'salon.jpg', size: 4182311, sha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=', path: '/p');
  const panorama = ImmersiveSource(name: 'salon_360.jpg', size: 12000000, sha1: 'cGFub3JhbWE=', path: '/q');

  group('the steps of each kind', () {
    test('go forward in the order of ImmersiveStage, so that what a job reports never goes back', () {
      for (final kind in ImmersiveKind.values) {
        final stages = ImmersiveStage.of(kind);

        expect(stages.first, ImmersiveStage.reading, reason: '$kind');
        expect(stages.last, ImmersiveStage.writing, reason: '$kind');
        for (var i = 1; i < stages.length; i++) {
          expect(stages[i].index, greaterThan(stages[i - 1].index), reason: '$kind ${stages[i]}');
        }
        // Preparing, then computing, then finishing
        final phases = stages.map((stage) => stage.phase.index).toList();
        expect(phases, [...phases]..sort(), reason: '$kind');
      }
    });

    test('are those of the design: the 3D photo of phase 1 unchanged', () {
      expect(ImmersiveStage.sbs, [
        ImmersiveStage.reading,
        ImmersiveStage.decoding,
        ImmersiveStage.depth,
        ImmersiveStage.rightEye,
        ImmersiveStage.encoding,
        ImmersiveStage.writing,
      ]);
      expect(ImmersiveStage.scene.where((stage) => stage.phase == ImmersivePhase.computing), [
        ImmersiveStage.geometry,
        ImmersiveStage.layers,
        ImmersiveStage.inpaint,
        ImmersiveStage.mesh,
      ]);
      expect(ImmersiveStage.panorama.where((stage) => stage.phase == ImmersivePhase.computing), [
        ImmersiveStage.loadingModels,
        ImmersiveStage.generating,
        ImmersiveStage.seam,
        ImmersiveStage.upscale,
      ]);
      // Every step belongs to a kind
      expect(ImmersiveKind.values.expand(ImmersiveStage.of).toSet(), ImmersiveStage.values.toSet());
    });

    test('each has its state in the queue, of the same name and phase, in the same order', () {
      for (final stage in ImmersiveStage.values) {
        final state = ConversionState.of(stage);

        expect(state.name, stage.name);
        expect(state.stage, stage);
        expect(state.isActive, isTrue);
        expect(state.phase.name, stage.phase.name);
      }
      final states = ImmersiveStage.values.map(ConversionState.of).toList();
      expect(states.map((state) => state.index), [...states.map((state) => state.index)]..sort());
      expect(ConversionState.waiting.stage, isNull);
      expect(ConversionState.failed.isEnded, isTrue);
    });
  });

  group('the kinds of the queue', () {
    test('write their kind of file, on the processor but the panorama', () {
      expect(
        {for (final kind in ConversionKind.values) kind: (kind.output, kind.lane)},
        {
          ConversionKind.sbsFromPhoto: (ImmersiveKind.stereoPhoto, ConversionLane.cpu),
          ConversionKind.sceneFromPhoto: (ImmersiveKind.volumetricScene, ConversionLane.cpu),
          ConversionKind.panoramaFromPhoto: (ImmersiveKind.panorama360, ConversionLane.gpu),
          ConversionKind.stereoPanoramaFromPanorama: (ImmersiveKind.stereoPanorama360, ConversionLane.cpu),
        },
      );
      expect(ConversionKind.sceneFromPhoto.stages, ImmersiveStage.scene);
    });
  });

  group('the specs, sealed per kind', () {
    String describe(ImmersiveJobSpec job) => switch (job) {
      ImmersiveJob() => 'photo ${job.parallax}',
      SceneJob() => 'scene of ${job.sources.length}',
      PanoramaJob() => 'panorama ${job.steps} steps',
      StereoPanoramaJob() => 'stereo of ${job.original.name}',
    };

    test('each names its kind, its sources, the original it is a version of and its steps', () {
      const sbs = SbsJob(
        id: '1',
        source: source,
        partPath: '/out/.a.part',
        derivativeId: 'urn:uuid:1',
        creatorTool: 'tool',
        created: 'now',
      );
      const scene = SceneJob(
        id: '2',
        sources: [source],
        partPath: '/out/.b.part',
        derivativeId: 'urn:uuid:2',
        creatorTool: 'tool',
        created: 'now',
      );
      const generated = PanoramaJob(
        id: '3',
        source: source,
        partPath: '/out/.c.part',
        derivativeId: 'urn:uuid:3',
        creatorTool: 'tool',
        created: 'now',
        generator: 'flux2-klein-base-4b-q8_0',
        steps: 28,
        seed: 42,
      );
      const stereoOfGenerated = StereoPanoramaJob(
        id: '4',
        source: panorama,
        photo: source,
        partPath: '/out/.d.part',
        derivativeId: 'urn:uuid:4',
        creatorTool: 'tool',
        created: 'now',
      );
      const stereoOf360 = StereoPanoramaJob(
        id: '5',
        source: panorama,
        partPath: '/out/.e.part',
        derivativeId: 'urn:uuid:5',
        creatorTool: 'tool',
        created: 'now',
      );

      expect([sbs, scene, generated, stereoOfGenerated].map((job) => job.kind).toSet(), ImmersiveKind.values.toSet());
      expect([sbs, scene, generated, stereoOfGenerated, stereoOf360].map(describe), [
        'photo ${ReliefV1.parallax}',
        'scene of 1',
        'panorama 28 steps',
        'stereo of salon.jpg',
        'stereo of salon_360.jpg',
      ]);
      // The 3D version of a generated panorama reads the panorama, and is a version of the photo
      expect(stereoOfGenerated.sources, [panorama]);
      expect(stereoOfGenerated.original, source);
      expect(scene.stages, ImmersiveStage.scene);
    });
  });

  group('the results', () {
    test('a 3D photo keeps its fields of phase 1, and its details say the same', () {
      const result = ImmersiveResult.done(eyeWidth: 8, eyeHeight: 6, bytesWritten: 10, reduced: true);
      final details = result.details! as SbsResultDetails;

      expect((details.eyeWidth, details.eyeHeight, details.reduced), (8, 6, true));
      expect(result.isDone, isTrue);
    });

    test('another kind gives its details, and no eye', () {
      const result = ImmersiveResult.made(
        details: PanoramaResultDetails(width: 8192, height: 4096, seed: 42, steps: 28, sourceCoverage: 0.08),
        bytesWritten: 12000000,
      );

      expect(result.isDone, isTrue);
      expect(result.eyeWidth, isNull);
      expect((result.details! as PanoramaResultDetails).seed, 42);
      expect(const ImmersiveResult.failed(ImmersiveErrorCode.gpuOutOfMemory).details, isNull);
    });

    test('the progress may count the steps of a generation, with the time left', () {
      const progress = ImmersiveProgress(
        ImmersiveStage.generating,
        420,
        step: 12,
        steps: 28,
        remaining: Duration(minutes: 3),
      );

      expect(progress, isNot(const ImmersiveProgress(ImmersiveStage.generating, 420)));
      expect('$progress', contains('12 of 28'));
      expect(const GeneratorProgress(12, 28, secondsPerStep: 11.25).remaining, const Duration(minutes: 3));
      expect(const GeneratorProgress(12, 28).remaining, isNull);
    });
  });

  group('the report of the probe of the graphics cards', () {
    test('goes through its JSON whole, and picks the dedicated card with the most memory', () {
      const report = GpuReport(
        adapters: [
          GpuAdapter(name: 'Iris Xe', kind: GpuKind.integrated, localMemory: 16 << 30),
          GpuAdapter(
            name: 'RTX 4060',
            kind: GpuKind.discrete,
            localMemory: 8 << 30,
            apiVersion: '1.4.312',
            budget: 7 << 30,
            usage: 1 << 30,
          ),
        ],
      );
      final read = GpuReport.fromJson(report.toJson());

      expect(read.adapters.map((adapter) => adapter.name), ['Iris Xe', 'RTX 4060']);
      expect(read.bestDiscrete!.name, 'RTX 4060');
      expect(read.bestDiscrete!.freeMemory, 6 << 30);
      expect(read.bestDiscrete!.vulkanVersion, (1, 4));
      expect(read.adapters.first.freeMemory, 16 << 30);
      expect(read.problem, isNull);
    });

    test('a damaged answer is a failed probe, a damaged adapter is left out', () {
      expect(GpuReport.fromJson('nonsense').problem, GpuProbeProblem.failed);
      expect(
        GpuReport.fromJson({
          'adapters': [
            {'name': 'x'},
            {'name': 'y', 'localMemory': 1, 'type': 'quantum'},
          ],
          'problem': 'noVulkan',
        }).adapters.single.kind,
        GpuKind.other,
      );
      expect(GpuReport.fromJson({'problem': 'noAnswer'}).problem, GpuProbeProblem.noAnswer);
    });

    test('a card of Vulkan tells its place in the loader, its UUID and LUID, its driver and its 16 bit storage', () {
      const report = GpuReport(
        instanceVersion: '1.4.341',
        adapters: [
          GpuAdapter(
            name: 'RTX 4060',
            kind: GpuKind.discrete,
            localMemory: 8 << 30,
            vulkanIndex: 1,
            uuid: '00000000000000000000000000004060',
            luid: '2b68010000000000',
            driverId: 4,
            storage16Bit: true,
          ),
          GpuAdapter(name: 'Old card', kind: GpuKind.discrete, localMemory: 1 << 30, source: 'dxgi'),
        ],
      );
      final read = GpuReport.fromJson(jsonDecode(jsonEncode(report.toJson())));

      expect(read.instanceVersion, '1.4.341');
      final card = read.adapters.first;
      expect(
        (card.vulkanIndex, card.uuid, card.luid, card.driverId, card.storage16Bit),
        (1, '00000000000000000000000000004060', '2b68010000000000', 4, true),
      );
      final old = read.adapters.last;
      expect(
        (old.vulkanIndex, old.uuid, old.luid, old.driverId, old.storage16Bit, old.source),
        (null, null, null, null, null, 'dxgi'),
      );
    });

    test('the answer of the native probe on the laptop of the owner and on ai1 reads whole', () {
      GpuReport fixture(String name) =>
          GpuReport.fromJson(jsonDecode(File('test/fixtures/ai_immersive/$name').readAsStringSync()));
      final laptop = fixture('gpu_probe_rtx4060_laptop.json');
      final ai1 = fixture('gpu_probe_iris_xe_mesa.json');

      expect(laptop.instanceVersion, '1.4.341');
      expect(laptop.adapters.map((adapter) => (adapter.kind, adapter.vulkanIndex)), [
        (GpuKind.integrated, 0),
        (GpuKind.discrete, 1),
        (GpuKind.integrated, 2),
      ]);
      final rtx = laptop.bestDiscrete!;
      expect(rtx.name, 'NVIDIA GeForce RTX 4060 Laptop GPU');
      expect(rtx.localMemory, 7956 << 20);
      expect(rtx.freeMemory, 7537164288);
      expect(rtx.vulkanVersion, (1, 4));
      expect(rtx.driverVersion, '616.56');
      expect(ai1.bestDiscrete, isNull);
      expect(ai1.adapters.map((adapter) => adapter.kind), [GpuKind.integrated, GpuKind.cpu]);
      expect(ai1.adapters.first.driverId, 6);
    });
  });
}
