// Which graphics card suits a video and how mpv decodes it (video_gpu.dart), on machines described by the test: the
// development laptop (an Intel UHD driving the panel and an RTX 4060 Laptop, as its decoder probe and GPU list read
// them on 2026-11-02), with the app on either card, a desktop with one card, a laptop with an integrated GPU only, an
// AMD APU listed twice, the software renderer in use, and a Windows without IDXGIFactory6. Also the GPU list as the
// plugin's DLL writes it, and DesktopGpuDecoders reading the machine once per run.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/desktop/video/video_gpu.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:logging/logging.dart';

/// What immuch_dv_gpus wrote on the development laptop, the app started without the runner's exports: DXGI lists the
/// Intel first. The second Intel entry is the same GPU as seen through another LUID, the last one Windows' software
/// renderer.
const _laptopJson =
    '{"adapters":[{"name":"Intel(R) UHD Graphics","driver":"32.0.101.7088","index":0,"vendorId":32902,'
    '"deviceId":42888,"subSysId":383979587,"revision":4,"dedicatedMB":128,"sharedMB":8006,"integrated":true,'
    '"software":false,"luid":"00000000:000164ca"},{"name":"NVIDIA GeForce RTX 4060 Laptop GPU",'
    '"driver":"32.0.16.1656","index":1,"vendorId":4318,"deviceId":10400,"subSysId":698159171,"revision":161,'
    '"dedicatedMB":7956,"sharedMB":8006,"integrated":false,"software":false,"luid":"00000000:0001698d"},'
    '{"name":"Intel(R) UHD Graphics","driver":"32.0.101.7088","index":2,"vendorId":32902,"deviceId":42888,'
    '"subSysId":383979587,"revision":4,"dedicatedMB":128,"sharedMB":8006,"integrated":true,"software":false,'
    '"luid":"00000000:00021624"},{"name":"Microsoft Basic Render Driver","driver":"10.0.26100.8925","index":3,'
    '"vendorId":5140,"deviceId":140,"subSysId":0,"revision":0,"dedicatedMB":0,"sharedMB":8006,"integrated":true,'
    '"software":true,"luid":"00000000:00016892"}],"highPerformance":"00000000:0001698d",'
    '"minimumPower":"00000000:000164ca"}';

final _laptop = GpuList.fromJson(jsonDecode(_laptopJson) as Map<String, Object?>);

/// The card the decoder probe reports in use (its default adapter), as Direct3D tells whether it is integrated
GpuAdapter _inUse(GpuAdapter listed, {bool? integrated}) => GpuAdapter(
  index: -1,
  name: listed.name,
  vendorId: listed.vendorId,
  deviceId: listed.deviceId,
  driver: listed.driver,
  dedicatedMB: listed.dedicatedMB,
  sharedMB: listed.sharedMB,
  integrated: integrated ?? listed.integrated,
  software: listed.software,
  luid: listed.luid,
);

final _intel = _inUse(_laptop.adapters[0]);
final _rtx = _inUse(_laptop.adapters[1]);

GpuAdapter _card(
  String name, {
  required bool integrated,
  String luid = '',
  int dedicatedMB = 0,
  bool software = false,
}) => GpuAdapter(
  index: 0,
  name: name,
  vendorId: 1,
  deviceId: name.length,
  driver: '1.0',
  dedicatedMB: dedicatedMB,
  sharedMB: 8000,
  integrated: integrated,
  software: software,
  luid: luid,
);

void main() {
  group('the GPU list of the plugin', () {
    test('reads the adapters in DXGI order, their LUIDs, and the cards Windows gives each preference', () {
      expect(_laptop.adapters.map((gpu) => gpu.name), [
        'Intel(R) UHD Graphics',
        'NVIDIA GeForce RTX 4060 Laptop GPU',
        'Intel(R) UHD Graphics',
        'Microsoft Basic Render Driver',
      ]);
      expect(_laptop.adapters.map((gpu) => gpu.luid).toSet(), hasLength(4));
      expect(_laptop.byLuid(_laptop.highPerformance)?.name, 'NVIDIA GeForce RTX 4060 Laptop GPU');
      expect(_laptop.byLuid(_laptop.minimumPower)?.name, 'Intel(R) UHD Graphics');
      expect(_laptop.byLuid(''), isNull);
      expect(_laptop.adapters.last.software, isTrue);
      expect(_laptop.error, isNull);
    });

    test('an old Windows without the preferences, and a list that failed', () {
      final old = GpuList.fromJson({
        'adapters': [
          {'name': 'GPU', 'luid': '00000000:00000001', 'integrated': false},
        ],
        'highPerformance': null,
        'minimumPower': null,
      });
      expect((old.highPerformance, old.minimumPower), ('', ''));
      final failed = GpuList.fromJson({'adapters': <Object>[], 'error': 'no DXGI factory'});
      expect(failed.adapters, isEmpty);
      expect(failed.error, 'no DXGI factory');
    });

    test('the decoder probe reads the LUID of the card in use, empty from an older plugin', () {
      expect(GpuAdapter.fromJson({'name': 'GPU', 'luid': '00000000:000164ca'}).luid, '00000000:000164ca');
      expect(GpuAdapter.fromJson({'name': 'GPU'}).luid, '');
    });
  });

  group('chooseVideoGpu', () {
    void expectChoice(
      VideoGpuChoice choice, {
      required String? card,
      required bool onIt,
      required VideoGpuAdvice advice,
    }) {
      expect(choice.card?.name, card);
      expect(choice.onIt, onIt);
      expect(choice.advice, advice);
      // Decoded on the card in use without a copy where it can, by mpv's own choice otherwise: never a copy to reach
      // another card
      expect(choice.hwdec, DesktopPlayerOptions.hwdec);
    }

    test('the laptop with the app on the RTX (the runner asked the drivers for it): every video plays there', () {
      final machine = (inUse: _rtx, gpus: _laptop);
      for (final (width, height) in [(7680, 4320), (3840, 2160), (1920, 1080), (5760, 2880)]) {
        expectChoice(
          chooseVideoGpu(machine, width: width, height: height),
          card: 'NVIDIA GeForce RTX 4060 Laptop GPU',
          onIt: true,
          advice: VideoGpuAdvice.none,
        );
      }
    });

    test('the laptop with the app on the Intel (a build without the exports): 4K and more want the RTX', () {
      final machine = (inUse: _intel, gpus: _laptop);
      // The video of the report, a Samsung S24+ 8K, and the 4K sizes
      for (final (width, height) in [
        (7680, 4320),
        (3840, 2160),
        (4096, 2160),
        (2160, 3840),
        (5760, 2880),
        (5760, 1440),
      ]) {
        expectChoice(
          chooseVideoGpu(machine, width: width, height: height),
          card: 'NVIDIA GeForce RTX 4060 Laptop GPU',
          onIt: false,
          advice: VideoGpuAdvice.useHighPerformanceCard,
        );
      }
      // Below 4K: nothing to say
      for (final (width, height) in [(1920, 1080), (2560, 1440), (3440, 1440), (0, 0)]) {
        expectChoice(
          chooseVideoGpu(machine, width: width, height: height),
          card: 'Intel(R) UHD Graphics',
          onIt: true,
          advice: VideoGpuAdvice.none,
        );
      }
    });

    test('the laptop with Power saving chosen for the app in Windows: Windows names the Intel as its high performance '
        'card too, and the RTX is still the one to suggest', () {
      // What the branch build logged on the development laptop with GpuPreference=1 for it (2 November 2026, 14:10):
      // "Intel(R) UHD Graphics (high performance, power saving, in use); NVIDIA GeForce RTX 4060 Laptop GPU; ..."
      final powerSaving = GpuList(
        adapters: _laptop.adapters,
        highPerformance: _laptop.adapters[0].luid,
        minimumPower: _laptop.adapters[0].luid,
      );
      expectChoice(
        chooseVideoGpu((inUse: _intel, gpus: powerSaving), width: 7680, height: 4320),
        card: 'NVIDIA GeForce RTX 4060 Laptop GPU',
        onIt: false,
        advice: VideoGpuAdvice.useHighPerformanceCard,
      );
      expectChoice(
        chooseVideoGpu((inUse: _intel, gpus: powerSaving), width: 1920, height: 1080),
        card: 'Intel(R) UHD Graphics',
        onIt: true,
        advice: VideoGpuAdvice.none,
      );
      // The same setting on the AMD laptop below, whose integrated GPU the list does not take for one
      final apu = _card('AMD Radeon 780M', integrated: true, luid: 'c', dedicatedMB: 2048);
      final amd = GpuList(
        adapters: [
          _card('AMD Radeon 780M', integrated: false, luid: 'c', dedicatedMB: 2048),
          _card('AMD Radeon RX 7600S', integrated: false, luid: 'd', dedicatedMB: 8176),
        ],
        highPerformance: 'c',
        minimumPower: 'c',
      );
      expectChoice(
        chooseVideoGpu((inUse: apu, gpus: amd), width: 3840, height: 2160),
        card: 'AMD Radeon RX 7600S',
        onIt: false,
        advice: VideoGpuAdvice.useHighPerformanceCard,
      );
    });

    test('a desktop with one card, and a laptop with an integrated GPU only: nothing better to suggest', () {
      final desktopCard = _card('Radeon RX 7800 XT', integrated: false, luid: 'a', dedicatedMB: 16000);
      final desktop = GpuList(
        adapters: [
          desktopCard,
          _card('Microsoft Basic Render Driver', integrated: true, luid: 'z', software: true),
        ],
        highPerformance: 'a',
        minimumPower: 'a',
      );
      expectChoice(
        chooseVideoGpu((inUse: desktopCard, gpus: desktop), width: 7680, height: 4320),
        card: 'Radeon RX 7800 XT',
        onIt: true,
        advice: VideoGpuAdvice.none,
      );

      final iris = _card('Intel(R) Iris(R) Xe Graphics', integrated: true, luid: 'b', dedicatedMB: 128);
      final thin = GpuList(
        adapters: [
          iris,
          _card('Microsoft Basic Render Driver', integrated: true, luid: 'z', software: true),
        ],
        highPerformance: 'b',
        minimumPower: 'b',
      );
      expectChoice(
        chooseVideoGpu((inUse: iris, gpus: thin), width: 7680, height: 4320),
        card: 'Intel(R) Iris(R) Xe Graphics',
        onIt: true,
        advice: VideoGpuAdvice.none,
      );
    });

    test('an AMD laptop whose integrated GPU reserves 2 GB: the card Windows names counts, not the memory', () {
      final apu = _card('AMD Radeon 780M', integrated: true, luid: 'c', dedicatedMB: 2048);
      final dgpu = _card('AMD Radeon RX 7600S', integrated: false, luid: 'd', dedicatedMB: 8176);
      final gpus = GpuList(
        adapters: [
          _card('AMD Radeon 780M', integrated: false, luid: 'c', dedicatedMB: 2048),
          dgpu,
        ],
        highPerformance: 'd',
        minimumPower: 'c',
      );
      expectChoice(
        chooseVideoGpu((inUse: apu, gpus: gpus), width: 3840, height: 2160),
        card: 'AMD Radeon RX 7600S',
        onIt: false,
        advice: VideoGpuAdvice.useHighPerformanceCard,
      );
    });

    test('an AMD APU that DXGI lists twice, without a dedicated GPU: its second LUID is not a better card', () {
      // The development laptop lists its Intel UHD twice, with two LUIDs; an APU that reserves 512 MB or more is not
      // taken for an integrated GPU by the list, so its second entry looks like a card of its own
      final apu = _card('AMD Radeon(TM) Graphics', integrated: true, luid: 'c', dedicatedMB: 2048);
      final listed = _card('AMD Radeon(TM) Graphics', integrated: false, luid: 'c', dedicatedMB: 2048);
      final twice = _card('AMD Radeon(TM) Graphics', integrated: false, luid: 'e', dedicatedMB: 2048);
      final software = _card('Microsoft Basic Render Driver', integrated: true, luid: 'z', software: true);
      for (final named in ['c', 'e', '']) {
        expectChoice(
          chooseVideoGpu(
            (
              inUse: apu,
              gpus: GpuList(adapters: [listed, twice, software], highPerformance: named, minimumPower: named),
            ),
            width: 7680,
            height: 4320,
          ),
          card: 'AMD Radeon(TM) Graphics',
          onIt: true,
          advice: VideoGpuAdvice.none,
        );
      }
      // With a dedicated GPU beside it, that one is still suggested
      final dgpu = _card('AMD Radeon RX 7600S', integrated: false, luid: 'd', dedicatedMB: 8176);
      expectChoice(
        chooseVideoGpu(
          (
            inUse: apu,
            gpus: GpuList(adapters: [listed, twice, dgpu, software], highPerformance: 'c', minimumPower: 'c'),
          ),
          width: 7680,
          height: 4320,
        ),
        card: 'AMD Radeon RX 7600S',
        onIt: false,
        advice: VideoGpuAdvice.useHighPerformanceCard,
      );
    });

    test("the app on Windows' software renderer (a Remote Desktop session, a missing driver): no card to suggest", () {
      final software = _inUse(_laptop.adapters[3]);
      expect((software.software, software.integrated), (true, true));
      for (final gpus in [
        _laptop,
        GpuList(adapters: _laptop.adapters),
        GpuList(adapters: _laptop.adapters, highPerformance: _laptop.adapters[3].luid),
      ]) {
        expectChoice(
          chooseVideoGpu((inUse: software, gpus: gpus), width: 7680, height: 4320),
          card: 'Microsoft Basic Render Driver',
          onIt: true,
          advice: VideoGpuAdvice.none,
        );
      }
    });

    test('a Windows without IDXGIFactory6: a card with memory of its own beside the integrated one in use', () {
      final gpus = GpuList(adapters: [_laptop.adapters[0], _laptop.adapters[1], _laptop.adapters[3]]);
      expectChoice(
        chooseVideoGpu((inUse: _intel, gpus: gpus), width: 7680, height: 4320),
        card: 'NVIDIA GeForce RTX 4060 Laptop GPU',
        onIt: false,
        advice: VideoGpuAdvice.useHighPerformanceCard,
      );
      // The software renderer and the integrated card itself are never the better card
      final alone = GpuList(adapters: [_laptop.adapters[0], _laptop.adapters[3]]);
      expectChoice(
        chooseVideoGpu((inUse: _intel, gpus: alone), width: 7680, height: 4320),
        card: 'Intel(R) UHD Graphics',
        onIt: true,
        advice: VideoGpuAdvice.none,
      );
    });

    test('nothing known (Linux, macOS, a probe that failed): no card, nothing to say', () {
      expectChoice(
        chooseVideoGpu((inUse: null, gpus: null), width: 7680, height: 4320),
        card: null,
        onIt: false,
        advice: VideoGpuAdvice.none,
      );
      expectChoice(
        chooseVideoGpu((inUse: _intel, gpus: null), width: 7680, height: 4320),
        card: 'Intel(R) UHD Graphics',
        onIt: true,
        advice: VideoGpuAdvice.none,
      );
    });

    test('the same card is told by its LUID, and by model, driver and name without one', () {
      expect(sameGpu(_laptop.adapters[0], _laptop.adapters[2]), isFalse, reason: 'two LUIDs, two adapters');
      expect(sameGpu(_intel, _laptop.adapters[0]), isTrue);
      final noLuid = _inUse(_laptop.adapters[1]);
      expect(sameGpu(GpuAdapter.fromJson({..._json(noLuid), 'luid': ''}), _laptop.adapters[1]), isTrue);
      expect(sameGpu(GpuAdapter.fromJson({..._json(noLuid), 'luid': ''}), _laptop.adapters[0]), isFalse);
    });
  });

  group('videoDecodingKind', () {
    test("mpv's hwdec-current: the card without a copy, with a copy, or the processor", () {
      expect(videoDecodingKind('d3d11va'), VideoDecodingKind.hardware);
      expect(videoDecodingKind('nvdec'), VideoDecodingKind.hardware);
      expect(videoDecodingKind('vaapi'), VideoDecodingKind.hardware);
      expect(videoDecodingKind('videotoolbox'), VideoDecodingKind.hardware);
      expect(videoDecodingKind('d3d11va-copy'), VideoDecodingKind.hardwareCopy);
      expect(videoDecodingKind('nvdec-copy'), VideoDecodingKind.hardwareCopy);
      expect(videoDecodingKind('no'), VideoDecodingKind.software);
      expect(videoDecodingKind(' no\n'), VideoDecodingKind.software);
      expect(videoDecodingKind(''), isNull);
      expect(videoDecodingKind(null), isNull);
    });
  });

  group('DesktopGpuDecoders.machine', () {
    final previousProber = DesktopGpuDecoders.prober;
    final previousLister = DesktopGpuDecoders.lister;
    var lists = 0;

    setUp(() {
      lists = 0;
      DesktopGpuDecoders.forget();
      DesktopGpuDecoders.prober = ({profiles, sizes = const [], rates = false}) async =>
          D3D11DecoderProbe(adapter: _rtx);
      DesktopGpuDecoders.lister = () async {
        lists++;
        return GpuList.fromJson(jsonDecode(_laptopJson) as Map<String, Object?>);
      };
    });

    tearDown(() {
      DesktopGpuDecoders.prober = previousProber;
      DesktopGpuDecoders.lister = previousLister;
      DesktopGpuDecoders.forget();
    });

    test('reads the card in use and the list once per run, and logs which card is which', () async {
      final lines = <String>[];
      final subscription = Logger.root.onRecord.listen((record) => lines.add(record.message));
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      try {
        final machine = await DesktopGpuDecoders.machine();
        await DesktopGpuDecoders.machine();
        expect(machine.inUse?.name, 'NVIDIA GeForce RTX 4060 Laptop GPU');
        expect(machine.gpus?.adapters, hasLength(4));
        expect(lists, 1);
        const logged =
            'Graphics cards: Intel(R) UHD Graphics (power saving); '
            'NVIDIA GeForce RTX 4060 Laptop GPU (high performance, in use); Intel(R) UHD Graphics; '
            'Microsoft Basic Render Driver (software)';
        expect(lines.where((line) => line.startsWith('Graphics cards: ')), [logged]);
      } finally {
        Logger.root.level = previousLevel;
        await subscription.cancel();
      }
    });

    test('a list that fails or never answers leaves the machine without it, and the app goes on', () async {
      DesktopGpuDecoders.lister = () => Future.error(ArgumentError('Failed to load dynamic library'));
      expect((await DesktopGpuDecoders.machine()).gpus, isNull);
      DesktopGpuDecoders.forget();
      DesktopGpuDecoders.lister = null;
      final machine = await DesktopGpuDecoders.machine();
      expect(machine.inUse?.name, 'NVIDIA GeForce RTX 4060 Laptop GPU');
      expect(machine.gpus, isNull);
    });
  });
}

Map<String, Object?> _json(GpuAdapter gpu) => {
  'index': gpu.index,
  'name': gpu.name,
  'vendorId': gpu.vendorId,
  'deviceId': gpu.deviceId,
  'driver': gpu.driver,
  'dedicatedMB': gpu.dedicatedMB,
  'sharedMB': gpu.sharedMB,
  'integrated': gpu.integrated,
  'software': gpu.software,
  'luid': gpu.luid,
};
