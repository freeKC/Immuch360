// A camera's live stream as an HLS live playlist of fragmented MP4 (RFC 8216, ISO/IEC 14496-12), for AVPlayer on
// iPhone and iPad: the H.264 access units of the RTP stream cut into segments at the IDR pictures, about 2 s each
// with the cameras' GOP, and a sliding playlist of the last few. The layout follows what ffmpeg writes with
// `-f hls -hls_segment_type fmp4`, which AVPlayer plays.
//
// The sound, G.711 on the cameras, is put in ALAC "escape" frames: 16 bit PCM stored as is inside ALAC, which needs
// no encoder and which AVPlayer decodes (HLS takes no raw PCM). It is placed against the video through the RTP-Info
// of PLAY (the npt of each clock), as the clips are through their PTS, else through the arrival times; a hole in the
// sound is filled with silence, so that it never drifts away from the picture.
//
// Everything stays in memory: the init segment of each SPS and the segments of the window plus a few, for a player
// that asks for one the window just let go.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/infrastructure/tapo/h264_parameter_sets.dart';
import 'package:immich_mobile/infrastructure/tapo/rtp_h264.dart';

/// One segment of the live playlist
class HlsSegment {
  const HlsSegment({
    required this.sequence,
    required this.duration,
    required this.bytes,
    required this.initVersion,
    required this.discontinuity,
  });

  final int sequence;

  /// In seconds
  final double duration;
  final Uint8List bytes;

  /// The init segment it is decoded with
  final int initVersion;

  /// The first segment after a change of the SPS (a new init segment)
  final bool discontinuity;

  String get name => 'seg$sequence.m4s';
}

class HlsLiveSegmenter {
  HlsLiveSegmenter({
    this.audioRate,
    this.videoRtpTime,
    this.audioRtpTime,
    Uint8List? sps,
    Uint8List? pps,
    this.window = 6,
    this.spare = 3,
    this.minSegment = const Duration(milliseconds: 1500),
    this.maxSegment = const Duration(seconds: 8),
    this.onSegment,
  }) : _sdpSps = sps,
       _sdpPps = pps;

  /// The clock of the sound, null for a playlist without sound
  final int? audioRate;

  /// The RTP time of the start of the stream on each track (RTP-Info), null when the camera did not tell
  final int? videoRtpTime;
  final int? audioRtpTime;

  /// The parameter sets of the SDP (sprop-parameter-sets), used when the first IDR picture comes without its own
  final Uint8List? _sdpSps;
  final Uint8List? _sdpPps;

  /// Segments listed in the playlist
  final int window;

  /// Segments kept after they left the playlist
  final int spare;

  /// A segment is cut at the first IDR picture after this length
  final Duration minSegment;

  /// ... and without an IDR picture once it reaches this one (a camera with a very long GOP)
  final Duration maxSegment;

  /// Called with each new segment
  final void Function(HlsSegment segment)? onSegment;

  static const videoTimescale = 90000;

  /// Samples per ALAC frame, as ffmpeg's encoder (0.512 s at 8 kHz)
  static const audioFrameLength = 4096;

  /// The frame duration when the timestamps cannot tell it: 15 frames a second, the rate of the cameras
  static const _defaultFrameTicks = videoTimescale ~/ 15;

  /// A hole in the sound longer than this one is not filled: the sound is placed again by its arrival
  static const _maxAudioGapSeconds = 2;

  final List<HlsSegment> _segments = [];
  final Map<int, Uint8List> _inits = {};
  int _initVersion = -1;
  Uint8List? _sps;
  Uint8List? _pps;
  int _nextSequence = 0;
  int _removedDiscontinuities = 0;
  int _target = 1;
  bool _independent = true;
  bool _discontinuityNext = false;

  /// New parameter sets could not be read: the pictures wait for an IDR picture with readable ones
  bool _waitingForParameters = false;

  // Video: the time of the first IDR picture is 0, on the 90 kHz clock
  final _videoClock = _RtpClock();
  int? _firstVideoTicks;
  int _lastVideoTime = 0;
  final List<_VideoSample> _video = [];

  // Sound: sample positions on the same timeline, at [audioRate]
  final _audioClock = _RtpClock();
  int? _audioAnchorTicks;
  int _audioAnchorPosition = 0;

  /// Samples placed so far (the position of the next one)
  int _audioEnd = 0;

  /// Samples already put in segments
  int _audioWritten = 0;
  final List<int> _pcm = [];

  /// Whether a picture can be shown: the first IDR picture came with readable parameter sets
  bool get started => _firstVideoTicks != null;

  /// The segments made so far
  int get segmentCount => _nextSequence;

  /// The playlist, null before the first segment
  String? playlist() {
    if (_segments.isEmpty) {
      return null;
    }
    final shown = _segments.length > window ? _segments.sublist(_segments.length - window) : _segments;
    final first = shown.first;
    final discontinuitySequence = _discontinuitiesBefore(first.sequence);
    final out = StringBuffer()
      ..write('#EXTM3U\n')
      ..write('#EXT-X-VERSION:7\n')
      ..write('#EXT-X-TARGETDURATION:$_target\n')
      ..write('#EXT-X-MEDIA-SEQUENCE:${first.sequence}\n');
    if (discontinuitySequence > 0) {
      out.write('#EXT-X-DISCONTINUITY-SEQUENCE:$discontinuitySequence\n');
    }
    if (_independent) {
      out.write('#EXT-X-INDEPENDENT-SEGMENTS\n');
    }
    for (final segment in shown) {
      if (segment.discontinuity) {
        out.write('#EXT-X-DISCONTINUITY\n');
      }
      if (identical(segment, first) || segment.discontinuity) {
        out.write('#EXT-X-MAP:URI="init${segment.initVersion}.mp4"\n');
      }
      out
        ..write('#EXTINF:${segment.duration.toStringAsFixed(3)},\n')
        ..write('${segment.name}\n');
    }
    return out.toString();
  }

  /// The discontinuities of the segments before [sequence], the ones no longer kept included
  int _discontinuitiesBefore(int sequence) =>
      _removedDiscontinuities +
      _segments.where((segment) => segment.sequence < sequence && segment.discontinuity).length;

  /// The init segment of [version], null when it is not kept
  Uint8List? init(int version) => _inits[version];

  /// The segment [sequence], null when it is not made yet or no longer kept
  HlsSegment? segment(int sequence) {
    for (final segment in _segments) {
      if (segment.sequence == sequence) {
        return segment;
      }
    }
    return null;
  }

  /// One picture of the camera
  void addVideo(H264AccessUnit unit) {
    Uint8List? sps;
    Uint8List? pps;
    for (final nal in unit.nals) {
      final type = nal.isEmpty ? 0 : nal[0] & 0x1f;
      if (type == 7) {
        sps = nal;
      } else if (type == 8) {
        pps = nal;
      }
    }
    final idr = unit.isIdr;
    final firstVideo = _firstVideoTicks;
    if (firstVideo == null) {
      // The stream starts at an IDR picture with parameter sets that can be read
      if (!idr || !_startInit(sps ?? _sdpSps, pps ?? _sdpPps)) {
        return;
      }
      _firstVideoTicks = _videoClock.extend(unit.timestamp);
      _video.add(_VideoSample(0, _sampleData(unit.nals), true));
      return;
    }
    final time = _videoClock.extend(unit.timestamp) - firstVideo;
    final changed = idr && ((sps != null && !_same(sps, _sps)) || (pps != null && !_same(pps, _pps)));
    if (_video.isNotEmpty) {
      final last = _video.last;
      final duration = time - last.time;
      last.duration = duration > 0 ? duration : _defaultFrameTicks;
      final length = time - _video.first.time;
      if (changed || (idr && length >= _ticks(minSegment))) {
        _cut(time);
      } else if (length >= _ticks(maxSegment)) {
        // No IDR picture in sight: the next segment starts on a picture that needs the ones before it
        _independent = false;
        _cut(time);
      }
    }
    if (changed || _waitingForParameters) {
      // A new picture size (or new parameter sets): a new init segment, after a discontinuity
      if (!idr || !_startInit(sps ?? _sps, pps ?? _pps)) {
        _waitingForParameters = true;
        return;
      }
      _waitingForParameters = false;
      _discontinuityNext = true;
    }
    _lastVideoTime = time;
    _video.add(_VideoSample(time, _sampleData(unit.nals), idr));
  }

  /// The sound of one RTP packet at [rtpTimestamp] (the clock of the sound), as 16 bit samples
  void addAudio(int rtpTimestamp, Int16List samples) {
    final rate = audioRate;
    final firstVideo = _firstVideoTicks;
    if (rate == null || firstVideo == null || samples.isEmpty) {
      // Before the first picture: nothing to place it against
      return;
    }
    final ticks = _audioClock.extend(rtpTimestamp);
    var position = _audioPosition(ticks, rate, firstVideo);
    if (position - _audioEnd > rate * _maxAudioGapSeconds || _audioEnd - position > rate * _maxAudioGapSeconds) {
      // The sound jumped (the camera started its clock again): placed again by its arrival
      _audioAnchorTicks = ticks;
      _audioAnchorPosition = _arrivalPosition(rate);
      position = _audioAnchorPosition;
    }
    var from = 0;
    if (position < _audioEnd) {
      // Already placed, or before the first picture
      from = min(_audioEnd - position, samples.length);
    } else if (position > _audioEnd) {
      // A hole: silence
      _pcm.addAll(List<int>.filled(position - _audioEnd, 0));
      _audioEnd = position;
    }
    for (var i = from; i < samples.length; i++) {
      _pcm.add(samples[i]);
    }
    _audioEnd += samples.length - from;
  }

  /// The position on the timeline of the sound at [ticks], the anchor set by the first packet
  int _audioPosition(int ticks, int rate, int firstVideo) {
    final anchor = _audioAnchorTicks;
    if (anchor != null) {
      return _audioAnchorPosition + ticks - anchor;
    }
    _audioAnchorTicks = ticks;
    final videoBase = videoRtpTime;
    final audioBase = audioRtpTime;
    var position = _arrivalPosition(rate);
    if (videoBase != null && audioBase != null) {
      // Both clocks at the npt of PLAY: the sound's npt minus the first picture's
      final audioSeconds = _signed32(ticks - audioBase) / rate;
      final videoSeconds = _signed32(firstVideo - videoBase) / videoTimescale;
      final told = ((audioSeconds - videoSeconds) * rate).round();
      // A camera whose RTP-Info is far off: the arrival is closer to the truth
      if ((told - position).abs() <= rate * _maxAudioGapSeconds) {
        position = told;
      }
    }
    _audioAnchorPosition = position;
    return position;
  }

  /// The position of a sound arriving now: with the newest picture
  int _arrivalPosition(int rate) => (_lastVideoTime * rate / videoTimescale).round();

  bool _startInit(Uint8List? sps, Uint8List? pps) {
    if (sps == null || pps == null) {
      return false;
    }
    final parsed = parseH264Sps(sps);
    if (parsed == null) {
      return false;
    }
    _sps = sps;
    _pps = pps;
    _initVersion++;
    _inits[_initVersion] = _initSegment(sps, pps, parsed);
    // The init segments of the segments no longer kept go
    _inits.removeWhere((version, _) => version < (_segments.firstOrNull?.initVersion ?? _initVersion));
    return true;
  }

  int _ticks(Duration duration) => duration.inMicroseconds * videoTimescale ~/ Duration.microsecondsPerSecond;

  /// The access unit as an MP4 sample: 4 byte lengths, without the parameter sets (in the init segment), the access
  /// unit delimiters and the filler data
  static Uint8List _sampleData(List<Uint8List> nals) {
    final out = BytesBuilder(copy: false);
    for (final nal in nals) {
      final type = nal.isEmpty ? 0 : nal[0] & 0x1f;
      if (nal.isEmpty || type == 7 || type == 8 || type == 9 || type == 12) {
        continue;
      }
      out
        ..add(_u32(nal.length))
        ..add(nal);
    }
    return out.takeBytes();
  }

  /// Ends the segment being made at [end] (the time of the picture that starts the next one)
  void _cut(int end) {
    final samples = List.of(_video);
    _video.clear();
    final start = samples.first.time;
    final last = samples.last;
    if (last.duration <= 0) {
      last.duration = end > last.time ? end - last.time : _defaultFrameTicks;
    }

    // The sound up to the end of the picture, in whole frames, the last one ending at most half a frame after it
    final rate = audioRate;
    final frames = <Uint8List>[];
    final audioStart = _audioWritten;
    if (rate != null) {
      final audioEnd = end * rate ~/ videoTimescale;
      if (audioEnd - _audioEnd > rate) {
        // More than a second without sound (a camera whose microphone is off sends none): silence up to half a second
        // before the picture, so that the player never waits for it; a late packet loses what overlaps
        final silence = audioEnd - rate ~/ 2 - _audioEnd;
        _pcm.addAll(List<int>.filled(silence, 0));
        _audioEnd += silence;
      }
      var taken = 0;
      while (_pcm.length - taken >= audioFrameLength &&
          _audioWritten + taken + audioFrameLength <= audioEnd + audioFrameLength ~/ 2) {
        frames.add(alacEscapeFrame(Int16List.fromList(_pcm.sublist(taken, taken + audioFrameLength))));
        taken += audioFrameLength;
      }
      _pcm.removeRange(0, taken);
      _audioWritten += taken;
    }

    final sequence = _nextSequence++;
    final videoSizes = [for (final sample in samples) sample.data.length];
    final videoBytes = videoSizes.fold<int>(0, (sum, size) => sum + size);
    Uint8List moof(int videoOffset, int audioOffset) => _box('moof', [
      _fullBox('mfhd', 0, 0, [_u32(sequence + 1)]),
      _traf(
        1,
        start,
        [for (final sample in samples) sample.duration],
        videoSizes,
        [for (final sample in samples) sample.sync ? 0x02000000 : 0x01010000],
        videoOffset,
      ),
      if (frames.isNotEmpty)
        _traf(
          2,
          audioStart,
          [for (final _ in frames) audioFrameLength],
          [for (final frame in frames) frame.length],
          null,
          audioOffset,
        ),
    ]);
    // The data offsets count from the start of the moof: its size first, then the boxes with them
    final moofSize = moof(0, 0).length;
    final out = BytesBuilder(copy: false)
      ..add(_box('styp', [ascii.encode('msdh'), _u32(0), ascii.encode('msdhmsix')]))
      ..add(moof(moofSize + 8, moofSize + 8 + videoBytes));
    final mdatSize = 8 + videoBytes + frames.fold<int>(0, (sum, frame) => sum + frame.length);
    out
      ..add(_u32(mdatSize))
      ..add(ascii.encode('mdat'));
    for (final sample in samples) {
      out.add(sample.data);
    }
    for (final frame in frames) {
      out.add(frame);
    }
    final duration = (end - start) / videoTimescale;
    final segment = HlsSegment(
      sequence: sequence,
      duration: duration,
      bytes: out.takeBytes(),
      initVersion: _initVersion,
      discontinuity: _discontinuityNext,
    );
    _discontinuityNext = false;
    // The target duration never goes down: a player reads it once for its reloads
    _target = max(_target, duration.round());
    _segments.add(segment);
    while (_segments.length > window + spare) {
      if (_segments.removeAt(0).discontinuity) {
        _removedDiscontinuities++;
      }
    }
    _inits.removeWhere((version, _) => version < _segments.first.initVersion);
    onSegment?.call(segment);
  }

  Uint8List _initSegment(Uint8List sps, Uint8List pps, H264Sps parsed) {
    final avc1 = _box('avc1', [
      Uint8List(6),
      _u16(1),
      Uint8List(16),
      _u16(parsed.width),
      _u16(parsed.height), //
      _u32(0x00480000),
      _u32(0x00480000),
      _u32(0),
      _u16(1),
      Uint8List(32),
      _u16(0x18),
      _u16(0xffff),
      _box('avcC', [h264AvcC(sps, pps, parsed)]),
    ]);
    final rate = audioRate;
    final tracks = [
      _trak(1, 'vide', videoTimescale, avc1, width: parsed.width, height: parsed.height),
      if (rate != null) _trak(2, 'soun', rate, _alacSampleEntry(rate)),
    ];
    return Uint8List.fromList([
      ..._box('ftyp', [ascii.encode('iso5'), _u32(512), ascii.encode('iso5iso6mp41')]),
      ..._box('moov', [
        _fullBox('mvhd', 0, 0, [
          _u32(0),
          _u32(0),
          _u32(1000),
          _u32(0),
          _u32(0x00010000),
          _u16(0x0100),
          Uint8List(10),
          _matrix, //
          Uint8List(24), _u32(tracks.length + 1),
        ]),
        ...tracks,
        _box('mvex', [
          for (var id = 1; id <= tracks.length; id++)
            _fullBox('trex', 0, 0, [_u32(id), _u32(1), _u32(0), _u32(0), _u32(0)]),
        ]),
      ]),
    ]);
  }

  static Uint8List _alacSampleEntry(int rate) {
    // The ALAC magic cookie: frame length, version 0, 16 bits, the encoder's tuning (40, 10, 14), one channel, the
    // longest run, the largest frame, the bit rate and the sample rate
    final config = _fullBox('alac', 0, 0, [
      _u32(audioFrameLength),
      [0, 16, 40, 10, 14, 1],
      _u16(255),
      _u32(alacFrameBytes(audioFrameLength)), //
      _u32(rate * 16), _u32(rate),
    ]);
    return _box('alac', [
      Uint8List(6),
      _u16(1),
      Uint8List(8),
      _u16(1),
      _u16(16),
      _u16(0),
      _u16(0),
      _u32(rate << 16),
      config, //
    ]);
  }

  static Uint8List _trak(
    int id,
    String handler,
    int timescale,
    Uint8List sampleEntry, {
    int width = 0,
    int height = 0,
  }) {
    final video = handler == 'vide';
    return _box('trak', [
      _fullBox('tkhd', 0, 3, [
        _u32(0),
        _u32(0),
        _u32(id),
        _u32(0),
        _u32(0),
        Uint8List(8),
        _u16(0),
        _u16(video ? 0 : 1), //
        _u16(video ? 0 : 0x0100),
        _u16(0),
        _matrix,
        _u32(width << 16),
        _u32(height << 16),
      ]),
      _box('mdia', [
        _fullBox('mdhd', 0, 0, [_u32(0), _u32(0), _u32(timescale), _u32(0), _u16(0x55c4), _u16(0)]),
        _fullBox('hdlr', 0, 0, [
          _u32(0),
          ascii.encode(handler),
          Uint8List(12),
          ascii.encode(video ? 'VideoHandler\u0000' : 'SoundHandler\u0000'),
        ]),
        _box('minf', [
          if (video) _fullBox('vmhd', 0, 1, [Uint8List(8)]) else _fullBox('smhd', 0, 0, [Uint8List(4)]),
          _box('dinf', [
            _fullBox('dref', 0, 0, [_u32(1), _fullBox('url ', 0, 1, [])]),
          ]),
          _box('stbl', [
            _fullBox('stsd', 0, 0, [_u32(1), sampleEntry]),
            _fullBox('stts', 0, 0, [_u32(0)]),
            _fullBox('stsc', 0, 0, [_u32(0)]),
            _fullBox('stsz', 0, 0, [_u32(0), _u32(0)]),
            _fullBox('stco', 0, 0, [_u32(0)]),
          ]),
        ]),
      ]),
    ]);
  }

  static Uint8List _traf(int id, int baseTime, List<int> durations, List<int> sizes, List<int>? flags, int dataOffset) {
    final perSample = BytesBuilder(copy: false);
    for (var i = 0; i < sizes.length; i++) {
      perSample
        ..add(_u32(durations[i]))
        ..add(_u32(sizes[i]));
      if (flags != null) {
        perSample.add(_u32(flags[i]));
      }
    }
    // data offset, sample duration, sample size, sample flags
    final trunFlags = 0x000001 | 0x000100 | 0x000200 | (flags != null ? 0x000400 : 0);
    return _box('traf', [
      // default-base-is-moof
      _fullBox('tfhd', 0, 0x020000, [_u32(id)]),
      _fullBox('tfdt', 1, 0, [_u64(baseTime)]),
      _fullBox('trun', 0, trunFlags, [_u32(sizes.length), _u32(dataOffset), perSample.takeBytes()]),
    ]);
  }

  static bool _same(Uint8List a, Uint8List? b) {
    if (b == null || a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

class _VideoSample {
  _VideoSample(this.time, this.data, this.sync);

  /// On the 90 kHz clock, from the first IDR picture
  final int time;
  final Uint8List data;
  final bool sync;

  /// Known once the next picture comes
  int duration = 0;
}

/// A 32 bit RTP clock made continuous: each time is placed after the previous one by the shortest way round
class _RtpClock {
  int? _last;
  int _extended = 0;

  int extend(int timestamp) {
    final last = _last;
    _last = timestamp;
    if (last == null) {
      _extended = timestamp;
    } else {
      _extended += _signed32(timestamp - last);
    }
    return _extended;
  }
}

int _signed32(int value) => ((value + 0x80000000) & 0xffffffff) - 0x80000000;

/// One ALAC frame holding [samples] as they are (the escape flag), mono, 16 bit: a single channel element, then the
/// end tag. [samples] holds the frame length of the magic cookie; a shorter one says how many it holds.
Uint8List alacEscapeFrame(Int16List samples, {int frameLength = HlsLiveSegmenter.audioFrameLength}) {
  final partial = samples.length != frameLength;
  final bits = _BitWriter()
    ..write(0, 3) // ID_SCE
    ..write(0, 4) // element instance tag
    ..write(0, 12) // unused
    ..write(partial ? 1 : 0, 1) // the number of samples follows
    ..write(0, 2) // bytes shifted
    ..write(1, 1); // escape: not compressed
  if (partial) {
    bits.write(samples.length, 32);
  }
  for (final sample in samples) {
    bits.write(sample & 0xffff, 16);
  }
  bits.write(7, 3); // ID_END
  return bits.finish();
}

/// The bytes of a whole escape frame of [samples] samples
int alacFrameBytes(int samples) => (23 + samples * 16 + 3 + 7) ~/ 8;

class _BitWriter {
  final _out = BytesBuilder(copy: false);
  int _byte = 0;
  int _count = 0;

  void write(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _byte = (_byte << 1) | ((value >> i) & 1);
      if (++_count == 8) {
        _out.addByte(_byte);
        _byte = 0;
        _count = 0;
      }
    }
  }

  Uint8List finish() {
    if (_count > 0) {
      _out.addByte(_byte << (8 - _count));
      _byte = 0;
      _count = 0;
    }
    return _out.takeBytes();
  }
}

Uint8List _u16(int value) => Uint8List(2)..buffer.asByteData().setUint16(0, value);

Uint8List _u32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value);

Uint8List _u64(int value) => Uint8List(8)..buffer.asByteData().setUint64(0, value);

final _matrix = Uint8List.fromList([
  ..._u32(0x00010000), ..._u32(0), ..._u32(0), //
  ..._u32(0), ..._u32(0x00010000), ..._u32(0), //
  ..._u32(0), ..._u32(0), ..._u32(0x40000000),
]);

Uint8List _box(String type, List<List<int>> parts) {
  final size = 8 + parts.fold<int>(0, (sum, part) => sum + part.length);
  final out = BytesBuilder(copy: false)
    ..add(_u32(size))
    ..add(ascii.encode(type));
  for (final part in parts) {
    out.add(part);
  }
  return out.takeBytes();
}

Uint8List _fullBox(String type, int version, int flags, List<List<int>> parts) =>
    _box(type, [_u32((version << 24) | flags), ...parts]);
