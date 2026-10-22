// RTP as the cameras send it on their RTSP port: the H.264 test pattern of test/fixtures/tapo in single NAL unit
// packets, STAP-A and FU-A (RFC 6184), and the A-law tone in packets of 1024 samples. Synthetic only.

import 'dart:typed_data';

import 'package:immich_mobile/infrastructure/tapo/mpeg_ts_demuxer.dart';

import 'tapo_test_streams.dart';

/// One RTP packet (RFC 3550) of [payload]
Uint8List rtpPacket({
  required int sequence,
  required int timestamp,
  required List<int> payload,
  bool marker = false,
  int payloadType = 96,
  int csrcCount = 0,
  List<int>? extension,
  int padding = 0,
}) {
  final out = BytesBuilder()
    ..add([
      0x80 | (padding > 0 ? 0x20 : 0) | (extension != null ? 0x10 : 0) | csrcCount,
      (marker ? 0x80 : 0) | payloadType,
      (sequence >> 8) & 0xff,
      sequence & 0xff,
      (timestamp >> 24) & 0xff,
      (timestamp >> 16) & 0xff,
      (timestamp >> 8) & 0xff,
      timestamp & 0xff,
      0x12, 0x34, 0x56, 0x78, // SSRC
    ]);
  for (var i = 0; i < csrcCount; i++) {
    out.add([0, 0, 0, i]);
  }
  if (extension != null) {
    assert(extension.length % 4 == 0);
    out.add([0xbe, 0xde, (extension.length ~/ 4) >> 8, (extension.length ~/ 4) & 0xff, ...extension]);
  }
  out.add(payload);
  if (padding > 0) {
    out.add([...List.filled(padding - 1, 0), padding]);
  }
  return out.takeBytes();
}

/// The payloads of one access unit: a single NAL unit packet per small NAL unit, the parameter sets together in a
/// STAP-A when [aggregate], FU-A fragments of at most [mtu] bytes for a large one
List<Uint8List> h264Payloads(List<Uint8List> nals, {int mtu = 1000, bool aggregate = true}) {
  final payloads = <Uint8List>[];
  var rest = nals;
  if (aggregate) {
    final sets = nals.takeWhile((nal) => const {6, 7, 8}.contains(nal[0] & 0x1f)).toList();
    if (sets.length > 1) {
      final stap = BytesBuilder()..addByte((sets.first[0] & 0x60) | 24);
      for (final nal in sets) {
        stap
          ..add([nal.length >> 8, nal.length & 0xff])
          ..add(nal);
      }
      payloads.add(stap.takeBytes());
      rest = nals.sublist(sets.length);
    }
  }
  for (final nal in rest) {
    if (nal.length <= mtu) {
      payloads.add(nal);
      continue;
    }
    final indicator = (nal[0] & 0xe0) | 28;
    final type = nal[0] & 0x1f;
    for (var offset = 1; offset < nal.length; offset += mtu) {
      final end = offset + mtu >= nal.length;
      payloads.add(
        Uint8List.fromList([
          indicator,
          (offset == 1 ? 0x80 : 0) | (end ? 0x40 : 0) | type,
          ...nal.sublist(offset, end ? nal.length : offset + mtu),
        ]),
      );
    }
  }
  return payloads;
}

/// The access units of the H.264 test pattern (64x36, 15 fps, an IDR picture every 30), as NAL units, repeated
/// [loops] times: 2 s per loop
List<List<Uint8List>> fixtureNalUnits({int loops = 1}) {
  final units = [for (final unit in fixtureAccessUnits()) splitAnnexB(unit)];
  return [for (var i = 0; i < loops; i++) ...units];
}

/// The video of [units] as RTP packets at 15 fps from [timestamp] and [sequence], the marker on the last packet of
/// each access unit
List<Uint8List> h264RtpPackets(
  List<List<Uint8List>> units, {
  int sequence = 1000,
  int timestamp = 3000000,
  int mtu = 1000,
}) {
  final packets = <Uint8List>[];
  var next = sequence;
  for (var i = 0; i < units.length; i++) {
    final payloads = h264Payloads(units[i], mtu: mtu);
    for (var j = 0; j < payloads.length; j++) {
      packets.add(
        rtpPacket(
          sequence: next++ & 0xffff,
          timestamp: (timestamp + i * 6000) & 0xffffffff,
          payload: payloads[j],
          marker: j == payloads.length - 1,
        ),
      );
    }
  }
  return packets;
}

/// [seconds] of the A-law tone as RTP packets of 1024 samples (payload type 8), from [timestamp]
List<Uint8List> alawRtpPackets(double seconds, {int sequence = 500, int timestamp = 160000}) {
  final count = (seconds * 8000 / 1024).ceil();
  return [
    for (var i = 0; i < count; i++)
      rtpPacket(
        sequence: (sequence + i) & 0xffff,
        timestamp: (timestamp + i * 1024) & 0xffffffff,
        payload: toneAlaw(1024, startSample: i * 1024),
        payloadType: 8,
        marker: i == 0,
      ),
  ];
}

/// The packets of the video (90 kHz, from [videoTimestamp]) and of the sound (8 kHz, from [audioTimestamp]) in the
/// order of their times, each on its interleaved channel (0 and 2), as a camera sends them
List<(int, Uint8List)> interleaveByTime(
  List<Uint8List> video,
  List<Uint8List> audio, {
  int videoTimestamp = 3000000,
  int audioTimestamp = 160000,
}) {
  int timestampOf(Uint8List packet) => (packet[4] << 24) | (packet[5] << 16) | (packet[6] << 8) | packet[7];
  final timed = [
    for (final packet in video) ((timestampOf(packet) - videoTimestamp) / 90000, 0, packet),
    for (final packet in audio) ((timestampOf(packet) - audioTimestamp) / 8000, 2, packet),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, channel, packet) in timed) (channel, packet)];
}
