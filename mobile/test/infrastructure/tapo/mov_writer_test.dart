// A clip of the test pattern with an A-law tone, demuxed and written as QuickTime, read back by the MP4 reader of the
// app: an avc1 track of 64x36 with its sync samples and durations, a sowt track at 8000 Hz, the date of the clip. With
// IMMUCH_FFPROBE set to the path of ffprobe, ffprobe reads it too.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/infrastructure/tapo/mov_writer.dart';
import 'package:immich_mobile/infrastructure/tapo/mpeg_ts_demuxer.dart';

import 'tapo_test_streams.dart';

void main() {
  late Directory directory;

  setUp(() async => directory = await Directory.systemTemp.createTemp('immuch360-mov'));
  tearDown(() => directory.delete(recursive: true));

  final clipStart = DateTime.utc(2026, 9, 18, 19, 0, 2);

  /// Writes [frames] and their sound as a .mov through the demuxer, the way a fetch does
  File writeClip(List<Uint8List> frames, {int audioWallOffsetMs = 40, String name = 'clip.mov'}) {
    final file = File('${directory.path}/$name');
    final output = file.openSync(mode: FileMode.write);
    final writer = MovWriter(output, creation: clipStart, zoneOffset: const Duration(hours: 2));
    late final MpegTsDemuxer demuxer;
    demuxer = MpegTsDemuxer(
      onVideo: writer.addVideo,
      onAudio: (chunk) {
        writer.audioOffsetSeconds = demuxer.audioOffsetSeconds;
        writer.addAudio(chunk);
      },
    );
    for (final part in clipParts(frames, audioWallOffsetMs: audioWallOffsetMs)) {
      demuxer.feed(part.ts, wallMs: part.wallMs);
    }
    demuxer.flush();
    writer.finish();
    output.closeSync();
    return file;
  }

  Future<SphericalProbe> probe(File file) {
    final bytes = file.readAsBytesSync();
    return probeSphericalMetadata(
      (offset, length) async =>
          Uint8List.sublistView(bytes, offset.clamp(0, bytes.length), (offset + length).clamp(0, bytes.length)),
    );
  }

  /// The boxes of [bytes] from [start] to [end], by path ("moov/trak/mdia/mdhd"), the first of each
  Map<String, (int, int)> boxes(Uint8List bytes, [int start = 0, int? end, String prefix = '']) {
    final found = <String, (int, int)>{};
    final data = ByteData.sublistView(bytes);
    var offset = start;
    final stop = end ?? bytes.length;
    while (offset + 8 <= stop) {
      var size = data.getUint32(offset);
      final type = latin1.decode(bytes.sublist(offset + 4, offset + 8));
      var header = 8;
      if (size == 1) {
        size = data.getUint64(offset + 8);
        header = 16;
      }
      final path = '$prefix$type';
      found.putIfAbsent(path, () => (offset + header, offset + size));
      if (const {'moov', 'trak', 'mdia', 'minf', 'stbl', 'udta', 'edts', 'dinf'}.contains(type)) {
        found.addAll(
          boxes(bytes, offset + header, offset + size, '$path/')..removeWhere((key, _) => found.containsKey(key)),
        );
      }
      offset += size;
    }
    return found;
  }

  test('writes an avc1 video and a sowt sound that the MP4 reader of the app reads', () async {
    final file = writeClip(fixtureAccessUnits());
    final probed = await probe(file);
    expect(probed.codec, 'avc1');
    expect(probed.codedWidth, 64);
    expect(probed.codedHeight, 36);
    expect(probed.frameRate, closeTo(15, 0.01));
    final video = probed.tracks.firstWhere((track) => track.handlerType == 'vide');
    final sound = probed.tracks.firstWhere((track) => track.handlerType == 'soun');
    expect(video.durationMs, 2000);
    expect(sound.codec, 'sowt');
    expect(sound.durationMs, closeTo(2040, 1));
    expect(probed.codecs, startsWith('avc1.64'));
  });

  test('numbers 30 samples with one sync sample, and two for a stream with two key frames', () {
    final frames = fixtureAccessUnits();
    final bytes = writeClip(frames).readAsBytesSync();
    final found = boxes(bytes);
    final data = ByteData.sublistView(bytes);
    final videoStsz = found['moov/trak/mdia/minf/stbl/stsz']!;
    expect(data.getUint32(videoStsz.$1 + 8), 30);
    final stss = found['moov/trak/mdia/minf/stbl/stss']!;
    expect(data.getUint32(stss.$1 + 4), 1);
    expect(data.getUint32(stss.$1 + 8), 1);

    final twice = writeClip([...frames, ...frames], name: 'twice.mov').readAsBytesSync();
    final twiceStss = boxes(twice)['moov/trak/mdia/minf/stbl/stss']!;
    final twiceData = ByteData.sublistView(twice);
    expect(twiceData.getUint32(twiceStss.$1 + 4), 2);
    expect(twiceData.getUint32(twiceStss.$1 + 12), 31);
  });

  test('patches the 64 bit size of mdat and ends with the moov', () {
    final bytes = writeClip(fixtureAccessUnits()).readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    expect(latin1.decode(bytes.sublist(4, 12)), 'ftypqt  ');
    expect(latin1.decode(bytes.sublist(24, 28)), 'mdat');
    expect(data.getUint32(20), 1);
    final mdatSize = data.getUint64(28);
    expect(latin1.decode(bytes.sublist(20 + mdatSize + 4, 20 + mdatSize + 8)), 'moov');
    expect(20 + mdatSize + data.getUint32(20 + mdatSize), bytes.length);
  });

  test('puts the sound after the first frame by the offset of the wall clocks, as silence', () {
    final bytes = writeClip(fixtureAccessUnits(), audioWallOffsetMs: 500).readAsBytesSync();
    final found = boxes(bytes);
    // The second trak is the sound: its sample count holds the 4000 samples of silence
    final moov = found['moov']!;
    final secondTrak = boxes(bytes, moov.$1, moov.$2).entries.where((entry) => entry.key == 'trak').toList();
    expect(secondTrak, hasLength(1));
    final soundStsz = _soundBox(bytes, found, 'stsz');
    final data = ByteData.sublistView(bytes);
    expect(data.getUint32(soundStsz + 4), 2);
    expect(data.getUint32(soundStsz + 8), 16000 + 4000);
  });

  test('carries the start of the clip in the movie header and as ©day in the camera zone', () {
    final bytes = writeClip(fixtureAccessUnits()).readAsBytesSync();
    final found = boxes(bytes);
    final mvhd = found['moov/mvhd']!;
    final data = ByteData.sublistView(bytes);
    expect(data.getUint32(mvhd.$1 + 4), clipStart.millisecondsSinceEpoch ~/ 1000 + 2082844800);
    final day = found['moov/udta/©day']!;
    expect(utf8.decode(bytes.sublist(day.$1 + 4, day.$2)), '2026-09-18T21:00:02+0200');
  });

  test('refuses a stream without a decodable frame', () {
    final file = File('${directory.path}/empty.mov');
    final output = file.openSync(mode: FileMode.write);
    final writer = MovWriter(output, creation: clipStart, zoneOffset: Duration.zero);
    expect(writer.finish, throwsA(isA<MovWriterException>()));
    output.closeSync();
  });

  test('is read by ffprobe when IMMUCH_FFPROBE is set', () async {
    final ffprobe = Platform.environment['IMMUCH_FFPROBE'];
    if (ffprobe == null || ffprobe.isEmpty) {
      markTestSkipped('IMMUCH_FFPROBE is not set');
      return;
    }
    final file = writeClip(fixtureAccessUnits());
    final result = await Process.run(ffprobe, [
      '-v',
      'error',
      '-show_entries',
      'stream=codec_name,width,height,sample_rate,nb_frames',
      '-of',
      'json',
      file.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect('${result.stderr}', isEmpty);
    final streams = (jsonDecode('${result.stdout}') as Map)['streams'] as List;
    expect(streams.map((stream) => (stream as Map)['codec_name']), containsAll(['h264', 'pcm_s16le']));
  });
}

/// The payload start of a box of the second track (the sound)
int _soundBox(Uint8List bytes, Map<String, (int, int)> found, String type) {
  final moov = found['moov']!;
  final data = ByteData.sublistView(bytes);
  var offset = moov.$1;
  var tracks = 0;
  while (offset < moov.$2) {
    final size = data.getUint32(offset);
    if (latin1.decode(bytes.sublist(offset + 4, offset + 8)) == 'trak') {
      tracks++;
      if (tracks == 2) {
        final index = _find(bytes, type, offset, offset + size);
        return index + 8;
      }
    }
    offset += size;
  }
  throw StateError('No second track');
}

int _find(Uint8List bytes, String type, int start, int end) {
  final pattern = latin1.encode(type);
  for (var i = start; i < end - 4; i++) {
    if (bytes[i] == pattern[0] &&
        bytes[i + 1] == pattern[1] &&
        bytes[i + 2] == pattern[2] &&
        bytes[i + 3] == pattern[3]) {
      return i - 4;
    }
  }
  throw StateError('No $type');
}
