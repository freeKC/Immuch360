// The H.264 RTP stream of a camera put back into access units: single NAL unit packets, STAP-A, FU-A, the RTP header
// with CSRC, extension and padding, a lost packet dropping what follows up to the next IDR picture, the marker and
// the timestamp telling where a picture ends.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/tapo/rtp_h264.dart';

import 'rtp_test_streams.dart';

void main() {
  List<H264AccessUnit> depacketize(Iterable<Uint8List> packets, {H264Depacketizer? into}) {
    final units = <H264AccessUnit>[];
    final depacketizer = into ?? H264Depacketizer(units.add);
    for (final data in packets) {
      depacketizer.add(RtpPacket.parse(data)!);
    }
    return units;
  }

  group('RtpPacket', () {
    test('reads the header and the payload', () {
      final packet = RtpPacket.parse(
        rtpPacket(sequence: 0xfffe, timestamp: 0xfffffff0, payload: [1, 2, 3], marker: true, payloadType: 8),
      )!;
      expect(packet.marker, isTrue);
      expect(packet.payloadType, 8);
      expect(packet.sequence, 0xfffe);
      expect(packet.timestamp, 0xfffffff0);
      expect(packet.payload, [1, 2, 3]);
    });

    test('skips the CSRC list and the extension, drops the padding', () {
      final packet = RtpPacket.parse(
        rtpPacket(sequence: 1, timestamp: 2, payload: [9, 8, 7], csrcCount: 2, extension: [1, 2, 3, 4], padding: 3),
      )!;
      expect(packet.payload, [9, 8, 7]);
    });

    test('refuses what is not RTP version 2 or is cut short', () {
      expect(RtpPacket.parse(Uint8List(11)), isNull);
      final packet = rtpPacket(sequence: 1, timestamp: 2, payload: [1]);
      packet[0] = 0x40;
      expect(RtpPacket.parse(packet), isNull);
      final padded = rtpPacket(sequence: 1, timestamp: 2, payload: [], padding: 4);
      padded[padded.length - 1] = 40;
      expect(RtpPacket.parse(padded), isNull);
      final extended = rtpPacket(sequence: 1, timestamp: 2, payload: [], extension: [1, 2, 3, 4]);
      expect(RtpPacket.parse(Uint8List.sublistView(extended, 0, 14)), isNull);
    });
  });

  group('H264Depacketizer', () {
    test('gives back the access units of the test pattern, through STAP-A and FU-A', () {
      final source = fixtureNalUnits();
      final units = depacketize(h264RtpPackets(source, mtu: 200));
      expect(units, hasLength(source.length));
      for (var i = 0; i < source.length; i++) {
        expect(units[i].timestamp, 3000000 + i * 6000);
        expect(units[i].nals, source[i], reason: 'access unit $i');
      }
      expect(units.first.isIdr, isTrue);
      expect(units.skip(1).where((unit) => unit.isIdr), isEmpty);
    });

    test('ends a picture at the marker, or when the timestamp changes without one', () {
      final units = depacketize([
        rtpPacket(sequence: 1, timestamp: 100, payload: [0x65, 1]),
        rtpPacket(sequence: 2, timestamp: 100, payload: [0x65, 2]),
        rtpPacket(sequence: 3, timestamp: 200, payload: [0x41, 3], marker: true),
        rtpPacket(sequence: 4, timestamp: 300, payload: [0x41, 4], marker: true),
      ]);
      expect([for (final unit in units) unit.timestamp], [100, 200, 300]);
      expect(units.first.nals, [
        [0x65, 1],
        [0x65, 2],
      ]);
    });

    test('a lost packet drops the pictures up to the next IDR picture', () {
      final source = fixtureNalUnits(loops: 2);
      final packets = h264RtpPackets(source, mtu: 200);
      // The fifth picture (one packet) goes missing
      var index = 0;
      for (var unit = 0; unit < 4; unit++) {
        index += h264Payloads(source[unit], mtu: 200).length;
      }
      expect(h264Payloads(source[4], mtu: 200), hasLength(1));
      packets.removeAt(index);
      final units = <H264AccessUnit>[];
      final depacketizer = H264Depacketizer(units.add);
      depacketize(packets, into: depacketizer);
      expect(depacketizer.lost, 1);
      // The first four pictures, then nothing until the IDR picture of the second loop
      expect(units, hasLength(4 + 30));
      expect(units[4].isIdr, isTrue);
      expect(units[4].timestamp, 3000000 + 30 * 6000);
      expect(depacketizer.dropped, 25);
    });

    test('a damaged IDR picture is dropped too', () {
      final source = fixtureNalUnits(loops: 2);
      final packets = h264RtpPackets(source, mtu: 50);
      // A middle fragment of the first IDR picture: the parameter sets came whole, the slice did not
      packets.removeAt(3);
      final units = <H264AccessUnit>[];
      depacketize(packets, into: H264Depacketizer(units.add));
      expect(units.first.isIdr, isTrue);
      expect(units.first.timestamp, 3000000 + 30 * 6000);
    });

    test('a fragment whose start was lost, or without its end, drops its picture', () {
      final units = <H264AccessUnit>[];
      final depacketizer = H264Depacketizer(units.add);
      // An FU-A middle with no start, then an FU-A start whose end never comes before the next timestamp
      depacketizer
        ..add(RtpPacket.parse(rtpPacket(sequence: 1, timestamp: 100, payload: [0x7c, 0x05, 1], marker: true))!)
        ..add(RtpPacket.parse(rtpPacket(sequence: 2, timestamp: 200, payload: [0x7c, 0x85, 1]))!)
        ..add(RtpPacket.parse(rtpPacket(sequence: 3, timestamp: 300, payload: [0x65, 9], marker: true))!);
      expect(units, hasLength(1));
      expect(units.single.timestamp, 300);
      expect(units.single.nals.single, [0x65, 9]);
    });

    test('follows the sequence numbers across their wrap', () {
      final source = fixtureNalUnits();
      final units = depacketize(h264RtpPackets(source, sequence: 0xfff0, timestamp: 0xffffff00));
      expect(units, hasLength(source.length));
    });
  });
}
