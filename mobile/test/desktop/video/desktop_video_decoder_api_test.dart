// DesktopVideoDecoderApi without a GPU: the static rule (Linux, macOS, and Windows when the probe fails), the answers
// from a probe given by the test (the profiles and sizes the two GPUs of the development laptop gave on 2026-10-10,
// see decoder_probe_windows_test.dart), the measured correction, two streams at once, and the decoders page rows.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/platform/desktop_video_decoder_api.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';

String _guid(String codec, String name) =>
    d3d11Profiles.firstWhere((profile) => profile.codec == codec && profile.name == name).guid;

/// A profile that takes every frame up to [max] in each direction, as a driver that checks sizes answers
D3D11DecoderProfile _profile(
  String codec,
  String name, {
  List<String> formats = const ['NV12'],
  (int, int) max = (8192, 8192),
  Iterable<(int, int)> sizes = ladderSizes,
  double? rate,
}) => D3D11DecoderProfile(
  guid: _guid(codec, name),
  formats: formats,
  sizeFormat: formats.first,
  sizes: [
    for (final (width, height) in sizes) (width: width, height: height, accepted: width <= max.$1 && height <= max.$2),
  ],
  maxFrameRate: rate,
);

const _rtx = GpuAdapter(
  index: -1,
  name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
  vendorId: 0x10de,
  deviceId: 0x28a0,
  driver: '32.0.16.1656',
  dedicatedMB: 7948,
  sharedMB: 7900,
  integrated: false,
  software: false,
);

const _intel = GpuAdapter(
  index: -1,
  name: 'Intel(R) UHD Graphics',
  vendorId: 0x8086,
  deviceId: 0xa788,
  driver: '32.0.101.7088',
  dedicatedMB: 128,
  sharedMB: 7900,
  integrated: true,
  software: false,
);

/// The profiles of [adapter] for the codecs of the app, as the probe found them on the development laptop
List<D3D11DecoderProfile> _profilesOf(GpuAdapter adapter, {Iterable<(int, int)> sizes = ladderSizes}) {
  final rtx = adapter == _rtx;
  final big = rtx ? (8192, 8192) : (16384, 16384);
  return [
    _profile(VideoMime.avc, 'High', max: (4096, 4096), sizes: sizes),
    // Listed, but no size taken in NV12: nothing to show
    _profile(VideoMime.avc, 'Stereo High', max: (0, 0), sizes: sizes),
    _profile(VideoMime.hevc, 'Main', max: big, sizes: sizes, rate: rtx ? null : 60),
    _profile(VideoMime.hevc, 'Main 10', formats: rtx ? ['P010'] : ['NV12', 'P010'], max: big, sizes: sizes),
    _profile(VideoMime.av1, 'Main', formats: ['NV12', 'P010'], max: big, sizes: sizes),
    _profile(VideoMime.vp9, 'Profile 0', max: big, sizes: sizes),
    _profile(VideoMime.mpeg2, 'Main', max: rtx ? (3840, 3840) : (1920, 1088), sizes: sizes),
  ];
}

/// The probe of the plugin, faked: [adapter]'s profiles, with the sizes asked
class _FakeProber {
  _FakeProber(this.adapter);

  GpuAdapter? adapter;
  final calls = <String>[];
  Error? failure;

  Future<D3D11DecoderProbe> call({
    Iterable<String>? profiles,
    Iterable<(int, int)> sizes = const [],
    bool rates = false,
  }) async {
    calls.add('${profiles?.length ?? 'all'} profiles, ${[for (final (w, h) in sizes) '${w}x$h'].join(' ')}');
    final error = failure;
    if (error != null) {
      throw error;
    }
    final gpu = adapter!;
    return D3D11DecoderProbe(
      adapter: gpu,
      profiles: _profilesOf(gpu, sizes: sizes),
      d3d12: rates,
    );
  }
}

DecodeMeasure _measure(
  GpuAdapter gpu,
  String codec,
  int width,
  int height,
  String hwdec, {
  int dropped = 0,
  double frameRate = 30,
  DateTime? at,
}) => DecodeMeasure(
  gpu: gpu.key,
  codec: codec,
  width: width,
  height: height,
  frameRate: frameRate,
  hwdec: hwdec,
  frames: 150,
  dropped: dropped,
  mpvVersion: 'mpv v0.39.0-179-g0f78584518',
  at: at ?? DateTime(2026, 10, 9, 20),
);

void main() {
  late Directory folder;
  late DecoderMeasureStore store;
  late _FakeProber prober;
  final now = DateTime(2026, 10, 10, 1);
  final previousProber = DesktopGpuDecoders.prober;

  DesktopVideoDecoderApi api() => DesktopVideoDecoderApi(measures: store, now: () => now);

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('desktop_video_decoder_api_test');
    store = DecoderMeasureStore(folder: () async => folder);
    prober = _FakeProber(_rtx);
    DesktopGpuDecoders.forget();
    DesktopGpuDecoders.prober = prober.call;
  });

  tearDown(() async {
    DesktopGpuDecoders.prober = previousProber;
    DesktopGpuDecoders.forget();
    await folder.delete(recursive: true);
  });

  group('what a video asks of a decoder', () {
    test('codec, depth, chroma and profile from the codecs string, the depth and the transfer', () {
      expect(desktopCodecNeed('avc1', 'avc1.640033', 8, 1), (
        mime: VideoMime.avc,
        bitDepth: 8,
        chroma: '4:2:0',
        profile: 'High',
      ));
      expect(desktopCodecNeed('avc1', 'avc1.6E0033', 0, 0)?.profile, 'High 10');
      expect(desktopCodecNeed('avc1', 'avc1.6E0033', 0, 0)?.bitDepth, 10);
      expect(desktopCodecNeed('avc1', 'avc1.7A0033', 10, 0)?.chroma, '4:2:2');
      expect(desktopCodecNeed('h264', null, 0, 0)?.profile, 'High');
      expect(desktopCodecNeed('hvc1', 'hvc1.1.6.L183.B0', 0, 0)?.profile, 'Main');
      expect(desktopCodecNeed('hvc1', 'hvc1.2.4.L153.B0', 0, 0)?.profile, 'Main 10');
      expect(desktopCodecNeed('hev1', 'hev1.4.10.L153.B0', 10, 0)?.chroma, '4:2:2');
      // HLG or PQ without a declared depth: 10 bit
      expect(desktopCodecNeed('hevc', null, 0, 18)?.profile, 'Main 10');
      expect(desktopCodecNeed('video/hevc', null, 12, 1)?.profile, 'Main 12');
      // Dolby Vision as its HEVC base layer
      expect(desktopCodecNeed('dvh1', 'dvh1.05.06', 0, 0), (
        mime: VideoMime.hevc,
        bitDepth: 10,
        chroma: '4:2:0',
        profile: 'Main 10',
      ));
      expect(desktopCodecNeed('vp09', 'vp09.02.10.10', 0, 0)?.profile, 'Profile 2');
      expect(desktopCodecNeed('vp09', 'vp09.02.10.10', 0, 0)?.bitDepth, 10);
      expect(desktopCodecNeed('av01', 'av01.0.16M.10', 0, 16)?.bitDepth, 10);
      expect(desktopCodecNeed('av01', 'av01.1.16M.08', 0, 0)?.chroma, '4:4:4');
      expect(desktopCodecNeed('mp4a', null, 0, 0), isNull);
      expect(desktopCodecNeed('', null, 0, 0), isNull);
    });

    test('the profiles FFmpeg tries', () {
      expect(ffmpegProfilesFor(VideoMime.avc), [
        _guid(VideoMime.avc, 'High, film grain'),
        _guid(VideoMime.avc, 'High'),
        _guid(VideoMime.avc, 'High, Intel'),
      ]);
      expect(ffmpegProfilesFor(VideoMime.avc, bitDepth: 10), isEmpty);
      expect(ffmpegProfilesFor(VideoMime.hevc), [_guid(VideoMime.hevc, 'Main')]);
      expect(ffmpegProfilesFor(VideoMime.hevc, bitDepth: 10), [_guid(VideoMime.hevc, 'Main 10')]);
      expect(ffmpegProfilesFor(VideoMime.hevc, bitDepth: 10, chroma: '4:2:2'), isEmpty);
      expect(ffmpegProfilesFor(VideoMime.vp8), isEmpty);
      expect(codedSize(VideoMime.avc, 1920, 1080), (width: 1920, height: 1088));
      expect(codedSize(VideoMime.hevc, 2880, 2880), (width: 2880, height: 2880));
      expect(codedSize(VideoMime.hevc, 1920, 1081), (width: 1920, height: 1088));
    });
  });

  group('static rule, without a probe', () {
    setUp(() => DesktopGpuDecoders.prober = null);

    test('software up to 8192 x 8192, whatever the codec', () async {
      final hevc8k = await api().canDecode('video/hevc', null, 7680, 3840, 30, 10, 16);
      expect(hevc8k.supported, isTrue);
      expect(hevc8k.hardware, isFalse);
      expect((hevc8k.maxWidth, hevc8k.maxHeight), (8192, 8192));
      expect(hevc8k.reason, startsWith('desktop static answer'));
      expect(hevc8k.profile, 'Main 10');
      expect(hevc8k.missingProfile, isNull);
      // The measures of the build hold for a GPU and a decoding path that a static answer does not know
      expect((await api().canDecode('hvc1', null, 7680, 3840, 30, 8, 1)).supported, isTrue);
      final huge = await api().canDecode('avc1', null, 16384, 8192, 30, 8, 1);
      expect(huge.supported, isFalse);
      expect(huge.reason, contains('larger than 8192x8192'));
    });

    test('an unknown codec is supported, as on the phones', () async {
      final verdict = await api().canDecode('prores', null, 3840, 2160, 25, 10, 1);
      expect(verdict.supported, isTrue);
      expect((verdict.maxWidth, verdict.maxHeight), (0, 0));
      expect(verdict.reason, "unknown codec 'prores'");
    });

    test('two streams at once: an X3 pair keeps up, an X4 file does not', () async {
      final x3 = await api().canDecode('avc1', null, 2880, 2880, 29.97, 8, 0, instances: 2);
      expect(x3.supported, isTrue);
      final x4 = await api().canDecode('hvc1', null, 3840, 3840, 29.97, 8, 0, instances: 2);
      expect(x4.supported, isFalse);
      expect(x4.reason, contains('2 streams of 3840x3840'));
      // The proxies and the transcoded lenses are small
      expect((await api().canDecode('avc1', null, 1440, 1440, 30, 8, 0, instances: 2)).supported, isTrue);
    });

    test('the decoders page: one software row per codec', () async {
      final rows = await api().listDecoders();
      expect(rows.map((row) => row.codec), DesktopVideoDecoderApi.softwareCodecs);
      expect(rows.every((row) => !row.hardware && row.name == 'FFmpeg (software)' && row.maxWidth == 8192), isTrue);
    });

    test('a probe that fails leaves the static rule', () async {
      DesktopGpuDecoders.prober = prober.call;
      prober.failure = StateError('no immuch_desktop_video.dll');
      final verdict = await api().canDecode('avc1', null, 5760, 2880, 30, 8, 1);
      expect(verdict.supported, isTrue);
      expect(verdict.reason, startsWith('desktop static answer'));
    });
  });

  group('Windows, from the Direct3D 11 profiles', () {
    test('H.264 up to 4096 in hardware, 5.7K in software as measured while the app was built', () async {
      final uhd = await api().canDecode('avc1', 'avc1.640033', 3840, 2160, 30, 8, 1);
      expect(uhd.supported, isTrue);
      expect(uhd.hardware, isTrue);
      expect((uhd.maxWidth, uhd.maxHeight), (4096, 4096));
      expect(uhd.reason, contains('NVIDIA GeForce RTX 4060 Laptop GPU decodes H.264 High at 3840x2160'));
      final export = await api().canDecode('avc1', 'avc1.640033', 5760, 2880, 30, 8, 1);
      expect(export.supported, isTrue);
      expect(export.hardware, isFalse);
      expect((export.maxWidth, export.maxHeight), (8192, 8192));
      expect(
        export.reason,
        'measured while the app was built (phase 2a, spike 6, both GPUs): '
        'H.264 5760x2880 at 30 fps through no, 0 of 300 frames dropped',
      );
    });

    test('8K HEVC in hardware until a playback tells the decoding path', () async {
      final verdict = await api().canDecode('hvc1', 'hvc1.1.6.L183.B0', 7680, 3840, 30, 8, 1);
      expect(verdict.supported, isTrue);
      expect(verdict.hardware, isTrue);
      expect(verdict.reason, startsWith('hardware: NVIDIA'));
      // 10 bit needs a profile writing P010, which the RTX's Main 10 does
      expect((await api().canDecode('hvc1', 'hvc1.2.4.L153.B0', 7680, 3840, 30, 10, 16)).hardware, isTrue);
    });

    test('no hardware profile for the depth: software, held to what software decoding was measured at', () async {
      final high10 = await api().canDecode('avc1', 'avc1.6E0033', 3840, 2160, 30, 10, 1);
      expect(high10.hardware, isFalse);
      expect(high10.supported, isTrue);
      expect(high10.profile, 'High 10');
      // 8K HEVC Main 12: no Main 12 profile here, and 8K HEVC in software dropped 50 to 80 frames in 300
      final main12 = await api().canDecode('video/hevc', null, 7680, 3840, 30, 12, 1);
      expect(main12.supported, isFalse);
      expect(main12.hardware, isFalse);
      expect(main12.missingProfile, 'Main 12');
      expect(main12.reason, contains('software on the Intel UHD'));
    });

    test('a size outside the ladder is asked of the driver once', () async {
      final first = await api().canDecode('hvc1', null, 2880, 2880, 29.97, 8, 0);
      expect(first.hardware, isTrue);
      await api().canDecode('hvc1', null, 2880, 2880, 29.97, 8, 0);
      expect(prober.calls.where((call) => call.endsWith(' 2880x2880')), hasLength(1));
      expect(prober.calls.first, startsWith('${d3d11Profiles.length} profiles, 1920x1088'));
      // H.264 lenses of an X3: under 4096, in hardware
      expect((await api().canDecode('avc1', null, 2880, 2880, 29.97, 8, 0)).hardware, isTrue);
      // An X4 lens alone, HEVC 3840 x 3840: in hardware, asked as well
      expect((await api().canDecode('hvc1', null, 3840, 3840, 29.97, 8, 0)).hardware, isTrue);
    });
  });

  group('the measured correction', () {
    test('on an integrated GPU whose HEVC comes back to memory, 8K follows the measure of the build', () async {
      prober.adapter = _intel;
      await store.record(_measure(_intel, VideoMime.hevc, 3840, 2160, 'd3d11va-copy'));
      final verdict = await api().canDecode('hvc1', null, 7680, 3840, 30, 8, 1);
      expect(verdict.supported, isFalse);
      expect(verdict.hardware, isTrue);
      expect(verdict.reason, contains('phase 2a, spike 6, Intel UHD'));
      expect(verdict.reason, contains('157 of 300 frames dropped'));
      // 4K was measured on this computer and kept up
      final uhd = await api().canDecode('hvc1', null, 3840, 2160, 30, 8, 1);
      expect(uhd.supported, isTrue);
      expect(uhd.reason, startsWith('measured on this computer'));
    });

    test('the same path on a dedicated GPU, or zero copy on any, keeps up at 8K', () async {
      await store.record(_measure(_rtx, VideoMime.hevc, 3840, 2160, 'd3d11va-copy'));
      expect((await api().canDecode('hvc1', null, 7680, 3840, 30, 8, 1)).supported, isTrue);
      DesktopGpuDecoders.forget();
      prober.adapter = _intel;
      await store.record(_measure(_intel, VideoMime.hevc, 3840, 2160, 'd3d11va'));
      final zeroCopy = await api().canDecode('hvc1', null, 7680, 3840, 30, 8, 1);
      expect(zeroCopy.supported, isTrue);
      expect(zeroCopy.reason, contains('phase 2b'));
    });

    test('what a playback of the same kind of video did on this computer wins, for two weeks when it failed', () async {
      prober.adapter = _intel;
      await store.record(
        _measure(_intel, VideoMime.hevc, 7680, 3840, 'd3d11va-copy', dropped: 78, at: DateTime(2026, 10, 9)),
      );
      final verdict = await api().canDecode('hvc1', null, 7680, 3840, 30, 8, 1);
      expect(verdict.supported, isFalse);
      expect(verdict.reason, startsWith('measured on this computer: HEVC 7680x3840 at 30 fps through d3d11va-copy'));
      final later = DesktopVideoDecoderApi(measures: store, now: () => DateTime(2026, 10, 24));
      final retried = await later.canDecode('hvc1', null, 7680, 3840, 30, 8, 1);
      expect(retried.supported, isTrue);
      expect(retried.reason, startsWith('hardware: Intel'));
    });

    test('software that kept up at a higher rate, or did not at a lower one, answers for the codec', () async {
      await store.record(_measure(_rtx, VideoMime.avc, 5760, 2880, 'no', dropped: 40));
      final export = await api().canDecode('avc1', null, 5760, 2880, 29.97, 8, 1);
      expect(export.supported, isFalse);
      expect(export.reason, startsWith('measured on this computer'));
      // 8K H.264 costs more than what already did not keep up
      expect((await api().canDecode('avc1', null, 7680, 3840, 30, 8, 1)).supported, isFalse);
      // 4096 and less is the hardware decoder's
      expect((await api().canDecode('avc1', null, 4096, 2048, 30, 8, 1)).supported, isTrue);
    });
  });

  group('the decoders page', () {
    test('one row per hardware profile by codec, the software rows, then what was measured', () async {
      await store.record(_measure(_rtx, VideoMime.hevc, 7680, 3840, 'd3d11va-copy', dropped: 75));
      final rows = await api().listDecoders();
      final hardware = rows.where((row) => row.hardware && row.name.endsWith('(Direct3D 11)')).toList();
      expect(hardware.map((row) => row.codec), [
        VideoMime.avc,
        VideoMime.hevc,
        VideoMime.hevc,
        VideoMime.av1,
        VideoMime.vp9,
        VideoMime.mpeg2,
      ]);
      expect(hardware.first.name, 'NVIDIA GeForce RTX 4060 Laptop GPU (Direct3D 11)');
      expect((hardware.first.maxWidth, hardware.first.maxHeight), (4096, 4096));
      expect(hardware.first.profiles, ['High (NV12)']);
      expect(hardware[2].profiles, ['Main 10 (P010)']);
      expect(hardware.every((row) => row.maxFrameRate == 0), isTrue);
      final software = rows.where((row) => row.name == 'FFmpeg (software)');
      expect(software.map((row) => row.codec), DesktopVideoDecoderApi.softwareCodecs);
      final measured = rows.last;
      expect(measured.name, 'Measured in playback: d3d11va-copy, 75 of 150 frames dropped');
      expect(measured.codec, VideoMime.hevc);
      expect(measured.hardware, isTrue);
      expect((measured.maxWidth, measured.maxHeight), (7680, 3840));
      expect(measured.maxFrameRate, 15);
    });

    test('a rate the driver tells is shown', () async {
      prober.adapter = _intel;
      final rows = await api().listDecoders();
      final main = rows.firstWhere((row) => row.codec == VideoMime.hevc && row.profiles!.single.startsWith('Main ('));
      expect(main.maxFrameRate, 60);
      expect((main.maxWidth, main.maxHeight), (16384, 16384));
    });
  });
}
