import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The gate of "Explore the splat scene" (lot S5): the flavour, the headset, the file and the count, in the order of
/// SplatGate.kt
void main() {
  const spz = SplatHead(format: SplatFormat.spz, formatVersion: 3, gaussians: 452451, shDegree: 0);

  SplatGateVerdict gate({
    SplatProbe probe = spz,
    String? flavor = 'quest',
    String? device = 'eureka',
    bool large = false,
    int fileBytes = 6824362,
  }) => splatGateOf(
    probe: probe,
    name: 'gsplat-cactus.spz',
    fileBytes: fileBytes,
    largeSplats: large,
    flavor: flavor,
    device: device,
  );

  test('a Quest 3, a 3S and an unknown headset open a splat with the count of the setting', () {
    for (final device in ['eureka', 'panther', null]) {
      expect(
        gate(device: device),
        const SplatGateVerdict.open(
          GaussianSplatRequest(
            format: 'spz',
            formatVersion: 3,
            gaussians: 452451,
            shDegree: 0,
            fileBytes: 6824362,
            maxGaussians: 50000,
            name: 'gsplat-cactus.spz',
          ),
        ),
      );
    }
    expect(gate(large: true).request!.maxGaussians, 150000);
  });

  test('the phone flavour first, then the Quest 2 and Pro', () {
    expect(gate(flavor: null, device: 'hollywood'), const SplatGateVerdict.refused(SplatRefusal.notInThisVersion));
    expect(gate(flavor: 'phone'), const SplatGateVerdict.refused(SplatRefusal.notInThisVersion));
    expect(gate(device: 'hollywood'), const SplatGateVerdict.refused(SplatRefusal.olderHeadset));
    expect(gate(device: 'seacliff'), const SplatGateVerdict.refused(SplatRefusal.olderHeadset));
  });

  test('a file the probe refused keeps its reason', () {
    for (final problem in SplatFileProblem.values) {
      expect(gate(probe: SplatRefused(problem, '')).refusal, splatRefusalOf(problem));
    }
    expect(splatRefusalOf(SplatFileProblem.compressedPly), SplatRefusal.compressedPly);
  });

  test('beyond what the headset reduces it is too large, with its count', () {
    const huge = SplatHead(format: SplatFormat.ply, formatVersion: 1, gaussians: 4000001, shDegree: 0);
    expect(gate(probe: huge), const SplatGateVerdict.refused(SplatRefusal.tooLarge, gaussians: 4000001));
    expect(gate(fileBytes: (1 << 30) + 1), const SplatGateVerdict.refused(SplatRefusal.tooLarge, gaussians: 452451));
    // A version 4 SPZ is not reduced: whole within the count, too large beyond
    const v4 = SplatHead(format: SplatFormat.spz, formatVersion: 4, gaussians: 60000, shDegree: 0);
    expect(gate(probe: v4).refusal, SplatRefusal.tooLarge);
    expect(gate(probe: v4, large: true).isOpen, isTrue);
  });
}
