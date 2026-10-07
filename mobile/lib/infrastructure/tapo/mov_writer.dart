// Writes a clip of a camera as a QuickTime file (.mov) as it arrives (Tapo design 3.7): `ftyp`, an `mdat` whose 64 bit
// size is patched at the end, then the `moov`. The video track is H.264 (`avc1`, the avcC of the first SPS and PPS,
// 90 kHz, durations from the PTS, the IDR frames as sync samples); the sound, G.711 on the camera, becomes 16 bit
// little endian PCM (`sowt`, 8000 Hz mono), which Media3 and AVFoundation read without a decoder. The layout follows
// what ffmpeg writes for the same streams in a .mov.
//
// The dates of the movie and a `©day` in the camera's zone carry the start of the clip, so that a clip sent to the
// Immich server lands at the time it was recorded. Runs in the isolate of the fetch (synchronous file I/O).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/infrastructure/tapo/h264_parameter_sets.dart';
import 'package:immich_mobile/infrastructure/tapo/mpeg_ts_demuxer.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';

/// Thrown when the stream cannot become a clip (no decodable video)
class MovWriterException implements Exception {
  const MovWriterException(this.message);

  final String message;

  @override
  String toString() => 'MovWriterException: $message';
}

class MovWriter {
  /// Starts the file in [file] (empty, opened for writing). [creation] is the start of the clip, [zoneOffset] the
  /// offset of the camera's zone at that time.
  MovWriter(this._file, {required this.creation, required this.zoneOffset}) {
    _file.setPositionSync(0);
    _write(_box('ftyp', [ascii.encode('qt  '), _u32(0x20050300), ascii.encode('qt  ')]));
    _mdatStart = _position;
    // A 64 bit size, patched by finish
    _write([0, 0, 0, 1, ...ascii.encode('mdat'), 0, 0, 0, 0, 0, 0, 0, 0]);
  }

  final RandomAccessFile _file;
  final DateTime creation;
  final Duration zoneOffset;

  static const videoTimescale = 90000;
  static const audioRate = 8000;

  /// The frame duration when the PTS cannot tell it: 15 frames a second, the rate of the cameras
  static const _defaultFrameTicks = videoTimescale ~/ 15;

  int _position = 0;
  int _mdatStart = 0;

  Uint8List? _sps;
  Uint8List? _pps;
  H264Sps? _parsedSps;
  bool _started = false;

  final List<int> _videoOffsets = [];
  final List<int> _videoSizes = [];
  final List<int?> _videoPts = [];
  final List<int> _syncSamples = [];

  final List<int> _audioOffsets = [];
  final List<int> _audioCounts = [];
  int _audioSamples = 0;

  /// Seconds the sound starts after the first frame, applied to the first samples written
  double _audioOffset = 0;
  bool _audioStarted = false;
  int _audioToDrop = 0;

  /// What came before the first video frame, written once it is there
  final List<TsAudioChunk> _earlyAudio = [];

  /// The bytes of the file so far
  int get length => _position;

  /// The video frames written
  int get videoFrames => _videoSizes.length;

  /// Seconds of video written, from the PTS
  double get videoSeconds {
    final first = _videoPts.firstWhere((pts) => pts != null, orElse: () => null);
    final last = _videoPts.lastWhere((pts) => pts != null, orElse: () => null);
    return first == null || last == null ? 0 : (last - first) / videoTimescale;
  }

  /// Seconds the sound starts after the first frame (from the wall clock of the parts, see
  /// MpegTsDemuxer.audioOffsetSeconds); taken until the first sample is written
  set audioOffsetSeconds(double seconds) {
    if (!_audioStarted) {
      _audioOffset = seconds;
    }
  }

  void addVideo(TsVideoFrame frame) {
    for (final nal in frame.nalUnits) {
      final type = nal[0] & 0x1f;
      if (type == 7 && _sps == null) {
        final parsed = parseH264Sps(nal);
        if (parsed != null) {
          _sps = Uint8List.fromList(nal);
          _parsedSps = parsed;
        }
      } else if (type == 8 && _pps == null) {
        _pps = Uint8List.fromList(nal);
      }
    }
    // A decoder starts from a key frame, and a frame without a PTS has no place on the time line yet
    if (!_started && (!frame.isKey || frame.pts == null || _sps == null || _pps == null)) {
      return;
    }
    final sample = BytesBuilder(copy: false);
    for (final nal in frame.nalUnits) {
      final type = nal[0] & 0x1f;
      // Parameter sets live in the sample entry; access unit delimiters are of no use in a file
      if (type == 7 || type == 8 || type == 9) {
        continue;
      }
      sample
        ..add(_u32(nal.length))
        ..add(nal);
    }
    if (sample.isEmpty) {
      return;
    }
    final bytes = sample.takeBytes();
    if (frame.isKey) {
      _syncSamples.add(_videoSizes.length + 1);
    }
    _videoOffsets.add(_position);
    _videoSizes.add(bytes.length);
    _videoPts.add(frame.pts);
    _write(bytes);
    if (!_started) {
      _started = true;
      for (final chunk in _earlyAudio) {
        _writeAudio(chunk);
      }
      _earlyAudio.clear();
    }
  }

  void addAudio(TsAudioChunk chunk) {
    if (!_started) {
      _earlyAudio.add(chunk);
      return;
    }
    _writeAudio(chunk);
  }

  void _writeAudio(TsAudioChunk chunk) {
    if (!_audioStarted) {
      _audioStarted = true;
      final shift = (_audioOffset * audioRate).round();
      if (shift > 0) {
        // The sound starts after the first frame: silence until then
        _writePcm(Uint8List(shift * 2), shift);
      } else {
        _audioToDrop = -shift;
      }
    }
    var samples = chunk.samples;
    if (_audioToDrop > 0) {
      final dropped = min(_audioToDrop, samples.length);
      _audioToDrop -= dropped;
      samples = Uint8List.sublistView(samples, dropped);
    }
    if (samples.isEmpty) {
      return;
    }
    final table = chunk.codec == TsAudioCodec.alaw ? alawToPcm16 : ulawToPcm16;
    final pcm = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      pcm.setInt16(i * 2, table[samples[i]], Endian.little);
    }
    _writePcm(pcm.buffer.asUint8List(), samples.length);
  }

  void _writePcm(Uint8List bytes, int count) {
    _audioOffsets.add(_position);
    _audioCounts.add(count);
    _audioSamples += count;
    _write(bytes);
  }

  /// Ends the file: the size of the media data, then the movie header. Throws a [MovWriterException] when no video
  /// frame could be written.
  void finish() {
    final sps = _sps;
    final pps = _pps;
    final parsed = _parsedSps;
    if (_videoSizes.isEmpty || sps == null || pps == null || parsed == null) {
      throw const MovWriterException('No decodable video');
    }
    final mdatSize = _position - _mdatStart;
    _file.setPositionSync(_mdatStart + 8);
    _file.writeFromSync((ByteData(8)..setUint64(0, mdatSize)).buffer.asUint8List());
    _file.setPositionSync(_position);

    final durations = _videoDurations();
    final videoTicks = durations.fold<int>(0, (sum, duration) => sum + duration);
    final videoMs = (videoTicks * 1000 / videoTimescale).round();
    final audioMs = (_audioSamples * 1000 / audioRate).round();
    final movieMs = max(videoMs, audioMs);
    final hasAudio = _audioSamples > 0;
    final seconds1904 = creation.toUtc().millisecondsSinceEpoch ~/ 1000 + 2082844800;

    final videoTrack = _track(
      id: 1,
      durationMs: videoMs,
      seconds1904: seconds1904,
      isVideo: true,
      width: parsed.width,
      height: parsed.height,
      mediaTimescale: videoTimescale,
      mediaDuration: videoTicks,
      sampleTable: [
        _box('stsd', [_u32(0), _u32(1), _avc1Entry(parsed, h264AvcC(sps, pps, parsed))]),
        _stts(durations),
        _box('stss', [_u32(0), _u32(_syncSamples.length), for (final sample in _syncSamples) _u32(sample)]),
        _box('stsc', [_u32(0), _u32(1), _u32(1), _u32(1), _u32(1)]),
        _box('stsz', [_u32(0), _u32(0), _u32(_videoSizes.length), for (final size in _videoSizes) _u32(size)]),
        _chunkOffsets(_videoOffsets),
      ],
    );
    final audioTrack = !hasAudio
        ? null
        : _track(
            id: 2,
            durationMs: audioMs,
            seconds1904: seconds1904,
            isVideo: false,
            mediaTimescale: audioRate,
            mediaDuration: _audioSamples,
            sampleTable: [
              _box('stsd', [_u32(0), _u32(1), _sowtEntry()]),
              _box('stts', [_u32(0), _u32(1), _u32(_audioSamples), _u32(1)]),
              _audioStsc(),
              _box('stsz', [_u32(0), _u32(2), _u32(_audioSamples)]),
              _chunkOffsets(_audioOffsets),
            ],
          );
    final moov = _box('moov', [
      _mvhd(seconds1904, movieMs, nextTrack: hasAudio ? 3 : 2),
      videoTrack,
      ?audioTrack,
      _box('udta', [_dayAtom()]),
    ]);
    _write(moov);
    _file.flushSync();
  }

  /// The duration of each frame from the PTS: the gap to the next frame, the usual one for a frame without a PTS or
  /// whose PTS goes back, and for the last frame
  List<int> _videoDurations() {
    final pts = List<int?>.of(_videoPts);
    final gaps = <int>[];
    for (var i = 1; i < pts.length; i++) {
      final previous = pts[i - 1];
      final current = pts[i];
      if (previous != null && current != null && current > previous) {
        gaps.add(current - previous);
      }
    }
    gaps.sort();
    final usual = gaps.isEmpty ? _defaultFrameTicks : gaps[gaps.length ~/ 2];
    for (var i = 1; i < pts.length; i++) {
      final previous = pts[i - 1]!;
      final current = pts[i];
      if (current == null || current <= previous || current - previous > usual * 30) {
        pts[i] = previous + usual;
      }
    }
    return [for (var i = 0; i < pts.length; i++) i + 1 < pts.length ? pts[i + 1]! - pts[i]! : usual];
  }

  Uint8List _track({
    required int id,
    required int durationMs,
    required int seconds1904,
    required bool isVideo,
    int width = 0,
    int height = 0,
    required int mediaTimescale,
    required int mediaDuration,
    required List<Uint8List> sampleTable,
  }) {
    final tkhd = _box('tkhd', [
      _u32(0x00000003), // enabled, in the movie
      _u32(seconds1904),
      _u32(seconds1904),
      _u32(id),
      _u32(0),
      _u32(durationMs),
      Uint8List(8),
      _u16(0), // layer
      _u16(isVideo ? 0 : 1), // alternate group
      _u16(isVideo ? 0 : 0x0100), // volume
      _u16(0),
      _matrix,
      _u32(width << 16),
      _u32(height << 16),
    ]);
    final edts = _box('edts', [
      _box('elst', [_u32(0), _u32(1), _u32(durationMs), _u32(0), _u32(0x00010000)]),
    ]);
    final mdhd = _box('mdhd', [
      _u32(0),
      _u32(seconds1904),
      _u32(seconds1904),
      _u32(mediaTimescale),
      _u32(mediaDuration),
      _u16(0x7fff), // language unspecified, as QuickTime writes it
      _u16(0),
    ]);
    final handler = _box('hdlr', [
      _u32(0),
      ascii.encode('mhlr'),
      ascii.encode(isVideo ? 'vide' : 'soun'),
      Uint8List(12),
      _pascal(isVideo ? 'VideoHandler' : 'SoundHandler'),
    ]);
    final mediaHeader = isVideo
        ? _box('vmhd', [_u32(0x00000001), Uint8List(8)])
        : _box('smhd', [_u32(0), _u16(0), _u16(0)]);
    final dataHandler = _box('hdlr', [
      _u32(0),
      ascii.encode('dhlr'),
      ascii.encode('url '),
      Uint8List(12),
      _pascal('DataHandler'),
    ]);
    final dinf = _box('dinf', [
      _box('dref', [
        _u32(0),
        _u32(1),
        _box('url ', [_u32(0x00000001)]),
      ]),
    ]);
    final minf = _box('minf', [mediaHeader, dataHandler, dinf, _box('stbl', sampleTable)]);
    return _box('trak', [
      tkhd,
      edts,
      _box('mdia', [mdhd, handler, minf]),
    ]);
  }

  Uint8List _mvhd(int seconds1904, int durationMs, {required int nextTrack}) => _box('mvhd', [
    _u32(0),
    _u32(seconds1904),
    _u32(seconds1904),
    _u32(1000),
    _u32(durationMs),
    _u32(0x00010000), // rate 1.0
    _u16(0x0100), // volume 1.0
    Uint8List(10),
    _matrix,
    Uint8List(24),
    _u32(nextTrack),
  ]);

  Uint8List _avc1Entry(H264Sps sps, Uint8List avcC) {
    final compressor = Uint8List(32);
    return _box('avc1', [
      Uint8List(6),
      _u16(1), // data reference index
      _u16(0),
      _u16(0),
      Uint8List(4), // vendor
      _u32(0x200), // temporal quality
      _u32(0x200), // spatial quality
      _u16(sps.width),
      _u16(sps.height),
      _u32(0x00480000),
      _u32(0x00480000),
      _u32(0),
      _u16(1), // frames per sample
      compressor,
      _u16(0x18), // depth
      _u16(0xffff), // no colour table
      _box('avcC', [avcC]),
      _box('pasp', [_u32(1), _u32(1)]),
    ]);
  }

  Uint8List _sowtEntry() => _box('sowt', [
    Uint8List(6),
    _u16(1), // data reference index
    _u16(0), // version
    _u16(0), // revision
    Uint8List(4), // vendor
    _u16(1), // channels
    _u16(16), // bits per sample
    _u16(0), // compression id
    _u16(0), // packet size
    _u32(audioRate << 16),
    // Mono, as kAudioChannelLayoutTag_Mono
    _box('chan', [_u32(0), _u32(0x00640001), _u32(0), _u32(0)]),
  ]);

  Uint8List _stts(List<int> durations) {
    final runs = <(int, int)>[];
    for (final duration in durations) {
      if (runs.isNotEmpty && runs.last.$2 == duration) {
        runs.last = (runs.last.$1 + 1, duration);
      } else {
        runs.add((1, duration));
      }
    }
    return _box('stts', [
      _u32(0),
      _u32(runs.length),
      for (final (count, duration) in runs) ...[_u32(count), _u32(duration)],
    ]);
  }

  /// One chunk per write of sound: an entry where the number of samples per chunk changes
  Uint8List _audioStsc() {
    final entries = <(int, int)>[];
    for (var i = 0; i < _audioCounts.length; i++) {
      if (entries.isEmpty || entries.last.$2 != _audioCounts[i]) {
        entries.add((i + 1, _audioCounts[i]));
      }
    }
    return _box('stsc', [
      _u32(0),
      _u32(entries.length),
      for (final (first, count) in entries) ...[_u32(first), _u32(count), _u32(1)],
    ]);
  }

  /// 32 bit offsets while the file allows them, 64 bit ones past 4 GiB
  Uint8List _chunkOffsets(List<int> offsets) {
    if (offsets.every((offset) => offset < 0x100000000)) {
      return _box('stco', [_u32(0), _u32(offsets.length), for (final offset in offsets) _u32(offset)]);
    }
    return _box('co64', [
      _u32(0),
      _u32(offsets.length),
      for (final offset in offsets) (ByteData(8)..setUint64(0, offset)).buffer.asUint8List(),
    ]);
  }

  /// The start of the clip in the camera's zone, "2026-09-18T21:00:02+0200", as Apple writes its creation date
  Uint8List _dayAtom() {
    final local = creation.toUtc().add(zoneOffset);
    String two(int value) => value.toString().padLeft(2, '0');
    final minutes = zoneOffset.inMinutes.abs();
    final text =
        '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}T'
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
        '${zoneOffset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}${two(minutes % 60)}';
    final bytes = utf8.encode(text);
    return _box('©day', [_u16(bytes.length), _u16(0x55c4), bytes]);
  }

  void _write(List<int> bytes) {
    _file.writeFromSync(bytes);
    _position += bytes.length;
  }

  static final Uint8List _matrix = () {
    final matrix = ByteData(36)
      ..setUint32(0, 0x00010000)
      ..setUint32(16, 0x00010000)
      ..setUint32(32, 0x40000000);
    return matrix.buffer.asUint8List();
  }();

  static Uint8List _box(String type, List<List<int>> parts) {
    final size = 8 + parts.fold<int>(0, (sum, part) => sum + part.length);
    final out = BytesBuilder(copy: false)
      ..add(_u32(size))
      ..add(latin1.encode(type));
    for (final part in parts) {
      out.add(part);
    }
    return out.takeBytes();
  }

  static Uint8List _u32(int value) => (ByteData(4)..setUint32(0, value & 0xffffffff)).buffer.asUint8List();

  static Uint8List _u16(int value) => (ByteData(2)..setUint16(0, value & 0xffff)).buffer.asUint8List();

  static Uint8List _pascal(String text) => Uint8List.fromList([text.length, ...ascii.encode(text)]);
}
