import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

    test('a system that does not say what is free never makes a job wait', () {
      expect(fitsBeside(jobMemoryNeedOf(ImmersiveKind.panorama360), const MemoryFacts(physical: 16 * gib)), isTrue);
      expect(fitsBeside(jobMemoryNeedOf(ImmersiveKind.panorama360), const MemoryFacts()), isTrue);
    });
  });
}
