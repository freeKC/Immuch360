// Synthetic GoPro .360 files for the tests of the probe and of the EAC geometry: the moov box of a GoPro MAX recording,
// as the real GS010013.360 has it (docs/18-design-projections-and-parsers.md, section 10.1). Seven tracks: video 1
// (hvc1, "GoPro H.265"), the sound, the timecode, two metadata tracks, video 6, then the ambisonic sound. The handler
// names are counted strings, as QuickTime writes them.

import 'dart:typed_data';

import '../../domain/services/spherical_probe_fixtures.dart';

List<int> _goProVideo(int trackId, int width, int height, int bitDepth) => mp4VideoTrack(
  [],
  width: width,
  height: height,
  config: mp4HvcC(profile: bitDepth == 10 ? 2 : 1, bitDepth: bitDepth),
  timescale: 30000,
  timeToSample: [(30, 1001)],
  trackId: trackId,
  handlerType: 'vide',
  handlerName: 'GoPro H.265',
  countedHandlerName: true,
  durationTicks: 30030,
);

List<int> _goProTrack(String entryType, String handlerType, String handlerName, int trackId) => mp4Track(
  mp4FullBox('stsd', [...mp4Uint32(1), ...mp4Box(entryType, mp4Zeros(28))]),
  trackId: trackId,
  handlerType: handlerType,
  handlerName: handlerName,
  countedHandlerName: true,
);

/// The moov box of a GoPro .360 whose two video tracks are [width] x [height] (4096 x 1344 on the MAX, 5888 x 1920 or
/// 5952 x 1920 on the MAX 2); [secondWidth] gives the second video track another width
List<int> goProMoov({int width = 4096, int height = 1344, int? secondWidth, int bitDepth = 8}) => mp4Moov([
  _goProVideo(1, width, height, bitDepth),
  _goProTrack('mp4a', 'soun', 'GoPro AAC', 2),
  _goProTrack('tmcd', 'tmcd', 'GoPro TCD', 3),
  _goProTrack('gpmd', 'meta', 'GoPro MET', 4),
  _goProTrack('fdsc', 'meta', 'GoPro SOS', 5),
  _goProVideo(6, secondWidth ?? width, height, bitDepth),
  _goProTrack('in32', 'soun', 'GoPro AMB', 7),
]);

/// A GoPro .360 file: ftyp, the media data, then the moov box of [goProMoov]
Uint8List goProFile({int width = 4096, int height = 1344, int? secondWidth, int bitDepth = 8}) =>
    mp4File(goProMoov(width: width, height: height, secondWidth: secondWidth, bitDepth: bitDepth), moovAtEnd: true);
