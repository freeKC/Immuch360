// What the tests of the engine share: a job for a fixture, a folder for the .part files, small JPEGs made on the fly.

import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:path/path.dart' as p;

import '../codec/codec_fixtures.dart';

/// The path of a fixture of the codec tests
String codecFixturePath(String name) => p.absolute(codecFixtures, name);

/// A job for the file at [path], its sum taken by native_sha1.dart as the queue takes it
ImmersiveJob jobFor(
  String path, {
  required String partPath,
  int quarterTurns = 0,
  int maxEyeWidth = 8192,
  ImmersiveExif exif = const ImmersiveExif(software: 'Immuch360 Desktop 3.3.0'),
  String? sha1,
  bool asBytes = false,
}) {
  final bytes = File(path).readAsBytesSync();
  return ImmersiveJob(
    id: 'job-${p.basename(path)}',
    source: ImmersiveSource(
      name: p.basename(path),
      size: bytes.length,
      sha1: sha1 ?? sha1OfFile(path),
      path: asBytes ? null : path,
      bytes: asBytes ? bytes : null,
    ),
    partPath: partPath,
    derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000001',
    creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
    created: '2026-10-27T10:12:00+01:00',
    quarterTurns: quarterTurns,
    maxEyeWidth: maxEyeWidth,
    exif: exif,
  );
}

/// The hidden .part of the 3D photo of [name] in [folder], as the writer names it
String partIn(Directory folder, String name) =>
    p.join(folder.path, '.${p.basenameWithoutExtension(name)}_3D_LRF_Full_SBS.jpg.4242-1.immuch360.part');

/// A JPEG of [width] x [height] made of a grey of [luma], with a lighter square low in the middle unless not
/// [square], written in [folder]
String syntheticJpeg(
  Directory folder,
  String name, {
  int width = 40,
  int height = 200,
  int luma = 120,
  bool square = true,
}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final inSquare = square && x > width ~/ 3 && x < 2 * width ~/ 3 && y > height ~/ 2;
      final value = inSquare ? (luma + 80).clamp(0, 255) : luma;
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  final path = p.join(folder.path, name);
  File(path).writeAsBytesSync(img.encodeJpg(image, quality: 95));
  return path;
}

/// The left half of each row of [picture]
Uint8List leftEyeOf(SbsPicture picture) {
  final eye = picture.width ~/ 2;
  final out = Uint8List(eye * picture.height * 4);
  for (var y = 0; y < picture.height; y++) {
    out.setRange(y * eye * 4, (y + 1) * eye * 4, picture.rgba, y * picture.width * 4);
  }
  return out;
}

/// The right half of each row of [picture]
Uint8List rightEyeOf(SbsPicture picture) {
  final eye = picture.width ~/ 2;
  final out = Uint8List(eye * picture.height * 4);
  for (var y = 0; y < picture.height; y++) {
    out.setRange(y * eye * 4, (y + 1) * eye * 4, picture.rgba, y * picture.width * 4 + eye * 4);
  }
  return out;
}

/// A JPEG of [width] x [height] of vertical stripes 10 pixels wide, white then black, written in [folder]
String stripesJpeg(Directory folder, String name, {int width = 200, int height = 20}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final value = x % 20 < 10 ? 250 : 5;
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  final path = p.join(folder.path, name);
  File(path).writeAsBytesSync(img.encodeJpg(image, quality: 95));
  return path;
}
