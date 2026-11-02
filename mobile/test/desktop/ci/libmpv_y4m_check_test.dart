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

void main() {
  group('y4m check of the macOS libmpv', _tests, skip: skipCiScripts);
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
