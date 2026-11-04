import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The gate of the splat viewer of the computers, phones and tablets (lot SV4): the device class, its cap, the
/// reduction above it, and what is refused (plan section 6). The Quest keeps splatGateOf (splat_gate_test.dart).
void main() {
  const cactus = SplatHead(format: SplatFormat.spz, formatVersion: 3, gaussians: 452451, shDegree: 0);

  SplatGateVerdict gate({
    SplatProbe probe = cactus,
    SplatDeviceClass device = SplatDeviceClass.phone,
    bool large = false,
    int fileBytes = 6824362,
  }) => splatViewerGateOf(
    probe: probe,
    name: 'gsplat-cactus.spz',
    fileBytes: fileBytes,
    largeSplats: large,
    device: device,
  );

  test('the caps: phones 150,000 or 500,000 with Large splats, computers 1,000,000 whatever the setting', () {
    expect(splatViewerCapOf(SplatDeviceClass.phone, largeSplats: false), 150000);
    expect(splatViewerCapOf(SplatDeviceClass.phone, largeSplats: true), 500000);
    expect(splatViewerCapOf(SplatDeviceClass.computer, largeSplats: false), 1000000);
    expect(splatViewerCapOf(SplatDeviceClass.computer, largeSplats: true), 1000000);
    // The headset's numbers do not move
    expect(splatViewerCapOf(SplatDeviceClass.quest, largeSplats: false), splatSafeGaussians);
    expect(splatViewerCapOf(SplatDeviceClass.quest, largeSplats: true), splatLargeGaussians);
  });

  test('a splat above the cap opens with the cap as its count, the reduction keeping its strongest', () {
    final phone = gate();
    expect(phone.isOpen, isTrue);
    expect(phone.request!.maxGaussians, 150000);
    expect(phone.request!.gaussians, 452451);
    expect(gate(large: true).request!.maxGaussians, 500000);
    final computer = gate(device: SplatDeviceClass.computer);
    expect(computer.request!.maxGaussians, 1000000);
  });

  test('every SPZ version and PLY opens under the cap, version 4 included', () {
    for (final version in [1, 2, 3, 4]) {
      final head = SplatHead(format: SplatFormat.spz, formatVersion: version, gaussians: 20000, shDegree: 1);
      expect(gate(probe: head).isOpen, isTrue, reason: 'version $version');
    }
    const ply = SplatHead(format: SplatFormat.ply, formatVersion: 1, gaussians: 20000, shDegree: 3);
    expect(gate(probe: ply).isOpen, isTrue);
  });

  test('version 4 above the cap is refused with its own reason, which the headset does not have', () {
    const v4 = SplatHead(format: SplatFormat.spz, formatVersion: 4, gaussians: 400000, shDegree: 0);
    expect(gate(probe: v4), const SplatGateVerdict.refused(SplatRefusal.v4AboveCap, gaussians: 400000));
    expect(gate(probe: v4, device: SplatDeviceClass.computer).isOpen, isTrue);
  });

  test('degree 4 harmonics are refused here, Spark draws degrees 0 to 3', () {
    const sh4 = SplatHead(format: SplatFormat.spz, formatVersion: 4, gaussians: 8, shDegree: 4);
    expect(gate(probe: sh4).refusal, SplatRefusal.degree4);
    expect(gate(probe: sh4, device: SplatDeviceClass.computer).refusal, SplatRefusal.degree4);
  });

  test('beyond 4 million gaussians or 1 GiB it is too large, with its count', () {
    const huge = SplatHead(format: SplatFormat.ply, formatVersion: 1, gaussians: 4000001, shDegree: 0);
    expect(gate(probe: huge), const SplatGateVerdict.refused(SplatRefusal.tooLarge, gaussians: 4000001));
    expect(gate(probe: huge, device: SplatDeviceClass.computer).refusal, SplatRefusal.tooLarge);
    expect(gate(fileBytes: (1 << 30) + 1).refusal, SplatRefusal.tooLarge);
    // Under the cap, a file of more than 1 GiB opens: nothing is reduced
    const big = SplatHead(format: SplatFormat.ply, formatVersion: 1, gaussians: 900000, shDegree: 3);
    expect(gate(probe: big, device: SplatDeviceClass.computer, fileBytes: (1 << 30) + 1).isOpen, isTrue);
  });

  test('a file the probe refused keeps its reason', () {
    for (final problem in SplatFileProblem.values) {
      expect(gate(probe: SplatRefused(problem, '')).refusal, splatRefusalOf(problem));
    }
  });

  test('the headset is never asked here: the Quest keeps its own gate', () {
    expect(gate(device: SplatDeviceClass.quest).refusal, SplatRefusal.notInThisVersion);
  });
}
