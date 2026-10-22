// The live playlist of the iPhone and iPad live view, from the H.264 test pattern and the A-law tone: the init
// segment and the fragments parsed back box by box, the samples where the data offsets say, the decode times
// continuous, the IDR pictures as sync samples; the ALAC escape frames bit by bit; the sound placed through RTP-Info,
// its holes filled; the playlist window, its target duration, a new init segment after a discontinuity when the SPS
// changes, and a camera with a very long GOP.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/tapo/hls_live_segmenter.dart';
import 'package:immich_mobile/infrastructure/tapo/rtp_h264.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';

import 'rtp_test_streams.dart';
import 'tapo_test_streams.dart';

/// One box of an MP4 file: its type, the bytes after its header, its offset in the file
class Box {
  Box(this.type, this.body, this.offset);

  final String type;
  final Uint8List body;
  final int offset;

  static const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'mvex', 'moof', 'traf', 'dinf'};

  /// The boxes of [data] from [base] in the file
  static List<Box> parse(Uint8List data, [int base = 0]) {
    final boxes = <Box>[];
    var offset = 0;
    while (offset + 8 <= data.length) {
      final size = ByteData.sublistView(data, offset).getUint32(0);
      expect(size, greaterThanOrEqualTo(8));
      expect(offset + size, lessThanOrEqualTo(data.length), reason: 'a box goes past its parent');
      boxes.add(
        Box(
          ascii.decode(data.sublist(offset + 4, offset + 8)),
          Uint8List.sublistView(data, offset + 8, offset + size),
          base + offset,
        ),
      );
      offset += size;
    }
    expect(offset, data.length, reason: 'bytes after the last box');
    return boxes;
  }

  List<Box> get children {
    expect(_containers, contains(type));
    return parse(body, offset + 8);
  }

  Box child(String name) => children.singleWhere((box) => box.type == name);

  /// The box at [path] ("moov/trak/mdia"), the first of each name
  Box at(String path) {
    var box = this;
    for (final name in path.split('/')) {
      box = box.children.firstWhere((child) => child.type == name);
    }
    return box;
  }

  int u32(int at) => ByteData.sublistView(body).getUint32(at);
  int u16(int at) => ByteData.sublistView(body).getUint16(at);
  int u64(int at) => ByteData.sublistView(body).getUint64(at);
}

/// What a trun says, per sample
typedef Trun = ({int dataOffset, List<int> durations, List<int> sizes, List<int>? flags});

Trun readTrun(Box trun) {
  final flags = trun.u32(0) & 0xffffff;
  final count = trun.u32(4);
  expect(flags & 0x1, 1, reason: 'data offset present');
  final perSample = 4 * ((flags & 0x100 != 0 ? 1 : 0) + (flags & 0x200 != 0 ? 1 : 0) + (flags & 0x400 != 0 ? 1 : 0));
  final durations = <int>[];
  final sizes = <int>[];
  final sampleFlags = <int>[];
  for (var i = 0; i < count; i++) {
    final at = 12 + i * perSample;
    durations.add(trun.u32(at));
    sizes.add(trun.u32(at + 4));
    if (flags & 0x400 != 0) {
      sampleFlags.add(trun.u32(at + 8));
    }
  }
  return (dataOffset: trun.u32(8), durations: durations, sizes: sizes, flags: flags & 0x400 != 0 ? sampleFlags : null);
}

/// The 16 bit samples of an ALAC escape frame (mono, 16 bit), checking its header bits
List<int> readAlacEscape(Uint8List frame, {int frameLength = HlsLiveSegmenter.audioFrameLength}) {
  var position = 0;
  int read(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 1) | ((frame[position >> 3] >> (7 - (position & 7))) & 1);
      position++;
    }
    return value;
  }

  expect(read(3), 0, reason: 'ID_SCE');
  expect(read(4), 0, reason: 'element instance tag');
  expect(read(12), 0, reason: 'unused header bits');
  final partial = read(1);
  expect(read(2), 0, reason: 'bytes shifted');
  expect(read(1), 1, reason: 'escape flag');
  final count = partial == 1 ? read(32) : frameLength;
  final samples = [for (var i = 0; i < count; i++) read(16).toSigned(16)];
  expect(read(3), 7, reason: 'ID_END');
  expect(frame.length, (position + 7) ~/ 8, reason: 'the frame ends on the byte after ID_END');
  return samples;
}

/// The segmenter fed with [loops] of the test pattern (2 s each) and the tone of the same length, in the order of
/// their times; [audioRate] null for the video alone
HlsLiveSegmenter feed({
  int loops = 4,
  int? audioRate = 8000,
  int? videoRtpTime = 3000000,
  int? audioRtpTime = 160000,
  double audioSeconds = -1,
  int audioStartTimestamp = 160000,
  List<HlsSegment>? into,
  HlsLiveSegmenter? segmenter,
}) {
  final hls =
      segmenter ??
      HlsLiveSegmenter(
        audioRate: audioRate,
        videoRtpTime: videoRtpTime,
        audioRtpTime: audioRtpTime,
        onSegment: into?.add,
      );
  final depacketizer = H264Depacketizer(hls.addVideo);
  final video = h264RtpPackets(fixtureNalUnits(loops: loops));
  final audio = audioRate == null
      ? <Uint8List>[]
      : alawRtpPackets(audioSeconds < 0 ? loops * 2.0 : audioSeconds, timestamp: audioStartTimestamp);
  for (final (channel, data) in interleaveByTime(video, audio, audioTimestamp: audioStartTimestamp)) {
    final packet = RtpPacket.parse(data)!;
    if (channel == 0) {
      depacketizer.add(packet);
    } else {
      hls.addAudio(packet.timestamp, Int16List.fromList([for (final byte in packet.payload) alawToPcm16[byte]]));
    }
  }
  return hls;
}

void main() {
  test('writes an init segment with the H.264 and ALAC sample entries', () {
    final hls = feed(loops: 1);
    final boxes = Box.parse(hls.init(0)!);
    expect([for (final box in boxes) box.type], ['ftyp', 'moov']);
    expect(ascii.decode(boxes[0].body.sublist(0, 4)), 'iso5');
    final moov = boxes[1];
    expect([for (final box in moov.children) box.type], ['mvhd', 'trak', 'trak', 'mvex']);
    final traks = moov.children.where((box) => box.type == 'trak').toList();

    final video = traks[0];
    expect(video.child('tkhd').u32(12), 1, reason: 'track id');
    expect(video.child('tkhd').u32(76), 64 << 16, reason: 'width');
    expect(video.child('tkhd').u32(80), 36 << 16, reason: 'height');
    expect(video.at('mdia/mdhd').u32(12), 90000);
    expect(ascii.decode(video.at('mdia/hdlr').body.sublist(8, 12)), 'vide');
    final stsd = video.at('mdia/minf/stbl/stsd');
    expect(stsd.u32(4), 1);
    final avc1 = Box.parse(Uint8List.sublistView(stsd.body, 8)).single;
    expect(avc1.type, 'avc1');
    expect((avc1.u16(24), avc1.u16(26)), (64, 36));
    final avcC = Box.parse(Uint8List.sublistView(avc1.body, 78)).single;
    expect(avcC.type, 'avcC');
    final sps = base64.decode('Z2QACqyyCP8+AiAAAAMAIAAAAwPB4kTJ');
    expect(avcC.body.sublist(0, 4), [1, sps[1], sps[2], sps[3]]);
    expect(avcC.body.sublist(8, 8 + sps.length), sps);

    final audio = traks[1];
    expect(audio.child('tkhd').u32(12), 2);
    expect(audio.at('mdia/mdhd').u32(12), 8000);
    expect(ascii.decode(audio.at('mdia/hdlr').body.sublist(8, 12)), 'soun');
    final alac = Box.parse(Uint8List.sublistView(audio.at('mdia/minf/stbl/stsd').body, 8)).single;
    expect(alac.type, 'alac');
    expect(alac.u16(16), 1, reason: 'channels');
    expect(alac.u16(18), 16, reason: 'bits');
    expect(alac.u32(24), 8000 << 16);
    final cookie = Box.parse(Uint8List.sublistView(alac.body, 28)).single;
    expect(cookie.type, 'alac');
    expect(cookie.u32(4), 4096, reason: 'frame length');
    expect(cookie.body.sublist(8, 14), [0, 16, 40, 10, 14, 1]);
    expect(cookie.u32(24), 8000, reason: 'sample rate');

    final trex = moov.child('mvex').children;
    expect([for (final box in trex) box.u32(4)], [1, 2]);
  });

  test('a playlist without sound has the video track alone', () {
    final hls = feed(loops: 2, audioRate: null);
    final moov = Box.parse(hls.init(0)!)[1];
    expect(moov.children.where((box) => box.type == 'trak'), hasLength(1));
    final segment = Box.parse(hls.segment(0)!.bytes);
    expect(segment[1].children.where((box) => box.type == 'traf'), hasLength(1));
  });

  test('cuts a segment at each IDR picture, with continuous decode times and the sound in escape frames', () {
    final segments = <HlsSegment>[];
    final hls = feed(loops: 4, into: segments);
    // The fourth loop waits for the next IDR picture
    expect(segments, hasLength(3));
    expect(hls.segmentCount, 3);
    var videoTime = 0;
    var audioTime = 0;
    final tone = [for (final byte in toneAlaw(8000 * 8)) alawToPcm16[byte]];
    for (final segment in segments) {
      expect(segment.duration, closeTo(2.0, 0.001));
      final boxes = Box.parse(segment.bytes);
      expect([for (final box in boxes) box.type], ['styp', 'moof', 'mdat']);
      final moof = boxes[1];
      final mdat = boxes[2];
      expect(moof.child('mfhd').u32(4), segment.sequence + 1);
      final trafs = moof.children.where((box) => box.type == 'traf').toList();
      expect(trafs, hasLength(2));

      final video = trafs[0];
      expect(video.child('tfhd').u32(4), 1);
      expect(video.child('tfhd').u32(0) & 0xffffff, 0x020000, reason: 'default-base-is-moof');
      expect(video.child('tfdt').u32(0) >> 24, 1, reason: '64 bit decode time');
      expect(video.child('tfdt').u64(4), videoTime);
      final trun = readTrun(video.child('trun'));
      expect(trun.durations, List.filled(30, 6000));
      expect(trun.flags!.first, 0x02000000, reason: 'the IDR picture is a sync sample');
      expect(trun.flags!.skip(1), everyElement(0x01010000));
      videoTime += trun.durations.fold(0, (a, b) => a + b);
      // The samples are where the offsets say: 4 byte lengths, no parameter sets
      var at = moof.offset + trun.dataOffset;
      expect(at, mdat.offset + 8);
      final fixture = fixtureNalUnits();
      for (var i = 0; i < trun.sizes.length; i++) {
        final sample = Uint8List.sublistView(segment.bytes, at, at + trun.sizes[i]);
        final nals = <List<int>>[];
        var offset = 0;
        while (offset < sample.length) {
          final length = ByteData.sublistView(sample, offset).getUint32(0);
          nals.add(sample.sublist(offset + 4, offset + 4 + length));
          offset += 4 + length;
        }
        expect(nals, [
          for (final nal in fixture[i])
            if (!const {7, 8}.contains(nal[0] & 0x1f)) nal,
        ]);
        at += trun.sizes[i];
      }

      final audio = trafs[1];
      expect(audio.child('tfhd').u32(4), 2);
      expect(audio.child('tfdt').u64(4), audioTime);
      final audioTrun = readTrun(audio.child('trun'));
      expect(audioTrun.flags, isNull);
      expect(audioTrun.durations, everyElement(4096));
      expect(moof.offset + audioTrun.dataOffset, at, reason: 'the sound follows the video in the mdat');
      for (final size in audioTrun.sizes) {
        final frame = Uint8List.sublistView(segment.bytes, at, at + size);
        expect(readAlacEscape(frame), tone.sublist(audioTime, audioTime + 4096), reason: 'frame at $audioTime');
        audioTime += 4096;
        at += size;
      }
      expect(at, mdat.offset + 8 + mdat.body.length);
      // The sound ends within half a frame of the picture
      expect((audioTime - videoTime * 8000 ~/ 90000).abs(), lessThanOrEqualTo(4096));
    }
  });

  test('writes the playlist of the last segments, with a target duration that never goes down', () {
    final hls = HlsLiveSegmenter(audioRate: 8000, window: 3, spare: 1);
    expect(hls.playlist(), isNull);
    feed(loops: 6, segmenter: hls);
    expect(hls.segmentCount, 5);
    expect(
      hls.playlist(),
      '#EXTM3U\n'
      '#EXT-X-VERSION:7\n'
      '#EXT-X-TARGETDURATION:2\n'
      '#EXT-X-MEDIA-SEQUENCE:2\n'
      '#EXT-X-INDEPENDENT-SEGMENTS\n'
      '#EXT-X-MAP:URI="init0.mp4"\n'
      '#EXTINF:2.000,\n'
      'seg2.m4s\n'
      '#EXTINF:2.000,\n'
      'seg3.m4s\n'
      '#EXTINF:2.000,\n'
      'seg4.m4s\n',
    );
    // One segment kept after the window, the older ones gone
    expect(hls.segment(1), isNotNull);
    expect(hls.segment(0), isNull);
    expect(hls.segment(5), isNull);
    expect(hls.init(0), isNotNull);
  });

  test('without RTP-Info, or with one far off, places the sound by its arrival', () {
    final tone = [for (final byte in toneAlaw(4096)) alawToPcm16[byte]];
    for (final (video, audio) in [(null, null), (3000000, 160000 + 8000 * 30)]) {
      final segments = <HlsSegment>[];
      feed(loops: 3, videoRtpTime: video, audioRtpTime: audio, into: segments);
      expect(_firstAlacFrame(segments.first), tone, reason: 'RTP-Info $video $audio');
    }
  });

  test('a sound that starts later is preceded by silence, one that starts earlier is cut', () {
    // The tone starts 0.5 s after the first picture (RTP-Info says so through its time)
    final later = <HlsSegment>[];
    feed(loops: 3, audioRtpTime: 160000 - 4000, into: later);
    var frame = _firstAlacFrame(later.first);
    expect(frame.sublist(0, 4000), everyElement(0));
    expect(frame[4000], isNot(0));

    // ... or 0.25 s before it: its first 2000 samples go
    final earlier = <HlsSegment>[];
    feed(loops: 3, audioRtpTime: 160000 + 2000, into: earlier);
    frame = _firstAlacFrame(earlier.first);
    final tone = [for (final byte in toneAlaw(4096, startSample: 2000)) alawToPcm16[byte]];
    expect(frame, tone);
  });

  test('fills a hole in the sound with silence, and a camera that sends none', () {
    final segments = <HlsSegment>[];
    final hls = HlsLiveSegmenter(audioRate: 8000, videoRtpTime: 3000000, audioRtpTime: 160000, onSegment: segments.add);
    final depacketizer = H264Depacketizer(hls.addVideo);
    final video = h264RtpPackets(fixtureNalUnits(loops: 4));
    // A second of sound, a hole of one packet, then nothing
    final audio = alawRtpPackets(1)..removeAt(3);
    for (final (channel, data) in interleaveByTime(video, audio)) {
      final packet = RtpPacket.parse(data)!;
      if (channel == 0) {
        depacketizer.add(packet);
      } else {
        hls.addAudio(packet.timestamp, Int16List.fromList([for (final byte in packet.payload) alawToPcm16[byte]]));
      }
    }
    final samples = <int>[];
    var audioTime = 0;
    for (final segment in segments) {
      final moof = Box.parse(segment.bytes)[1];
      final traf = moof.children.where((box) => box.type == 'traf').last;
      expect(traf.child('tfdt').u64(4), audioTime);
      final trun = readTrun(traf.child('trun'));
      var at = moof.offset + trun.dataOffset;
      for (final size in trun.sizes) {
        samples.addAll(readAlacEscape(Uint8List.sublistView(segment.bytes, at, at + size)));
        at += size;
        audioTime += 4096;
      }
    }
    // The sound keeps up with the picture (6 s) without the camera
    expect(audioTime, greaterThanOrEqualTo(8000 * 5));
    expect(samples.sublist(3 * 1024, 4 * 1024), everyElement(0), reason: 'the lost packet');
    expect(samples.sublist(4 * 1024, 5 * 1024), isNot(everyElement(0)));
    expect(samples.sublist(8000 + 1024, 8000 * 5), everyElement(0), reason: 'no sound from the camera');
  });

  test('a new SPS starts a new init segment after a discontinuity', () {
    final segments = <HlsSegment>[];
    final hls = HlsLiveSegmenter(audioRate: null, window: 6, onSegment: segments.add);
    final depacketizer = H264Depacketizer(hls.addVideo);
    final units = fixtureNalUnits(loops: 3);
    // The third loop comes with another SPS (another level), as after a change of the picture settings
    for (var i = 60; i < 90; i++) {
      units[i] = [
        for (final nal in units[i])
          if ((nal[0] & 0x1f) == 7) (Uint8List.fromList(nal)..[3] = 0x1e) else nal,
      ];
    }
    for (final data in h264RtpPackets([...units, ...fixtureNalUnits()])) {
      depacketizer.add(RtpPacket.parse(data)!);
    }
    expect(segments.map((segment) => (segment.initVersion, segment.discontinuity)), [
      (0, false),
      (0, false),
      (1, true),
    ]);
    expect(hls.init(1), isNotNull);
    final playlist = hls.playlist()!;
    expect(
      playlist,
      contains(
        '#EXT-X-MAP:URI="init0.mp4"\n'
        '#EXTINF:2.000,\nseg0.m4s\n#EXTINF:2.000,\nseg1.m4s\n'
        '#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI="init1.mp4"\n#EXTINF:2.000,\nseg2.m4s\n',
      ),
    );
    final stsd = Box.parse(hls.init(1)!)[1].at('trak/mdia/minf/stbl/stsd');
    final avc1 = Box.parse(Uint8List.sublistView(stsd.body, 8)).single;
    final avcC = Box.parse(Uint8List.sublistView(avc1.body, 78)).single;
    expect(avcC.body[3], 0x1e, reason: 'the level of the new SPS');
  });

  test('a discontinuity that leaves the window is counted', () {
    final hls = HlsLiveSegmenter(audioRate: null, window: 2, spare: 0);
    final depacketizer = H264Depacketizer(hls.addVideo);
    final units = fixtureNalUnits(loops: 6);
    for (var i = 30; i < 180; i++) {
      units[i] = [
        for (final nal in units[i])
          if ((nal[0] & 0x1f) == 7) (Uint8List.fromList(nal)..[3] = 0x1e) else nal,
      ];
    }
    for (final data in h264RtpPackets(units)) {
      depacketizer.add(RtpPacket.parse(data)!);
    }
    final playlist = hls.playlist()!;
    expect(playlist, contains('#EXT-X-MEDIA-SEQUENCE:3\n#EXT-X-DISCONTINUITY-SEQUENCE:1\n'));
    expect(playlist, contains('#EXT-X-MAP:URI="init1.mp4"\n#EXTINF:2.000,\nseg3.m4s\n'));
    expect(playlist, isNot(contains('#EXT-X-DISCONTINUITY\n')));
    expect(hls.init(0), isNull);
  });

  test('a camera with a very long GOP gets segments cut without an IDR picture', () {
    final hls = HlsLiveSegmenter(audioRate: null, maxSegment: const Duration(milliseconds: 1000));
    final depacketizer = H264Depacketizer(hls.addVideo);
    // One IDR picture, then only the P pictures of the next loops
    final first = fixtureNalUnits();
    final units = [...first, for (var loop = 0; loop < 2; loop++) ...first.skip(1)];
    for (final data in h264RtpPackets(units)) {
      depacketizer.add(RtpPacket.parse(data)!);
    }
    final playlist = hls.playlist()!;
    expect(playlist, isNot(contains('INDEPENDENT-SEGMENTS')));
    expect(hls.segmentCount, greaterThanOrEqualTo(4));
    final second = readTrun(Box.parse(hls.segment(1)!.bytes)[1].at('traf/trun'));
    expect(second.flags!.first, 0x01010000);
    expect(playlist, contains('#EXTINF:1.000,'));
  });

  test('waits for an IDR picture with parameter sets: from the stream, else from the SDP', () {
    final units = fixtureNalUnits(loops: 2);
    // P pictures first, then an IDR picture without its parameter sets
    final withoutSets = [
      ...units.skip(25).take(5),
      for (final unit in units.skip(30))
        [
          for (final nal in unit)
            if (!const {7, 8}.contains(nal[0] & 0x1f)) nal,
        ],
      ...fixtureNalUnits(),
    ];
    final alone = HlsLiveSegmenter(audioRate: null);
    final fromSdp = HlsLiveSegmenter(
      audioRate: null,
      sps: base64.decode('Z2QACqyyCP8+AiAAAAMAIAAAAwPB4kTJ'),
      pps: base64.decode('aOvDyyLA'),
    );
    for (final hls in [alone, fromSdp]) {
      final depacketizer = H264Depacketizer(hls.addVideo);
      for (final data in h264RtpPackets(withoutSets)) {
        depacketizer.add(RtpPacket.parse(data)!);
      }
    }
    // Without the SDP, the stream starts at the second IDR picture, the one with its parameter sets
    expect(alone.started, isTrue);
    expect(alone.segmentCount, 0);
    expect(fromSdp.segmentCount, 1);
  });

  test('writes a partial ALAC frame with its number of samples', () {
    final samples = Int16List.fromList([for (var i = 0; i < 100; i++) (sin(i / 5) * 20000).round()]);
    final frame = alacEscapeFrame(samples);
    expect(readAlacEscape(frame), samples);
    final whole = alacEscapeFrame(Int16List(4096));
    expect(whole.length, alacFrameBytes(4096));
  });
}

List<int> _firstAlacFrame(HlsSegment segment) {
  final moof = Box.parse(segment.bytes)[1];
  final trun = readTrun(moof.children.where((box) => box.type == 'traf').last.child('trun'));
  final at = moof.offset + trun.dataOffset;
  return readAlacEscape(Uint8List.sublistView(segment.bytes, at, at + trun.sizes.first));
}
