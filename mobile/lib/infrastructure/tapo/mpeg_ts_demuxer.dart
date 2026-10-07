// The MPEG-TS the cameras send on their media port (Tapo design 2.7, P§8): PAT, PMT on PID 0x12, H.264 video (stream
// type 0x1B) on 0x44, G.711 A-law (0x90) on 0x45, TP-Link tags on the null PID. Each part of the media port holds whole
// 188 byte packets of at most one access unit, but a key frame spreads over several parts: this demuxer is fed every
// part in order, in pieces of any size, and gives back whole video access units (their NAL units, PTS and key flag)
// and the audio samples of each PES.
//
// The audio and video PTS clocks of a recording may differ by seconds although the streams are in sync (P§8.3): the
// audio is placed from the wall clock of the parts (X-Data-PTS) instead, see [MpegTsDemuxer.audioOffsetSeconds].

import 'dart:typed_data';

/// The codecs the cameras use
enum TsVideoCodec { h264, h265 }

enum TsAudioCodec { alaw, ulaw }

/// One video access unit: its NAL units without start codes, its PTS (90 kHz, unwrapped across the 2^33 wrap; null for
/// the rare PES without one) and whether it holds a key frame (an IDR picture)
class TsVideoFrame {
  const TsVideoFrame({required this.nalUnits, required this.pts, required this.isKey});

  final List<Uint8List> nalUnits;
  final int? pts;
  final bool isKey;
}

/// The samples of one audio PES (G.711, one byte per sample)
class TsAudioChunk {
  const TsAudioChunk({required this.samples, required this.pts, required this.codec});

  final Uint8List samples;
  final int? pts;
  final TsAudioCodec codec;
}

/// See the header
class MpegTsDemuxer {
  MpegTsDemuxer({required this.onVideo, required this.onAudio});

  final void Function(TsVideoFrame frame) onVideo;
  final void Function(TsAudioChunk chunk) onAudio;

  static const packetSize = 188;

  /// The bytes of a packet cut between two calls of [feed]
  Uint8List _rest = Uint8List(0);

  int? _pmtPid;
  final Map<int, int> _streamTypes = {};

  /// The PES being gathered, by PID
  final Map<int, BytesBuilder> _pes = {};

  /// The wall clock of the part each PES started in
  final Map<int, int?> _pesWall = {};

  TsVideoCodec? _videoCodec;

  /// The codec of the video, once the PMT or the first video PES told it
  TsVideoCodec? get videoCodec => _videoCodec;

  int? _lastRawPts;
  int _ptsWraps = 0;

  /// The wall clocks (ms) of the first video and the first audio PES, see [audioOffsetSeconds]
  int? firstVideoWallMs;
  int? firstAudioWallMs;
  bool _sawVideo = false;
  bool _sawAudio = false;

  /// Seconds the first audio sample comes after the first video frame, from the wall clock of the parts; 0 when a part
  /// had none, or when the difference is not plausible (outside -0.5 s to +1 s), as the reference client does
  double get audioOffsetSeconds {
    final video = firstVideoWallMs;
    final audio = firstAudioWallMs;
    if (video == null || audio == null) {
      return 0;
    }
    final offset = (audio - video) / 1000;
    return offset >= -0.5 && offset <= 1.0 ? offset : 0;
  }

  /// Whether both the first video and the first audio were seen, so that [audioOffsetSeconds] is final
  bool get knowsAudioOffset => _sawVideo && _sawAudio;

  /// Feeds the next bytes of the stream; [wallMs] is the X-Data-PTS header of the part they came in, when it had one
  void feed(Uint8List data, {int? wallMs}) {
    var bytes = data;
    if (_rest.isNotEmpty) {
      bytes = Uint8List(_rest.length + data.length)
        ..setRange(0, _rest.length, _rest)
        ..setRange(_rest.length, _rest.length + data.length, data);
    }
    var offset = 0;
    while (offset + packetSize <= bytes.length) {
      if (bytes[offset] != 0x47) {
        // Lost the sync inside a part: look for the next packet start
        final next = bytes.indexOf(0x47, offset + 1);
        if (next < 0) {
          offset = bytes.length;
          break;
        }
        offset = next;
        continue;
      }
      _packet(Uint8List.sublistView(bytes, offset, offset + packetSize), wallMs);
      offset += packetSize;
    }
    _rest = Uint8List.fromList(Uint8List.sublistView(bytes, offset));
  }

  /// Gives back what is still gathered (the last video frame waits for the next one to know its end)
  void flush() {
    for (final pid in _pes.keys.toList()) {
      _emit(pid);
    }
  }

  void _packet(Uint8List packet, int? wallMs) {
    final pid = ((packet[1] & 0x1f) << 8) | packet[2];
    final unitStart = (packet[1] & 0x40) != 0;
    final adaptation = (packet[3] >> 4) & 0x3;
    var payloadStart = 4;
    if ((adaptation & 0x2) != 0) {
      payloadStart += 1 + packet[4];
    }
    if ((adaptation & 0x1) == 0 || payloadStart >= packetSize) {
      return;
    }
    final payload = Uint8List.sublistView(packet, payloadStart);
    if (pid == 0x1fff) {
      return;
    }
    if (pid == 0) {
      _pat(payload, unitStart);
      return;
    }
    if (pid == _pmtPid) {
      _pmt(payload, unitStart);
      return;
    }
    if (unitStart) {
      _emit(pid);
      if (payload.length >= 4 && payload[0] == 0 && payload[1] == 0 && payload[2] == 1) {
        final streamId = payload[3];
        if (!_streamTypes.containsKey(pid)) {
          // No PMT seen yet: the stream id tells video from audio, with the codecs of the cameras
          if (streamId >= 0xe0 && streamId <= 0xef) {
            _streamTypes[pid] = 0x1b;
          } else if (streamId >= 0xc0 && streamId <= 0xdf) {
            _streamTypes[pid] = 0x90;
          }
        }
        _pes[pid] = BytesBuilder(copy: true)..add(payload);
        _pesWall[pid] = wallMs;
      }
      return;
    }
    _pes[pid]?.add(payload);
  }

  void _pat(Uint8List payload, bool unitStart) {
    if (!unitStart || payload.isEmpty) {
      return;
    }
    final start = 1 + payload[0];
    if (start + 8 > payload.length || payload[start] != 0x00) {
      return;
    }
    final sectionLength = ((payload[start + 1] & 0x0f) << 8) | payload[start + 2];
    final end = start + 3 + sectionLength - 4;
    for (var at = start + 8; at + 4 <= end && at + 4 <= payload.length; at += 4) {
      final program = (payload[at] << 8) | payload[at + 1];
      if (program != 0) {
        _pmtPid = ((payload[at + 2] & 0x1f) << 8) | payload[at + 3];
        return;
      }
    }
  }

  void _pmt(Uint8List payload, bool unitStart) {
    if (!unitStart || payload.isEmpty) {
      return;
    }
    final start = 1 + payload[0];
    if (start + 12 > payload.length || payload[start] != 0x02) {
      return;
    }
    final sectionLength = ((payload[start + 1] & 0x0f) << 8) | payload[start + 2];
    final end = start + 3 + sectionLength - 4;
    final programInfoLength = ((payload[start + 10] & 0x0f) << 8) | payload[start + 11];
    for (var at = start + 12 + programInfoLength; at + 5 <= end && at + 5 <= payload.length;) {
      final streamType = payload[at];
      final pid = ((payload[at + 1] & 0x1f) << 8) | payload[at + 2];
      final infoLength = ((payload[at + 3] & 0x0f) << 8) | payload[at + 4];
      _streamTypes[pid] = streamType;
      at += 5 + infoLength;
    }
  }

  void _emit(int pid) {
    final builder = _pes.remove(pid);
    final wall = _pesWall.remove(pid);
    if (builder == null) {
      return;
    }
    final pes = builder.takeBytes();
    if (pes.length < 9) {
      return;
    }
    final headerLength = pes[8];
    final dataStart = 9 + headerLength;
    if (dataStart > pes.length) {
      return;
    }
    int? pts;
    if ((pes[7] & 0x80) != 0 && headerLength >= 5) {
      pts =
          ((pes[9] >> 1) & 0x07) * (1 << 30) +
          (pes[10] << 22) +
          ((pes[11] >> 1) << 15) +
          (pes[12] << 7) +
          (pes[13] >> 1);
    }
    // A bounded PES says how long it is: what a packet adds past it is stuffing
    final declared = (pes[4] << 8) | pes[5];
    final end = declared == 0 ? pes.length : (6 + declared).clamp(dataStart, pes.length);
    final data = Uint8List.sublistView(pes, dataStart, end);
    switch (_streamTypes[pid]) {
      case 0x1b:
        _video(data, pts, wall, TsVideoCodec.h264);
      case 0x24:
        _video(data, pts, wall, TsVideoCodec.h265);
      case 0x90:
        _audio(data, pts, wall, TsAudioCodec.alaw);
      case 0x91:
        _audio(data, pts, wall, TsAudioCodec.ulaw);
      default:
        break;
    }
  }

  void _video(Uint8List data, int? rawPts, int? wall, TsVideoCodec codec) {
    _videoCodec ??= codec;
    final nalUnits = splitAnnexB(data);
    if (nalUnits.isEmpty) {
      return;
    }
    if (!_sawVideo && rawPts != null) {
      _sawVideo = true;
      firstVideoWallMs = wall;
    }
    final isKey = nalUnits.any((nal) => isKeyNalUnit(nal, codec));
    onVideo(TsVideoFrame(nalUnits: nalUnits, pts: rawPts == null ? null : _unwrap(rawPts), isKey: isKey));
  }

  void _audio(Uint8List data, int? pts, int? wall, TsAudioCodec codec) {
    if (data.isEmpty) {
      return;
    }
    if (!_sawAudio) {
      _sawAudio = true;
      firstAudioWallMs = wall;
    }
    onAudio(TsAudioChunk(samples: Uint8List.fromList(data), pts: pts, codec: codec));
  }

  /// The video PTS on a line that goes on past the 33 bit wrap
  int _unwrap(int raw) {
    const wrap = 1 << 33;
    final last = _lastRawPts;
    if (last != null && raw < last && last - raw > wrap ~/ 2) {
      _ptsWraps++;
    }
    _lastRawPts = raw;
    return raw + _ptsWraps * wrap;
  }
}

/// Whether [nal] is a picture a decoder can start from: an IDR slice in H.264, an IRAP picture (types 16 to 21) in
/// H.265
bool isKeyNalUnit(Uint8List nal, TsVideoCodec codec) {
  if (nal.isEmpty) {
    return false;
  }
  if (codec == TsVideoCodec.h264) {
    return (nal[0] & 0x1f) == 5;
  }
  final type = (nal[0] >> 1) & 0x3f;
  return type >= 16 && type <= 21;
}

/// The NAL units of an Annex B byte stream, without their start codes (00 00 01 or 00 00 00 01)
List<Uint8List> splitAnnexB(Uint8List data) {
  final starts = <int>[];
  final ends = <int>[];
  var i = 0;
  while (i + 3 <= data.length) {
    if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
      if (starts.isNotEmpty) {
        // A 4 byte start code leaves one zero at the end of the previous unit
        var end = i;
        while (end > starts.last && data[end - 1] == 0) {
          end--;
        }
        ends.add(end);
      }
      starts.add(i + 3);
      i += 3;
    } else {
      i++;
    }
  }
  if (starts.isEmpty) {
    return const [];
  }
  ends.add(data.length);
  return [
    for (var n = 0; n < starts.length; n++)
      if (ends[n] > starts[n]) Uint8List.sublistView(data, starts[n], ends[n]),
  ];
}
