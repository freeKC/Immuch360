// The demuxer of the cameras' MPEG-TS: fed in pieces not aligned on packets, it gives whole access units with their
// PTS across the 33 bit wrap, the A-law of each PES, and the offset of the sound from the wall clock of the parts.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/tapo/mpeg_ts_demuxer.dart';

import 'tapo_test_streams.dart';

void main() {
  List<TsVideoFrame> video = [];
  List<TsAudioChunk> audio = [];
  late MpegTsDemuxer demuxer;

  setUp(() {
    video = [];
    audio = [];
    demuxer = MpegTsDemuxer(onVideo: video.add, onAudio: audio.add);
  });

  test('gives every access unit and every audio PES, whatever the size of the pieces', () {
    final frames = fixtureAccessUnits();
    final parts = clipParts(frames);
    final stream = BytesBuilder();
    for (final part in parts) {
      stream.add(part.ts);
    }
    final bytes = stream.takeBytes();
    // Deliberately not aligned on packets
    for (var i = 0; i < bytes.length; i += 188 * 7 + 50) {
      demuxer.feed(Uint8List.sublistView(bytes, i, (i + 188 * 7 + 50).clamp(0, bytes.length)));
    }
    demuxer.flush();
    expect(video, hasLength(frames.length));
    expect(video.where((frame) => frame.isKey), hasLength(1));
    expect(video.first.isKey, isTrue);
    expect(video.first.nalUnits.map((nal) => nal[0] & 0x1f), containsAll([7, 8, 5]));
    expect(video[1].pts! - video[0].pts!, 6000);
    expect(audio, hasLength(20));
    expect(audio.every((chunk) => chunk.samples.length == 800 && chunk.codec == TsAudioCodec.alaw), isTrue);
    expect(audio.first.samples, toneAlaw(800));
    expect(demuxer.videoCodec, TsVideoCodec.h264);
  });

  test('places the sound from the wall clock of the parts, not from the TS clocks', () {
    final parts = clipParts(fixtureAccessUnits(), audioPtsOffset: 90000 * 2, audioWallOffsetMs: 40);
    for (final part in parts) {
      demuxer.feed(part.ts, wallMs: part.wallMs);
    }
    expect(demuxer.knowsAudioOffset, isTrue);
    expect(demuxer.audioOffsetSeconds, closeTo(0.040, 1e-9));
  });

  test('clamps an implausible offset of the sound to none, and takes none without wall clocks', () {
    for (final part in clipParts(fixtureAccessUnits(), audioWallOffsetMs: 2213)) {
      demuxer.feed(part.ts, wallMs: part.wallMs);
    }
    expect(demuxer.audioOffsetSeconds, 0);

    final other = MpegTsDemuxer(onVideo: (_) {}, onAudio: (_) {});
    for (final part in clipParts(fixtureAccessUnits())) {
      other.feed(part.ts);
    }
    expect(other.audioOffsetSeconds, 0);
  });

  test('keeps the video PTS growing across the 33 bit wrap', () {
    const nearWrap = (1 << 33) - 6000 * 5;
    for (final part in clipParts(fixtureAccessUnits().take(10).toList(), basePts: nearWrap)) {
      demuxer.feed(part.ts);
    }
    demuxer.flush();
    expect(video, hasLength(10));
    for (var i = 1; i < video.length; i++) {
      expect(video[i].pts! - video[i - 1].pts!, 6000);
    }
    expect(video.last.pts, greaterThan(1 << 33));
  });

  test('takes a key frame PES without a PTS', () {
    final frame = fixtureAccessUnits().first;
    demuxer.feed(Uint8List.fromList([...programTables(), ...packetsOf(videoPid, pes(0xe0, null, frame))]));
    demuxer.flush();
    expect(video.single.pts, isNull);
    expect(video.single.isKey, isTrue);
  });

  test('tells an H.265 stream from its program table', () {
    demuxer.feed(programTables(videoType: 0x24));
    demuxer.feed(packetsOf(videoPid, pes(0xe0, 9000, [0, 0, 0, 1, 0x26, 0x01, 0xaf])));
    demuxer.flush();
    expect(demuxer.videoCodec, TsVideoCodec.h265);
    expect(video.single.isKey, isTrue);
  });

  test('splits Annex B with 3 and 4 byte start codes', () {
    final nalUnits = splitAnnexB(Uint8List.fromList([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4]));
    expect(nalUnits.map((nal) => nal.toList()), [
      [0x67, 1, 2],
      [0x68, 3],
      [0x65, 4],
    ]);
  });
}
