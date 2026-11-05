// Synthetic GoPro files with a GPMF track, for the tests of gopro_motion.dart: GPMF items (KLV: a four character key,
// a type character, the size of one structure, a repeat count, the payload padded to 4 bytes, all big endian), the
// streams of a GoPro MAX payload as the real GS010013.360 lays them out (the head of ACCL and GYRO, SHUT, CORI, IORI,
// GRAV), and an MP4 of a video track and a gpmd track (handler "GoPro MET") whose samples are such payloads, after
// stand ins for the video frames in the media data, the moov box at the end as the camera writes it.

import 'dart:convert';
import 'dart:typed_data';

import '../../domain/services/spherical_probe_fixtures.dart';
import 'gopro_gpmf_frames.dart';

List<int> _be16(int value) => [value >> 8 & 0xff, value & 0xff];

List<int> _be64(int value) => [...mp4Uint32(value ~/ 0x100000000), ...mp4Uint32(value % 0x100000000)];

List<int> _f32(double value) => (ByteData(4)..setFloat32(0, value)).buffer.asUint8List();

/// A GPMF item: [key], the [type] character (0 for nested items), the [size] of one structure and the [repeat] count,
/// then [payload] padded with zeros to a multiple of 4. [repeat] defaults to the length of [payload] over [size].
List<int> gpmfItem(String key, int type, int size, List<int> payload, {int? repeat}) => [
  ...ascii.encode(key),
  type,
  size,
  ..._be16(repeat ?? payload.length ~/ size),
  ...payload,
  ...List.filled((4 - payload.length % 4) % 4, 0),
];

/// Nested items under [key] (DEVC, STRM): type 0, structures of one byte
List<int> gpmfNest(String key, List<List<int>> items) {
  final payload = [for (final item in items) ...item];
  return gpmfItem(key, 0, 1, payload);
}

List<int> gpmfString(String key, String value) => gpmfItem(key, 0x63, 1, latin1.encode(value));

/// Rows of int16 values (type s), one structure a row
List<int> gpmfInt16Rows(String key, List<List<int>> rows) =>
    gpmfItem(key, 0x73, 2 * (rows.isEmpty ? 1 : rows.first.length), [
      for (final row in rows)
        for (final value in row) ..._be16(value & 0xffff),
    ], repeat: rows.length);

List<int> gpmfFloats(String key, List<double> values) =>
    gpmfItem(key, 0x66, 4, [for (final value in values) ..._f32(value)]);

List<int> gpmfUint32(String key, int value) => gpmfItem(key, 0x4c, 4, mp4Uint32(value));

List<int> gpmfUint64(String key, int value) => gpmfItem(key, 0x4a, 8, _be64(value));

/// A SCAL of int16 divisors (one, or one per element)
List<int> gpmfScale(List<int> divisors) =>
    gpmfItem('SCAL', 0x73, 2, [for (final divisor in divisors) ..._be16(divisor)]);

/// The head of the ACCL or GYRO stream of the real first payload: its timestamps, name, orientation, scale and three
/// samples
List<int> goProImuStream(String key) => gpmfNest('STRM', [
  gpmfUint64('STMP', key == 'ACCL' ? 183669 : 184083),
  gpmfUint32('TSMP', key == 'ACCL' ? 198 : 793),
  gpmfString('STNM', key == 'ACCL' ? goProAcclName : goProGyroName),
  gpmfString('ORIN', key == 'ACCL' ? goProAcclOrin : goProGyroOrin),
  gpmfScale([key == 'ACCL' ? goProAcclScale : goProGyroScale]),
  gpmfInt16Rows(key, key == 'ACCL' ? goProAcclFirst : goProGyroFirst),
]);

/// One stream of [rows] of int16 under [key], scaled by [scale] (one divisor, or one per element)
List<int> goProRowStream(String key, String name, List<List<int>> rows, {List<int> scale = const [32767]}) =>
    gpmfNest('STRM', [
      gpmfUint64('STMP', 184952),
      gpmfUint32('TSMP', rows.length),
      gpmfString('STNM', name),
      gpmfScale(scale),
      gpmfInt16Rows(key, rows),
    ]);

/// The SHUT stream: one exposure in seconds a frame
List<int> goProShutStream(List<double> exposures) => gpmfNest('STRM', [
  gpmfUint64('STMP', 184952),
  gpmfUint32('TSMP', exposures.length),
  gpmfString('STNM', 'Exposure time (shutter speed)'),
  gpmfString('SIUN', 's'),
  gpmfFloats('SHUT', exposures),
]);

/// A GPMF payload as a GoPro MAX writes it: DEVC with its id and name, then the streams. [cori] null leaves CORI out,
/// [grav] or [shut] null leave GRAV or SHUT out; [gravScale] the SCAL of GRAV; [extra] more streams at the end.
List<int> goProPayload({
  List<List<int>>? cori,
  List<List<int>>? grav,
  List<double>? shut,
  List<int> gravScale = const [32767],
  bool withImu = true,
  String name = goProMaxName,
  List<List<int>> extra = const [],
}) => gpmfNest('DEVC', [
  gpmfUint32('DVID', 1),
  gpmfString('DVNM', name),
  if (withImu) ...[goProImuStream('ACCL'), goProImuStream('GYRO')],
  if (shut != null) goProShutStream(shut),
  if (cori != null) goProRowStream('CORI', 'CameraOrientation', cori),
  if (cori != null)
    goProRowStream('IORI', 'ImageOrientation', [
      for (var i = 0; i < cori.length; i++) [32767, 0, 0, 0],
    ]),
  if (grav != null) goProRowStream('GRAV', 'Gravity Vector', grav, scale: gravScale),
  ...extra,
]);

/// A GoPro file: ftyp, the media data (for each payload, [frameStandIn] bytes standing for its video frames, then the
/// payload), then the moov box: a video track of [videoFrames] frames at 30000 / 1001 fps (90 kHz, 3003 ticks a frame)
/// unless [withVideo] is false, then the gpmd track, its samples [payloadTicks] long in a time scale of 1000 (1001 by
/// default, as the camera writes them), [perChunk] samples in a chunk, its chunk offsets as co64 when [co64]. [entry]
/// is the type of the sample entry of the metadata track and [handlerName] the name of its handler. [moovPadding]
/// pads the moov box with a free box.
Uint8List goProMotionFile(
  List<List<int>> payloads, {
  int? videoFrames,
  bool withVideo = true,
  List<int>? payloadTicks,
  int perChunk = 1,
  bool co64 = false,
  String entry = 'gpmd',
  String handlerName = 'GoPro MET',
  int frameStandIn = 64,
  int moovPadding = 0,
  String firmware = goProMaxFirmware,
}) {
  final mdatStart = mp4Ftyp.length + 8;
  final media = <int>[];
  final offsets = <int>[];
  for (var i = 0; i < payloads.length; i++) {
    // A chunk of [perChunk] payloads after the video stand in
    if (i % perChunk == 0) {
      media.addAll(List.filled(frameStandIn, 0x11));
      offsets.add(mdatStart + media.length);
    }
    media.addAll(payloads[i]);
  }
  final sizes = [for (final payload in payloads) payload.length];
  final ticks = payloadTicks ?? List.filled(payloads.length, 1001);
  final frames = videoFrames ?? 30 * payloads.length;
  final tracks = [
    if (withVideo)
      _track(
        handlerType: 'vide',
        handlerName: 'GoPro H.265',
        entry: 'hvc1',
        timescale: 90000,
        timeToSample: [(frames, 3003)],
        sizes: List.filled(frames, 16),
        chunkOffsets: List.filled(frames, mdatStart),
        perChunk: 1,
        co64: false,
      ),
    _track(handlerType: 'soun', handlerName: 'GoPro AAC', entry: 'mp4a', timescale: 48000),
    _track(
      handlerType: 'meta',
      handlerName: handlerName,
      entry: entry,
      timescale: 1000,
      timeToSample: [for (final tick in ticks) (1, tick)],
      sizes: sizes,
      chunkOffsets: offsets,
      perChunk: perChunk,
      co64: co64,
    ),
  ];
  final moov = mp4Box('moov', [
    ...mp4FullBox('mvhd', mp4Zeros(96)),
    ...mp4Box('udta', mp4Box('FIRM', ascii.encode(firmware))),
    for (final track in tracks) ...track,
    if (moovPadding > 0) ...mp4Box('free', mp4Zeros(moovPadding)),
  ]);
  return Uint8List.fromList([...mp4Ftyp, ...mp4Box('mdat', media), ...moov]);
}

List<int> _track({
  required String handlerType,
  required String handlerName,
  required String entry,
  required int timescale,
  List<(int, int)> timeToSample = const [],
  List<int> sizes = const [],
  List<int> chunkOffsets = const [],
  int perChunk = 1,
  bool co64 = false,
}) => mp4Box('trak', [
  ...mp4Tkhd(),
  ...mp4Box('mdia', [
    ...mp4Mdhd(timescale: timescale),
    ...mp4Hdlr(handlerType, name: handlerName, counted: true),
    ...mp4Box('minf', [
      ...mp4Box('stbl', [
        ...mp4FullBox('stsd', [...mp4Uint32(1), ...mp4Box(entry, mp4Zeros(16))]),
        ...mp4Stts(timeToSample),
        ...mp4FullBox('stsc', [...mp4Uint32(1), ...mp4Uint32(1), ...mp4Uint32(perChunk), ...mp4Uint32(1)]),
        ...mp4Stsz(sizes: sizes),
        if (co64)
          ...mp4FullBox('co64', [
            ...mp4Uint32(chunkOffsets.length),
            for (final offset in chunkOffsets) ..._be64(offset),
          ])
        else
          ...mp4FullBox('stco', [
            ...mp4Uint32(chunkOffsets.length),
            for (final offset in chunkOffsets) ...mp4Uint32(offset),
          ]),
      ]),
    ]),
  ]),
]);
