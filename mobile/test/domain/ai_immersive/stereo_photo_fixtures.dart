// Small photo files for the tests of the side by side probe: the head of a JPEG with its frame and, when asked, our
// XMP; the head of a PNG or a WebP. Only what the probe reads is real; the image data is zeros.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

/// Our packet for a photo of [eyeWidth] x [eyeHeight] pixels per eye, made from [sourceName]
StereoPhotoXmp ourXmp({
  int eyeWidth = 4000,
  int eyeHeight = 3000,
  String sourceName = 'salon.jpg',
  StereoEyes eyes = StereoEyes.full,
  EyeOrder eyeOrder = EyeOrder.leftRight,
  int formatVersion = immersiveFormatVersion,
}) => StereoPhotoXmp(
  formatVersion: formatVersion,
  eyes: eyes,
  eyeOrder: eyeOrder,
  eyeWidth: eyeWidth,
  eyeHeight: eyeHeight,
  leftEye: LeftEyeSource.original,
  origin: ImmersiveOrigin.estimatedDepth,
  depthModel: depthModelName,
  depthModelSha256: depthModelOnnxSha256,
  pipeline: ReliefV1.pipeline,
  parallax: ReliefV1.parallax,
  convergence: ReliefV1.convergence,
  derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000000',
  sourceName: sourceName,
  sourceSize: 4182311,
  sourceSha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=',
  sourceQuarterTurns: 0,
  created: '2026-10-27T10:12:00+01:00',
  creatorTool: 'Immuch360 Desktop 3.3.0 (windows)',
  description: stereoPhotoDescription,
);

/// The SOF0 segment of a picture of [width] x [height] pixels, three components
Uint8List sof0(int width, int height) => Uint8List.fromList([
  0xff,
  0xc0,
  0,
  17,
  8,
  height >> 8,
  height & 0xff,
  width >> 8,
  width & 0xff,
  3,
  ...List.filled(9, 1),
]);

/// A JPEG of [width] x [height] pixels: SOI, the APP1 XMP of [xmp] (or the packet [xmpText]) when given, any [segments],
/// the frame, then [dataLength] bytes of image data and EOI
Uint8List jpegFile({
  required int width,
  required int height,
  StereoPhotoXmp? xmp,
  String? xmpText,
  List<Uint8List> segments = const [],
  int dataLength = 1024,
}) {
  final packet = xmpText ?? xmp?.toXml();
  return Uint8List.fromList([
    0xff,
    0xd8,
    if (packet != null) ...xmpApp1Segment(packet),
    for (final segment in segments) ...segment,
    ...sof0(width, height),
    0xff,
    0xda,
    ...List.filled(dataLength, 0),
    0xff,
    0xd9,
  ]);
}

/// A GPano packet in an APP1 segment, declaring an equirectangular projection
Uint8List gpanoSegment() => xmpApp1Segment(
  '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
  '<rdf:Description xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" GPano:ProjectionType="equirectangular"/>'
  '</rdf:RDF></x:xmpmeta>',
);

/// A PNG of [width] x [height] pixels as iw3 writes them: its signature, IHDR, then zeros
Uint8List pngFile({required int width, required int height, int dataLength = 1024}) {
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  return Uint8List.fromList([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
    0, 0, 0, 13, ...ascii.encode('IHDR'), ...ihdr.buffer.asUint8List(), 0, 0, 0, 0,
    ...List.filled(dataLength, 0),
  ]);
}
