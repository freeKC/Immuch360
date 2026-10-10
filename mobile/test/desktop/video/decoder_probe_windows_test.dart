// The decoder probe of immuch_desktop_video on the GPUs of the computer it runs on: the default adapter (the GPU the
// app's video uses) and every adapter of DXGI's list, with the sizes of the decoders page, the rates Direct3D 12 tells,
// and DesktopVideoDecoderApi answering from them. It prints what it found, for the reports, and checks what holds on
// any GPU with a video decoder. Windows only, after a Windows build of the app (it holds immuch_desktop_video.dll):
//   flutter build windows --debug -t lib/main_desktop.dart
//   flutter test test/desktop/video/decoder_probe_windows_test.dart
// IMMUCH360_DESKTOP_VIDEO_DLL may name the DLL itself, IMMUCH360_BUILD_DIR the folder holding it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/platform/desktop_video_decoder_api.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:path/path.dart' as p;

/// The DLL of a Windows build, null when there is none
String? _library() {
  final given = Platform.environment['IMMUCH360_DESKTOP_VIDEO_DLL'];
  final buildDir = Platform.environment['IMMUCH360_BUILD_DIR'];
  final candidates = [
    if (given != null && given.isNotEmpty) given,
    if (buildDir != null && buildDir.isNotEmpty) p.join(buildDir, D3D11Decoders.libraryName),
    for (final mode in ['Debug', 'Profile', 'Release'])
      p.join('build', 'windows', 'x64', 'runner', mode, D3D11Decoders.libraryName),
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      return p.absolute(path);
    }
  }
  return null;
}

/// What the probe found, in the test's output for the reports
void _report(String text) {
  // ignore: avoid_print
  print(text);
}

String _summary(D3D11DecoderProbe probe) {
  final lines = ['${probe.adapter} d3d12 ${probe.d3d12} ${probe.error ?? ''}'];
  for (final profile in probe.profiles) {
    final info = d3d11ProfileInfo(profile.guid);
    final largest = profile.largest;
    final refused = [
      for (final size in profile.sizes)
        if (!size.accepted) '${size.width}x${size.height}',
    ];
    final rate = profile.rateUntold
        ? ', rate not told'
        : (profile.maxFrameRate == null ? '' : ', ${profile.maxFrameRate} fps');
    lines.add(
      '  ${info == null ? profile.guid : '${videoCodecLabel(info.codec)} ${info.name}'}: ${profile.formats.join(',')}'
      '${largest == null ? '' : ', largest ${largest.width}x${largest.height}'}'
      '${refused.isEmpty ? '' : ', refused ${refused.join(' ')}'}$rate',
    );
  }
  return lines.join('\n');
}

void main() {
  final library = Platform.isWindows ? _library() : null;
  final skip = !Platform.isWindows
      ? 'Windows only'
      : library == null
      ? 'no immuch_desktop_video.dll: build the app for Windows first'
      : null;

  test('the default adapter: profiles, sizes and rates', () async {
    final profiles = d3d11Profiles.map((profile) => profile.guid).toList();
    Future<(D3D11DecoderProbe, int)> timed({required bool rates}) async {
      final watch = Stopwatch()..start();
      final probe = await D3D11Decoders.probe(profiles: profiles, sizes: ladderSizes, rates: rates, library: library!);
      return (probe, watch.elapsedMilliseconds);
    }

    // The first call of a process pays for the driver's start; the app makes it once, early
    final (_, cold) = await timed(rates: false);
    final (probe, withRates) = await timed(rates: true);
    final (_, warm) = await timed(rates: false);
    _report(
      'default adapter, probe in $cold ms cold, $withRates ms with the rates, $warm ms warm:\n${_summary(probe)}',
    );
    expect(probe.error, isNull);
    expect(probe.adapter, isNotNull);
    expect(probe.adapter!.software, isFalse);
    expect(probe.adapter!.driver, isNotEmpty);
    final known = probe.profiles.map((profile) => d3d11ProfileInfo(profile.guid)).nonNulls.toList();
    expect(known.where((info) => info.codec == VideoMime.avc), isNotEmpty);
    expect(known.where((info) => info.codec == VideoMime.hevc), isNotEmpty);
    // Every GPU of the last ten years decodes HEVC Main at 4K
    final hevcMain = probe.profile(ffmpegProfilesFor(VideoMime.hevc).single);
    expect(hevcMain?.accepts(3840, 2160), isTrue);
    // A size check does not open a decoder: once the driver runs, a probe stays well under the decoder check's wait
    // of 2 s
    expect(warm, lessThan(2000));
  }, skip: skip);

  test('every adapter of the list', () async {
    final count = D3D11Decoders.adapterCount(library: library!);
    _report('$count adapters');
    expect(count, greaterThan(0));
    for (var index = 0; index < count; index++) {
      final watch = Stopwatch()..start();
      final probe = await D3D11Decoders.probe(
        adapter: index,
        profiles: d3d11Profiles.map((profile) => profile.guid),
        sizes: [...ladderSizes, (5760, 2880), (2880, 2880), (3840, 3840)],
        rates: true,
        library: library,
      );
      _report('adapter $index, probe in ${watch.elapsedMilliseconds} ms:\n${_summary(probe)}');
      final adapter = probe.adapter;
      if (adapter == null || adapter.software || probe.error != null) {
        continue;
      }
      // What phase 2a saw through FFmpeg on an RTX 4060 Laptop and an Intel UHD: no Direct3D decoder of NVIDIA or
      // Intel takes H.264 above 4096, so 5.7K exports are decoded in software
      if (adapter.vendorId == 0x10de || adapter.vendorId == 0x8086) {
        for (final guid in ffmpegProfilesFor(VideoMime.avc)) {
          expect(probe.profile(guid)?.accepts(5760, 2880), isNot(isTrue), reason: '${adapter.name} $guid');
        }
      }
    }
  }, skip: skip);

  test('DesktopVideoDecoderApi answers from the probe of the default adapter', () async {
    final folder = await Directory.systemTemp.createTemp('decoder_probe_windows');
    addTearDown(() => folder.delete(recursive: true));
    DesktopGpuDecoders.forget();
    final previous = DesktopGpuDecoders.prober;
    DesktopGpuDecoders.prober = ({profiles, sizes = const [], rates = false}) =>
        D3D11Decoders.probe(profiles: profiles, sizes: sizes, rates: rates, library: library!);
    addTearDown(() {
      DesktopGpuDecoders.prober = previous;
      DesktopGpuDecoders.forget();
    });
    final api = DesktopVideoDecoderApi(measures: DecoderMeasureStore(folder: () async => folder));
    final questions = {
      '5.7K H.264': await api.canDecode('avc1', 'avc1.640033', 5760, 2880, 30, 8, 1),
      '4K H.264': await api.canDecode('avc1', 'avc1.640033', 3840, 2160, 30, 8, 1),
      '8K HEVC Main': await api.canDecode('hvc1', 'hvc1.1.6.L183.B0', 7680, 3840, 30, 8, 1),
      '5.7K HEVC Main 10 HLG': await api.canDecode('hvc1', null, 5760, 2880, 30, 10, 18),
      'X3 lens H.264, two at once': await api.canDecode('avc1', null, 2880, 2880, 29.97, 8, 0, instances: 2),
      'X4 lens HEVC, two at once': await api.canDecode('hvc1', null, 3840, 3840, 29.97, 8, 0, instances: 2),
      '8K AV1 10 bit': await api.canDecode('av01', 'av01.0.16M.10', 7680, 4320, 30, 10, 16),
    };
    for (final MapEntry(:key, :value) in questions.entries) {
      _report(
        '$key: supported ${value.supported}, hardware ${value.hardware}, up to ${value.maxWidth}x${value.maxHeight}, '
        'profile ${value.profile}, ${value.reason}',
      );
    }
    expect(questions['5.7K H.264']!.supported, isTrue);
    expect(questions['4K H.264']!.hardware, isTrue);
    expect(questions['X3 lens H.264, two at once']!.supported, isTrue);
    expect(questions['X4 lens HEVC, two at once']!.supported, isFalse);
    final rows = await api.listDecoders();
    _report(
      [for (final row in rows) '${row.codec} ${row.name} ${row.maxWidth}x${row.maxHeight} ${row.profiles}'].join('\n'),
    );
    expect(rows.where((row) => row.hardware), isNotEmpty);
    expect(
      rows.where((row) => !row.hardware).map((row) => row.codec),
      containsAll(DesktopVideoDecoderApi.softwareCodecs),
    );
  }, skip: skip);
}
