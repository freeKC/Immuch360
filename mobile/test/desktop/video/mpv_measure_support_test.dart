import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'mpv_measure_support.dart';

void main() {
  group('MpvLogFilter', () {
    test('keeps the renderer and decoder lines, drops the rest', () {
      final logs = MpvLogFilter()
        ..addText("libmpv_render: GL_VERSION='OpenGL ES 3.0.0 (ANGLE 2.1.18844)'")
        ..addText('cplayer: Set property: start="none" -> 1')
        ..addText('vd: Using hardware decoding (d3d11va).')
        ..addText('libmpv_render: No advanced processing required. Enabling dumb mode.');
      expect(logs.lines, hasLength(3));
      expect(logs.firstWith('GL_VERSION'), contains('OpenGL ES 3.0.0'));
      expect(logs.markers['dumb mode'], 1);
    });

    test('never keeps a URL, an absolute path or a given secret', () {
      final logs = MpvLogFilter(secrets: ['nas.example', 'hunter22'], keepAll: true)
        ..addText('cplayer: Opening failed or was aborted: http://127.0.0.1:41000/Zq8tokenzz/smb-1/clip.mp4')
        ..addText("cplayer: Opening failed or was aborted: 'D:\\Users\\Someone\\Videos\\clip.mp4'")
        ..addText('cplayer: Opening /home/someone/clips/clip.mp4')
        ..addText('stream: rtsp://admin:pw@192.168.1.20:554/stream1 error')
        ..addText('ffmpeg: connecting to nas.example with hunter22');
      final text = logs.lines.join('\n');
      for (final leak in ['Zq8tokenzz', 'Someone', 'someone', 'admin:pw', '192.168.1.20', 'nas.example', 'hunter22']) {
        expect(text, isNot(contains(leak)));
      }
      expect(text, contains('<url>'));
      expect(text, contains('<path>'));
      expect(text, contains('<named>'));
    });

    test('scrub redacts whatever the text says', () {
      expect(
        MpvLogFilter.scrub('Failed to open https://server.example/api/assets/1/original?key=abc'),
        'Failed to open <url>',
      );
    });

    test('stops keeping lines past its limit and counts them', () {
      final logs = MpvLogFilter(maxLines: 2);
      for (var i = 0; i < 5; i++) {
        logs.addText('vd: decoder error $i');
      }
      expect(logs.lines, hasLength(2));
      expect(logs.dropped, 3);
    });
  });

  test('the reference AVI has the RIFF layout and the size of its raw I420 frames', () async {
    final folder = await Directory.systemTemp.createTemp('immuch360_avi_');
    addTearDown(() => folder.delete(recursive: true));
    final file = await aviReference(folder, width: 64, height: 32, frames: 3, fps: 30);
    final bytes = await file.readAsBytes();
    final data = ByteData.sublistView(bytes);
    String fourcc(int offset) => String.fromCharCodes(bytes.sublist(offset, offset + 4));
    expect(fourcc(0), 'RIFF');
    expect(data.getUint32(4, Endian.little), bytes.length - 8);
    expect(fourcc(8), 'AVI ');
    expect(fourcc(12), 'LIST');
    expect(fourcc(20), 'hdrl');
    const frameSize = 64 * 32 * 3 ~/ 2;
    // RIFF header 12, hdrl list 12 + 56 + 8 (avih) + 12 + 56 + 8 + 40 + 8 (strl), movi list 12, frames, idx1 8 + 16 a frame
    expect(bytes.length, 12 + (12 + 64 + 12 + 64 + 48) + 12 + 3 * (8 + frameSize) + 8 + 3 * 16);
    expect(String.fromCharCodes(bytes), contains('00dc'));
    expect(String.fromCharCodes(bytes), contains('idx1'));
  });
}
