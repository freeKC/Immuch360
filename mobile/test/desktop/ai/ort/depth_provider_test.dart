// Where the depth model of the 3D videos runs (lot ai-360-3d-51, lib/desktop/ai/ort/depth_provider.dart): the plan per
// system and choice, from the devices DirectML listed on FreeKC's laptop (23 Nov 2026), the check against the
// processor, the fall back of a card that fails during a job. With IMMUCH360_ORT_LIB (ONNX Runtime 1.31.0, the CI)
// the processor through the real library, and with IMMUCH360_ORT_CARD_LIB (the DirectML build, the Windows runner) the
// card the runner has, WARP counted as one: its check, one window compared with the processor, two libraries in one
// process.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/depth_provider.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';

const _tinyVda = 'test/fixtures/ai_immersive/tiny_vda.onnx';

/// The devices DirectML of ONNX Runtime 1.24.4 listed on FreeKC's laptop, 23 Nov 2026
const _laptop = [
  OrtEpDeviceInfo(
    epName: 'CPUExecutionProvider',
    type: 0,
    vendor: 'Intel',
    vendorId: 32902,
    deviceId: 7,
    metadata: {'Description': '13th Gen Intel(R) Core(TM) i9-13980HX'},
  ),
  OrtEpDeviceInfo(
    epName: directMlEpName,
    type: 1,
    vendor: 'NVIDIA',
    vendorId: 4318,
    deviceId: 10400,
    metadata: {
      'Description': 'NVIDIA GeForce RTX 4060 Laptop GPU',
      'Discrete': '1',
      'DxgiAdapterNumber': '1',
      'DxgiHighPerformanceIndex': '0',
      'DxgiVideoMemory': '7956 MB',
      'LUID': '99454',
    },
  ),
  OrtEpDeviceInfo(
    epName: directMlEpName,
    type: 1,
    vendor: 'Intel Corporation',
    vendorId: 32902,
    deviceId: 42888,
    metadata: {
      'Description': 'Intel(R) UHD Graphics',
      'Discrete': '0',
      'DxgiAdapterNumber': '0',
      'DxgiHighPerformanceIndex': '1',
      'DxgiVideoMemory': '128 MB',
      'LUID': '98370',
    },
  ),
];

/// The second Intel adapter of the same laptop (adapter 2, high performance order 3), as the job log listed it
const _intelAgain = OrtEpDeviceInfo(
  epName: directMlEpName,
  type: 1,
  vendor: 'Intel Corporation',
  vendorId: 32902,
  deviceId: 42888,
  metadata: {
    'Description': 'Intel(R) UHD Graphics',
    'Discrete': '0',
    'DxgiAdapterNumber': '2',
    'DxgiHighPerformanceIndex': '3',
    'DxgiVideoMemory': '128 MB',
    'LUID': '98371',
  },
);

/// [device] with [metadata] changed
OrtEpDeviceInfo _with(OrtEpDeviceInfo device, Map<String, String?> metadata) => OrtEpDeviceInfo(
  epName: device.epName,
  type: device.type,
  vendor: device.vendor,
  vendorId: device.vendorId,
  deviceId: device.deviceId,
  metadata: {
    for (final entry in {...device.metadata, ...metadata}.entries)
      if (entry.value != null) entry.key: entry.value!,
  },
);

const _warp = OrtEpDeviceInfo(
  epName: directMlEpName,
  type: 1,
  vendor: 'Microsoft',
  vendorId: 0x1414,
  deviceId: 140,
  metadata: {'Description': 'Microsoft Basic Render Driver', 'DxgiAdapterNumber': '0', 'DxgiHighPerformanceIndex': '0'},
);

DepthProviderPlan _plan(String choice, {List<OrtEpDeviceInfo> devices = _laptop, bool software = false}) =>
    planDepthProvider(choice: choice, windows: true, appleSilicon: false, devices: devices, allowSoftware: software);

void main() {
  group('the plan', () {
    test('automatic on the hybrid laptop: DirectML on the RTX 4060, the high performance card of Windows', () {
      final plan = _plan(depthDeviceAuto);
      expect(plan.provider, const OrtProvider.directMl(1));
      expect(plan.provider.options, {'device_id': '1'});
      expect(plan.title, 'DirectML on NVIDIA GeForce RTX 4060 Laptop GPU (adapter 1, 7956 MB)');
      expect(plan.why, 'the high performance card of Windows');
    });

    test('the order of EnumAdapters, the Intel chip first: still the RTX, by the high performance order', () {
      final enumOrder = [_laptop[2], _intelAgain, _laptop[1]];
      expect(_plan(depthDeviceAuto, devices: enumOrder).provider, const OrtProvider.directMl(1));
      // A system that gives no high performance order: the dedicated card wins
      final unordered = [
        for (final device in enumOrder) _with(device, {'DxgiHighPerformanceIndex': null}),
      ];
      expect(_plan(depthDeviceAuto, devices: unordered).provider, const OrtProvider.directMl(1));
    });

    test('This computer lists the Intel chip once, though DirectML gives it twice; its choice takes adapter 0', () {
      final cards = depthCards([..._laptop, _intelAgain]);
      expect(cards.map((card) => card.description), ['NVIDIA GeForce RTX 4060 Laptop GPU', 'Intel(R) UHD Graphics']);
      expect(cards.last.dxgiAdapter, 0, reason: 'the first of the high performance order');
      final chosen = _plan('${depthDeviceCardPrefix}Intel(R) UHD Graphics', devices: [_intelAgain, ..._laptop]);
      expect(chosen.provider, const OrtProvider.directMl(0));
    });

    test('a card chosen by its name, a card no longer there, the processor', () {
      expect(_plan('${depthDeviceCardPrefix}Intel(R) UHD Graphics').provider, const OrtProvider.directMl(0));
      final gone = _plan('${depthDeviceCardPrefix}AMD Radeon RX 7600');
      expect(gone.provider, const OrtProvider.directMl(1));
      expect(gone.why, contains('AMD Radeon RX 7600 chosen in This computer is not there'));
      final processor = _plan(depthDeviceProcessor);
      expect(processor.provider, OrtProvider.cpu);
      expect(processor.why, 'the processor, as chosen in This computer');
    });

    test('the software renderer of Windows is never a card, but for the CI', () {
      expect(_plan(depthDeviceAuto, devices: const [_warp]).provider, OrtProvider.cpu);
      expect(_plan(depthDeviceAuto, devices: const [_warp]).why, 'no graphics card DirectML can use');
      expect(_plan(depthDeviceAuto, devices: const [_warp], software: true).provider, const OrtProvider.directMl(0));
      expect(depthCards([..._laptop, _warp]).map((card) => card.description), [
        'NVIDIA GeForce RTX 4060 Laptop GPU',
        'Intel(R) UHD Graphics',
      ]);
    });

    test('no DirectML runtime, Linux, a Mac with Apple silicon', () {
      expect(
        planDepthProvider(choice: depthDeviceAuto, windows: true, appleSilicon: false, cardLibrary: false).why,
        'the DirectML runtime is not installed',
      );
      final linux = planDepthProvider(choice: depthDeviceAuto, windows: false, appleSilicon: false);
      expect(linux.provider, OrtProvider.cpu);
      expect(linux.why, 'no graphics card runtime for this system');
      final mac = planDepthProvider(choice: depthDeviceAuto, windows: false, appleSilicon: true);
      expect(mac.provider, OrtProvider.coreMl);
      expect(mac.provider.options, {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'ALL'});
      expect(mac.title, 'Core ML (Apple GPU and Neural Engine)');
    });
  });

  group('the check', () {
    test('the same depth passes, the depth of the Intel chip under DirectML fails, values not numbers fail', () {
      final processor = Float32List.fromList([6.5, 7.0, 9.0, 11.5]);
      expect(depthDifference(Float32List.fromList(processor), processor).largest, 0);
      final close = Float32List.fromList([6.50005, 7.0, 9.0, 11.5]);
      expect(depthDifference(close, processor).largest, lessThan(depthCheckTolerance));
      // What DirectML on the Intel UHD Graphics gave: a map from 0, far from the processor's
      final wrong = Float32List.fromList([0.0, 3.0, 9.5, 2.0]);
      expect(depthDifference(wrong, processor).largest, greaterThan(depthCheckTolerance));
      final broken = Float32List.fromList([6.5, double.nan, 9.0, 11.5]);
      expect(depthDifference(broken, processor).largest, double.infinity);
      expect(depthValuesFinite(broken), isFalse);
      expect(depthShare(9e-6), '0.00090 %');
    });

    test('the input of the check: 32 frames of 112 x 112, three channels, normalised', () {
      final input = depthCheckInput();
      expect(input, hasLength(32 * 3 * depthCheckSide * depthCheckSide));
      expect(depthValuesFinite(input), isTrue);
      expect(input.reduce((a, b) => a > b ? a : b), lessThan(3));
    });
  });

  group('a card that fails during the job', () {
    test('an error of the card: the window again on the processor, said once', () {
      final reasons = <String>[];
      var onCard = true;
      final values = runDepthWindow(
        onCard: true,
        run: () {
          if (onCard) {
            throw const OrtException('Run: DXGI_ERROR_DEVICE_REMOVED');
          }
          return Float32List.fromList([1, 2]);
        },
        toProcessor: (reason) {
          reasons.add(reason);
          onCard = false;
        },
      );
      expect(values, [1, 2]);
      expect(reasons, ['Run: DXGI_ERROR_DEVICE_REMOVED']);
    });

    test('values that are not numbers are a failure; a stop is not; the processor is never checked', () {
      final reasons = <String>[];
      var calls = 0;
      runDepthWindow(
        onCard: true,
        run: () => calls++ == 0 ? Float32List.fromList([double.nan]) : Float32List.fromList([1]),
        toProcessor: reasons.add,
      );
      expect(reasons, ['it gave values that are not numbers']);
      expect(
        () => runDepthWindow(
          onCard: true,
          run: () => throw const OrtRunStopped('Run: stopped'),
          toProcessor: (_) => fail('a stop is not a failure of the card'),
        ),
        throwsA(isA<OrtRunStopped>()),
      );
      expect(
        runDepthWindow(
          onCard: false,
          run: () => Float32List.fromList([double.nan]),
          toProcessor: (_) => fail('the processor has no fall back'),
        ).single.isNaN,
        isTrue,
      );
    });
  });

  final processorLibrary = Platform.environment['IMMUCH360_ORT_LIB'];
  final cardLibrary = Platform.environment['IMMUCH360_ORT_CARD_LIB'];

  test(
    'on the processor through the real library: its devices, the line of the job log, a window',
    skip: processorLibrary == null ? 'IMMUCH360_ORT_LIB not set' : null,
    () {
      final runtime = OrtRuntime.load(processorLibrary!);
      final devices = runtime.executionDevices();
      expect(devices.map((device) => device.epName), contains('CPUExecutionProvider'));
      final depth = openDepthSession(
        processorLibrary: processorLibrary,
        modelPath: _tinyVda,
        width: 56,
        height: 28,
        settings: const OrtSessionSettings(intraOpThreads: 2),
        windows: false,
        appleSilicon: false,
      );
      expect(depth.plan.provider, OrtProvider.cpu);
      expect(depth.lines.last, startsWith('depth model on the processor: ONNX Runtime ${runtime.version}, 2 threads'));
      final out = depth.session.run(Float32List(32 * 3 * 28 * 56), [1, 32, 3, 28, 56]);
      expect(out.shape, [1, 32, 28, 56]);
      depth.session.close();

      // The free dimensions fixed: the session takes that size only
      final fixed = runtime.openSession(
        _tinyVda,
        settings: const OrtSessionSettings(intraOpThreads: 1, fixedDimensions: {'height': 28, 'width': 56}),
      );
      expect(fixed.run(Float32List(32 * 3 * 28 * 56), [1, 32, 3, 28, 56]).shape, [1, 32, 28, 56]);
      expect(() => fixed.run(Float32List(32 * 3 * 14 * 14), [1, 32, 3, 14, 14]), throwsA(isA<OrtException>()));
      fixed.close();
    },
  );

  test(
    'Core ML on Apple silicon: the check, a window against the processor (the macOS runner proves it loads and runs)',
    skip: processorLibrary == null || Platform.environment['IMMUCH360_ORT_COREML'] == null
        ? 'IMMUCH360_ORT_COREML not set'
        : null,
    () {
      final depth = openDepthSession(
        processorLibrary: processorLibrary!,
        modelPath: _tinyVda,
        width: 56,
        height: 28,
        settings: const OrtSessionSettings(intraOpThreads: 2),
        windows: false,
        appleSilicon: true,
      );
      // ignore: avoid_print
      print(depth.lines.join('\n'));
      expect(depth.lines, contains(startsWith('check of Core ML (Apple GPU and Neural Engine) against the processor')));
      final input = Float32List(32 * 3 * 28 * 56);
      for (var i = 0; i < input.length; i++) {
        input[i] = (i % 97) / 50 - 1;
      }
      final reference = OrtRuntime.load(
        processorLibrary,
      ).openSession(_tinyVda, settings: const OrtSessionSettings(intraOpThreads: 2));
      final expected = reference.run(input, [1, 32, 3, 28, 56]).values;
      reference.close();
      expect(depthDifference(depth.session.run(input, [1, 32, 3, 28, 56]).values, expected).largest, lessThan(0.02));
      depth.session.close();
    },
  );

  test(
    'on the card of the runner (DirectML, WARP counted): the devices, the check, a window against the processor',
    skip: cardLibrary == null || processorLibrary == null ? 'IMMUCH360_ORT_CARD_LIB not set' : null,
    () {
      final card = OrtRuntime.load(cardLibrary!);
      final processor = OrtRuntime.load(processorLibrary!);
      // Two libraries in one process, each its own: the 3D photos keep 1.31.0 while a video runs on 1.24.4
      expect(card.version, '1.24.4');
      expect(processor.version, '1.31.0');
      final devices = card.executionDevices();
      // ignore: avoid_print
      print('devices of DirectML on this runner: ${devices.join('; ')}');
      final depth = openDepthSession(
        processorLibrary: processorLibrary,
        cardLibrary: cardLibrary,
        modelPath: _tinyVda,
        width: 56,
        height: 28,
        settings: const OrtSessionSettings(intraOpThreads: 2),
        allowSoftware: true,
        windows: true,
        appleSilicon: false,
      );
      // ignore: avoid_print
      print(depth.lines.join('\n'));
      expect(depth.lines.first, startsWith('graphics cards of DirectML (ONNX Runtime 1.24.4): '));
      final input = Float32List(32 * 3 * 28 * 56);
      for (var i = 0; i < input.length; i++) {
        input[i] = (i % 97) / 50 - 1;
      }
      final reference = processor.openSession(_tinyVda, settings: const OrtSessionSettings(intraOpThreads: 2));
      final expected = reference.run(input, [1, 32, 3, 28, 56]).values;
      reference.close();
      final got = depth.session.run(input, [1, 32, 3, 28, 56]).values;
      expect(depthDifference(got, expected).largest, lessThan(depthCheckTolerance));
      if (depth.plan.isGraphicsCard) {
        expect(depth.session.provider.kind, OrtProviderKind.directMl);
        expect(depth.lines, contains(startsWith('check of DirectML on ')));
        expect(depth.lines.last, startsWith('depth model on the graphics card: DirectML on '));
      } else {
        expect(depth.lines.last, startsWith('depth model on the processor: '));
      }
      depth.session.close();

      // A card that cannot be used (an adapter that is not there) leaves the processor, said
      final missing = card.openSession;
      expect(
        () => missing(
          _tinyVda,
          settings: const OrtSessionSettings(intraOpThreads: 1, provider: OrtProvider.directMl(97)),
        ),
        throwsA(isA<OrtException>()),
      );
    },
  );
}
