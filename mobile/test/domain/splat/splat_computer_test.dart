import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_computer.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The gaussians a computer shows (lot SVC, 3 November 2026), held to what was measured on a laptop with 16 GB, an RTX
/// 4060 Laptop of 8 GB and an Intel UHD (test/fixtures/splat_viewer/computer_measures.json): the memory the page and the
/// card took, the scenes each chip drew whole, and the gate that follows.
void main() {
  final measures =
      jsonDecode(File('test/fixtures/splat_viewer/computer_measures.json').readAsStringSync()) as Map<String, Object?>;
  final cases = (measures['cases']! as List).cast<Map<String, Object?>>();
  final physical = measures['physicalMemory']! as int;
  final rtxMemory = ((measures['cards']! as List).first as Map)['memory']! as int;
  const mb = 1024 * 1024;

  final rtx = SplatComputer(
    gpu: SplatGpu(SplatGpuKind.dedicated, name: 'NVIDIA GeForce RTX 4060 Laptop GPU', memory: rtxMemory),
    physicalMemory: physical,
  );
  final intel = SplatComputer(
    gpu: const SplatGpu(SplatGpuKind.integrated, name: 'Intel(R) UHD Graphics'),
    physicalMemory: physical,
  );

  SplatHead headOf(Map<String, Object?> kase) => SplatHead(
    format: '${kase['file']}'.endsWith('.ply') ? SplatFormat.ply : SplatFormat.spz,
    formatVersion: '${kase['file']}'.endsWith('.ply') ? 1 : 2,
    gaussians: kase['gaussians']! as int,
    shDegree: 3,
  );

  SplatGateVerdict gate(
    Map<String, Object?> kase,
    SplatComputer computer, {
    SplatFrameAnswer? answer,
    SplatHead? head,
    int? fileBytes,
  }) => splatViewerGateOf(
    probe: head ?? headOf(kase),
    name: '${kase['file']}',
    fileBytes: fileBytes ?? kase['fileBytes']! as int,
    largeSplats: false,
    device: SplatDeviceClass.computer,
    computer: computer,
    answer: answer,
  );

  Map<String, Object?> measured(String gpu, int gaussians, {String page = 'app'}) =>
      cases.firstWhere((kase) => kase['gpu'] == gpu && kase['gaussians'] == gaussians && kase['page'] == page);

  test('the fixture holds the measures of both chips, 637,401 to 8 million gaussians', () {
    expect(cases.where((kase) => kase['gpu'] == 'rtx' && kase['page'] == 'app').map((kase) => kase['gaussians']), [
      637401,
      1000000,
      2000000,
      3000000,
      4000000,
      6000000,
      8000000,
    ]);
    expect(cases.where((kase) => kase['gpu'] == 'intel' && kase['page'] == 'app').length, 5);
    for (final kase in cases) {
      final renderer = '${kase['renderer']}';
      expect(renderer, contains(kase['gpu'] == 'rtx' ? 'RTX 4060' : 'Intel(R) UHD'), reason: 'the chip proven');
    }
  });

  test('the memory counted covers every measure: the page, and the card of the RTX', () {
    for (final kase in cases) {
      final gaussians = kase['gaussians']! as int;
      final fileBytes = kase['fileBytes']! as int;
      final page = kase['pageMB']! as int;
      expect(
        splatPageBytes(gaussians, fileBytes: fileBytes),
        greaterThanOrEqualTo(page * mb),
        reason: '${kase['gpu']} ${kase['page']} ${kase['file']}: $page MB measured',
      );
      if (kase['gpu'] == 'rtx') {
        expect(
          splatCardBytes(gaussians),
          greaterThanOrEqualTo((kase['cardMB']! as int) * mb),
          reason: '${kase['file']}: ${kase['cardMB']} MB of the card measured',
        );
      }
    }
  });

  test('the measured laptop shows every scene it drew whole, 8 million included, within a third of its memory', () {
    final most = splatComputerMostGaussians(rtx, fileBytesPerGaussian: 21);
    expect(most, greaterThanOrEqualTo(8000000));
    expect(most, lessThan(16000000), reason: 'a third of 16 GB: the RTX drew 8 million with 3.07 GB');
    expect(splatComputerMostGaussians(rtx, fileBytesPerGaussian: 236), greaterThan(4000000), reason: 'PLY');
    // Half of the card's 8 GB would hold more: the computer's memory is what limits this laptop
    final cardOnly = splatComputerMostGaussians(SplatComputer(gpu: rtx.gpu));
    expect(cardOnly, greaterThan(20000000));
    expect(cardOnly, lessThan(splatEngineMostGaussians));
    expect(splatComputerMostGaussians(const SplatComputer()), splatEngineMostGaussians);
  });

  test('on the RTX every measured scene opens whole, with no reduction', () {
    for (final kase in cases.where((kase) => kase['gpu'] == 'rtx')) {
      final verdict = gate(kase, rtx);
      expect(verdict.isOpen, isTrue, reason: '${kase['file']}');
      expect(verdict.request!.maxGaussians, kase['gaussians'], reason: '${kase['file']} whole');
    }
  });

  test('on the Intel the cap of 1,000,000 stays, reduced up to 4 million, refused beyond as before', () {
    // Under the cap the request carries the cap, as before: shown whole
    for (final gaussians in [637401, 1000000]) {
      final request = gate(measured('intel', gaussians), intel).request!;
      expect(request.maxGaussians, splatComputerGaussians);
      expect(request.gaussians, lessThanOrEqualTo(request.maxGaussians));
    }
    for (final gaussians in [2000000, 3000000, 4000000]) {
      expect(gate(measured('intel', gaussians), intel).request!.maxGaussians, splatComputerGaussians);
    }
    final six = measured('rtx', 6000000);
    expect(gate(six, intel), const SplatGateVerdict.refused(SplatRefusal.tooLarge, gaussians: 6000000));
  });

  test('Keep every gaussian shows them whole on the Intel too, up to the memory', () {
    final keep = intel.copyWith(keepEveryGaussian: true);
    for (final gaussians in [2000000, 3000000, 4000000]) {
      expect(gate(measured('intel', gaussians), keep).request!.maxGaussians, gaussians);
    }
    expect(gate(measured('rtx', 8000000), keep).request!.maxGaussians, 8000000);
  });

  test('beyond the memory: refused with the count and what this computer holds', () {
    final eight = measured('rtx', 8000000);
    final small = SplatComputer(gpu: rtx.gpu, physicalMemory: 8 * 1024 * mb);
    final most = splatComputerMostGaussians(small, fileBytesPerGaussian: (eight['fileBytes']! as int) / 8000000);
    expect(most, inInclusiveRange(4000000, 5000000), reason: 'a computer of 8 GB');
    expect(gate(eight, small), SplatGateVerdict.refused(SplatRefusal.beyondMemory, gaussians: 8000000, most: most));
    // A card of 2 GB holds less than its computer
    final card2 = SplatComputer(
      gpu: const SplatGpu(SplatGpuKind.dedicated, memory: 2048 * mb),
      physicalMemory: physical,
    );
    expect(gate(measured('rtx', 6000000), card2).refusal, SplatRefusal.beyondMemory);
    expect(gate(measured('rtx', 4000000), card2).isOpen, isTrue);
  });

  test('the answer kept for a file comes first: its reduced copy, or every gaussian', () {
    final four = measured('intel', 4000000);
    final keepIntel = intel.copyWith(keepEveryGaussian: true);
    expect(gate(four, keepIntel, answer: const SplatFrameAnswer.reduce(1710000)).request!.maxGaussians, 1710000);
    // Kept them all: whole on that file even where the cap would apply
    expect(gate(four, intel, answer: const SplatFrameAnswer.whole()).request!.maxGaussians, 4000000);
    // A reduced copy above 4 million on a dedicated card: the reduction reads the file from the disk
    final eight = measured('rtx', 8000000);
    expect(gate(eight, rtx, answer: const SplatFrameAnswer.reduce(5000000)).request!.maxGaussians, 5000000);
    // An SPZ of version 4 is never reduced here: whole when it fits
    const v4 = SplatHead(format: SplatFormat.spz, formatVersion: 4, gaussians: 2000000, shDegree: 0);
    expect(gate(four, rtx, head: v4, answer: const SplatFrameAnswer.reduce(1000000)).request!.maxGaussians, 2000000);
  });

  test('the first frames are watched on a computer only, for a splat shown whole above the phones cap', () {
    final head = headOf(measured('rtx', 4000000));
    expect(splatWatchesFrames(device: SplatDeviceClass.computer, head: head, cap: 4000000), isTrue);
    expect(splatWatchesFrames(device: SplatDeviceClass.computer, head: head, cap: 1000000), isFalse);
    expect(splatWatchesFrames(device: SplatDeviceClass.phone, head: head, cap: 4000000), isFalse);
    expect(
      splatWatchesFrames(
        device: SplatDeviceClass.computer,
        head: head,
        cap: 4000000,
        answer: const SplatFrameAnswer.whole(),
      ),
      isFalse,
    );
    const small = SplatHead(format: SplatFormat.spz, formatVersion: 2, gaussians: 150000, shDegree: 0);
    expect(splatWatchesFrames(device: SplatDeviceClass.computer, head: small, cap: 150000), isFalse);
    const v4 = SplatHead(format: SplatFormat.spz, formatVersion: 4, gaussians: 2000000, shDegree: 0);
    expect(splatWatchesFrames(device: SplatDeviceClass.computer, head: v4, cap: 2000000), isFalse);
  });

  test('the answers as they are kept', () {
    expect(
      SplatFrameAnswer.fromJson(const SplatFrameAnswer.reduce(1330000).toJson()),
      const SplatFrameAnswer.reduce(1330000),
    );
    expect(SplatFrameAnswer.fromJson(const SplatFrameAnswer.whole().toJson()), const SplatFrameAnswer.whole());
    expect(SplatFrameAnswer.fromJson({'keep': 0}), isNull);
    expect(SplatFrameAnswer.fromJson('whole'), isNull);
  });

  test('the chip a WebGL renderer names', () {
    for (final kase in cases) {
      expect(
        splatGpuKindOfRenderer('${kase['renderer']}'),
        kase['gpu'] == 'rtx' ? SplatGpuKind.dedicated : SplatGpuKind.integrated,
      );
    }
    const dedicated = [
      'ANGLE (AMD, AMD Radeon RX 7600 (0x00007480) Direct3D11 vs_5_0 ps_5_0, D3D11)',
      'ANGLE (Intel, Intel(R) Arc(TM) A770 Graphics (0x000056A0) Direct3D11 vs_5_0 ps_5_0, D3D11)',
      'ANGLE (NVIDIA, NVIDIA GeForce GTX 1650 (0x00001F91) Direct3D11 vs_5_0 ps_5_0, D3D11)',
      'NVIDIA GeForce RTX 3060/PCIe/SSE2',
      'AMD Radeon Pro 5500M OpenGL Engine',
    ];
    const integrated = [
      'ANGLE (AMD, AMD Radeon(TM) Graphics (0x00001638) Direct3D11 vs_5_0 ps_5_0, D3D11)',
      'ANGLE (Intel, Intel(R) Arc(TM) Graphics (0x00007D55) Direct3D11 vs_5_0 ps_5_0, D3D11)',
      'ANGLE (Intel, Intel(R) Iris(R) Xe Graphics (0x00009A49) Direct3D11 vs_5_0 ps_5_0, D3D11)',
      'AMD Radeon 780M Graphics',
      'Mesa Intel(R) UHD Graphics 620 (KBL GT2)',
      'llvmpipe (LLVM 15.0.7, 256 bits)',
      'ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)), SwiftShader driver)',
      'Apple M2',
      'Adreno (TM) 740',
    ];
    for (final name in dedicated) {
      expect(splatGpuKindOfRenderer(name), SplatGpuKind.dedicated, reason: name);
    }
    for (final name in integrated) {
      expect(splatGpuKindOfRenderer(name), SplatGpuKind.integrated, reason: name);
    }
    // WebKitGTK and WKWebView hide it
    expect(splatGpuKindOfRenderer('Apple GPU'), SplatGpuKind.unknown);
    expect(splatGpuKindOfRenderer(null), SplatGpuKind.unknown);
    expect(splatGpuKindOfRenderer(''), SplatGpuKind.unknown);
  });
}
