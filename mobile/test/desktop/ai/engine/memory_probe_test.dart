import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

void main() {
  group('/proc/meminfo', () {
    test('MemTotal and MemAvailable, from kB to bytes', () {
      const text =
          'MemTotal:       32689148 kB\n'
          'MemFree:         1234560 kB\n'
          'MemAvailable:   20971520 kB\n'
          'Buffers:          102400 kB\n';
      final facts = parseProcMeminfo(text);
      expect(facts.physical, 32689148 * 1024);
      expect(facts.available, 20971520 * 1024);
    });

    test('a kernel without MemAvailable gives no available memory, never a guess', () {
      final facts = parseProcMeminfo('MemTotal:        4045860 kB\nMemFree:          812000 kB\nCached: 900000 kB\n');
      expect(facts.physical, 4045860 * 1024);
      expect(facts.available, isNull);
    });

    test('nothing readable, nothing known', () {
      final facts = parseProcMeminfo('');
      expect((facts.physical, facts.available), (null, null));
    });
  });

  test('this computer, read from its system', () {
    final facts = const SystemMemoryProbe().read();
    expect(facts.physical, isNotNull);
    expect(facts.physical, greaterThan(1024 * 1024 * 1024));
    if (Platform.isMacOS) {
      expect(facts.available, isNull, reason: 'macOS gives no simple available figure');
    } else {
      expect(facts.available, isNotNull);
      expect(facts.available, inInclusiveRange(1, facts.physical!));
    }
  });

  group('what a job needs', () {
    test('a 12 Mpx photo of a phone, its session open: some 380 MiB', () {
      final need = jobMemoryNeed(sourceWidth: 4000, sourceHeight: 3000, eyeWidth: 4000, eyeHeight: 3000);
      const mib = 1024 * 1024;
      expect(need ~/ mib, inInclusiveRange(370, 390));
      final opening = jobMemoryNeed(
        sourceWidth: 4000,
        sourceHeight: 3000,
        eyeWidth: 4000,
        eyeHeight: 3000,
        sessionOpen: false,
      );
      expect(opening - need, depthSessionMemory);
    });

    test('grows with the photo, and with its eye', () {
      final small = jobMemoryNeed(sourceWidth: 100, sourceHeight: 100, eyeWidth: 100, eyeHeight: 100);
      final source = jobMemoryNeed(sourceWidth: 12000, sourceHeight: 8000, eyeWidth: 100, eyeHeight: 100);
      final eye = jobMemoryNeed(sourceWidth: 100, sourceHeight: 100, eyeWidth: 8192, eyeHeight: 5461);
      expect(source, greaterThan(small));
      expect(eye, greaterThan(small));
    });

    test('a computer sold with 4 GB is enough, one with 3 GB is not', () {
      // 4 GB machines report 3.6 to 3.9 GiB
      expect((3.6 * 1024 * 1024 * 1024).round(), greaterThanOrEqualTo(aiMinimumPhysicalMemory));
      expect(3 * 1024 * 1024 * 1024, lessThan(aiMinimumPhysicalMemory));
    });
  });

  group('a job beside one of the other lane', () {
    const gib = 1024 * 1024 * 1024;

    test('each kind needs its own memory: the panorama most, the scene 2 GiB (M2), then the 3D photo', () {
      expect(jobMemoryNeedOf(ImmersiveKind.volumetricScene), 2 * gib);
      expect(jobMemoryNeedOf(ImmersiveKind.panorama360), greaterThanOrEqualTo(6 * gib));
      expect(jobMemoryNeedOf(ImmersiveKind.stereoPanorama360), inInclusiveRange(gib ~/ 2, gib));
      expect(
        jobMemoryNeedOf(ImmersiveKind.stereoPhoto),
        jobMemoryNeed(sourceWidth: 6000, sourceHeight: 4000, eyeWidth: 6000, eyeHeight: 4000, sessionOpen: false),
      );
      for (final kind in ImmersiveKind.values) {
        expect(jobMemoryNeedOf(kind), lessThanOrEqualTo(jobMemoryNeedOf(ImmersiveKind.panorama360)), reason: '$kind');
      }
    });

    test('a scene starts during a generation from 3 GiB free (M3), not under', () {
      final scene = jobMemoryNeedOf(ImmersiveKind.volumetricScene);

      expect(fitsBeside(scene, const MemoryFacts(physical: 16 * gib, available: 3 * gib)), isTrue);
      expect(fitsBeside(scene, const MemoryFacts(physical: 16 * gib, available: 3 * gib - 1)), isFalse);
      // A panorama beside a scene asks for its 6 GiB and more
      expect(
        fitsBeside(
          jobMemoryNeedOf(ImmersiveKind.panorama360),
          const MemoryFacts(physical: 16 * gib, available: 6 * gib),
        ),
        isFalse,
      );
    });

    test('a job under way counts its whole need until its models run, nothing once they do', () {
      const panorama = ImmersiveKind.panorama360;
      final need = jobMemoryNeedOf(panorama);

      for (final stage in [null, ImmersiveStage.reading, ImmersiveStage.fieldOfView, ImmersiveStage.loadingModels]) {
        expect(jobMemoryStillNeeded(panorama, stage), need, reason: '$stage');
      }
      for (final stage in [ImmersiveStage.generating, ImmersiveStage.upscale, ImmersiveStage.writing]) {
        expect(jobMemoryStillNeeded(panorama, stage), 0, reason: '$stage');
      }
      // The step of the models of each kind is one of its own steps
      for (final kind in ImmersiveKind.values) {
        expect(ImmersiveStage.of(kind), contains(memoryPeakOf(kind)), reason: '$kind');
        expect(jobMemoryStillNeeded(kind, ImmersiveStage.of(kind).first), jobMemoryNeedOf(kind), reason: '$kind');
        expect(jobMemoryStillNeeded(kind, memoryPeakOf(kind)), 0, reason: '$kind');
      }
      expect(jobMemoryStillNeeded(ImmersiveKind.volumetricScene, ImmersiveStage.decoding), 2 * gib);
      expect(jobMemoryStillNeeded(ImmersiveKind.volumetricScene, ImmersiveStage.inpaint), 0);
    });

    test('a scene waits beside a panorama that has not loaded its models yet, not beside its generation', () {
      final scene = jobMemoryNeedOf(ImmersiveKind.volumetricScene);
      const fourFree = MemoryFacts(physical: 16 * gib, available: 4 * gib);
      final loading = jobMemoryStillNeeded(ImmersiveKind.panorama360, ImmersiveStage.fieldOfView);
      final generating = jobMemoryStillNeeded(ImmersiveKind.panorama360, ImmersiveStage.generating);

      expect(fitsBeside(scene, fourFree, besideNeeds: loading), isFalse);
      expect(fitsBeside(scene, fourFree, besideNeeds: generating), isTrue);
      // A computer with memory for both
      expect(
        fitsBeside(
          scene,
          const MemoryFacts(physical: 32 * gib, available: 12 * gib),
          besideNeeds: loading,
        ),
        isTrue,
      );
      // A panorama beside a scene still reading its photo
      final panorama = jobMemoryNeedOf(ImmersiveKind.panorama360);
      const eightFree = MemoryFacts(physical: 16 * gib, available: 8 * gib);
      expect(
        fitsBeside(
          panorama,
          eightFree,
          besideNeeds: jobMemoryStillNeeded(ImmersiveKind.volumetricScene, ImmersiveStage.reading),
        ),
        isFalse,
      );
      expect(
        fitsBeside(
          panorama,
          eightFree,
          besideNeeds: jobMemoryStillNeeded(ImmersiveKind.volumetricScene, ImmersiveStage.geometry),
        ),
        isTrue,
      );
      expect(fitsBeside(scene, const MemoryFacts(physical: 16 * gib), besideNeeds: loading), isTrue);
    });

    test('a system that does not say what is free never makes a job wait', () {
      expect(fitsBeside(jobMemoryNeedOf(ImmersiveKind.panorama360), const MemoryFacts(physical: 16 * gib)), isTrue);
      expect(fitsBeside(jobMemoryNeedOf(ImmersiveKind.panorama360), const MemoryFacts()), isTrue);
    });
  });
}
