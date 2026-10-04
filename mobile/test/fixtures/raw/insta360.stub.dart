// Synthetic Insta360 files for the tests of the trailer reader: a JPEG stub, protobuf metadata, the records of a trailer
// and its fixed tail, and the head of a photo whose EXIF names the camera and whose MakerNote holds one IMU sample as
// ASCII. The calibration strings are those of a real X3 (firmware v1.0.93), as the research report on the formats gives
// them.

import 'dart:convert';
import 'dart:typed_data';

const x3Serial = 'IAQFB24035RBRX';
const x3Model = 'Insta360 X3';
const x3Firmware = 'v1.0.93_build1';

const x3OffsetV1 =
    '2_2905.880_2960.630_3009.220_0.171_0.125_89.532_2897.780_8937.430_3000.010_-0.013_-0.020_89.463_11904_5952_2887';

const x3OffsetV3 =
    '2_1.948170_4627.540_4627.460_2967.480_2999.850_-0.029_-0.038_89.510_0.000000_0.000000_0.000000_0.38808271_'
    '1.29547262_-3.96876335_0.00178320_-0.00158561_11904_5952_71_1.948170_4615.530_4615.530_8933.200_2998.620_-0.030_'
    '-0.086_89.487_-0.000275_0.000160_-0.026903_0.39306432_1.25673521_-3.90715361_-0.00147705_0.00090004_11904_5952_71_'
    '199424';

/// The MakerNote text of the same X3 photo: accelerometer in g, then gyroscope
const x3MakerNote = '-1.003906_-0.124023_0.082031_0.024501_0.007457_0.053263';

List<int> u16le(int value) => [value & 0xff, value >> 8 & 0xff];

List<int> u32le(int value) => [value & 0xff, value >> 8 & 0xff, value >> 16 & 0xff, value >> 24 & 0xff];

List<int> u64le(int value) => [for (var shift = 0; shift < 64; shift += 8) value >> shift & 0xff];

List<int> f32le(double value) => (ByteData(4)..setFloat32(0, value, Endian.little)).buffer.asUint8List();

List<int> f64le(double value) => (ByteData(8)..setFloat64(0, value, Endian.little)).buffer.asUint8List();

// Protobuf encoding

List<int> pbVarint(int value) {
  final bytes = <int>[];
  var rest = value;
  for (var i = 0; i < 10; i++) {
    final byte = rest & 0x7f;
    // Unsigned shift: negative values take 10 bytes, as protobuf writes them
    rest = rest >>> 7;
    if (rest == 0) {
      bytes.add(byte);
      return bytes;
    }
    bytes.add(byte | 0x80);
  }
  return bytes;
}

List<int> pbKey(int field, int wireType) => pbVarint(field << 3 | wireType);

List<int> pbVarintField(int field, int value) => [...pbKey(field, 0), ...pbVarint(value)];

List<int> pbBytesField(int field, List<int> bytes) => [...pbKey(field, 2), ...pbVarint(bytes.length), ...bytes];

List<int> pbStringField(int field, String value) => pbBytesField(field, utf8.encode(value));

List<int> pbFloatField(int field, double value) => [...pbKey(field, 5), ...f32le(value)];

List<int> pbDoubleField(int field, double value) => [...pbKey(field, 1), ...f64le(value)];

/// The metadata record of an X3 photo, with fields the reader skips around the ones it reads. [floatRanges] writes the
/// ranges of the IMU as floats, as the schema has them, rather than as the varints of the X3.
List<int> x3Metadata({
  String? offsetV1 = x3OffsetV1,
  String? offsetV3 = x3OffsetV3,
  bool? rawGyro = true,
  bool withRanges = true,
  bool floatRanges = false,
}) => [
  ...pbStringField(1, x3Serial),
  ...pbStringField(2, x3Model),
  ...pbStringField(3, x3Firmware),
  if (offsetV1 != null) ...pbStringField(5, offsetV1),
  // Skipped: the offset of the trailer, a negative varint, a double
  ...pbVarintField(9, 21971125),
  ...pbVarintField(10, -1),
  if (offsetV1 != null) ...pbStringField(17, '2_1_1_1_0_0_0_1_1_1_0_0_0_2_1_0'),
  ...pbBytesField(19, [...pbVarintField(1, 11968), ...pbVarintField(2, 5984)]),
  ...pbDoubleField(25, 4.576444625854492),
  ...pbBytesField(27, [
    ...pbVarintField(1, 5952),
    ...pbVarintField(2, 5952),
    ...pbVarintField(3, 5984),
    ...pbVarintField(4, 5984),
  ]),
  if (offsetV3 != null) ...pbStringField(54, offsetV3),
  // Skipped: the rotation of the photo, nine floats
  for (final value in [-0.9976, 0.0549, 0.0415, -0.0578, -0.9958, -0.0716, 0.0373, -0.0738, 0.9966])
    ...pbFloatField(60, value),
  if (rawGyro != null) ...pbVarintField(62, rawGyro ? 1 : 0),
  if (withRanges)
    ...pbBytesField(
      65,
      floatRanges
          ? [...pbFloatField(1, 16), ...pbFloatField(2, 1000)]
          : [...pbVarintField(1, 32), ...pbVarintField(2, 2000)],
    ),
  ...pbVarintField(68, 0),
];

// Trailer

/// A record of a trailer: its payload, then its footer
List<int> insta360Record(int id, List<int> payload, {int format = 0}) => [
  ...payload,
  format,
  id,
  ...u32le(payload.length),
];

/// The bytes of a JPEG of no consequence: start and end of the image
const jpegStub = [0xff, 0xd8, 0xff, 0xd9];

/// A file of [body] followed by a trailer of [records], in the order of the file (the last one ends next to the tail)
Uint8List insta360File(
  List<List<int>> records, {
  List<int> body = jpegStub,
  int version = 3,
  String magic = '8db42d694ccc418790edff439fe026bf',
  int? trailerLength,
}) {
  final payload = [for (final record in records) ...record];
  return Uint8List.fromList([
    ...body,
    ...payload,
    ...List.filled(32, 0),
    ...u32le(trailerLength ?? payload.length + 72),
    ...u32le(version),
    ...ascii.encode(magic),
  ]);
}

/// Raw IMU samples (20 bytes each) with the given raw accelerometer values and a still gyroscope
List<int> rawImuSamples(List<(int, int, int)> accelerometer) => [
  for (var i = 0; i < accelerometer.length; i++) ...[
    ...u64le(1000 * i),
    ...u16le(accelerometer[i].$1),
    ...u16le(accelerometer[i].$2),
    ...u16le(accelerometer[i].$3),
    ...u16le(32768),
    ...u16le(32768),
    ...u16le(32768),
  ],
];

/// IMU samples of doubles (56 bytes each) with the given accelerometer values in g and a still gyroscope
List<int> imuSamples(List<(double, double, double)> accelerometer) => [
  for (var i = 0; i < accelerometer.length; i++) ...[
    ...u64le(i),
    ...f64le(accelerometer[i].$1),
    ...f64le(accelerometer[i].$2),
    ...f64le(accelerometer[i].$3),
    ...f64le(0),
    ...f64le(0),
    ...f64le(0),
  ],
];

// EXIF

/// The head of a photo: start of the image, then an APP1 segment of EXIF whose IFD0 has Make "Arashi Vision", the
/// Model [model] when given, and a pointer to an Exif IFD whose MakerNote holds [makerNote] as ASCII padded with zeros,
/// and whose BodySerialNumber is [serial] when given (the X3 writes none), then the start of the scan. [app0] puts a
/// JFIF segment before the EXIF.
Uint8List insta360PhotoHead({
  String makerNote = x3MakerNote,
  String? model = x3Model,
  String? serial,
  bool bigEndian = false,
  bool app0 = false,
}) {
  List<int> u16(int value) => bigEndian ? [value >> 8 & 0xff, value & 0xff] : u16le(value);
  List<int> u32(int value) => bigEndian ? u32le(value).reversed.toList() : u32le(value);
  List<int> entry(int tag, int type, int count, int value) => [
    ...u16(tag),
    ...u16(type),
    ...u32(count),
    // A short value sits in the first bytes of the field, whatever the byte order
    ...(type == 3 && count == 1 ? [...u16(value), 0, 0] : u32(value)),
  ];
  // ASCII values ending with a NUL, as EXIF writes them; all longer than 4 bytes here, so out of their entries
  List<int>? text(String? value) => value == null ? null : [...ascii.encode(value), 0];

  final make = text('Arashi Vision')!;
  final modelText = text(model);
  final serialText = text(serial);
  final note = [...ascii.encode(makerNote), ...List.filled(192 - makerNote.length, 0)];
  final ifd0Entries = modelText == null ? 3 : 4;
  final exifEntries = serialText == null ? 2 : 3;
  // TIFF header (8), IFD0 (2 + 12 per entry + 4), Exif IFD (the same), then the values
  const ifd0 = 8;
  final exifIfd = ifd0 + 2 + 12 * ifd0Entries + 4;
  final makeOffset = exifIfd + 2 + 12 * exifEntries + 4;
  final modelOffset = makeOffset + make.length;
  final serialOffset = modelOffset + (modelText?.length ?? 0);
  final noteOffset = serialOffset + (serialText?.length ?? 0);
  // The entries of each IFD in the order of their tags, as TIFF has them
  final tiff = [
    ...(bigEndian ? ascii.encode('MM') : ascii.encode('II')),
    ...u16(42),
    ...u32(ifd0),
    ...u16(ifd0Entries),
    ...entry(0x010f, 2, make.length, makeOffset),
    if (modelText != null) ...entry(0x0110, 2, modelText.length, modelOffset),
    ...entry(0x0112, 3, 1, 1),
    ...entry(0x8769, 4, 1, exifIfd),
    ...u32(0),
    ...u16(exifEntries),
    ...entry(0x9000, 7, 4, 0x30323230),
    ...entry(0x927c, 7, note.length, noteOffset),
    if (serialText != null) ...entry(0xa431, 2, serialText.length, serialOffset),
    ...u32(0),
    ...make,
    ...?modelText,
    ...?serialText,
    ...note,
  ];
  final exif = [...ascii.encode('Exif'), 0, 0, ...tiff];
  final jfif = [...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0];
  return Uint8List.fromList([
    0xff,
    0xd8,
    if (app0) ...[
      0xff,
      0xe0,
      ...[(jfif.length + 2) >> 8, (jfif.length + 2) & 0xff],
      ...jfif,
    ],
    0xff,
    0xe1,
    (exif.length + 2) >> 8,
    (exif.length + 2) & 0xff,
    ...exif,
    0xff,
    0xda,
    0,
    2,
  ]);
}
