// The RTP packets of a camera's live stream (RFC 3550) and its H.264 video put back together into access units
// (RFC 6184: single NAL unit packets, STAP-A and FU-A, the packetization modes 0 and 1 the cameras use). A lost packet
// drops what follows up to the next IDR picture, so that the player never gets a broken picture to decode.

import 'dart:typed_data';

/// One RTP packet: its header fields and its payload (without CSRC, extension and padding)
class RtpPacket {
  const RtpPacket({
    required this.marker,
    required this.payloadType,
    required this.sequence,
    required this.timestamp,
    required this.payload,
  });

  final bool marker;
  final int payloadType;
  final int sequence;

  /// On the clock of the track, 32 bits
  final int timestamp;
  final Uint8List payload;

  /// The packet in [data], null when it is not RTP version 2 or is cut short
  static RtpPacket? parse(Uint8List data) {
    if (data.length < 12 || (data[0] >> 6) != 2) {
      return null;
    }
    final padding = (data[0] & 0x20) != 0;
    final extension = (data[0] & 0x10) != 0;
    var offset = 12 + 4 * (data[0] & 0x0f);
    if (extension) {
      if (data.length < offset + 4) {
        return null;
      }
      offset += 4 + 4 * ((data[offset + 2] << 8) | data[offset + 3]);
    }
    var end = data.length;
    if (padding) {
      end -= data[end - 1];
    }
    if (offset > end) {
      return null;
    }
    return RtpPacket(
      marker: (data[1] & 0x80) != 0,
      payloadType: data[1] & 0x7f,
      sequence: (data[2] << 8) | data[3],
      timestamp: (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7],
      payload: Uint8List.sublistView(data, offset, end),
    );
  }
}

/// The NAL units of one picture, at its RTP time (90 kHz)
class H264AccessUnit {
  const H264AccessUnit(this.timestamp, this.nals);

  final int timestamp;

  /// The NAL units, header byte included, without start codes
  final List<Uint8List> nals;

  /// Whether it holds an IDR picture, where decoding can start
  bool get isIdr => nals.any((nal) => nal.isNotEmpty && (nal[0] & 0x1f) == 5);
}

/// Puts the H.264 RTP packets back into access units, handed to [onAccessUnit] in order
class H264Depacketizer {
  H264Depacketizer(this.onAccessUnit);

  final void Function(H264AccessUnit unit) onAccessUnit;

  int? _lastSequence;
  int? _timestamp;
  final List<Uint8List> _nals = [];
  BytesBuilder? _fragment;

  /// The access unit being read lost a packet
  bool _damaged = false;

  /// A packet was lost: nothing goes out until the next whole IDR picture
  bool _waitingForIdr = false;

  /// Packets missing from the sequence numbers so far
  int lost = 0;

  /// Access units dropped while waiting for an IDR picture, or damaged
  int dropped = 0;

  void add(RtpPacket packet) {
    final last = _lastSequence;
    if (last != null && packet.sequence != (last + 1) & 0xffff) {
      lost += (packet.sequence - last - 1) & 0xffff;
      _damaged = true;
      _waitingForIdr = true;
      _fragment = null;
    }
    _lastSequence = packet.sequence;
    if (_timestamp != null && packet.timestamp != _timestamp) {
      _emit();
    }
    _timestamp = packet.timestamp;
    final data = packet.payload;
    if (data.isNotEmpty) {
      _read(data);
    }
    if (packet.marker) {
      _emit();
    }
  }

  void _read(Uint8List data) {
    final type = data[0] & 0x1f;
    if (type >= 1 && type <= 23) {
      _nals.add(Uint8List.fromList(data));
    } else if (type == 24) {
      // STAP-A: 16 bit sizes, each followed by its NAL unit
      var offset = 1;
      while (offset + 2 <= data.length) {
        final size = (data[offset] << 8) | data[offset + 1];
        offset += 2;
        if (size == 0 || offset + size > data.length) {
          _damaged = true;
          break;
        }
        _nals.add(Uint8List.fromList(Uint8List.sublistView(data, offset, offset + size)));
        offset += size;
      }
    } else if (type == 28 && data.length > 2) {
      // FU-A: the NAL header rebuilt from the indicator and the fragment header
      final start = (data[1] & 0x80) != 0;
      final end = (data[1] & 0x40) != 0;
      if (start) {
        if (_fragment != null) {
          _damaged = true;
        }
        _fragment = BytesBuilder(copy: false)..addByte((data[0] & 0xe0) | (data[1] & 0x1f));
      }
      final fragment = _fragment;
      if (fragment == null) {
        // Its start was lost
        _damaged = true;
        return;
      }
      fragment.add(Uint8List.fromList(Uint8List.sublistView(data, 2)));
      if (end) {
        _nals.add(fragment.takeBytes());
        _fragment = null;
      }
    }
    // STAP-B, MTAP and FU-B (interleaved mode) are not sent by the cameras: ignored
  }

  void _emit() {
    final timestamp = _timestamp;
    _timestamp = null;
    if (_fragment != null) {
      // A fragment without its end
      _fragment = null;
      _damaged = true;
    }
    final damaged = _damaged;
    _damaged = false;
    if (_nals.isEmpty || timestamp == null) {
      _nals.clear();
      return;
    }
    final unit = H264AccessUnit(timestamp, List.of(_nals));
    _nals.clear();
    if (damaged) {
      _waitingForIdr = true;
      dropped++;
      return;
    }
    if (_waitingForIdr) {
      if (!unit.isIdr) {
        dropped++;
        return;
      }
      _waitingForIdr = false;
    }
    onAccessUnit(unit);
  }
}
