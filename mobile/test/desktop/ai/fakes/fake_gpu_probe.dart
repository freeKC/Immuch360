// What the probe of the graphics cards tells, without a graphics card: the reports of the cases of the gate
// (design-final 2026-10-27, sections 4.7 and 10.1 point 7), for the tests of the gate, the dialog, the settings and
// the queue (lots C6, U3, C3). Each report also goes through the JSON the native probe writes, so the cases are those
// a real probe can give.

import 'package:immich_mobile/desktop/ai/engine/backends.dart';

const _gib = 1 << 30;
const _mib = 1 << 20;

/// An RTX 4060 Laptop of 8 188 MiB, as on the PC of FreeKC
const rtx4060Laptop = GpuAdapter(
  name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
  kind: GpuKind.discrete,
  localMemory: 8188 * _mib,
  vendorId: 0x10de,
  deviceId: 0x28a0,
  driverVersion: '581.57',
  apiVersion: '1.4.312',
  budget: 7800 * _mib,
  usage: 400 * _mib,
);

/// An Intel Iris Xe that shares the memory of the computer (ai1), through Mesa
const irisXe = GpuAdapter(
  name: 'Intel(R) Iris(R) Xe Graphics (TGL GT2)',
  kind: GpuKind.integrated,
  localMemory: 15 * _gib,
  vendorId: 0x8086,
  deviceId: 0x9a49,
  driverVersion: '25.0.7',
  apiVersion: '1.4.305',
);

/// A dedicated card of 6 GiB, too small for the Q8_0 transformer
const sixGigabyteCard = GpuAdapter(
  name: 'NVIDIA GeForce RTX 3060 Laptop GPU',
  kind: GpuKind.discrete,
  localMemory: 6 * _gib,
  vendorId: 0x10de,
  apiVersion: '1.3.277',
);

/// The cases of the gate, as reports
abstract final class FakeGpuReports {
  static const noVulkan = GpuReport(problem: GpuProbeProblem.noVulkan);
  static const noDevice = GpuReport();
  static const noAnswer = GpuReport(problem: GpuProbeProblem.noAnswer);
  static const mac = GpuReport(problem: GpuProbeProblem.notSupported);
  static const integratedOnly = GpuReport(adapters: [irisXe]);
  static const sixGigabytes = GpuReport(adapters: [sixGigabyteCard]);
  static const rtx4060 = GpuReport(adapters: [rtx4060Laptop]);

  /// A laptop with its integrated graphics and its dedicated card: the dedicated one is used
  static const twoCards = GpuReport(adapters: [irisXe, rtx4060Laptop]);

  /// The RTX 4060 while a game holds most of its memory: 2.1 GB free
  static const rtx4060Busy = GpuReport(
    adapters: [
      GpuAdapter(
        name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
        kind: GpuKind.discrete,
        localMemory: 8188 * _mib,
        budget: 7800 * _mib,
        usage: 5800 * _mib,
        apiVersion: '1.4.312',
      ),
    ],
  );
}

/// A probe that answers [reports] in turn, the last one again after them, and counts its calls
class FakeGpuProbe implements GpuProbe {
  FakeGpuProbe(List<GpuReport> reports) : _reports = List.of(reports);

  FakeGpuProbe.of(GpuReport report) : this([report]);

  final List<GpuReport> _reports;
  int calls = 0;

  /// The reports go through the JSON of the native probe, as a real answer would
  @override
  Future<GpuReport> probe() async {
    final report = _reports.length > 1 ? _reports.removeAt(0) : _reports.single;
    calls++;
    return GpuReport.fromJson(report.toJson());
  }
}
