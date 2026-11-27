// The probe of Metal (release 53): on the macOS runner of the CI the real probe of the app's process reads the GPU of
// the virtual Mac ("Apple Paravirtual device") and prints what Metal says of it; elsewhere it gives nothing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/gpu/metal_probe.dart';

void main() {
  test('nothing on another system than macOS', () {
    if (!Platform.isMacOS) {
      expect(const SystemMetalProbe().read(), isNull);
    }
  });

  test('on macOS: the GPU Metal gives, its working set, unified memory, the Apple family 7', () {
    final facts = const SystemMetalProbe().read();
    // ignore: avoid_print
    print('Metal on this Mac: ${jsonEncode(facts?.toJson())}');
    expect(facts, isNotNull);
    expect(facts!.name, isNotEmpty);
    expect(facts.workingSet, greaterThan(0));
  }, skip: Platform.isMacOS ? null : 'macOS only');

  test('the facts as JSON', () {
    const facts = MetalFacts(name: 'Apple M1', workingSet: 11453251584, unifiedMemory: true, apple7: true);
    expect(facts.toJson(), {
      'name': 'Apple M1',
      'recommendedMaxWorkingSetSize': 11453251584,
      'hasUnifiedMemory': true,
      'apple7': true,
    });
    expect(metalGpuFamilyApple7, 1007);
  });
}
