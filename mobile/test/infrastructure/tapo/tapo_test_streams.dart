// Synthetic MPEG-TS as the cameras send it (Tapo design 2.7, P§8): PAT, PMT on PID 0x12, H.264 on 0x44, G.711 A-law
// on 0x45, one access unit per part. The same builder as tapo-v4-protocol/tests/test_tapo_media.py, plus the program
// tables and the access units of the test pattern of test/fixtures/tapo.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/infrastructure/tapo/mpeg_ts_demuxer.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';

const videoPid = 0x44;
const audioPid = 0x45;
const pmtPid = 0x12;

/// One 188 byte packet of [payload] (184 bytes at most), padded with an adaptation field
Uint8List tsPacket(int pid, List<int> payload, {bool unitStart = false, int counter = 0}) {
  assert(payload.length <= 184);
  final head = [0x47, (unitStart ? 0x40 : 0) | (pid >> 8), pid & 0xff];
  final stuffing = 184 - payload.length;
  if (stuffing == 0) {
    return Uint8List.fromList([...head, 0x10 | (counter & 0x0f), ...payload]);
  }
  final adaptation = [
    stuffing - 1,
    if (stuffing > 1) ...[0x00, ...List.filled(stuffing - 2, 0xff)],
  ];
  return Uint8List.fromList([...head, 0x30 | (counter & 0x0f), ...adaptation, ...payload]);
}

/// A PES of [streamId] with [pts] (none when null); a video PES says no length, as the cameras' key frames
Uint8List pes(int streamId, int? pts, List<int> data) {
  final header = pts == null
      ? [0x80, 0x00, 0x00]
      : [
          0x80,
          0x80,
          5,
          0x21 | ((pts >> 29) & 0x0e),
          (pts >> 22) & 0xff,
          0x01 | ((pts >> 14) & 0xfe),
          (pts >> 7) & 0xff,
          0x01 | ((pts << 1) & 0xfe),
        ];
  final body = [...header, ...data];
  final length = streamId >= 0xe0 && streamId <= 0xef ? 0 : body.length;
  return Uint8List.fromList([0, 0, 1, streamId, length >> 8, length & 0xff, ...body]);
}

/// The packets of one PES on [pid]
Uint8List packetsOf(int pid, List<int> pesBytes) {
  final out = BytesBuilder();
  for (var i = 0; i < pesBytes.length; i += 184) {
    out.add(tsPacket(pid, pesBytes.sublist(i, min(i + 184, pesBytes.length)), unitStart: i == 0, counter: i ~/ 184));
  }
  return out.takeBytes();
}

Uint8List _section(int tableId, List<int> body) {
  final length = body.length + 4 + 5;
  final section = [tableId, 0xb0 | (length >> 8), length & 0xff, 0x00, 0x01, 0xc1, 0x00, 0x00, ...body];
  final crc = _mpegCrc(section);
  return Uint8List.fromList([0, ...section, crc >> 24, (crc >> 16) & 0xff, (crc >> 8) & 0xff, crc & 0xff]);
}

int _mpegCrc(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte << 24;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x80000000) != 0 ? ((crc << 1) ^ 0x04c11db7) & 0xffffffff : (crc << 1) & 0xffffffff;
    }
  }
  return crc;
}

/// PAT and PMT: H.264 (or [videoType]) on 0x44, A-law (or [audioType]) on 0x45
Uint8List programTables({int videoType = 0x1b, int audioType = 0x90}) {
  final pat = _section(0x00, [0x00, 0x01, 0xe0 | (pmtPid >> 8), pmtPid & 0xff]);
  final pmt = _section(0x02, [
    0xe0 | (videoPid >> 8), videoPid & 0xff, 0xf0, 0x00, // PCR PID, no program info
    videoType, 0xe0 | (videoPid >> 8), videoPid & 0xff, 0xf0, 0x00,
    audioType, 0xe0 | (audioPid >> 8), audioPid & 0xff, 0xf0, 0x00,
  ]);
  return Uint8List.fromList([...tsPacket(0, pat, unitStart: true), ...tsPacket(pmtPid, pmt, unitStart: true)]);
}

/// The access units of the H.264 test pattern (testsrc 64x36, 15 fps, 30 frames, one IDR), each in Annex B with its
/// parameter sets and SEI before the slice they go with
List<Uint8List> fixtureAccessUnits() {
  final stream = File('test/fixtures/tapo/testsrc_64x36.h264').readAsBytesSync();
  final units = <Uint8List>[];
  final pending = BytesBuilder();
  for (final nal in splitAnnexB(stream)) {
    pending
      ..add([0, 0, 0, 1])
      ..add(nal);
    final type = nal[0] & 0x1f;
    if (type == 1 || type == 5) {
      units.add(pending.takeBytes());
    }
  }
  return units;
}

/// One part of the media port: its TS bytes and its wall clock
typedef StreamPart = ({Uint8List ts, int wallMs, bool isKey, bool isAudio});

/// The parts of a clip of [frames] video access units at 15 fps and the A-law sound of the same length in PES of 800
/// samples (100 ms), the program tables before each key frame. [audioPtsOffset] puts the audio PTS clock elsewhere, as
/// the cameras do; [audioWallOffsetMs] is what the wall clock of the parts says of the audio.
List<StreamPart> clipParts(
  List<Uint8List> frames, {
  int basePts = 90000 * 5,
  int audioPtsOffset = 90000 * 2,
  int audioWallOffsetMs = 40,
  int wallStartMs = 1789752472000,
  int videoType = 0x1b,
}) {
  final parts = <StreamPart>[];
  const frameTicks = 90000 ~/ 15;
  final seconds = frames.length / 15;
  final audioChunks = (seconds * 10).round();
  var audioIndex = 0;
  for (var i = 0; i < frames.length; i++) {
    final pts = basePts + i * frameTicks;
    final wall = wallStartMs + i * 1000 ~/ 15;
    final isKey = splitAnnexB(frames[i]).any((nal) => (nal[0] & 0x1f) == 5);
    final ts = BytesBuilder()
      ..add(isKey ? programTables(videoType: videoType) : Uint8List(0))
      ..add(packetsOf(videoPid, pes(0xe0, pts, frames[i])));
    parts.add((ts: ts.takeBytes(), wallMs: wall, isKey: isKey, isAudio: false));
    // The sound up to the time of this frame, 100 ms per PES
    while (audioIndex < audioChunks && audioIndex * 100 <= (i + 1) * 1000 ~/ 15) {
      final samples = toneAlaw(800, startSample: audioIndex * 800);
      final audioPts = basePts + audioPtsOffset + audioIndex * 9000;
      parts.add((
        ts: packetsOf(audioPid, pes(0xc0, audioPts, samples)),
        wallMs: wallStartMs + audioWallOffsetMs + audioIndex * 100,
        isKey: false,
        isAudio: true,
      ));
      audioIndex++;
    }
  }
  return parts;
}

/// [count] A-law samples of a 440 Hz tone at 8 kHz
Uint8List toneAlaw(int count, {int startSample = 0}) => Uint8List.fromList([
  for (var i = 0; i < count; i++) pcm16ToAlaw((sin(2 * pi * 440 * (startSample + i) / 8000) * 8000).round()),
]);
