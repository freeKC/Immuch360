// Transport streams for the tests of the media bridge and of m2ts.dart

import 'dart:typed_data';

import 'package:immich_mobile/domain/services/m2ts.dart';

/// A 188 byte TS of [packets] packets, each a sync byte and a pattern of its own
Uint8List tsPackets(int packets) {
  final bytes = Uint8List(packets * tsPacketSize);
  for (var packet = 0; packet < packets; packet++) {
    final at = packet * tsPacketSize;
    bytes[at] = 0x47;
    for (var i = 1; i < tsPacketSize; i++) {
      bytes[at + i] = (packet * 7 + i * 13) & 0xff;
    }
  }
  return bytes;
}

/// [ts] as an M2TS file: a 4 byte timestamp before each packet
Uint8List m2tsOf(Uint8List ts) {
  final packets = ts.length ~/ tsPacketSize;
  final bytes = Uint8List(packets * m2tsPacketSize);
  for (var packet = 0; packet < packets; packet++) {
    final at = packet * m2tsPacketSize;
    bytes.setAll(at, [0x1a, (packet >> 16) & 0xff, (packet >> 8) & 0xff, packet & 0xff]);
    bytes.setRange(at + 4, at + m2tsPacketSize, ts, packet * tsPacketSize);
  }
  return bytes;
}
