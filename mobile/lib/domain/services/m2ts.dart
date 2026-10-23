// MPEG transport streams with 192 byte packets (M2TS): Blu-ray .m2ts files, AVCHD camcorders (.MTS), the "timestamped"
// TS of DLNA servers and the recordings of many TV boxes put a 4 byte arrival timestamp before each 188 byte packet.
// Media3, the player of Android, reads 188 byte packets only (its TS extractor looks for a sync byte every 188 bytes)
// and refuses such a file with "None of the available extractors could read the stream". The media bridge serves it
// as the 188 byte TS it holds: the timestamps left out, the offsets and the size mapped, with ranges.

import 'dart:math';
import 'dart:typed_data';

/// The bytes of a packet in the file, and in the stream served
const m2tsPacketSize = 192;
const tsPacketSize = 188;

/// The 4 byte arrival timestamp before each packet of an M2TS file
const _timestampSize = m2tsPacketSize - tsPacketSize;

const _syncByte = 0x47;

/// Packets whose sync bytes [isM2tsHead] checks
const _checkedPackets = 5;

/// The bytes of the head of a file that [isM2tsHead] needs
const m2tsSniffLength = m2tsPacketSize * _checkedPackets;

/// Whether [head], the first bytes of a file, is an MPEG-TS with 192 byte packets: a sync byte after the 4 byte
/// timestamp of each of the first packets. A TS with 188 byte packets, whose own sync bytes come every 188 bytes from
/// the start, is not one. False for a head shorter than [m2tsSniffLength].
bool isM2tsHead(Uint8List head) {
  if (head.length < m2tsSniffLength) {
    return false;
  }
  bool syncedEvery(int packetSize, int offset) =>
      Iterable<int>.generate(_checkedPackets).every((packet) => head[offset + packet * packetSize] == _syncByte);
  return !syncedEvery(tsPacketSize, 0) && syncedEvery(m2tsPacketSize, _timestampSize);
}

/// Whether the bridge should look at the head of a file named with [extension] and typed [mimeType] for 192 byte
/// packets: the names and types of transport streams
bool mayBeM2ts(String extension, String mimeType) =>
    const {'mts', 'm2ts', 'm2t', 'ts', 'tod'}.contains(extension) ||
    const {'video/mp2t', 'video/vnd.dlna.mpeg-tts', 'video/m2ts', 'video/mts'}.contains(mimeType);

/// The size of the 188 byte packet TS that an M2TS file of [fileSize] bytes holds (an incomplete last packet left out)
int tsSizeOfM2ts(int fileSize) => fileSize ~/ m2tsPacketSize * tsPacketSize;

/// The bytes of an M2TS file to read for the bytes [start] to [end] (excluded) of the TS it holds: whole packets, the
/// first one at a packet boundary of the file, within [fileSize]
({int start, int end}) m2tsFileRange(int start, int end, int fileSize) => (
  start: start ~/ tsPacketSize * m2tsPacketSize,
  end: min(fileSize, ((end - 1) ~/ tsPacketSize + 1) * m2tsPacketSize),
);

/// Turns the bytes of an M2TS file read from a packet boundary, chunk by chunk as they come, into the bytes of the TS
/// it holds: the timestamp before each packet left out, then the first [skip] bytes dropped (where the range asked
/// starts in its first packet) and [length] bytes kept.
class M2tsToTs {
  M2tsToTs({required int skip, required int length}) : _skip = skip, _left = length;

  /// Where the next byte of the file is in its packet
  int _offset = 0;
  int _skip;
  int _left;

  /// Whether [length] bytes were given
  bool get isDone => _left <= 0;

  /// The TS bytes of [chunk], the next bytes of the file; empty once [length] bytes were given
  Uint8List convert(List<int> chunk) {
    final out = Uint8List(min(chunk.length, max(_left, 0)));
    var written = 0;
    var i = 0;
    while (i < chunk.length && _left > 0) {
      if (_offset < _timestampSize) {
        final timestamp = min(_timestampSize - _offset, chunk.length - i);
        i += timestamp;
        _offset += timestamp;
        continue;
      }
      final inPacket = min(m2tsPacketSize - _offset, chunk.length - i);
      var from = i;
      var count = inPacket;
      if (_skip > 0) {
        final skipped = min(_skip, count);
        _skip -= skipped;
        from += skipped;
        count -= skipped;
      }
      count = min(count, _left);
      out.setRange(written, written + count, chunk, from);
      written += count;
      _left -= count;
      i += inPacket;
      _offset = (_offset + inPacket) % m2tsPacketSize;
    }
    return Uint8List.sublistView(out, 0, written);
  }
}
