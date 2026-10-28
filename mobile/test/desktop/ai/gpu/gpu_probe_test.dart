// The probe of the graphics cards in its child process (lot C6; design-final 2026-10-27, section 4.7, point 1), with
// fake processes: the flag and the file it names, the answer read then deleted, a probe that hangs stopped at 10 s, one
// that ends without its answer, one that does not start, the Mac where nothing starts; and the index ggml gives each
// card, after ggml_vk_instance_init of the ggml the pinned stable-diffusion.cpp builds.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_probe.dart';

import '../fakes/fake_gpu_probe.dart';
import '../fakes/fake_process_runner.dart';

const _gib = 1024 * 1024 * 1024;

/// Fake processes, each writing [answer] (when given) into the file its flag names before it plays its script
class _ProbeRunner extends FakeProcessRunner {
  _ProbeRunner(super.scripts, {this.answer});

  final String? answer;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    final flag = launch.arguments.single;
    if (answer != null && flag.startsWith(gpuProbeFlag)) {
      File(flag.substring(gpuProbeFlag.length)).writeAsStringSync(answer!);
    }
    return super.start(launch);
  }
}

class _NoStart implements ProcessRunner {
  @override
  Future<RunningProcess> start(ProcessLaunch launch) async => throw const ProcessException('immuch360', [], 'gone');
}

GpuReport _fixture(String name) =>
    GpuReport.fromJson(jsonDecode(File('test/fixtures/ai_immersive/$name').readAsStringSync()));

void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('gpu_probe_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  ProcessGpuProbe probeWith(ProcessRunner runner, {bool isMacOS = false}) =>
      ProcessGpuProbe(executable: '/opt/immuch360/immuch360', runner: runner, folder: () => folder, isMacOS: isMacOS);

  group('the child process', () {
    test(
      'the executable of the app with the flag and a file of its own; the answer read, then the file deleted',
      () async {
        final answer = File('test/fixtures/ai_immersive/gpu_probe_rtx4060_laptop.json').readAsStringSync();
        final runner = _ProbeRunner([const FakeProcessScript()], answer: answer);

        final report = await probeWith(runner).probe();

        final launch = runner.launches.single;
        expect(launch.executable, '/opt/immuch360/immuch360');
        expect(launch.arguments.single, startsWith('$gpuProbeFlag${folder.path}${Platform.pathSeparator}gpu-probe-'));
        expect(launch.arguments.single, endsWith('.json'));
        expect(launch.lowPriority, isFalse);
        expect(report.problem, isNull);
        expect(report.bestDiscrete!.name, 'NVIDIA GeForce RTX 4060 Laptop GPU');
        expect(folder.listSync(), isEmpty);
      },
    );

    test('two probes at once write two files', () async {
      final runner = _ProbeRunner([const FakeProcessScript()], answer: '{"adapters":[],"problem":null}');
      final probe = probeWith(runner);

      await Future.wait([probe.probe(), probe.probe()]);

      expect(runner.launches.map((launch) => launch.arguments.single).toSet(), hasLength(2));
    });

    test('a probe that hangs is stopped at its time, 10 s: the graphics card did not answer', () async {
      final runner = _ProbeRunner([const FakeProcessScript(hangs: true)]);
      final probe = ProcessGpuProbe(
        executable: 'immuch360',
        runner: runner,
        folder: () => folder,
        isMacOS: false,
        timeout: const Duration(milliseconds: 300),
      );
      final watch = Stopwatch()..start();

      final report = await probe.probe();

      expect(report.problem, GpuProbeProblem.noAnswer);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(300));
      expect(runner.processes.single.killed, isTrue);
      expect(ProcessGpuProbe.ofThisApp().timeout, const Duration(seconds: 10));
    });

    test('a probe that ends without its answer, or with a damaged one, failed', () async {
      final crashed = await probeWith(_ProbeRunner([const FakeProcessScript(exitCode: -1073741819)])).probe();
      final damaged = await probeWith(_ProbeRunner([const FakeProcessScript()], answer: '{"adapters": [')).probe();

      expect(crashed.problem, GpuProbeProblem.failed);
      expect(damaged.problem, GpuProbeProblem.failed);
      expect(folder.listSync(), isEmpty);
    });

    test('a probe that does not start failed, and says it', () async {
      expect((await probeWith(_NoStart()).probe()).problem, GpuProbeProblem.failed);
    });

    test('a Mac starts nothing: no Vulkan there', () async {
      final runner = _ProbeRunner([const FakeProcessScript()]);
      expect((await probeWith(runner, isMacOS: true).probe()).problem, GpuProbeProblem.notSupported);
      expect(runner.launches, isEmpty);
    });

    test('the probe of the app is its own executable', () {
      expect(ProcessGpuProbe.ofThisApp().executable, Platform.resolvedExecutable);
    });
  });

  group('the cards as ggml numbers them', () {
    GpuAdapter card(
      String name,
      int place, {
      GpuKind kind = GpuKind.discrete,
      String? uuid,
      String? luid,
      int vendor = 0x10de,
      int? driver,
      bool? storage16Bit = true,
    }) => GpuAdapter(
      name: name,
      kind: kind,
      localMemory: 8 * _gib,
      vendorId: vendor,
      vulkanIndex: place,
      uuid: uuid ?? 'uuid-$name',
      luid: luid,
      driverId: driver,
      storage16Bit: storage16Bit,
    );

    List<String> names(GpuReport report) => [for (final device in ggmlVulkanDevices(report)) device.name];

    test('the laptop of the owner: the Intel seen twice kept once, the RTX 4060 Vulkan1 (M3)', () {
      final laptop = _fixture('gpu_probe_rtx4060_laptop.json');

      expect(names(laptop), ['Intel(R) RaptorLake-S Mobile Graphics Controller', 'NVIDIA GeForce RTX 4060 Laptop GPU']);
      expect(ggmlVulkanIndexOf(laptop, laptop.bestDiscrete!), 1);
    });

    test('ai1: the Iris Xe Vulkan0, llvmpipe left out', () {
      final ai1 = _fixture('gpu_probe_iris_xe_mesa.json');
      expect(names(ai1), ['Intel(R) Iris(R) Xe Graphics (TGL GT2)']);
      expect(ggmlVulkanIndexOf(ai1, ai1.adapters.last), isNull);
    });

    test('in the order of the loader, whatever the order of the answer', () {
      final report = GpuReport(
        adapters: [
          card('second', 1),
          card('first', 0, kind: GpuKind.integrated),
        ],
      );
      expect(names(report), ['first', 'second']);
    });

    test('a card without 16 bit storage buffers, a virtual one or an adapter of DXGI is left out', () {
      final report = GpuReport(
        adapters: [
          card('old', 0, storage16Bit: false),
          card('virtual', 1, kind: GpuKind.virtual),
          const GpuAdapter(name: 'dxgi', kind: GpuKind.discrete, localMemory: 1, source: 'dxgi'),
          card('kept', 2),
        ],
      );
      expect(names(report), ['kept']);
    });

    test('one card under two drivers is kept once, by the driver ggml prefers', () {
      // RADV before the proprietary driver of AMD, the second one listed taking the place of the first at the end
      final amd = GpuReport(
        adapters: [
          card('amdvlk', 0, uuid: 'same', vendor: 0x1002, driver: 1),
          card('other', 1),
          card('radv', 2, uuid: 'same', vendor: 0x1002, driver: 3),
        ],
      );
      expect(names(amd), ['other', 'radv']);
      // The driver of NVIDIA before NVK; neither preferred: the first kept
      final nvidia = GpuReport(
        adapters: [
          card('nvidia', 0, uuid: 'same', driver: 4),
          card('nvk', 1, uuid: 'same', driver: 24),
        ],
      );
      expect(names(nvidia), ['nvidia']);
      final unknown = GpuReport(
        adapters: [
          card('a', 0, uuid: 'same', vendor: 0x1234, driver: 99),
          card('b', 1, uuid: 'same', vendor: 0x1234, driver: 98),
        ],
      );
      expect(names(unknown), ['a']);
      // Dozen, the Vulkan of Direct3D 12, after any driver of the card
      final dozen = GpuReport(
        adapters: [
          card('dozen', 0, luid: 'luid', driver: 23),
          card('native', 1, luid: 'luid', vendor: 0x1234, driver: 99),
        ],
      );
      expect(names(dozen), ['dozen'], reason: 'ggml reads the priority of the vendor of the card kept: Dozen is 100');
    });

    test('two cards of MoltenVK with the same UUID stay two', () {
      final report = GpuReport(
        adapters: [
          card('left', 0, uuid: 'same', driver: 14),
          card('right', 1, uuid: 'same', driver: 14),
        ],
      );
      expect(names(report), ['left', 'right']);
    });

    test('no dedicated nor integrated card: the first that is not a processor', () {
      final report = GpuReport(
        adapters: [
          card('llvmpipe', 0, kind: GpuKind.cpu),
          card('virgl', 1, kind: GpuKind.virtual),
          card('other', 2, kind: GpuKind.other),
        ],
      );
      expect(names(report), ['virgl']);
      expect(names(GpuReport(adapters: [card('llvmpipe', 0, kind: GpuKind.cpu)])), isEmpty);
    });

    test('the cards of the fakes, which tell no place, keep the order of the report', () {
      expect(ggmlVulkanIndexOf(FakeGpuReports.twoCards, FakeGpuReports.twoCards.bestDiscrete!), 1);
      expect(ggmlVulkanIndexOf(FakeGpuReports.rtx4060, FakeGpuReports.rtx4060.bestDiscrete!), 0);
    });
  });

  test('the name shown for a computer: the dedicated card, else the integrated one, never llvmpipe', () {
    expect(gpuNameOf(FakeGpuReports.twoCards), rtx4060Laptop.name);
    expect(gpuNameOf(FakeGpuReports.integratedOnly), irisXe.name);
    expect(gpuNameOf(_fixture('gpu_probe_iris_xe_mesa.json')), 'Intel(R) Iris(R) Xe Graphics (TGL GT2)');
    expect(gpuNameOf(FakeGpuReports.noVulkan), isNull);
    expect(
      gpuNameOf(
        const GpuReport(
          adapters: [
            GpuAdapter(name: 'Radeon (no Vulkan driver)', kind: GpuKind.other, localMemory: 1, source: 'dxgi'),
          ],
        ),
      ),
      'Radeon (no Vulkan driver)',
    );
  });
}
