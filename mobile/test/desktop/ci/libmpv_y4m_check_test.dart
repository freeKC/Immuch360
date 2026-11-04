// The y4m check of the macOS libmpv (.github/desktop/libmpv-macos/check_y4m.py): its fixtures are y4m as the AV2
// decoder writes them, a report of a libmpv that reads them passes every check, and the reports of a libmpv without
// the demuxer, of 10 bit read as 8, of a seek to the wrong frame, of a seek read through instead of asked for, or of a
// dropped frame fail. The probe itself needs a libmpv: the workflows run it (immuch360-libmpv.yml on the frameworks it
// builds, immuch360-desktop.yml on those of the app).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _script = 'libmpv-macos/check_y4m.py';

// The fixture as check_y4m.py makes it: 320x180, 32 frames at 16 per second, frame k one grey of luma 16 + 6k
const _width = 320;
const _height = 180;
const _frames = 32;
const _fps = 16;

int _frameSize(int depth) => _width * _height * 3 ~/ 2 * (depth == 8 ? 1 : 2);

String _header(int depth) =>
    'YUV4MPEG2 W$_width H$_height F$_fps:1 Ip A1:1 ${depth == 8 ? 'C420' : 'C420p10'} XCOLORRANGE=LIMITED\n';

int _frameOffset(int depth, int frame) => _header(depth).length + frame * (6 + _frameSize(depth));

/// The grey on screen of frame [frame]: its limited range luma in full range RGB
double _grey(int frame) => 6 * frame * 255 / 219;

Map<String, Object?> _frame(double grey) => {
  'w': _width,
  'h': _height,
  'bgr': [grey, grey, grey],
};

/// The report of y4m_probe.c for a libmpv that reads the fixture of [depth] bits
Map<String, Object?> _goodReport(int depth) => {
  'source': '/tmp/fixture-${depth}bit.y4m',
  'mpv-version': 'mpv v0.41.0',
  'file-format': 'yuv4mpegpipe',
  'current-tracks/video/codec': 'rawvideo',
  'video-params/pixelformat': depth == 8 ? 'yuv420p' : 'yuv420p10',
  'video-params/w': '$_width',
  'video-params/h': '$_height',
  'container-fps': 16.0,
  'duration': 2.0,
  'estimated-frame-count': '$_frames',
  'firstTime': 0.0,
  'firstFrame': _frame(_grey(0)),
  'forwardTime': 1.5,
  'forwardFrame': _frame(_grey(24) + 0.4),
  'backTime': 0.5,
  'backFrame': _frame(_grey(8) - 0.3),
  'endTime': 1.9375,
  'frame-drop-count': '0',
  'decoder-frame-drop-count': '0',
  'error': null,
  'log': '',
};

/// The report of y4m_probe.c for the serve of an AV2 companion: the 1080p clip of the CI played five times (300
/// pictures at 30 a second), read with the options of the app, seeks to pictures 210 and 60
Map<String, Object?> _companionReport() => {
  'source': 'http://127.0.0.1:50123/TOKEN/video.y4m',
  'forcedFormat': 'yuv4mpegpipe',
  'file-format': 'yuv4mpegpipe',
  'current-tracks/video/codec': 'rawvideo',
  'video-params/pixelformat': 'yuv420p',
  'video-params/w': '1920',
  'video-params/h': '1080',
  'container-fps': 30.0,
  'duration': 10.0,
  'openSeconds': 0.065,
  'firstTime': 0.0,
  'firstFrame': {
    'w': 1920,
    'h': 1080,
    'bgr': [120.0, 96.0, 80.0],
  },
  'forwardTime': 7.0,
  'forwardFrame': {
    'w': 1920,
    'h': 1080,
    'bgr': [100.0, 90.0, 70.0],
  },
  'backTime': 2.0,
  'backFrame': {
    'w': 1920,
    'h': 1080,
    'bgr': [110.0, 95.0, 75.0],
  },
  'playFrom': 2.0,
  'playSeconds': 1.55,
  'endTime': 9.966667,
  'frame-drop-count': '0',
  'decoder-frame-drop-count': '0',
  'error': null,
  'log': '',
};

void main() {
  group('y4m check of the macOS libmpv', _tests, skip: skipCiScripts);
  group('the AV2 path through the libmpv of the app (review of lot AD4, m8)', _companionTests, skip: skipCiScripts);
}

void _companionTests() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('libmpv_av2_path_check'));
  tearDown(() => folder.deleteSync(recursive: true));

  ScriptRun evaluate(Map<String, Object?> report) {
    final file = File(p.join(folder.path, 'report.json'))..writeAsStringSync(jsonEncode(report));
    return runCiScript(_script, [
      'evaluate-companion',
      file.path,
      '--width',
      '1920',
      '--height',
      '1080',
      '--depth',
      '8',
      '--frames',
      '300',
      '--fps',
      '30',
      '--forward',
      '210',
      '--back',
      '60',
    ]);
  }

  test('a libmpv that reads the 1080p stream of the companion with the options of the app passes, with its speed', () {
    final run = evaluate(_companionReport());
    expect(run.exitCode, 0, reason: '$run');
    expect(run.output, isNot(contains('FAILED')));
    // 240 pictures from 2.0 s to its last one, at 9.97 s, in 1.55 s
    expect(run.output, contains('passed: frames a second of the untimed playback (154.8 for 30 needed)'));
  });

  test('a seek that lands on another picture, a stop before the end or a dropped picture fails', () {
    final seek = evaluate({..._companionReport(), 'backTime': 1.9});
    expect(seek.exitCode, 1);
    expect(seek.output, contains('FAILED: exact seek back: frame 60'));
    final stopped = evaluate({..._companionReport(), 'endTime': 5.0});
    expect(stopped.output, contains('FAILED: played to the last frame, none dropped'));
    final dropped = evaluate({..._companionReport(), 'decoder-frame-drop-count': '1'});
    expect(dropped.exitCode, 1);
    expect(dropped.output, contains('FAILED: played to the last frame, none dropped'));
  });

  test('a libmpv without the y4m demuxer, or a stream of another size, fails', () {
    final missing = evaluate({
      'source': 'http://127.0.0.1:50123/TOKEN/video.y4m',
      'error': 'unrecognized file format',
      'log': '[error] ffmpeg/demuxer: Requested format yuv4mpegpipe not found',
    });
    expect(missing.exitCode, 1);
    expect(missing.output, contains('FAILED: demuxer yuv4mpegpipe'));
    expect(missing.output, contains('FAILED: frames a second of the untimed playback (not measured)'));
    final smaller = evaluate({..._companionReport(), 'video-params/w': '1280', 'video-params/h': '720'});
    expect(smaller.output, contains('FAILED: size 1920x1080 (1280x720)'));
  });

  test('the macOS job reads the serve of the av2-macos archive on a fixture and the 1080p clip of the CI', () {
    final workflow = File(
      p.join(repositoryRoot, '.github', 'workflows', 'immuch360-desktop.yml'),
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final start = workflow.indexOf('\n  macos:\n');
    final end = workflow.indexOf(RegExp(r'\n  [a-z0-9-]+:\n'), start + 1);
    final job = workflow.substring(start, end);
    expect(job, contains('needs: [codegen, av2-macos]'));
    expect(job, contains('check_y4m.py companion'));
    expect(job, contains('mobile/test/fixtures/av2/av2-256x144-10bit.ivf'));
    expect(job, contains('.github/desktop/av2/clips/lighthouse-1080p30-8bit-60f.ivf:5'));
    expect(File(p.join(ciScriptsDir, 'av2', 'clips', 'lighthouse-1080p30-8bit-60f.ivf')).lengthSync(), 376066);
  });

  test('the probe takes the options of the app after its own and times the first frame and the playback', () {
    final source = File(p.join(ciScriptsDir, 'libmpv-macos', 'y4m_probe.c')).readAsStringSync();
    expect(source, contains('[FORMAT [OPTION=VALUE...]]'));
    for (final key in ['"openSeconds"', '"playSeconds"', '"playFrom"']) {
      expect(source, contains(key));
    }
  });
}

void _tests() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('libmpv_y4m_check'));
  tearDown(() => folder.deleteSync(recursive: true));

  ScriptRun evaluate(Map<String, Object?> report, {required int depth, List<int>? ranges}) {
    final file = File(p.join(folder.path, 'report.json'))..writeAsStringSync(jsonEncode(report));
    return runCiScript(_script, [
      'evaluate',
      file.path,
      '--depth',
      '$depth',
      if (ranges != null) ...['--http', '--ranges', for (final start in ranges) '$start'],
    ]);
  }

  for (final depth in [8, 10]) {
    test('the $depth bit fixture is a y4m as the AV2 decoder writes it, frame k one grey', () {
      final out = p.join(folder.path, 'fixture.y4m');
      final run = runCiScript(_script, ['fixture', out, '--depth', '$depth']);
      expect(run.exitCode, 0, reason: '$run');
      final bytes = File(out).readAsBytesSync();
      expect(bytes.length, _frameOffset(depth, _frames));
      expect(ascii.decode(bytes.sublist(0, _header(depth).length)), _header(depth));
      for (final frame in [0, 8, 24, _frames - 1]) {
        final start = _frameOffset(depth, frame);
        expect(ascii.decode(bytes.sublist(start, start + 6)), 'FRAME\n', reason: 'frame $frame');
        final data = ByteData.sublistView(bytes, start + 6);
        const lumaSamples = _width * _height;
        if (depth == 8) {
          expect(data.getUint8(0), 16 + 6 * frame);
          expect(data.getUint8(lumaSamples - 1), 16 + 6 * frame);
          expect(data.getUint8(lumaSamples), 128, reason: 'chroma at the middle');
        } else {
          expect(data.getUint16(0, Endian.little), (16 + 6 * frame) * 4);
          expect(data.getUint16((lumaSamples - 1) * 2, Endian.little), (16 + 6 * frame) * 4);
          expect(data.getUint16(lumaSamples * 2, Endian.little), 512, reason: 'chroma at the middle');
        }
      }
    });

    test('a $depth bit report of a libmpv that reads it passes every check, from a file and over HTTP', () {
      final file = evaluate(_goodReport(depth), depth: depth);
      expect(file.exitCode, 0, reason: '$file');
      expect(file.output, isNot(contains('FAILED')));
      // The seek back of FFmpeg's demuxer starts one frame before the target
      final http = evaluate(_goodReport(depth), depth: depth, ranges: [0, _frameOffset(depth, 7)]);
      expect(http.exitCode, 0, reason: '$http');
      expect(http.output, contains('passed: over HTTP, the seek back asked for a range from a frame'));
    });
  }

  test('a libmpv without the y4m demuxer fails', () {
    final run = evaluate({
      'source': 'http://127.0.0.1:50000/fixture-8bit.y4m',
      'error': 'unrecognized file format',
      'log': '[error] ffmpeg/demuxer: Requested format yuv4mpegpipe not found',
    }, depth: 8);
    expect(run.exitCode, 1);
    expect(run.output, contains('FAILED: opened and played (unrecognized file format)'));
    expect(run.output, contains('FAILED: demuxer yuv4mpegpipe'));
    expect(run.output, contains('FAILED: decoder rawvideo'));
  });

  test('10 bit read as 8 bit fails', () {
    final run = evaluate({
      ..._goodReport(10),
      'video-params/pixelformat': 'yuv420p',
      'firstFrame': _frame(37),
    }, depth: 10);
    expect(run.exitCode, 1);
    expect(run.output, contains('FAILED: pixel format yuv420p10'));
    expect(run.output, contains('FAILED: first frame: frame 0'));
  });

  test('a seek that shows the frame before the one asked for fails', () {
    final run = evaluate({..._goodReport(8), 'forwardFrame': _frame(_grey(23))}, depth: 8);
    expect(run.exitCode, 1);
    expect(run.output, contains('FAILED: exact seek forward: frame 24'));
    expect(run.output, contains('passed: exact seek back: frame 8'));
  });

  test('a frame that is not grey fails', () {
    final run = evaluate({
      ..._goodReport(8),
      'backFrame': {
        'w': _width,
        'h': _height,
        'bgr': [_grey(8), _grey(8) + 20, _grey(8)],
      },
    }, depth: 8);
    expect(run.exitCode, 1);
    expect(run.output, contains('FAILED: exact seek back: frame 8'));
  });

  test('over HTTP, a seek back read from the start of the stream fails', () {
    final run = evaluate(_goodReport(8), depth: 8, ranges: [0]);
    expect(run.exitCode, 1);
    expect(run.output, contains('FAILED: over HTTP, the seek back asked for a range from a frame'));
  });

  test('a playback that stopped early or dropped a frame fails', () {
    final stopped = evaluate({..._goodReport(8), 'endTime': 1.0}, depth: 8);
    expect(stopped.exitCode, 1);
    expect(stopped.output, contains('FAILED: played to the last frame, none dropped'));
    final dropped = evaluate({..._goodReport(10), 'decoder-frame-drop-count': '2'}, depth: 10);
    expect(dropped.exitCode, 1);
    expect(dropped.output, contains('FAILED: played to the last frame, none dropped'));
  });
}
